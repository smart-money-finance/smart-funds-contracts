// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import './SMFundFactory.sol';

// TODO:
// figure out how to close out the last investment(s) and wipe out AUM
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

contract SMFund is Context, ERC20 {
  using SafeMath for uint256;
  using ECDSA for bytes32;
  using SafeERC20 for ERC20;

  SMFundFactory public factory;
  address public manager;
  address public immutable feeWallet;
  address public immutable aumUpdater;
  uint256 public immutable timelock;
  uint256 public immutable managementFee; // basis points
  uint256 public immutable performanceFee; // basis points
  bool public immutable investmentsEnabled;
  bool public signedAum;

  // bool public closed;

  // uint256[] public aums;
  uint256 public aum;

  mapping(address => bool) public whitelist;

  struct Investment {
    address investor;
    uint256 initialUsdTokenAmount;
    uint256 usdTokenFeesCollected;
    uint256 initialFundAmount;
    uint256 fundAmount;
    uint256 timestamp;
    uint256 lastFeeTimestamp;
    bool redeemed;
  }

  Investment[] public investments;
  uint256 public activeInvestmentCount = 1;

  event NavUpdated(uint256 aum, uint256 totalSupply);
  event Whitelisted(address indexed investor);
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

  constructor(
    address _manager,
    address _feeWallet,
    address _aumUpdater,
    uint256 _timelock,
    uint256 _managementFee,
    uint256 _performanceFee,
    bool _investmentsEnabled,
    bool _signedAum,
    string memory name,
    string memory symbol,
    uint256 initialAum,
    address initialInvestor,
    uint256 deadline,
    bytes memory signature
  ) public ERC20(name, symbol) {
    factory = SMFundFactory(_msgSender());
    _setupDecimals(factory.usdToken().decimals());
    manager = _manager;
    feeWallet = _feeWallet;
    aumUpdater = _aumUpdater;
    timelock = _timelock;
    managementFee = _managementFee;
    performanceFee = _performanceFee;
    investmentsEnabled = _investmentsEnabled;
    signedAum = _signedAum;
    aum = initialAum;
    verifyAumSignature(deadline, signature);
    _addToWhitelist(initialInvestor);
    _addInvestment(initialInvestor, initialAum.mul(1000), 1);
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
    // require(!closed, 'Fund is closed');
    require(totalSupply() != 0, 'Fund is closed');
    _;
  }

  modifier onlyInvestmentsEnabled() {
    require(investmentsEnabled, 'Investments are disabled');
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[_msgSender()] == true, 'Not whitelisted');
    _;
  }

  modifier onlyBeforeDeadline(uint256 deadline) {
    require(block.timestamp <= deadline, 'Past deadline');
    _;
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
  ) public onlyAumUpdater onlyBeforeDeadline(deadline) {
    aum = _aum;
    verifyAumSignature(deadline, signature);
    emit NavUpdated(_aum, totalSupply());
  }

  function whitelistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      _addToWhitelist(investors[i]);
    }
  }

  function _addToWhitelist(address investor) private {
    whitelist[investor] = true;
    emit Whitelisted(investor);
  }

  function blacklistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      whitelist[investors[i]] = false;
      emit Blacklisted(investors[i]);
    }
  }

  function invest(
    uint256 usdTokenAmount,
    uint256 minFundAmount,
    uint256 deadline
  )
    public
    notClosed
    onlyInvestmentsEnabled
    onlyWhitelisted
    onlyBeforeDeadline(deadline)
  {
    _addInvestment(_msgSender(), usdTokenAmount, minFundAmount);
  }

  function _addInvestment(
    address investor,
    uint256 usdTokenAmount,
    uint256 minFundAmount
  ) internal {
    require(usdTokenAmount > 0 && minFundAmount > 0, 'Amount is 0');
    uint256 fundAmount = usdTokenAmount.mul(totalSupply()).div(aum);
    require(fundAmount >= minFundAmount, 'Less than min fund amount');
    factory.usdToken().safeTransferFrom(
      investor,
      address(this),
      usdTokenAmount
    );
    aum = aum.add(usdTokenAmount);
    _mint(investor, fundAmount);
    uint256 investmentId = investments.length;
    Investment storage investment = investments[investmentId];
    investment.investor = investor;
    investment.initialUsdTokenAmount = usdTokenAmount;
    investment.initialFundAmount = fundAmount;
    investment.fundAmount = fundAmount;
    investment.timestamp = block.timestamp;
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
    notClosed
    onlyInvestmentsEnabled
    onlyWhitelisted
    onlyBeforeDeadline(deadline)
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
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBeforeDeadline(deadline)
  {
    // TODO: process fees, figure out how closing out final fund assets should work
    // if (activeInvestmentCount == investmentIds.length) {
    //   // close out fund and use final usd tokens spread evenly?
    // }
    address investor = investments[investmentIds[0]].investor;
    uint256 usdTokenAmount = 0;
    uint256 fundAmount = 0;
    uint256 totalFundFeesBurned = 0;
    uint256 totalUsdTokenFeesCollected = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.timestamp.add(timelock) <= block.timestamp,
        'Time locked'
      );
      require(investment.investor == investor, 'Not from one investor');
      (uint256 fundBurned, uint256 usdTokenCollected) = _extractFees(
        investment
      );
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
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBeforeDeadline(deadline)
  {
    uint256 totalFundFeesBurned = 0;
    uint256 totalUsdTokenFeesCollected = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.lastFeeTimestamp.add(2419200) <= block.timestamp,
        'Fee last collected less than a month ago'
      );
      (uint256 fundBurned, uint256 usdTokenCollected) = _extractFees(
        investment
      );
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

  // TODO: refactor so it's a single usd transfer instead of one per investment?
  function _extractFees(Investment storage investment)
    private
    returns (uint256, uint256)
  {
    uint256 investmentDuration = block.timestamp.sub(investment.timestamp);
    uint256 usdTokenManagementFee = investmentDuration
      .mul(managementFee)
      .mul(investment.initialUsdTokenAmount)
      .div(315576000000);
    uint256 supply = totalSupply();
    uint256 currentUsdValue = aum.mul(investment.initialFundAmount).div(supply);
    uint256 usdTokenPerformanceFee = 0;
    if (currentUsdValue > investment.initialUsdTokenAmount) {
      usdTokenPerformanceFee = currentUsdValue
        .sub(investment.initialUsdTokenAmount)
        .mul(performanceFee)
        .div(10000);
    }
    uint256 totalUsdFee = usdTokenManagementFee.add(usdTokenPerformanceFee);
    uint256 usdAmountToCollect = 0;
    uint256 fundAmountToBurn = 0;
    if (totalUsdFee > investment.usdTokenFeesCollected) {
      usdAmountToCollect = totalUsdFee.sub(investment.usdTokenFeesCollected);
      fundAmountToBurn = supply.mul(usdAmountToCollect).div(aum);
      _burn(investment.investor, fundAmountToBurn);
      aum = aum.sub(usdAmountToCollect);
      factory.usdToken().safeTransferFrom(
        manager,
        feeWallet,
        usdAmountToCollect
      );
    }
    investment.lastFeeTimestamp = block.timestamp;
    return (fundAmountToBurn, usdAmountToCollect);
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
