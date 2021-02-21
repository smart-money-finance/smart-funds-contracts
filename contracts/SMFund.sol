// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
// import 'hardhat/console.sol';

import './SMFundFactory.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

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
  // TODO: make these params?
  uint256 public constant maxInvestors = 20;
  uint256 public constant maxInvestmentsPerInvestor = 5;
  uint256 public constant minInvestmentAmount = 10000e6; // $10,000

  // uint256[] public aums;
  uint256 public aum;

  struct Investor {
    bool whitelisted;
    string name;
  }

  mapping(address => Investor) public whitelist;

  struct Investment {
    address investor;
    uint256 initialUsdAmount;
    uint256 usdManagementFeesCollected;
    uint256 usdPerformanceFeesCollected;
    uint256 initialFundAmount;
    uint256 fundAmount;
    uint256 timestamp;
    uint256 lastFeeTimestamp;
    bool redeemed;
  }

  Investment[] public investments;
  uint256 public activeInvestmentCount;
  mapping(address => uint256) public activeInvestmentCountPerInvestor;
  uint256 public investorCount;

  event NavUpdated(uint256 aum, uint256 totalSupply);
  event Whitelisted(address indexed investor, string name);
  event Blacklisted(address indexed investor);
  event Invested(
    address indexed investor,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 investmentId
  );
  event RedemptionRequested(
    address indexed investor,
    uint256 minUsdAmount,
    uint256[] investmentIds
  );
  event Redeemed(
    address indexed investor,
    uint256 fundAmount,
    uint256 usdAmount,
    uint256 investmentId
  );
  event FeesCollected(
    uint256 fundAmountManagement,
    uint256 fundAmountPerformance,
    uint256 usdAmountManagement,
    uint256 usdAmountPerformance,
    uint256 investmentId
  );
  event FeesWithdrawn(address indexed to, uint256 usdAmount);

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
    require(investorCount < maxInvestors, 'Too many investors whitelisted');
    investorCount++;
    whitelist[investor] = Investor({ whitelisted: true, name: name });
    emit Whitelisted(investor, name);
  }

  function blacklistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      require(
        activeInvestmentCountPerInvestor[investors[i]] == 0,
        'Investor has open investments'
      );
      require(whitelist[investors[i]].whitelisted, 'Not whitelisted');
      investorCount--;
      delete whitelist[investors[i]];
      emit Blacklisted(investors[i]);
    }
  }

  function invest(
    uint256 usdAmount,
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
    _addInvestment(_msgSender(), usdAmount, minFundAmount);
  }

  function _addInvestment(
    address investor,
    uint256 usdAmount,
    uint256 minFundAmount
  ) internal {
    require(usdAmount >= minInvestmentAmount, 'Amount is less than min');
    require(minFundAmount > 0, 'Min amount is 0');
    require(
      activeInvestmentCountPerInvestor[investor] < maxInvestmentsPerInvestor,
      'Max investments per investor reached'
    );
    uint256 investmentId = investments.length;
    uint256 fundAmount;
    // if intialization investment, use price of 1 cent
    if (investmentId == 0) {
      fundAmount = usdAmount.mul(100);
    } else {
      fundAmount = usdAmount.mul(totalSupply()).div(aum);
    }
    require(fundAmount >= minFundAmount, 'Less than min fund amount');
    // don't transfer tokens if it's the initialization investment
    if (investmentId != 0) {
      factory.usdToken().safeTransferFrom(investor, manager, usdAmount);
    }
    aum = aum.add(usdAmount);
    _mint(investor, fundAmount);
    investments.push(
      Investment({
        investor: investor,
        initialUsdAmount: usdAmount,
        usdManagementFeesCollected: 0,
        usdPerformanceFeesCollected: 0,
        initialFundAmount: fundAmount,
        fundAmount: fundAmount,
        timestamp: block.timestamp,
        lastFeeTimestamp: block.timestamp,
        redeemed: false
      })
    );
    activeInvestmentCount++;
    activeInvestmentCountPerInvestor[investor]++;
    emit Invested(investor, usdAmount, fundAmount, investmentId);
    emit NavUpdated(aum, totalSupply());
  }

  function requestRedemption(
    uint256 minUsdAmount,
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
    emit RedemptionRequested(sender, minUsdAmount, investmentIds);
  }

  // used to process a redemption on the initial investment with index 0 after all other investments have been redeemed
  // does the same as the other redemptions except it doesn't transfer usd
  // all remaining aum is considered owned by the initial investor (which should be the fund manager)
  function closeFund(uint256 deadline)
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    // close out fund, don't transfer any AUM, let the fund manager do it manually
    require(activeInvestmentCount == 1, 'Must redeem other investments first');
    Investment storage investment = investments[0];
    require(investment.redeemed == false, 'Already redeemed');
    require(
      investment.timestamp.add(timelock) <= block.timestamp,
      'Time locked'
    );
    _extractFees(0);
    investment.redeemed = true;
    activeInvestmentCount--;
    activeInvestmentCountPerInvestor[investment.investor]--;
    _burn(investment.investor, investment.fundAmount);
    uint256 finalAum = aum;
    aum = 0;
    emit Redeemed(investment.investor, investment.fundAmount, finalAum, 0);
    emit NavUpdated(aum, totalSupply());
  }

  function processRedemptions(
    uint256[] calldata investmentIds,
    uint256 minUsdAmount,
    uint256 deadline
  )
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    address investor = investments[investmentIds[0]].investor;
    uint256 usdAmount = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.investor == investor, 'Not from one investor');
      _extractFees(investmentIds[i]);
      usdAmount = _redeem(investmentIds[i]).add(usdAmount);
    }
    require(usdAmount >= minUsdAmount, 'Less than min usd amount');
    emit NavUpdated(aum, totalSupply());
  }

  function _redeem(uint256 investmentId) private returns (uint256 usdAmount) {
    Investment storage investment = investments[investmentId];
    require(
      investmentId != 0,
      'Initial investment must be redeemed separately'
    );
    require(investment.redeemed == false, 'Already redeemed');
    require(
      investment.timestamp.add(timelock) <= block.timestamp,
      'Time locked'
    );
    // mark investment as redeemed and lower total investment count
    investment.redeemed = true;
    activeInvestmentCount--;
    activeInvestmentCountPerInvestor[investment.investor]--;
    // calculate usd value of the current fundAmount remaining in the investment
    usdAmount = investment.fundAmount.mul(aum).div(totalSupply());
    // burn fund tokens
    _burn(investment.investor, investment.fundAmount);
    // subtract usd amount from aum
    aum = aum.sub(usdAmount);
    // transfer usd to investor
    factory.usdToken().safeTransferFrom(
      manager,
      investment.investor,
      usdAmount
    );
    emit Redeemed(
      investment.investor,
      investment.fundAmount,
      usdAmount,
      investmentId
    );
  }

  function processFees(uint256[] calldata investmentIds, uint256 deadline)
    public
    onlyInitialized
    notClosed
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'Already redeemed');
      require(
        investment.lastFeeTimestamp.add(30 days) <= block.timestamp,
        'Fee last collected less than a month ago'
      );
      _extractFees(investmentIds[i]);
    }
    emit NavUpdated(aum, totalSupply());
  }

  function _extractFees(uint256 investmentId) private {
    // calculate fees in usd and fund token
    (uint256 usdManagementFee, uint256 fundManagementFee) =
      calculateManagementFee(investmentId);
    (uint256 usdPerformanceFee, uint256 fundPerformanceFee) =
      calculatePerformanceFee(investmentId);

    Investment storage investment = investments[investmentId];
    // update totals stored in the investment struct
    investment.usdManagementFeesCollected = investment
      .usdManagementFeesCollected
      .add(usdManagementFee);
    investment.usdPerformanceFeesCollected = investment
      .usdPerformanceFeesCollected
      .add(usdPerformanceFee);
    investment.fundAmount = investment.fundAmount.sub(fundManagementFee).sub(
      fundPerformanceFee
    );
    investment.lastFeeTimestamp = block.timestamp;

    // 2 burns and 2 transfers are done so events show up separately on etherscan and elsewhere which makes matching them up with what the UI shows a lot easier
    // burn the two fee amounts from the investor
    _burn(investment.investor, fundManagementFee);
    _burn(investment.investor, fundPerformanceFee);
    // decrement fund aum by the usd amounts
    aum = aum.sub(usdManagementFee).sub(usdPerformanceFee);
    // transfer usd for the two fee amounts
    factory.usdToken().safeTransferFrom(
      manager,
      address(this),
      usdManagementFee
    );
    factory.usdToken().safeTransferFrom(
      manager,
      address(this),
      usdPerformanceFee
    );
    emit FeesCollected(
      fundManagementFee,
      fundPerformanceFee,
      usdManagementFee,
      usdPerformanceFee,
      investmentId
    );
  }

  function calculateManagementFee(uint256 investmentId)
    public
    view
    returns (uint256 usdManagementFee, uint256 fundManagementFee)
  {
    Investment storage investment = investments[investmentId];
    // calculate management fee % of current fund tokens scaled over the time since last fee withdrawal
    fundManagementFee = block
      .timestamp
      .sub(investment.timestamp)
      .mul(managementFee)
      .mul(investment.fundAmount)
      .div(3652500 days); // management fee is over a whole year (365.25 days) and denoted in basis points so also need to divide by 10000, do it in one operation to save a little gas

    // calculate the usd value of the management fee being pulled
    usdManagementFee = fundManagementFee.mul(aum).div(totalSupply());
  }

  function calculatePerformanceFee(uint256 investmentId)
    public
    view
    returns (uint256 usdPerformanceFee, uint256 fundPerformanceFee)
  {
    Investment storage investment = investments[investmentId];
    uint256 supply = totalSupply();
    // usd value of the investment
    uint256 currentUsdValue = aum.mul(investment.fundAmount).div(supply);
    uint256 totalUsdPerformanceFee = 0;
    if (currentUsdValue > investment.initialUsdAmount) {
      // calculate current performance fee from initial usd value of investment to current usd value
      totalUsdPerformanceFee = currentUsdValue
        .sub(investment.initialUsdAmount)
        .mul(performanceFee)
        .div(10000);
    }
    // if we're over the high water mark, meaning more performance fees are owed than have previously been collected
    if (totalUsdPerformanceFee > investment.usdPerformanceFeesCollected) {
      usdPerformanceFee = totalUsdPerformanceFee.sub(
        investment.usdPerformanceFeesCollected
      );
      fundPerformanceFee = supply.mul(usdPerformanceFee).div(aum);
    }
  }

  function highWaterMark(uint256 investmentId)
    public
    view
    returns (uint256 usdValue)
  {
    Investment storage investment = investments[investmentId];
    usdValue = investment
      .usdPerformanceFeesCollected
      .mul(10000)
      .div(performanceFee)
      .add(investment.initialUsdAmount);
  }

  function withdrawFees(
    uint256 usdAmount,
    address to,
    uint256 deadline
  ) public onlyManager onlyBefore(deadline) {
    factory.usdToken().safeTransferFrom(address(this), to, usdAmount);
    emit FeesWithdrawn(to, usdAmount);
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
