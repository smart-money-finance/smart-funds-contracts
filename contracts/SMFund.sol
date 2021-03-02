// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.1;

import '@openzeppelin/contracts-upgradeable/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol';

import './SMFundFactory.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

contract SMFund is Initializable, ERC20Upgradeable {
  SMFundFactory public factory;
  ERC20 public usdToken;
  uint8 _decimals;
  address public manager;
  uint256 public timelock;
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  bool public investmentsEnabled;
  bool public signedAum;
  string public logoUrl;
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals

  uint256 public aum;
  uint256 public aumTimestamp;

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

  constructor() {}

  function initialize(
    address[2] memory addressParams, // manager, initialInvestor
    bool[2] memory boolParams, // signedAum, investmentsEnabled
    uint256[8] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory initialInvestorName,
    bytes memory signature
  ) public initializer onlyBefore(uintParams[4]) {
    __ERC20_init(name, symbol);
    require(uintParams[3] > 0, 'S0');
    factory = SMFundFactory(msg.sender);
    usdToken = factory.usdToken();
    _decimals = usdToken.decimals();
    manager = addressParams[0];
    signedAum = boolParams[0];
    investmentsEnabled = boolParams[1];
    timelock = uintParams[0];
    managementFee = uintParams[1];
    performanceFee = uintParams[2];
    maxInvestors = uintParams[5];
    maxInvestmentsPerInvestor = uintParams[6];
    minInvestmentAmount = uintParams[7];
    logoUrl = _logoUrl;
    _addToWhitelist(addressParams[1], initialInvestorName);
    _addInvestment(addressParams[1], uintParams[3], 1);
    verifyAumSignature(manager, uintParams[4], signature);
  }

  modifier onlyManager() {
    require(msg.sender == manager, 'S1');
    _;
  }

  modifier onlyInvestmentsEnabled() {
    require(investmentsEnabled, 'S2');
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[msg.sender].whitelisted == true, 'S3');
    _;
  }

  modifier onlyBefore(uint256 deadline) {
    require(block.timestamp <= deadline, 'S4');
    _;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    bytes calldata signature
  ) public onlyBefore(deadline) {
    aum = _aum;
    aumTimestamp = block.timestamp;
    verifyAumSignature(msg.sender, deadline, signature);
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

  function _addToWhitelist(address investor, string memory name) private {
    require(investorCount < maxInvestors, 'S5');
    require(!whitelist[investor].whitelisted, 'S6');
    investorCount++;
    whitelist[investor] = Investor({ whitelisted: true, name: name });
    emit Whitelisted(investor, name);
  }

  function blacklistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      require(activeInvestmentCountPerInvestor[investors[i]] == 0, 'S7');
      require(whitelist[investors[i]].whitelisted, 'S8');
      investorCount--;
      delete whitelist[investors[i]];
      emit Blacklisted(investors[i]);
    }
  }

  function invest(
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 deadline
  ) public onlyInvestmentsEnabled onlyWhitelisted onlyBefore(deadline) {
    _addInvestment(msg.sender, usdAmount, minFundAmount);
  }

  function _addInvestment(
    address investor,
    uint256 usdAmount,
    uint256 minFundAmount
  ) internal {
    require(usdAmount >= minInvestmentAmount, 'S9');
    require(minFundAmount > 0, 'S10');
    require(
      activeInvestmentCountPerInvestor[investor] < maxInvestmentsPerInvestor,
      'S11'
    );
    uint256 investmentId = investments.length;
    uint256 fundAmount;
    // if intialization investment, use price of 1 cent
    if (investmentId == 0) {
      fundAmount = usdAmount * 100;
    } else {
      fundAmount = (usdAmount * totalSupply()) / aum;
    }
    require(fundAmount >= minFundAmount, 'S12');
    // don't transfer tokens if it's the initialization investment
    if (investmentId != 0) {
      usdToken.transferFrom(investor, manager, usdAmount);
    }
    aum += usdAmount;
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
    uint256[] calldata investmentIds
  ) public onlyInvestmentsEnabled onlyWhitelisted {
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.investor == msg.sender, 'S13');
      require(investment.redeemed == false, 'S14');
      require(investment.timestamp + timelock <= block.timestamp, 'S15');
    }
    emit RedemptionRequested(msg.sender, minUsdAmount, investmentIds);
  }

  // used to process a redemption on the initial investment with index 0 after all other investments have been redeemed
  // does the same as the other redemptions except it doesn't transfer usd
  // all remaining aum is considered owned by the initial investor (which should be the fund manager)
  function closeFund() public onlyManager {
    // close out fund, don't transfer any AUM, let the fund manager do it manually
    require(activeInvestmentCount == 1, 'S16');
    Investment storage investment = investments[0];
    require(investment.redeemed == false, 'S17');
    require(investment.timestamp + timelock <= block.timestamp, 'S18');
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
  ) public onlyInvestmentsEnabled onlyManager onlyBefore(deadline) {
    address investor = investments[investmentIds[0]].investor;
    uint256 usdAmount = 0;
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.investor == investor, 'S19');
      _extractFees(investmentIds[i]);
      usdAmount += _redeem(investmentIds[i]);
    }
    require(usdAmount >= minUsdAmount, 'S20');
    emit NavUpdated(aum, totalSupply());
  }

  function _redeem(uint256 investmentId) private returns (uint256 usdAmount) {
    Investment storage investment = investments[investmentId];
    require(investmentId != 0, 'S21');
    require(investment.redeemed == false, 'S22');
    require(investment.timestamp + timelock <= block.timestamp, 'S23');
    // mark investment as redeemed and lower total investment count
    investment.redeemed = true;
    activeInvestmentCount--;
    activeInvestmentCountPerInvestor[investment.investor]--;
    // calculate usd value of the current fundAmount remaining in the investment
    usdAmount = (investment.fundAmount * aum) / totalSupply();
    // burn fund tokens
    _burn(investment.investor, investment.fundAmount);
    // subtract usd amount from aum
    aum -= usdAmount;
    // transfer usd to investor
    usdToken.transferFrom(manager, investment.investor, usdAmount);
    emit Redeemed(
      investment.investor,
      investment.fundAmount,
      usdAmount,
      investmentId
    );
  }

  function processFees(uint256[] calldata investmentIds, uint256 deadline)
    public
    onlyInvestmentsEnabled
    onlyManager
    onlyBefore(deadline)
  {
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.redeemed == false, 'S24');
      require(investment.lastFeeTimestamp + 30 days <= block.timestamp, 'S25');
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
    investment.usdManagementFeesCollected += usdManagementFee;
    investment.usdPerformanceFeesCollected += usdPerformanceFee;
    investment.fundAmount -= (fundManagementFee + fundPerformanceFee);
    investment.lastFeeTimestamp = block.timestamp;

    // 2 burns and 2 transfers are done so events show up separately on etherscan and elsewhere which makes matching them up with what the UI shows a lot easier
    // burn the two fee amounts from the investor
    _burn(investment.investor, fundManagementFee);
    _burn(investment.investor, fundPerformanceFee);
    // decrement fund aum by the usd amounts
    aum -= (usdManagementFee + usdPerformanceFee);
    // transfer usd for the two fee amounts
    usdToken.transferFrom(manager, address(this), usdManagementFee);
    usdToken.transferFrom(manager, address(this), usdPerformanceFee);
    emit FeesCollected(
      fundManagementFee,
      fundPerformanceFee,
      usdManagementFee,
      usdPerformanceFee,
      investmentId
    );
  }

  function withdrawFees(
    uint256 usdAmount,
    address to,
    uint256 deadline
  ) public onlyManager onlyBefore(deadline) {
    usdToken.transferFrom(address(this), to, usdAmount);
    emit FeesWithdrawn(to, usdAmount);
  }

  function editLogo(string calldata _logoUrl) public onlyManager {
    logoUrl = _logoUrl;
  }

  function editInvestorLimits(
    uint256 _maxInvestors,
    uint256 _maxInvestmentsPerInvestor,
    uint256 _minInvestmentAmount
  ) public onlyManager {
    maxInvestors = _maxInvestors;
    maxInvestmentsPerInvestor = _maxInvestmentsPerInvestor;
    minInvestmentAmount = _minInvestmentAmount;
  }

  function verifyAumSignature(
    address sender,
    uint256 deadline,
    bytes memory signature
  ) public view {
    if (!signedAum) {
      require(sender == manager, 'L0');
    } else if (sender == manager) {
      bytes32 message = keccak256(abi.encode(manager, aum, deadline));
      address signer =
        ECDSAUpgradeable.recover(
          ECDSAUpgradeable.toEthSignedMessageHash(message),
          signature
        );
      require(signer == factory.owner(), 'L1');
    } else {
      require(sender == factory.owner(), 'L2');
    }
  }

  function calculateManagementFee(uint256 investmentId)
    public
    view
    returns (uint256 usdManagementFee, uint256 fundManagementFee)
  {
    Investment storage investment = investments[investmentId];
    // calculate management fee % of current fund tokens scaled over the time since last fee withdrawal
    fundManagementFee =
      ((block.timestamp - investment.timestamp) *
        managementFee *
        investment.fundAmount) /
      365.25 days /
      10000; // management fee is over a whole year (365.25 days) and denoted in basis points so also need to divide by 10000

    // calculate the usd value of the management fee being pulled
    usdManagementFee = (fundManagementFee * aum) / totalSupply();
  }

  function calculatePerformanceFee(uint256 investmentId)
    public
    view
    returns (uint256 usdPerformanceFee, uint256 fundPerformanceFee)
  {
    Investment storage investment = investments[investmentId];
    // usd value of the investment
    uint256 currentUsdValue = (aum * investment.fundAmount) / totalSupply();
    uint256 totalUsdPerformanceFee = 0;
    if (currentUsdValue > investment.initialUsdAmount) {
      // calculate current performance fee from initial usd value of investment to current usd value
      totalUsdPerformanceFee =
        ((currentUsdValue - investment.initialUsdAmount) * performanceFee) /
        10000;
    }
    // if we're over the high water mark, meaning more performance fees are owed than have previously been collected
    if (totalUsdPerformanceFee > investment.usdPerformanceFeesCollected) {
      usdPerformanceFee =
        totalUsdPerformanceFee -
        investment.usdPerformanceFeesCollected;
      fundPerformanceFee = (totalSupply() * usdPerformanceFee) / aum;
    }
  }

  function highWaterMark(uint256 investmentId)
    public
    view
    returns (uint256 usdValue)
  {
    Investment storage investment = investments[investmentId];
    usdValue =
      (investment.usdPerformanceFeesCollected * 10000) /
      performanceFee +
      investment.initialUsdAmount;
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    require(from == address(0) || to == address(0), 'S26');
  }
}
