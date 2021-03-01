// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './SMFundFactory.sol';
import './SMFundLibrary.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

contract SMFund is Context, ERC20 {
  using SafeMath for uint256;

  SMFundFactory public factory;
  ERC20 public usdToken;
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
    address[2] memory addressParams, // manager, initialInvestor
    bool[2] memory boolParams, // signedAum, investmentsEnabled
    uint256[8] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory initialInvestorName,
    bytes memory signature
  ) ERC20(name, symbol) onlyBefore(uintParams[4]) {
    require(uintParams[3] > 0, 'S0');
    factory = SMFundFactory(_msgSender());
    usdToken = factory.usdToken();
    _setupDecimals(usdToken.decimals());
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
    if (boolParams[0]) {
      SMFundLibrary.verifyAumSignature(
        boolParams[0],
        addressParams[0],
        factory.owner(),
        addressParams[0],
        aum,
        uintParams[4],
        signature
      );
    }
  }

  modifier onlyManager() {
    require(_msgSender() == manager, 'S1');
    _;
  }

  modifier onlyInvestmentsEnabled() {
    require(investmentsEnabled, 'S2');
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[_msgSender()].whitelisted == true, 'S3');
    _;
  }

  modifier onlyBefore(uint256 deadline) {
    require(block.timestamp <= deadline, 'S4');
    _;
  }

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    bytes calldata signature
  ) public onlyBefore(deadline) {
    aum = _aum;
    aumTimestamp = block.timestamp;
    SMFundLibrary.verifyAumSignature(
      signedAum,
      _msgSender(),
      factory.owner(),
      manager,
      aum,
      deadline,
      signature
    );
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
    _addInvestment(_msgSender(), usdAmount, minFundAmount);
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
      fundAmount = usdAmount.mul(100);
    } else {
      fundAmount = usdAmount.mul(totalSupply()).div(aum);
    }
    require(fundAmount >= minFundAmount, 'S12');
    // don't transfer tokens if it's the initialization investment
    if (investmentId != 0) {
      usdToken.transferFrom(investor, manager, usdAmount);
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
    uint256[] calldata investmentIds
  ) public onlyInvestmentsEnabled onlyWhitelisted {
    address sender = _msgSender();
    for (uint256 i = 0; i < investmentIds.length; i++) {
      Investment storage investment = investments[investmentIds[i]];
      require(investment.investor == sender, 'S13');
      require(investment.redeemed == false, 'S14');
      require(investment.timestamp.add(timelock) <= block.timestamp, 'S15');
    }
    emit RedemptionRequested(sender, minUsdAmount, investmentIds);
  }

  // used to process a redemption on the initial investment with index 0 after all other investments have been redeemed
  // does the same as the other redemptions except it doesn't transfer usd
  // all remaining aum is considered owned by the initial investor (which should be the fund manager)
  function closeFund() public onlyManager {
    // close out fund, don't transfer any AUM, let the fund manager do it manually
    require(activeInvestmentCount == 1, 'S16');
    Investment storage investment = investments[0];
    require(investment.redeemed == false, 'S17');
    require(investment.timestamp.add(timelock) <= block.timestamp, 'S18');
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
      usdAmount = _redeem(investmentIds[i]).add(usdAmount);
    }
    require(usdAmount >= minUsdAmount, 'S20');
    emit NavUpdated(aum, totalSupply());
  }

  function _redeem(uint256 investmentId) private returns (uint256 usdAmount) {
    Investment storage investment = investments[investmentId];
    require(investmentId != 0, 'S21');
    require(investment.redeemed == false, 'S22');
    require(investment.timestamp.add(timelock) <= block.timestamp, 'S23');
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
      require(
        investment.lastFeeTimestamp.add(30 days) <= block.timestamp,
        'S25'
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

  function calculateManagementFee(uint256 investmentId)
    public
    view
    returns (uint256 usdManagementFee, uint256 fundManagementFee)
  {
    Investment storage investment = investments[investmentId];
    (usdManagementFee, fundManagementFee) = SMFundLibrary
      .calculateManagementFee(investment, managementFee, aum, totalSupply());
  }

  function calculatePerformanceFee(uint256 investmentId)
    public
    view
    returns (uint256 usdPerformanceFee, uint256 fundPerformanceFee)
  {
    Investment storage investment = investments[investmentId];
    (usdPerformanceFee, fundPerformanceFee) = SMFundLibrary
      .calculatePerformanceFee(investment, performanceFee, aum, totalSupply());
  }

  function highWaterMark(uint256 investmentId)
    public
    view
    returns (uint256 usdValue)
  {
    Investment storage investment = investments[investmentId];
    usdValue = SMFundLibrary.highWaterMark(investment, performanceFee);
  }

  function withdrawFees(
    uint256 usdAmount,
    address to,
    uint256 deadline
  ) public onlyManager onlyBefore(deadline) {
    usdToken.transferFrom(address(this), to, usdAmount);
    emit FeesWithdrawn(to, usdAmount);
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
