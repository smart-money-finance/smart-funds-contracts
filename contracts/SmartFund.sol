// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.4;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

import './FeeDividendToken.sol';
import './SmartFundFactory.sol';

// import 'hardhat/console.sol';

contract SmartFund is Initializable, FeeDividendToken {
  SmartFundFactory internal factory;
  ERC20 internal usdToken;
  address public custodian;
  address public manager;
  address public aumUpdater;
  address public feeBeneficiary;
  uint256 public timelock;
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  uint256 public feeTimelock;
  uint256 public redemptionWaitingPeriod;
  string public logoUrl;
  string public contactInfo;
  string public tags;
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals
  bool public investmentRequestsEnabled; // whether an investor can make a request for investment with escrowed usd
  bool public redemptionRequestsEnabled; // whether an investor can make a request for redemption
  bool public closed; // set true after last investment redeems

  uint256 public aum;
  uint256 public aumTimestamp; // block timestamp of last aum update
  uint256 public highWaterPrice; // highest ((aum * 10^18) / supply)
  uint256 public highWaterPriceTimestamp; // timestamp of highest price
  uint256 public feeWithdrawnTimestamp;

  struct Investor {
    bool whitelisted;
    string name;
  }
  mapping(address => Investor) public whitelist;

  struct Investment {
    address investor;
    uint256 initialUsdAmount;
    uint256 initialFundAmount;
    uint256 initialBaseAmount;
    uint256 initialHighWaterPrice;
    uint256 timestamp;
    uint256 investmentRequestId;
    uint256 redemptionRequestId;
    bool redeemed;
  }
  Investment[] public investments;
  uint256 public investmentsCount;

  uint256 public investorCount;
  mapping(address => uint256) public activeAndPendingInvestmentCountPerInvestor;
  uint256 public activeAndPendingInvestmentCount;

  enum RequestStatus { Pending, Failed, Processed }

  struct InvestmentRequest {
    address investor;
    uint256 usdAmount;
    uint256 minFundAmount;
    uint256 maxFundAmount;
    uint256 timestamp;
    uint256 deadline;
    uint256 investmentId;
    RequestStatus status;
  }
  InvestmentRequest[] public investmentRequests;
  uint256 public nextInvestmentRequestIndex;

  struct RedemptionRequest {
    address investor;
    uint256 minUsdAmount;
    uint256 timestamp;
    uint256 investmentId;
    RequestStatus status;
  }
  RedemptionRequest[] public redemptionRequests;
  uint256 public nextRedemptionRequestIndex;

  event NavUpdated(uint256 aum, uint256 totalSupply, string ipfsHash);
  event Whitelisted(address indexed investor, string name);
  event Blacklisted(address indexed investor);
  event InvestmentRequested(
    address indexed investor,
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 investmentRequestId
  );
  event InvestmentRequestFailed(
    address indexed investor,
    uint256 investmentRequestId
  );
  event Invested(
    address indexed investor,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 investmentId,
    uint256 investmentRequestId
  );
  event RedemptionRequested(
    address indexed investor,
    uint256 minUsdAmount,
    uint256 investmentId,
    uint256 redemptionRequestId
  );
  event RedemptionRequestFailed(
    address indexed investor,
    uint256 redemptionRequestId
  );
  event Redeemed(
    address indexed investor,
    uint256 fundAmount,
    uint256 performanceFeeFundAmount,
    uint256 usdAmount,
    uint256 investmentId,
    uint256 redemptionRequestId
  );
  event FeesCollected(
    uint256 managementFeeFundAmount,
    uint256 performanceFeeFundAmount,
    uint256 nonFeeSupply
  );
  event FeesWithdrawn(
    address indexed to,
    uint256 fundAmount,
    uint256 usdAmount
  );
  event FeesChanged(uint256 managementFee, uint256 performanceFee);
  event NewHighWaterPrice(uint256 indexed price);
  event Closed();

  function initialize(
    address[4] memory addressParams, // initialInvestor, aumUpdater, feeBeneficiary, custodian
    uint256[9] memory uintParams, // timelock, managementFee, performanceFee, initialAum, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock, redemptionWaitingPeriod
    bool[2] memory boolParams, // investmentRequestsEnabled, redemptionRequestsEnabled
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory _contactInfo,
    string memory initialInvestorName,
    string memory _tags,
    string memory aumIpfsHash,
    address _manager
  ) public initializer {
    _FeeDividendToken_init(name, symbol, 6);
    require(addressParams[3] != address(0), 'S52'); // Invalid custodian
    require(
      addressParams[2] != address(0) && addressParams[2] != addressParams[3],
      'S50'
    ); // Invalid fee beneficiary
    require(uintParams[3] == 0 || addressParams[0] != address(0), 'S53'); // Initial investor must be set if initial AUM is not 0
    factory = SmartFundFactory(msg.sender);
    usdToken = factory.usdToken();
    manager = _manager;
    aumUpdater = addressParams[1];
    feeBeneficiary = addressParams[2];
    custodian = addressParams[3];
    timelock = uintParams[0];
    managementFee = uintParams[1];
    performanceFee = uintParams[2];
    feeTimelock = uintParams[7];
    redemptionWaitingPeriod = uintParams[8];
    maxInvestors = uintParams[4];
    maxInvestmentsPerInvestor = uintParams[5];
    minInvestmentAmount = uintParams[6];
    investmentRequestsEnabled = boolParams[0];
    redemptionRequestsEnabled = boolParams[1];
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
    aumTimestamp = block.timestamp;
    highWaterPrice = 1e16; // initial price of $0.01
    highWaterPriceTimestamp = block.timestamp;
    if (addressParams[0] != address(0)) {
      _addToWhitelist(addressParams[0], initialInvestorName);
    }
    if (uintParams[3] > 0) {
      activeAndPendingInvestmentCount = 1;
      activeAndPendingInvestmentCountPerInvestor[addressParams[0]] = 1;
      _addInvestment(
        0,
        addressParams[0],
        uintParams[3],
        uintParams[3] * 100, // initial price of 1 cent
        type(uint256).max
      );
      emit NavUpdated(aum, totalSupply(), aumIpfsHash);
    }
    emit NewHighWaterPrice(highWaterPrice);
  }

  modifier onlyManager() {
    require(msg.sender == manager, 'S1'); // Manager only
    _;
  }

  modifier onlyAumUpdater() {
    require(msg.sender == aumUpdater, 'S54'); // AUM updater only
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[msg.sender].whitelisted, 'S3'); // Whitelisted investors only
    _;
  }

  modifier notClosed() {
    require(!closed, 'S57'); // Fund is closed
    _;
  }

  modifier onlyBefore(uint256 deadline) {
    require(block.timestamp <= deadline, 'S4'); // Transaction mined after deadline
    _;
  }

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    uint256 extraInvestmentsToProcess,
    uint256 extraRedemptionsToProcess,
    string calldata ipfsHash
  ) public notClosed onlyAumUpdater onlyBefore(deadline) {
    uint256 previousAumTimestamp = aumTimestamp;
    uint256 previousHighWaterPrice = highWaterPrice;
    aum = _aum;
    aumTimestamp = block.timestamp;
    uint256 supply = totalSupply();
    emit NavUpdated(_aum, supply, ipfsHash);
    uint256 price = (aum * 1e18) / supply;
    if (price > highWaterPrice) {
      highWaterPrice = price;
      highWaterPriceTimestamp = block.timestamp;
      emit NewHighWaterPrice(highWaterPrice);
    }
    _processFees(previousAumTimestamp, previousHighWaterPrice);
    _processInvestments(extraInvestmentsToProcess);
    _processRedemptions(extraRedemptionsToProcess);
  }

  function _processInvestments(uint256 investmentsToProcess) internal {
    investmentsToProcess += 5;
    for (uint256 i = 0; i < investmentsToProcess; i++) {
      if (nextInvestmentRequestIndex == investmentRequests.length) {
        return;
      }
      _addInvestmentFromRequest(nextInvestmentRequestIndex);
      nextInvestmentRequestIndex++;
    }
  }

  function _processRedemptions(uint256 earlyRedemptionsToProcess) internal {
    uint256 maxRedemptionsToProcess = earlyRedemptionsToProcess + 5;
    for (uint256 i = 0; i < maxRedemptionsToProcess; i++) {
      if (nextRedemptionRequestIndex == redemptionRequests.length) {
        return;
      }
      RedemptionRequest storage redemptionRequest =
        redemptionRequests[nextRedemptionRequestIndex];
      if (
        redemptionRequest.timestamp + redemptionWaitingPeriod < block.timestamp
      ) {
        if (earlyRedemptionsToProcess == 0) {
          return;
        }
        earlyRedemptionsToProcess--;
      }
      _redeemFromRequest(nextRedemptionRequestIndex);
      nextRedemptionRequestIndex++;
    }
  }

  function whitelistMulti(address[] calldata investors, string[] calldata names)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      _addToWhitelist(investors[i], names[i]);
    }
  }

  function _addToWhitelist(address investor, string memory name) internal {
    require(investorCount < maxInvestors, 'S5'); // Too many investors
    require(!whitelist[investor].whitelisted, 'S6'); // Investor is already whitelisted
    // require(investor != custodian, 'S31'); // Custodian can't be investor
    investorCount++;
    whitelist[investor] = Investor({ whitelisted: true, name: name });
    emit Whitelisted(investor, name);
  }

  function blacklistMulti(address[] calldata investors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      require(
        activeAndPendingInvestmentCountPerInvestor[investors[i]] == 0,
        'S7'
      ); // Investor has open investments
      require(whitelist[investors[i]].whitelisted, 'S8'); // Investor isn't whitelisted
      investorCount--;
      delete whitelist[investors[i]];
      emit Blacklisted(investors[i]);
    }
  }

  function requestInvestment(
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 investmentDeadline,
    uint256 deadline
  ) public notClosed onlyWhitelisted onlyBefore(deadline) {
    require(investmentRequestsEnabled, 'S55'); // Investment requests are disabled
    require(
      activeAndPendingInvestmentCountPerInvestor[msg.sender] <
        maxInvestmentsPerInvestor,
      'S11' // Investor has reached max investment limit
    );
    require(usdAmount >= minInvestmentAmount, 'S9'); // Less than minimum investment amount
    require(minFundAmount > 0, 'S10'); // Minimum fund amount returned must be greater than 0
    require(investmentDeadline >= block.timestamp + 24 hours, 'S35'); // Investment deadline too short
    _addInvestmentRequest(
      msg.sender,
      usdAmount,
      minFundAmount,
      maxFundAmount,
      investmentDeadline
    );
  }

  function _addInvestmentRequest(
    address investor,
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 investmentDeadline
  ) internal {
    investmentRequests.push(
      InvestmentRequest({
        investor: investor,
        usdAmount: usdAmount,
        minFundAmount: minFundAmount,
        maxFundAmount: maxFundAmount,
        timestamp: block.timestamp,
        deadline: investmentDeadline,
        investmentId: type(uint256).max,
        status: RequestStatus.Pending
      })
    );
    factory.usdTransferFrom(investor, address(this), usdAmount);
    activeAndPendingInvestmentCount++;
    activeAndPendingInvestmentCountPerInvestor[investor]++;
    emit InvestmentRequested(
      investor,
      usdAmount,
      minFundAmount,
      maxFundAmount,
      investmentRequests.length - 1
    );
  }

  function cancelInvestmentRequest(
    uint256 investmentRequestId,
    uint256 deadline
  ) public onlyBefore(deadline) {
    InvestmentRequest storage investmentRequest =
      investmentRequests[investmentRequestId];
    require(investmentRequest.status == RequestStatus.Pending, 'S36'); // Investment request is no longer pending
    require(investmentRequest.investor == msg.sender, 'S37'); // Investor doesn't own that investment request
    require(investmentRequest.deadline < block.timestamp, 'S38'); // Investment request isn't past deadline
    investmentRequest.status = RequestStatus.Failed;
    // send the escrow funds back
    usdToken.transfer(investmentRequest.investor, investmentRequest.usdAmount);
    activeAndPendingInvestmentCount--;
    activeAndPendingInvestmentCountPerInvestor[investmentRequest.investor]--;
    emit InvestmentRequestFailed(
      investmentRequest.investor,
      investmentRequestId
    );
    if (activeAndPendingInvestmentCount == 0 && investments.length > 0) {
      closed = true;
      emit Closed();
    }
  }

  function requestRedemption(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline
  ) public onlyBefore(deadline) {
    require(redemptionRequestsEnabled, 'S56'); // Redemption requests are disabled
    Investment storage investment = investments[investmentId];
    require(investment.investor == msg.sender, 'S13'); // Investor does not own that investment
    require(investment.redeemed == false, 'S14'); // Investment already redeemed
    require(investment.timestamp + timelock <= block.timestamp, 'S15'); // Investment is still locked up
    require(minUsdAmount > 0, 'S39'); // Min amount must be greater than 0
    uint256 redemptionRequestId = redemptionRequests.length;
    if (redemptionRequestId > 0) {
      RedemptionRequest storage redemptionRequest =
        redemptionRequests[investment.redemptionRequestId];
      require(
        redemptionRequest.investmentId != investmentId ||
          redemptionRequest.status == RequestStatus.Failed,
        'S41'
      ); // Investment already has an open redemption request
    }
    investment.redemptionRequestId = redemptionRequestId;
    redemptionRequests.push(
      RedemptionRequest({
        investor: investment.investor,
        minUsdAmount: minUsdAmount,
        timestamp: block.timestamp,
        investmentId: investmentId,
        status: RequestStatus.Pending
      })
    );
    emit RedemptionRequested(
      investment.investor,
      minUsdAmount,
      investmentId,
      redemptionRequestId
    );
  }

  function addManualInvestment(address investor, uint256 usdAmount)
    public
    notClosed
    onlyManager
  {
    require(whitelist[investor].whitelisted, 'S58'); // Investor isn't whitelisted
    uint256 investmentId = investments.length;
    uint256 fundAmount;
    // if intialization investment, use price of 1 cent
    if (investmentId == 0) {
      fundAmount = usdAmount * 100;
    } else {
      fundAmount = (usdAmount * totalSupply()) / aum;
    }
    activeAndPendingInvestmentCount++;
    activeAndPendingInvestmentCountPerInvestor[investor]++;
    _addInvestment(
      investmentId,
      investor,
      usdAmount,
      fundAmount,
      type(uint256).max
    );
  }

  function _addInvestmentFromRequest(uint256 investmentRequestId) internal {
    InvestmentRequest storage investmentRequest =
      investmentRequests[investmentRequestId];
    // if the investor already withdrew his investment after the deadline
    if (investmentRequest.status == RequestStatus.Failed) {
      return;
    }
    // only process if within the deadline, otherwise fallback to failure below
    if (
      investmentRequest.deadline >= block.timestamp &&
      whitelist[investmentRequest.investor].whitelisted
    ) {
      uint256 investmentId = investments.length;
      uint256 fundAmount;
      // if initialization investment, use price of 1 cent
      if (investmentId == 0) {
        fundAmount = investmentRequest.usdAmount * 100;
      } else {
        fundAmount = (investmentRequest.usdAmount * totalSupply()) / aum;
      }
      if (
        fundAmount >= investmentRequest.minFundAmount &&
        fundAmount <= investmentRequest.maxFundAmount
      ) {
        // investment succeeds
        investmentRequest.status = RequestStatus.Processed;
        investmentRequest.investmentId = investmentId;
        usdToken.transfer(custodian, investmentRequest.usdAmount);
        _addInvestment(
          investmentId,
          investmentRequest.investor,
          investmentRequest.usdAmount,
          fundAmount,
          investmentRequestId
        );
        return;
      }
    }
    // investment fails
    investmentRequest.status = RequestStatus.Failed;
    // send the escrow funds back
    usdToken.transfer(investmentRequest.investor, investmentRequest.usdAmount);
    activeAndPendingInvestmentCount--;
    activeAndPendingInvestmentCountPerInvestor[investmentRequest.investor]--;
    emit InvestmentRequestFailed(
      investmentRequest.investor,
      investmentRequestId
    );
    if (activeAndPendingInvestmentCount == 0 && investments.length > 0) {
      closed = true;
      emit Closed();
    }
  }

  function _addInvestment(
    uint256 investmentId,
    address investor,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 investmentRequestId
  ) internal {
    aum += usdAmount;
    _mint(investor, fundAmount);
    investments.push(
      Investment({
        investor: investor,
        initialUsdAmount: usdAmount,
        initialFundAmount: fundAmount,
        initialBaseAmount: toBase(fundAmount),
        initialHighWaterPrice: highWaterPrice,
        timestamp: block.timestamp,
        investmentRequestId: investmentRequestId,
        redemptionRequestId: type(uint256).max,
        redeemed: false
      })
    );
    investmentsCount++;
    emit Invested(
      investor,
      usdAmount,
      fundAmount,
      investmentId,
      investmentRequestId
    );
    emit NavUpdated(aum, totalSupply(), '');
  }

  function addManualRedemption(uint256 investmentId, bool transferUsd)
    public
    onlyManager
  {
    Investment storage investment = investments[investmentId];
    require(!investment.redeemed, 'S59'); // Investment already redeemed
    uint256 performanceFeeFundAmount = _calculatePerformanceFee(investmentId);
    uint256 fundAmount = fromBase(investment.initialBaseAmount);
    uint256 usdAmount =
      ((fundAmount - performanceFeeFundAmount) * aum) / totalSupply();
    if (transferUsd) {
      // transfer usd to investor
      _transferUsdFromCustodian(investment.investor, usdAmount);
    }
    _redeem(
      investmentId,
      fundAmount,
      performanceFeeFundAmount,
      usdAmount,
      type(uint256).max
    );
  }

  function _redeemFromRequest(uint256 redemptionRequestId) internal {
    RedemptionRequest storage redemptionRequest =
      redemptionRequests[redemptionRequestId];
    Investment storage investment = investments[redemptionRequest.investmentId];
    if (!investment.redeemed) {
      uint256 performanceFeeFundAmount =
        _calculatePerformanceFee(redemptionRequest.investmentId);
      uint256 fundAmount = fromBase(investment.initialBaseAmount);
      uint256 usdAmount =
        ((fundAmount - performanceFeeFundAmount) * aum) / totalSupply();
      if (usdAmount >= redemptionRequest.minUsdAmount) {
        // success
        redemptionRequest.status = RequestStatus.Processed;
        // transfer usd to investor
        _transferUsdFromCustodian(investment.investor, usdAmount);
        _redeem(
          redemptionRequest.investmentId,
          fundAmount,
          performanceFeeFundAmount,
          usdAmount,
          redemptionRequestId
        );
        return;
      }
    }
    // fail
    redemptionRequest.status = RequestStatus.Failed;
    emit RedemptionRequestFailed(
      redemptionRequest.investor,
      redemptionRequestId
    );
  }

  function _redeem(
    uint256 investmentId,
    uint256 fundAmount,
    uint256 performanceFeeFundAmount,
    uint256 usdAmount,
    uint256 redemptionRequestId
  ) internal {
    Investment storage investment = investments[investmentId];
    // mark investment as redeemed and lower total investment count
    investment.redeemed = true;
    activeAndPendingInvestmentCount--;
    activeAndPendingInvestmentCountPerInvestor[investment.investor]--;
    // burn fund tokens
    _burn(investment.investor, fundAmount);
    if (performanceFeeFundAmount > 0) {
      // mint performance fee tokens
      _mint(address(this), performanceFeeFundAmount);
    }
    // subtract usd amount from aum
    aum -= usdAmount;
    emit Redeemed(
      investment.investor,
      fundAmount,
      performanceFeeFundAmount,
      usdAmount,
      investmentId,
      redemptionRequestId
    );
    emit NavUpdated(aum, totalSupply(), '');
    if (activeAndPendingInvestmentCount == 0) {
      closed = true;
      emit Closed();
    }
  }

  function _processFees(
    uint256 previousAumTimestamp,
    uint256 previousHighWaterPrice
  ) internal {
    uint256 supply = totalSupply();
    uint256 nonFeeSupply = supply - balanceOf(address(this));
    uint256 managementFeeFundAmount =
      _calculateManagementFee(nonFeeSupply, previousAumTimestamp);

    uint256 performanceFeeFundAmount = 0;
    // if a new high water mark is reached, calculate performance fee
    if (previousHighWaterPrice != highWaterPrice) {
      performanceFeeFundAmount =
        ((highWaterPrice - previousHighWaterPrice) *
          nonFeeSupply *
          performanceFee) /
        highWaterPrice /
        10000;
    }
    _collectFees(
      address(this),
      managementFeeFundAmount + performanceFeeFundAmount
    );
    emit FeesCollected(
      managementFeeFundAmount,
      performanceFeeFundAmount,
      nonFeeSupply
    );
  }

  function _calculateManagementFee(
    uint256 fundAmount,
    uint256 previousFeeTimestamp
  ) internal view returns (uint256) {
    return
      ((block.timestamp - previousFeeTimestamp) * managementFee * fundAmount) /
      365.25 days /
      10000; // management fee is over a whole year (365.25 days) and denoted in basis points so also need to divide by 10000
  }

  function _calculatePerformanceFee(uint256 investmentId)
    internal
    view
    returns (uint256 performanceFeeFundAmount)
  {
    Investment storage investment = investments[investmentId];
    uint256 initialPrice =
      (investment.initialUsdAmount * 1e18) / investment.initialFundAmount;
    uint256 priceNow = (aum * 1e18) / totalSupply();
    // if the last high water mark happened after the investment was made
    if (
      highWaterPriceTimestamp > investment.timestamp &&
      investment.initialHighWaterPrice > initialPrice
    ) {
      // calculate the performance fee between the price at investment and the high water mark at time of investment
      performanceFeeFundAmount =
        ((investment.initialHighWaterPrice - initialPrice) *
          fromBase(investment.initialBaseAmount) *
          performanceFee) /
        investment.initialHighWaterPrice /
        10000;
    } else if (priceNow > initialPrice) {
      // calculate the performance fee between the price at investment and current price
      performanceFeeFundAmount =
        ((priceNow - initialPrice) *
          fromBase(investment.initialBaseAmount) *
          performanceFee) /
        priceNow /
        10000;
    }
  }

  function remainingFundAmount(uint256 investmentId)
    public
    view
    returns (uint256)
  {
    Investment storage investment = investments[investmentId];
    return fromBase(investment.initialBaseAmount);
  }

  function unpaidFees(uint256 investmentId)
    public
    view
    returns (uint256 managementFeeFundAmount, uint256 performanceFeeFundAmount)
  {
    managementFeeFundAmount = _calculateManagementFee(
      remainingFundAmount(investmentId),
      aumTimestamp
    );
    performanceFeeFundAmount = _calculatePerformanceFee(investmentId);
  }

  function withdrawFees(uint256 fundAmount) public onlyManager {
    require(block.timestamp >= feeWithdrawnTimestamp + feeTimelock, 'S44'); // Can't withdraw fees yet
    feeWithdrawnTimestamp = block.timestamp;
    uint256 usdAmount = (fundAmount * aum) / totalSupply();
    _burn(address(this), fundAmount);
    aum -= usdAmount;
    _transferUsdFromCustodian(feeBeneficiary, usdAmount);
    emit FeesWithdrawn(feeBeneficiary, fundAmount, usdAmount);
    emit NavUpdated(aum, totalSupply(), '');
  }

  function editFundDetails(
    string calldata _logoUrl,
    string calldata _contactInfo,
    string calldata _tags
  ) public onlyManager {
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
  }

  function editInvestorLimits(
    uint256 _maxInvestors,
    uint256 _maxInvestmentsPerInvestor,
    uint256 _minInvestmentAmount,
    bool _investmentRequestsEnabled,
    bool _redemptionRequestsEnabled
  ) public onlyManager {
    maxInvestors = _maxInvestors;
    maxInvestmentsPerInvestor = _maxInvestmentsPerInvestor;
    minInvestmentAmount = _minInvestmentAmount;
    investmentRequestsEnabled = _investmentRequestsEnabled;
    redemptionRequestsEnabled = _redemptionRequestsEnabled;
  }

  function editFees(
    uint256 _managementFee,
    uint256 _performanceFee,
    address _feeBeneficiary
  ) public onlyManager {
    require(
      _managementFee <= managementFee && _performanceFee <= performanceFee,
      'S48'
    ); // Can't increase fees
    require(
      _feeBeneficiary != address(0) && _feeBeneficiary != custodian,
      'S51'
    ); // Invalid fee beneficiary
    if (_managementFee != managementFee || _performanceFee != performanceFee) {
      emit FeesChanged(_managementFee, _performanceFee);
    }
    managementFee = _managementFee;
    performanceFee = _performanceFee;
    feeBeneficiary = _feeBeneficiary;
  }

  function editAumUpdater(address _aumUpdater) public onlyManager {
    aumUpdater = _aumUpdater;
  }

  function _transferUsdFromCustodian(address to, uint256 amount) internal {
    require(
      usdToken.balanceOf(custodian) >= amount &&
        usdToken.allowance(custodian, address(factory)) >= amount,
      'S42'
    ); // Not enough usd tokens available and approved
    factory.usdTransferFrom(custodian, to, amount);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    require(from == address(0) || to == address(0), 'S26'); // Token is not transferable
  }
}
