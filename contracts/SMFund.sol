// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.2;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol';

import './SMFundFactory.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

contract SMFund is Initializable, ERC20Upgradeable {
  SMFundFactory internal factory;
  ERC20 internal usdToken;
  uint8 internal _decimals;
  address public manager;
  uint256 public timelock;
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  bool public signedAum;
  string public logoUrl;
  string public contactInfo;
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals

  uint256 public aum;
  uint256 public aumTimestamp; // block timestamp of last aum update
  // uint256 public aumAverage; // average aum since the last fee sweep
  // uint256 public aumAverageCount; // number of aum updates since the last fee sweep
  uint256 public globalHighWaterPrice; // highest ((aum * 10^18) / supply)
  uint256 public globalHighWaterPriceTimestamp; // timestamp of highest price
  uint256 public highWaterPriceSinceLastFee; // highest price * 10^18 since last fee sweep
  uint256 public highWaterPriceTimestampSinceLastFee; // timestamp of highest price since last fee sweep
  uint256 public lastFeeTimestamp; // timestamp of the start of the last fee update
  bool public processingRequestsAndFees; // whether the fund manager is in the middle of processing requests and/or fees
  uint256 public processingRedemptionsEarlyCount; // how many redemption requests the fund manager wants to process early this time
  uint256 public feesInEscrow; // keeps track of all usd held by fund contract that are from fees as opposed to investment requests

  struct Investor {
    bool whitelisted;
    string name;
  }
  mapping(address => Investor) public whitelist;

  struct Investment {
    address investor;
    uint256 initialUsdAmount;
    uint256 initialFundAmount;
    uint256 fundAmount;
    uint256 timestamp;
    uint256 lastFeeTimestamp;
    uint256 highWaterPrice; // highest fund price while this investment has been active * 10^18
    uint256 highWaterPriceTimestamp;
    uint256 usdManagementFeesCollected;
    uint256 usdPerformanceFeesCollected;
    uint256 investmentRequestId;
    uint256 redemptionRequestId;
    bool redeemed;
  }
  Investment[] public investments;

  EnumerableSetUpgradeable.UintSet internal activeInvestmentIds;
  uint256 public nextFeeActiveInvestmentIndex;

  uint256 internal investorCount;
  mapping(address => uint256) internal activeInvestmentCountPerInvestor;

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

  event NavUpdated(uint256 aum, uint256 totalSupply);
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
    uint256 usdAmount,
    uint256 investmentId,
    uint256 redemptionRequestId
  );
  event FeesCollected(
    address indexed investor,
    uint256 fundAmountManagement,
    uint256 fundAmountPerformance,
    uint256 usdAmountManagement,
    uint256 usdAmountPerformance,
    uint256 investmentId
  );
  event FeesWithdrawn(address indexed to, uint256 usdAmount);
  event NewGlobalHighWaterPrice(uint256 indexed price);
  event StartedProcessingRequestsAndFees();
  event DoneProcessingRequestsAndFees();

  function initialize(
    address[2] memory addressParams, // manager, initialInvestor
    uint256[8] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount
    bool _signedAum,
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory _contactInfo,
    string memory initialInvestorName,
    bytes memory signature
  ) public initializer onlyBefore(uintParams[4]) {
    __ERC20_init(name, symbol);
    require(uintParams[3] > 0, 'S0'); // Initial AUM must be greater than 0
    factory = SMFundFactory(msg.sender);
    usdToken = factory.usdToken();
    _decimals = usdToken.decimals();
    manager = addressParams[0];
    signedAum = _signedAum;
    timelock = uintParams[0];
    managementFee = uintParams[1];
    performanceFee = uintParams[2];
    maxInvestors = uintParams[5];
    maxInvestmentsPerInvestor = uintParams[6];
    minInvestmentAmount = uintParams[7];
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    _addToWhitelist(addressParams[1], initialInvestorName);
    _addInvestmentRequest(
      addressParams[1],
      uintParams[3],
      1,
      type(uint256).max,
      block.timestamp
    );
    _addInvestment(0);
    verifyAumSignature(manager, uintParams[4], signature);
    globalHighWaterPrice = (aum * 1e18) / totalSupply();
    globalHighWaterPriceTimestamp = block.timestamp;
    emit NewGlobalHighWaterPrice(globalHighWaterPrice);
  }

  modifier onlyManager() {
    require(msg.sender == manager, 'S1'); // Fund manager only
    _;
  }

  modifier onlyWhitelisted() {
    require(whitelist[msg.sender].whitelisted, 'S3'); // Whitelisted investors only
    _;
  }

  modifier onlyBefore(uint256 deadline) {
    require(block.timestamp <= deadline, 'S4'); // Transaction mined after deadline
    _;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    bool processFees,
    uint256 processCount,
    uint256 earlyRedemptionCount,
    bytes calldata signature
  ) public onlyBefore(deadline) {
    require(!processingRequestsAndFees, ''); // Can't update AUM until finished processing requests and fees
    require(!processFees || block.timestamp > lastFeeTimestamp + 27 days, ''); // Can't process fees until 27 days have passed
    aum = _aum;
    aumTimestamp = block.timestamp;
    // update the rolling average
    // if (aumAverageCount > 0) {
    //   aumAverage =
    //     (aumAverage * aumAverageCount + _aum) /
    //     (aumAverageCount + 1);
    // } else {
    //   aumAverage = _aum;
    // }
    // aumAverageCount++;
    verifyAumSignature(msg.sender, deadline, signature);
    uint256 supply = totalSupply();
    emit NavUpdated(_aum, supply);
    uint256 price = (aum * 1e18) / supply;
    if (price > globalHighWaterPrice) {
      globalHighWaterPrice = price;
      globalHighWaterPriceTimestamp = block.timestamp;
      emit NewGlobalHighWaterPrice(globalHighWaterPrice);
    }
    if (price > highWaterPriceSinceLastFee) {
      highWaterPriceSinceLastFee = price;
      highWaterPriceTimestampSinceLastFee = block.timestamp;
    }
    if (processFees || block.timestamp > lastFeeTimestamp + 32 days) {
      lastFeeTimestamp = block.timestamp;
      // aumAverageCount = 0;
    }
    processingRequestsAndFees = true;
    processingRedemptionsEarlyCount = earlyRedemptionCount;
    emit StartedProcessingRequestsAndFees();
    _processRequestsAndFees(processCount);
  }

  function processRequestsAndFees(uint256 processCount) public onlyManager {
    require(processingRequestsAndFees, ''); // Not currently processing requests and fees
    _processRequestsAndFees(processCount);
  }

  function _processRequestsAndFees(uint256 processCount) internal {
    // first process redemptions
    // TODO: may need this if statement to prevent indexing out of bounds in storage, add back if it reverts the tx
    // if (nextRedemptionRequestIndex < redemptionRequests.length) {
    RedemptionRequest storage redemptionRequest =
      redemptionRequests[nextRedemptionRequestIndex];
    while (
      nextRedemptionRequestIndex < redemptionRequests.length &&
      (redemptionRequest.timestamp + 6 days < aumTimestamp ||
        (processingRedemptionsEarlyCount > 0 &&
          redemptionRequest.timestamp < aumTimestamp))
    ) {
      if (processCount == 0) return;
      _redeem(nextRedemptionRequestIndex);
      redemptionRequest = redemptionRequests[nextRedemptionRequestIndex++];
      processCount--;
      if (processingRedemptionsEarlyCount > 0) {
        processingRedemptionsEarlyCount--;
      }
    }
    // }
    // then process fees
    if (lastFeeTimestamp == aumTimestamp) {
      while (
        nextFeeActiveInvestmentIndex <
        EnumerableSetUpgradeable.length(activeInvestmentIds)
      ) {
        if (processCount == 0) return;
        uint256 investmentId =
          EnumerableSetUpgradeable.at(
            activeInvestmentIds,
            nextFeeActiveInvestmentIndex
          );
        Investment storage investment = investments[investmentId];
        if (investment.timestamp + 30 days < lastFeeTimestamp) {
          _processFees(investmentId);
        }
        nextFeeActiveInvestmentIndex++;
        processCount--;
      }
    }
    // and finally process investments
    while (nextInvestmentRequestIndex < investmentRequests.length) {
      if (processCount == 0) return;
      _addInvestment(nextInvestmentRequestIndex);
      nextInvestmentRequestIndex++;
      processCount--;
    }
    if (lastFeeTimestamp == aumTimestamp) {
      highWaterPriceSinceLastFee = 0;
      highWaterPriceTimestampSinceLastFee = 0;
    }
    nextFeeActiveInvestmentIndex = 0;
    processingRequestsAndFees = false;
    emit DoneProcessingRequestsAndFees();
  }

  function whitelistMulti(address[] calldata investors, string[] calldata names)
    public
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      _addToWhitelist(investors[i], names[i]);
    }
  }

  function _addToWhitelist(address investor, string memory name) internal {
    require(investorCount < maxInvestors, 'S5'); // Too many investors
    require(!whitelist[investor].whitelisted, 'S6'); // Investor is already whitelisted
    require(investor != manager, 'S31'); // Manager can't be investor
    investorCount++;
    whitelist[investor] = Investor({ whitelisted: true, name: name });
    emit Whitelisted(investor, name);
  }

  function blacklistMulti(address[] calldata investors) public onlyManager {
    for (uint256 i = 0; i < investors.length; i++) {
      require(activeInvestmentCountPerInvestor[investors[i]] == 0, 'S7'); // Investor has open investments
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
  ) public onlyWhitelisted onlyBefore(deadline) {
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
    require(
      activeInvestmentCountPerInvestor[investor] < maxInvestmentsPerInvestor,
      'S11' // Investor has reached max investment limit
    );
    require(usdAmount >= minInvestmentAmount, 'S9'); // Less than minimum investment amount
    require(minFundAmount > 0, 'S10'); // Minimum fund amount returned must be greater than 0
    require(investmentDeadline > block.timestamp + 24 hours, ''); // Investment deadline too short
    investmentRequests.push(
      InvestmentRequest({
        investor: investor,
        usdAmount: usdAmount,
        minFundAmount: minFundAmount,
        maxFundAmount: maxFundAmount,
        timestamp: block.timestamp,
        deadline: investmentDeadline,
        investmentId: 0,
        status: RequestStatus.Pending
      })
    );
    // only skip transferring on the initial investment
    if (investmentRequests.length > 1) {
      factory.usdTransferFrom(investor, address(this), usdAmount);
    }
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
  ) public onlyWhitelisted onlyBefore(deadline) {
    InvestmentRequest storage investmentRequest =
      investmentRequests[investmentRequestId];
    require(investmentRequest.status == RequestStatus.Pending, ''); // Investment request is no longer pending
    require(investmentRequest.investor == msg.sender, ''); // Investor doesn't own that investment request
    require(investmentRequest.deadline < block.timestamp, ''); // Investment request isn't past deadline
    investmentRequest.status = RequestStatus.Failed;
    // send the escrow funds back
    usdToken.transfer(investmentRequest.investor, investmentRequest.usdAmount);
    emit InvestmentRequestFailed(
      investmentRequest.investor,
      investmentRequestId
    );
  }

  function requestRedemption(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline
  ) public onlyBefore(deadline) {
    Investment storage investment = investments[investmentId];
    require(investment.investor == msg.sender, 'S13'); // Investor does not own that investment
    require(investment.redeemed == false, 'S14'); // Investment already redeemed
    require(investment.timestamp + timelock <= block.timestamp, 'S15'); // Investment is still locked up
    require(minUsdAmount > 0, ''); // Min amount must be greater than 0
    require(
      EnumerableSetUpgradeable.length(activeInvestmentIds) == 1 ||
        investmentId != 0,
      ''
    ); // Initial investment can only be redeemed after all other investments
    uint256 redemptionRequestId = redemptionRequests.length;
    if (redemptionRequestId > 0) {
      RedemptionRequest storage redemptionRequest =
        redemptionRequests[investment.redemptionRequestId];
      require(
        redemptionRequest.investmentId != investmentId ||
          redemptionRequest.status == RequestStatus.Failed,
        ''
      ); // Investment already has an open redemption request
    }
    investment.redemptionRequestId = redemptionRequestId;
    redemptionRequests.push(
      RedemptionRequest({
        investor: msg.sender,
        minUsdAmount: minUsdAmount,
        timestamp: block.timestamp,
        investmentId: investmentId,
        status: RequestStatus.Pending
      })
    );
    emit RedemptionRequested(
      msg.sender,
      minUsdAmount,
      investmentId,
      redemptionRequestId
    );
  }

  function _addInvestment(uint256 investmentRequestId) internal {
    InvestmentRequest storage investmentRequest =
      investmentRequests[investmentRequestId];

    // if the investor already withdrew his investment after the deadline
    if (investmentRequest.status == RequestStatus.Failed) {
      return;
    }

    // only process if within the deadline, otherwise fallback to failure below
    if (investmentRequest.deadline >= block.timestamp) {
      uint256 investmentId = investments.length;
      uint256 fundAmount;
      // if intialization investment, use price of 1 cent
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
        // don't transfer tokens if it's the initialization investment
        if (investmentId != 0) {
          usdToken.transfer(manager, investmentRequest.usdAmount);
        }
        aum += investmentRequest.usdAmount;
        _mint(investmentRequest.investor, fundAmount);

        investments.push(
          Investment({
            investor: investmentRequest.investor,
            initialUsdAmount: investmentRequest.usdAmount,
            initialFundAmount: fundAmount,
            fundAmount: fundAmount,
            timestamp: block.timestamp,
            lastFeeTimestamp: block.timestamp,
            highWaterPrice: (aum * 1e18) / totalSupply(),
            highWaterPriceTimestamp: block.timestamp,
            usdManagementFeesCollected: 0,
            usdPerformanceFeesCollected: 0,
            investmentRequestId: investmentRequestId,
            redemptionRequestId: 0,
            redeemed: false
          })
        );
        EnumerableSetUpgradeable.add(activeInvestmentIds, investmentId);
        activeInvestmentCountPerInvestor[investmentRequest.investor]++;
        emit Invested(
          investmentRequest.investor,
          investmentRequest.usdAmount,
          fundAmount,
          investmentId,
          investmentRequestId
        );
        emit NavUpdated(aum, totalSupply());
        return;
      }
    }
    // investment fails
    investmentRequest.status = RequestStatus.Failed;
    // send the escrow funds back
    usdToken.transfer(investmentRequest.investor, investmentRequest.usdAmount);
    emit InvestmentRequestFailed(
      investmentRequest.investor,
      investmentRequestId
    );
  }

  function _redeem(uint256 redemptionRequestId) internal {
    RedemptionRequest storage redemptionRequest =
      redemptionRequests[redemptionRequestId];
    Investment storage investment = investments[redemptionRequest.investmentId];
    if (!investment.redeemed) {
      // calculate fees in usd and fund token
      (uint256 usdManagementFee, uint256 fundManagementFee) =
        calculateManagementFee(redemptionRequest.investmentId);
      (uint256 usdPerformanceFee, uint256 fundPerformanceFee) =
        calculatePerformanceFee(redemptionRequest.investmentId);

      // calculate usd value of the current fundAmount remaining in the investment
      uint256 usdAmount =
        ((investment.fundAmount - (fundManagementFee + fundPerformanceFee)) *
          aum) / totalSupply();
      if (usdAmount >= redemptionRequest.minUsdAmount) {
        // success
        // extract fees
        _extractFees(
          redemptionRequest.investmentId,
          usdManagementFee,
          fundManagementFee,
          usdPerformanceFee,
          fundPerformanceFee
        );
        // mark investment as redeemed and lower total investment count
        investment.redeemed = true;
        EnumerableSetUpgradeable.remove(
          activeInvestmentIds,
          redemptionRequest.investmentId
        );
        activeInvestmentCountPerInvestor[investment.investor]--;
        redemptionRequest.status = RequestStatus.Processed;
        // burn fund tokens
        _burn(investment.investor, investment.fundAmount);
        // subtract usd amount from aum
        aum -= usdAmount;
        if (redemptionRequest.investmentId != 0) {
          // transfer usd to investor
          require(
            usdToken.balanceOf(manager) >= usdAmount &&
              usdToken.allowance(manager, address(factory)) >= usdAmount,
            ''
          ); // Not enough usd tokens available and approved
          factory.usdTransferFrom(manager, investment.investor, usdAmount);
        }
        emit Redeemed(
          investment.investor,
          investment.fundAmount,
          usdAmount,
          redemptionRequest.investmentId,
          redemptionRequestId
        );
        emit NavUpdated(aum, totalSupply());
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

  function _processFees(uint256 investmentId) internal {
    // calculate fees in usd and fund token
    (uint256 usdManagementFee, uint256 fundManagementFee) =
      calculateManagementFee(investmentId);
    (uint256 usdPerformanceFee, uint256 fundPerformanceFee) =
      calculatePerformanceFee(investmentId);

    _extractFees(
      investmentId,
      usdManagementFee,
      fundManagementFee,
      usdPerformanceFee,
      fundPerformanceFee
    );
  }

  function _extractFees(
    uint256 investmentId,
    uint256 usdManagementFee,
    uint256 fundManagementFee,
    uint256 usdPerformanceFee,
    uint256 fundPerformanceFee
  ) internal {
    Investment storage investment = investments[investmentId];

    // update totals stored in the investment struct
    investment.usdManagementFeesCollected += usdManagementFee;
    investment.usdPerformanceFeesCollected += usdPerformanceFee;
    investment.fundAmount -= (fundManagementFee + fundPerformanceFee);
    investment.lastFeeTimestamp = block.timestamp;
    if (
      investment.timestamp < lastFeeTimestamp &&
      highWaterPriceSinceLastFee > investment.highWaterPrice
    ) {
      investment.highWaterPrice = highWaterPriceSinceLastFee;
    }

    // 2 burns and 2 transfers are done so events show up separately on etherscan and elsewhere which makes matching them up with what the UI shows a lot easier
    // burn the two fee amounts from the investor
    _burn(investment.investor, fundManagementFee);
    _burn(investment.investor, fundPerformanceFee);
    uint256 totalUsdFee = usdManagementFee + usdPerformanceFee;
    require(
      usdToken.balanceOf(manager) >= totalUsdFee &&
        usdToken.allowance(manager, address(factory)) >= totalUsdFee,
      ''
    ); // Not enough usd tokens available and approved
    // decrement fund aum by the usd amounts
    aum -= totalUsdFee;
    // increment fees in escrow count by the usd amounts
    feesInEscrow += totalUsdFee;
    // transfer usd for the two fee amounts
    factory.usdTransferFrom(manager, address(this), usdManagementFee);
    factory.usdTransferFrom(manager, address(this), usdPerformanceFee);
    emit FeesCollected(
      investment.investor,
      fundManagementFee,
      fundPerformanceFee,
      usdManagementFee,
      usdPerformanceFee,
      investmentId
    );
    emit NavUpdated(aum, totalSupply());
  }

  function withdrawFees(uint256 usdAmount, address to) public onlyManager {
    // safemath on underflow will prevent withdrawing more than is owed
    feesInEscrow -= usdAmount;
    usdToken.transfer(to, usdAmount);
    emit FeesWithdrawn(to, usdAmount);
  }

  function editLogo(string calldata _logoUrl) public onlyManager {
    logoUrl = _logoUrl;
  }

  function editContactInfo(string calldata _contactInfo) public onlyManager {
    contactInfo = _contactInfo;
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
  ) internal view {
    if (!signedAum) {
      require(sender == manager, 'S28'); // Fund manager only
    } else if (sender == manager) {
      bytes32 message = keccak256(abi.encode(manager, aum, deadline));
      address signer =
        ECDSAUpgradeable.recover(
          ECDSAUpgradeable.toEthSignedMessageHash(message),
          signature
        );
      require(signer == factory.owner(), 'S29'); // AUM signer mismatch
    } else {
      require(sender == factory.owner(), 'S30'); // AUM signer only
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
      ((block.timestamp - investment.lastFeeTimestamp) *
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
    // usd value of the investment at the high water mark
    uint256 usdValue = highWaterMark(investmentId);
    uint256 totalUsdPerformanceFee = 0;
    if (usdValue > investment.initialUsdAmount) {
      // calculate current performance fee from initial usd value of investment to current usd value
      totalUsdPerformanceFee =
        ((usdValue - investment.initialUsdAmount) * performanceFee) /
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
    uint256 price;
    if (
      investment.timestamp < lastFeeTimestamp &&
      highWaterPriceSinceLastFee > investment.highWaterPrice
    ) {
      price = highWaterPriceSinceLastFee;
    } else {
      price = investment.highWaterPrice;
    }
    usdValue = (price * investment.fundAmount) / 1e18;
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
