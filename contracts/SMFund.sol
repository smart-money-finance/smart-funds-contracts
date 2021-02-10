// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import 'hardhat/console.sol';

import './SMFundFactory.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, 
// should manager have admin power to reassign investments to different addresses?

contract SMFund is Context, ERC20 {
  using SafeMath for uint256;
  using ECDSA for bytes32;
  using SafeERC20 for ERC20;

  SMFundFactory public factory;
  address public immutable manager;
  address public immutable aumUpdater;
  uint256 public timelock;
  uint256 public managementFee; // basis points
  uint256 public performanceFee; // basis points
  bool public investmentsEnabled;
  bool public immutable signedAum;
  bool public initialized;
  string public logoUrl;

  // uint256[] public aums;
  uint256 public aum;

  struct Investor {
    bool whitelisted;
    string name;
  }

  mapping(address => Investor) public whitelist;

  struct Investment {
    address investor;
    uint256 initialUsdTokenAmount;
    uint256 usdTokenFeesCollected;
    uint256 usdPerformanceFeesCollected;
    uint256 usdManagementFeesCollected;
    uint256 initialFundAmount;
    uint256 fundAmount;
    uint256 timestamp;
    uint256 lastFeeTimestamp;
    bool redeemed;
  }

  Investment[] public investments;
  uint256 public activeInvestmentCount;

  event NavUpdated(uint256 aum, uint256 totalSupply);
  event Whitelisted(address indexed investor, string name);
  event Blacklisted(address indexed investor);
  event Invested(
    address indexed investor,
    uint256 usdTokenAmount,
    uint256 fundAmount,
    uint256 investmentId
  );
  event RedemptionRequested(
    address indexed investor,
    uint256 minUsdTokenAmount,
    uint256[] investmentIds
  );
  event Redeemed(
    address indexed investor,
    uint256 fundAmount,
    uint256 usdTokenAmount,
    uint256[] investmentIds
  );
  event FeesCollected(
    uint256 fundAmount,
    uint256 usdTokenAmount,
    uint256[] investmentIds
  );
  event FeesWithdrawn(address indexed to, uint256 usdTokenAmount);

  constructor(
    address _manager,
    address _aumUpdater,
    bool _signedAum,
    string memory name,
    string memory symbol,
    string memory _logoUrl
  ) ERC20(name, symbol) {
    factory = SMFundFactory(_msgSender());
    _setupDecimals(factory.usdToken().decimals());
    manager = _manager;
    aumUpdater = _aumUpdater;
    signedAum = _signedAum;
    logoUrl = _logoUrl;
  }

  modifier onlyManager() {
    require(_msgSender() == manager, 'Not manager');
    _;
  }

  modifier onlyAumUpdater() {
    require(_msgSender() == aumUpdater, 'Not AUM updater');
    _;
  }

  modifier notClosed() {
    require(totalSupply() != 0, 'Fund is closed');
    _;
  }

  modifier onlyInvestmentsEnabled() {
    require(investmentsEnabled, 'Investments are disabled');
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[_msgSender()].whitelisted == true, 'Not whitelisted');
    _;
  }

  modifier onlyBefore(uint256 deadline) {
    require(block.timestamp <= deadline, 'Past deadline');
    _;
  }

  modifier onlyInitialized() {
    require(initialized, 'Not initialized');
    _;
  }

  modifier onlyNotInitialized() {
    require(!initialized, 'Already initialized');
    _;
  }

  function initialize(
    uint256 _timelock,
    uint256 _managementFee,
    uint256 _performanceFee,
    bool _investmentsEnabled,
    uint256 initialAum,
    address initialInvestor,
    string calldata initialInvestorName,
    uint256 deadline,
    bytes memory signature
  ) public onlyNotInitialized onlyAumUpdater onlyBefore(deadline) {
    require(initialAum > 0);
    timelock = _timelock;
    managementFee = _managementFee;
    performanceFee = _performanceFee;
    investmentsEnabled = _investmentsEnabled;
    _addToWhitelist(initialInvestor, initialInvestorName);
    _addInvestment(initialInvestor, initialAum, 1);
    verifyAumSignature(deadline, signature);
    initialized = true;
  }

  function verifyAumSignature(uint256 deadline, bytes memory signature)
    internal
    view
  {
    if (signedAum) {
      bytes32 message = keccak256(abi.encode(manager, aum, deadline));
      address signer = message.toEthSignedMessageHash().recover(signature);
      require(signer == factory.owner(), 'Signer mismatch');
    }
  }

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    bytes calldata signature
  ) public onlyInitialized onlyAumUpdater onlyBefore(deadline) {
    aum = _aum;
    verifyAumSignature(deadline, signature);
    emit NavUpdated(_aum, totalSupply());
  }

  function whitelistMulti(address[] calldata investors, string[] calldata names)
    public
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      _addToWhitelist(investors[i], names[i]);
    }
  }

  function _addToWhitelist(address investor, string calldata name) private {
    whitelist[investor] = Investor({ whitelisted: true, name: name });
    emit Whitelisted(investor, name);
  }

  function blacklistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      delete whitelist[investors[i]];
      emit Blacklisted(investors[i]);
    }
  }

  function invest(
    uint256 usdTokenAmount,
    uint256 minFundAmount,
    uint256 deadline
  )
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyWhitelisted
    onlyBefore(deadline)
  {
    _addInvestment(_msgSender(), usdTokenAmount, minFundAmount);
  }

  function _addInvestment(
    address investor,
    uint256 usdTokenAmount,
    uint256 minFundAmount
  ) internal {
    require(usdTokenAmount > 0 && minFundAmount > 0, 'Amount is 0');
    uint256 investmentId = investments.length;
    uint256 fundAmount;
    // if intialization investment, use price of 1 cent
    if (investmentId == 0) {
      fundAmount = usdTokenAmount.mul(100);
    } else {
      fundAmount = usdTokenAmount.mul(totalSupply()).div(aum);
    }
    require(fundAmount >= minFundAmount, 'Less than min fund amount');
    // don't transfer tokens if it's the initialization investment
    if (investmentId != 0) {
      factory.usdToken().safeTransferFrom(investor, manager, usdTokenAmount);
    }
    aum = aum.add(usdTokenAmount);
    _mint(investor, fundAmount);
    investments.push(
      Investment({
        investor: investor,
        initialUsdTokenAmount: usdTokenAmount,
        usdTokenFeesCollected: 0,
        usdPerformanceFeesCollected: 0,
        usdManagementFeesCollected: 0,
        initialFundAmount: fundAmount,
        fundAmount: fundAmount,
        timestamp: block.timestamp,
        lastFeeTimestamp: 0,
        redeemed: false
      })
    );
    activeInvestmentCount++;
    emit Invested(investor, usdTokenAmount, fundAmount, investmentId);
    emit NavUpdated(aum, totalSupply());
  }

  function requestRedemption(
    uint256 minUsdTokenAmount,
    uint256[] calldata investmentIds,
    uint256 deadline
  )
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyWhitelisted
    onlyBefore(deadline)
  {
    address sender = _msgSender();
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.investor == sender, "Not sender's investment");
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.timestamp.add(timelock) <= block.timestamp,
        'Time locked'
      );
    }
    emit RedemptionRequested(sender, minUsdTokenAmount, investmentIds);
  }

  function processRedemptions(
    uint256[] calldata investmentIds,
    uint256 minUsdTokenAmount,
    uint256 deadline
  )
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    if (activeInvestmentCount == 1 && investmentIds.length == 1) {
      // close out fund, don't transfer any AUM, let the fund manager do it manually
      require(aum >= minUsdTokenAmount, 'Less than min usd amount');
      Investment storage investment = investments[investmentIds[0]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.timestamp.add(timelock) <= block.timestamp,
        'Time locked'
      );
      (uint256 fundBurned, uint256 usdTokenCollected) =
        _extractFees(investment);
      investment.redeemed = true;
      activeInvestmentCount--;
      _burn(investment.investor, investment.fundAmount);
      uint256 finalAum = aum;
      aum = 0;
      emit FeesCollected(fundBurned, usdTokenCollected, investmentIds);
      emit Redeemed(
        investment.investor,
        investment.fundAmount,
        finalAum,
        investmentIds
      );
      emit NavUpdated(aum, totalSupply());
      return;
    }
    address investor = investments[investmentIds[0]].investor;
    uint256 usdTokenAmount = 0;
    uint256 fundAmount = 0;
    uint256 totalFundFeesBurned = 0;
    uint256 totalUsdTokenFeesCollected = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      require(
        investmentIds[i] != 0,
        'Initial investment must be redeemed separately'
      );
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.timestamp.add(timelock) <= block.timestamp,
        'Time locked'
      );
      require(investment.investor == investor, 'Not from one investor');
      (uint256 fundBurned, uint256 usdTokenCollected) =
        _extractFees(investment);
      totalFundFeesBurned = totalFundFeesBurned.add(fundBurned);
      totalUsdTokenFeesCollected = totalUsdTokenFeesCollected.add(
        usdTokenCollected
      );
      investment.redeemed = true;
      activeInvestmentCount--;
      fundAmount = investment.fundAmount.add(fundAmount);
      // TODO: does total supply and/or aum changing every loop affect the math?
      usdTokenAmount = investment.fundAmount.mul(aum).div(totalSupply()).add(
        usdTokenAmount
      );
    }
    require(usdTokenAmount >= minUsdTokenAmount, 'Less than min usd amount');
    _burn(investor, fundAmount);
    aum = aum.sub(usdTokenAmount);
    factory.usdToken().safeTransferFrom(manager, investor, usdTokenAmount);
    emit FeesCollected(
      totalFundFeesBurned,
      totalUsdTokenFeesCollected,
      investmentIds
    );
    emit Redeemed(investor, fundAmount, usdTokenAmount, investmentIds);
    emit NavUpdated(aum, totalSupply());
  }

  function processFees(uint256[] calldata investmentIds, uint256 deadline)
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    uint256 totalFundFeesBurned = 0;
    uint256 totalUsdTokenFeesCollected = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.lastFeeTimestamp.add(30 days) <= block.timestamp,
        'Fee last collected less than a month ago'
      );
      (uint256 fundBurned, uint256 usdTokenCollected) =
        _extractFees(investment);
      totalFundFeesBurned = totalFundFeesBurned.add(fundBurned);
      totalUsdTokenFeesCollected = totalUsdTokenFeesCollected.add(
        usdTokenCollected
      );
    }
    emit FeesCollected(
      totalFundFeesBurned,
      totalUsdTokenFeesCollected,
      investmentIds
    );
    emit NavUpdated(aum, totalSupply());
  }
  
  function getManagementFee(Investment memory investment) public view returns (uint256){
    uint256 investmentDuration = block.timestamp.sub(investment.timestamp);
    uint256 usdTokenManagementFee =
      investmentDuration
        .mul(managementFee)
        .mul(investment.initialUsdTokenAmount)
        .div(315576000000);
    return usdTokenManagementFee;
  }
  
  function getPerformanceFee(Investment memory investment) public view returns (uint256) {
    uint256 supply = totalSupply();
    uint256 currentUsdValue = aum.mul(investment.initialFundAmount).div(supply);
    uint256 usdTokenPerformanceFee = 0;
    if (currentUsdValue > investment.initialUsdTokenAmount) {
      usdTokenPerformanceFee = currentUsdValue
        .sub(investment.initialUsdTokenAmount)
        .mul(performanceFee)
        .div(10000);
    }
    return usdTokenPerformanceFee;
  }

  // TODO: refactor so it's a single usd transfer instead of one per investment? 
  // actually may be better this way so transfers can be seen as separate on etherscan
  function _extractFees(Investment storage investment)
    private
    returns (uint256, uint256)
  {
    uint256 usdTokenManagementFee = getManagementFee(investment);
    uint256 usdTokenPerformanceFee = getPerformanceFee(investment);
    uint256 totalUsdFee = usdTokenManagementFee.add(usdTokenPerformanceFee);
    uint256 supply = totalSupply();
    uint256 usdAmountToCollect = 0;
    uint256 fundAmountToBurn = 0;

    uint256 usdManagementFeeToCollect = usdTokenManagementFee.sub(
      investment.usdManagementFeesCollected);
    
    uint256 fundMgmtFeeToBurn = supply.mul(usdTokenManagementFee).div(aum);
    fundAmountToBurn = fundAmountToBurn.add(fundMgmtFeeToBurn);
    investment.usdManagementFeesCollected = usdTokenManagementFee;
    investment.fundAmount = investment.fundAmount.sub(fundMgmtFeeToBurn);

    uint256 usdPerformanceFeeToCollect = 0;
    if (usdTokenPerformanceFee > investment.usdPerformanceFeesCollected) {
      usdPerformanceFeeToCollect = usdTokenPerformanceFee.sub(
        investment.usdPerformanceFeesCollected);
    
      uint256 fundPerfFeeToBurn = supply.mul(usdPerformanceFeeToCollect).div(aum);
      fundAmountToBurn = fundAmountToBurn.add(fundPerfFeeToBurn);
      investment.usdPerformanceFeesCollected = usdTokenPerformanceFee;
      investment.fundAmount = investment.fundAmount.sub(fundPerfFeeToBurn);
    }
    usdAmountToCollect = usdManagementFeeToCollect.add(usdPerformanceFeeToCollect);
    investment.usdTokenFeesCollected = investment.usdTokenFeesCollected.add(usdAmountToCollect);
    _burn(investment.investor, fundAmountToBurn);
    aum = aum.sub(usdAmountToCollect);
    factory.usdToken().safeTransferFrom(
      manager,
      address(this),
      usdAmountToCollect
    );

    investment.lastFeeTimestamp = block.timestamp;
    return (fundAmountToBurn, usdAmountToCollect);
  }

  function withdrawFees(
    uint256 usdTokenAmount,
    address to,
    uint256 deadline
  ) public onlyManager onlyBefore(deadline) {
    factory.usdToken().safeTransferFrom(address(this), to, usdTokenAmount);
    emit FeesWithdrawn(to, usdTokenAmount);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    require(from == address(0) || to == address(0), 'Cannot transfer');
  }
}
