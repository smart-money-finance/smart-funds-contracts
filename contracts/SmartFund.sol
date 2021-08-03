// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.6;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';

import './FeeDividendToken.sol';
import './SmartFundFactory.sol';

// import 'hardhat/console.sol';

contract SmartFund is Initializable, FeeDividendToken {
  SmartFundFactory internal factory;
  ERC20Permit internal usdToken;
  address public manager;
  address public aumUpdater;
  address public feeBeneficiary;
  uint256 public timelock;
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  uint256 public feeTimelock;
  string public logoUrl;
  string public contactInfo;
  string public tags;
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals
  bool public usingUsdToken; // enables requests, transfers usd on redemption and fee withdrawal

  bool public closed; // set true after last investment redeems
  uint256 public aum;
  uint256 public aumTimestamp; // block timestamp of last aum update
  uint256 public highWaterPrice; // highest ((aum * 10^18) / supply)
  uint256 public highWaterPriceTimestamp; // timestamp of highest price
  uint256 public feeWithdrawnTimestamp;
  uint256 public capitalContributed;

  mapping(address => bool) public whitelist;

  struct Investment {
    InvestmentRequest investmentRequest; // default 0 values if it's a manual investment
    address investor;
    uint256 initialUsdAmount;
    uint256 initialFundAmount;
    uint256 initialBaseAmount;
    uint256 initialHighWaterPrice;
    bool usdTransferred;
    uint256 timestamp;
    uint256 redeemedTimestamp; // 0 if not redeemed
    bool redemptionUsdTransferred;
  }
  Investment[] public investments;

  uint256 public investorCount;
  mapping(address => uint256) public activeInvestmentCountPerInvestor;
  uint256 public activeInvestmentCount;

  struct InvestmentRequest {
    uint256 usdAmount;
    uint256 minFundAmount;
    uint256 maxFundAmount;
    uint256 deadline;
    uint256 timestamp;
    uint256 nonce;
  }
  mapping(address => InvestmentRequest) public investmentRequests; // investor address to investment request

  struct RedemptionRequest {
    uint256 minUsdAmount;
    uint256 deadline;
    uint256 timestamp;
    uint256 nonce;
  }
  mapping(uint256 => RedemptionRequest) public redemptionRequests; // investment id to redemption request

  event NavUpdated(uint256 aum, uint256 totalSupply, string ipfsHash);
  event Whitelisted(address indexed investor);
  event Blacklisted(address indexed investor);
  event InvestmentRequestUpdated(
    address indexed investor,
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 deadline,
    uint256 nonce
  );
  event Invested(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 investmentRequestNonce
  );
  event RedemptionRequestUpdated(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 minUsdAmount,
    uint256 deadline,
    uint256 nonce
  );
  event Redeemed(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 fundAmount,
    uint256 performanceFeeFundAmount,
    uint256 usdAmount
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

  error InvalidFeeBeneficiary();
  error InvalidMaxInvestors();
  error ManagerOnly();
  error AumUpdaterOnly();
  error WhitelistedOnly();
  error FundClosed();
  error AfterDeadline();
  error NotActive();
  error TooManyInvestors();
  error AlreadyWhitelisted();
  error InvalidInvestor();
  error InvestorIsActive();
  error NotInvestor();
  error MaxInvestmentsReached();
  error InvestmentTooSmall();
  error MinAmountZero();
  error NotInvestmentOwner();
  error InvestmentRedeemed();
  error InvestmentLockedUp();
  error NotPastFeeTimelock();
  error FeeBeneficiaryNotSet();
  error InvalidFees();
  error NotTransferable();
  error NotUsingUsdToken();
  error InvalidMaxAmount();
  error PriceOutsideTolerance();
  error NoExistingRequest();
  error RequestAlreadyCreated();
  error NonceMismatch();
  error InvestorsNoncesLengthMismatch();
  error InsufficientUsd();
  error InsufficientUsdApproved();
  error PermitValueMismatch();
  error InvalidInvestmentId();

  function initialize(
    address[2] memory addressParams, // aumUpdater, feeBeneficiary
    uint256[7] memory uintParams, // timelock, managementFee, performanceFee, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory _contactInfo,
    string memory _tags,
    bool _usingUsdToken,
    address _manager
  ) public initializer {
    _FeeDividendToken_init(name, symbol, 6);
    factory = SmartFundFactory(msg.sender);
    usdToken = factory.usdToken();
    manager = _manager;
    aumUpdater = addressParams[0];
    feeBeneficiary = addressParams[1];
    if (feeBeneficiary == manager) {
      revert InvalidFeeBeneficiary();
    }
    timelock = uintParams[0];
    managementFee = uintParams[1];
    performanceFee = uintParams[2];
    maxInvestors = uintParams[3];
    maxInvestmentsPerInvestor = uintParams[4];
    minInvestmentAmount = uintParams[5];
    feeTimelock = uintParams[6];
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
    usingUsdToken = _usingUsdToken;
    aumTimestamp = block.timestamp;
    feeWithdrawnTimestamp = block.timestamp;
    highWaterPrice = 1e16; // initial price of $0.01
    highWaterPriceTimestamp = block.timestamp;
    emit NewHighWaterPrice(highWaterPrice);
  }

  modifier onlyManager() {
    if (msg.sender != manager) {
      revert ManagerOnly(); // Manager only
    }
    _;
  }

  modifier onlyAumUpdater() {
    if (msg.sender != aumUpdater) {
      revert AumUpdaterOnly(); // AUM updater only
    }
    _;
  }

  modifier onlyWhitelisted() {
    if (!whitelist[msg.sender]) {
      revert WhitelistedOnly();
    }
    _;
  }

  modifier notClosed() {
    if (closed) {
      revert FundClosed(); // Fund is closed
    }
    _;
  }

  modifier onlyUsingUsdToken() {
    if (!usingUsdToken) {
      revert NotUsingUsdToken();
    }
    _;
  }

  modifier onlyValidInvestmentId(uint256 investmentId) {
    if (investmentId >= investments.length) {
      revert InvalidInvestmentId();
    }
    _;
  }

  function updateAum(uint256 _aum, string calldata ipfsHash)
    public
    notClosed
    onlyAumUpdater
  {
    if (investments.length == 0) {
      revert NotActive(); // Fund cannot have AUM until the first investment is made
    }
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
  }

  function updateAumAndProcessInvestments(
    uint256 _aum,
    string calldata ipfsHash,
    address[] calldata investors,
    uint256[] calldata currentNonces
  ) public {
    if (investors.length != currentNonces.length) {
      revert InvestorsNoncesLengthMismatch();
    }
    updateAum(_aum, ipfsHash);
    for (uint256 i = 0; i < investors.length; i++) {
      processInvestmentRequest(investors[i], currentNonces[i]);
    }
  }

  function whitelistMulti(address[] calldata investors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      _addToWhitelist(investors[i]);
    }
  }

  function _addToWhitelist(address investor) internal {
    if (investorCount >= maxInvestors) {
      revert TooManyInvestors(); // Too many investors
    }
    if (whitelist[investor]) {
      revert AlreadyWhitelisted();
    }
    if (investor == manager) {
      revert InvalidInvestor();
    }
    investorCount++;
    whitelist[investor] = true;
    emit Whitelisted(investor);
  }

  function blacklistMulti(address[] calldata investors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < investors.length; i++) {
      if (activeInvestmentCountPerInvestor[investors[i]] > 0) {
        revert InvestorIsActive();
      }
      if (!whitelist[investors[i]]) {
        revert NotInvestor();
      }
      investorCount--;
      delete whitelist[investors[i]];
      uint256 newNonce = investmentRequests[investors[i]].nonce;
      delete investmentRequests[investors[i]];
      investmentRequests[investors[i]].nonce = newNonce;
      investmentRequests[investors[i]].timestamp = block.timestamp;
      emit InvestmentRequestUpdated(investors[i], 0, 0, 0, 0, newNonce);
      emit Blacklisted(investors[i]);
    }
  }

  // Nonce prevents a race condition:
  // Investor sends out tx to update an existing request
  // Manager sends out tx to process request, accidentally frontruns, tx mines first
  // Investor's tx mines and now he has a second investment request opened that he didn't intend
  // It also prevents the manager from processing a request that has been updated since he sent the tx
  function updateInvestmentRequest(
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 deadline,
    uint256 currentNonce,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public notClosed onlyUsingUsdToken onlyWhitelisted {
    if (investmentRequests[msg.sender].nonce != currentNonce) {
      revert NonceMismatch();
    }
    if (
      activeInvestmentCountPerInvestor[msg.sender] >= maxInvestmentsPerInvestor
    ) {
      revert MaxInvestmentsReached(); // Investor has reached max investment limit
    }
    if (usdAmount < 1 || usdAmount < minInvestmentAmount) {
      revert InvestmentTooSmall();
    }
    if (minFundAmount == 0) {
      revert MinAmountZero(); // Minimum amount must be greater than 0
    }
    if (maxFundAmount <= minFundAmount) {
      revert InvalidMaxAmount();
    }
    if (deadline < block.timestamp) {
      revert AfterDeadline();
    }
    _verifyUsdBalance(msg.sender, usdAmount);
    usdToken.permit(msg.sender, address(this), usdAmount, deadline, v, r, s);
    // save some gas?
    if (investmentRequests[msg.sender].deadline != 0) {
      delete investmentRequests[msg.sender];
    }
    uint256 newNonce = currentNonce + 1;
    investmentRequests[msg.sender] = InvestmentRequest({
      usdAmount: usdAmount,
      minFundAmount: minFundAmount,
      maxFundAmount: maxFundAmount,
      timestamp: block.timestamp,
      deadline: deadline,
      nonce: newNonce
    });
    emit InvestmentRequestUpdated(
      msg.sender,
      usdAmount,
      minFundAmount,
      maxFundAmount,
      deadline,
      newNonce
    );
  }

  function cancelInvestmentRequest(
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public notClosed onlyUsingUsdToken onlyWhitelisted {
    if (investmentRequests[msg.sender].deadline == 0) {
      revert NoExistingRequest();
    }
    usdToken.permit(msg.sender, address(this), 0, permitDeadline, v, r, s);
    uint256 newNonce = investmentRequests[msg.sender].nonce + 1;
    delete investmentRequests[msg.sender];
    investmentRequests[msg.sender].nonce = newNonce;
    investmentRequests[msg.sender].timestamp = block.timestamp;
    emit InvestmentRequestUpdated(msg.sender, 0, 0, 0, 0, newNonce);
  }

  function _addInvestment(
    address investor,
    uint256 usdAmount,
    uint256 fundAmount,
    bool transferUsd,
    InvestmentRequest memory investmentRequest
  ) internal {
    if (
      activeInvestmentCountPerInvestor[investor] >= maxInvestmentsPerInvestor
    ) {
      revert MaxInvestmentsReached(); // Investor has reached max investment limit
    }
    if (transferUsd) {
      _verifyUsdBalance(investor, usdAmount);
      _verifyUsdAllowance(investor, usdAmount);
      usdToken.transferFrom(investor, manager, usdAmount);
    }
    aum += usdAmount;
    capitalContributed += usdAmount;
    _mint(investor, fundAmount);
    investments.push(
      Investment({
        investmentRequest: investmentRequest,
        investor: investor,
        initialUsdAmount: usdAmount,
        initialFundAmount: fundAmount,
        initialBaseAmount: toBase(fundAmount),
        initialHighWaterPrice: highWaterPrice,
        usdTransferred: transferUsd,
        timestamp: block.timestamp,
        redeemedTimestamp: 0,
        redemptionUsdTransferred: false
      })
    );
    activeInvestmentCount++;
    activeInvestmentCountPerInvestor[investor]++;
    emit Invested(
      investor,
      investments.length - 1,
      usdAmount,
      fundAmount,
      investmentRequest.nonce
    );
    emit NavUpdated(aum, totalSupply(), '');
  }

  function processInvestmentRequest(address investor, uint256 currentNonce)
    public
    notClosed
    onlyUsingUsdToken
    onlyManager
  {
    if (!whitelist[investor]) {
      revert NotInvestor();
    }
    InvestmentRequest storage investmentRequest = investmentRequests[investor];
    if (investmentRequest.nonce != currentNonce) {
      revert NonceMismatch();
    }
    if (investmentRequest.deadline == 0) {
      revert NoExistingRequest();
    }
    if (investmentRequest.deadline < block.timestamp) {
      revert AfterDeadline();
    }
    uint256 fundAmount;
    // if first investment, use price of 1 cent
    if (investments.length == 0) {
      fundAmount = investmentRequest.usdAmount * 100;
    } else {
      fundAmount = (investmentRequest.usdAmount * totalSupply()) / aum;
    }
    if (
      fundAmount < investmentRequest.minFundAmount ||
      fundAmount > investmentRequest.maxFundAmount
    ) {
      revert PriceOutsideTolerance();
    }
    _addInvestment(
      investor,
      investmentRequest.usdAmount,
      fundAmount,
      true,
      investmentRequest
    );
    uint256 newNonce = currentNonce + 1;
    delete investmentRequests[investor];
    investmentRequests[investor].nonce = newNonce;
    investmentRequests[investor].timestamp = block.timestamp;
    emit InvestmentRequestUpdated(investor, 0, 0, 0, 0, newNonce);
  }

  function addManualInvestment(address investor, uint256 usdAmount)
    public
    notClosed
    onlyManager
  {
    if (!whitelist[investor]) {
      _addToWhitelist(investor);
    }
    uint256 fundAmount;
    // if intialization investment, use price of 1 cent
    if (investments.length == 0) {
      fundAmount = usdAmount * 100;
    } else {
      fundAmount = (usdAmount * totalSupply()) / aum;
    }
    _addInvestment(
      investor,
      usdAmount,
      fundAmount,
      false,
      InvestmentRequest({
        usdAmount: 0,
        minFundAmount: 0,
        maxFundAmount: 0,
        timestamp: 0,
        deadline: 0,
        nonce: 0
      })
    );
  }

  function updateRedemptionRequest(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline,
    uint256 currentNonce
  )
    public
    onlyUsingUsdToken
    onlyWhitelisted
    onlyValidInvestmentId(investmentId)
  {
    Investment storage investment = investments[investmentId];
    if (investment.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redeemedTimestamp != 0) {
      revert InvestmentRedeemed();
    }
    if (investment.timestamp + timelock > block.timestamp) {
      revert InvestmentLockedUp();
    }
    if (redemptionRequests[investmentId].nonce != currentNonce) {
      revert NonceMismatch();
    }
    if (minUsdAmount < 1) {
      revert MinAmountZero();
    }
    if (deadline < block.timestamp) {
      revert AfterDeadline();
    }
    delete redemptionRequests[investmentId];
    uint256 newNonce = currentNonce + 1;
    redemptionRequests[investmentId] = RedemptionRequest({
      minUsdAmount: minUsdAmount,
      deadline: deadline,
      timestamp: block.timestamp,
      nonce: newNonce
    });
    emit RedemptionRequestUpdated(
      msg.sender,
      investmentId,
      minUsdAmount,
      deadline,
      newNonce
    );
  }

  function cancelRedemptionRequest(uint256 investmentId)
    public
    onlyUsingUsdToken
    onlyWhitelisted
    onlyValidInvestmentId(investmentId)
  {
    Investment storage investment = investments[investmentId];
    if (investment.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redeemedTimestamp != 0) {
      revert InvestmentRedeemed();
    }
    if (redemptionRequests[investmentId].deadline == 0) {
      revert NoExistingRequest();
    }
    uint256 newNonce = redemptionRequests[investmentId].nonce + 1;
    delete redemptionRequests[investmentId];
    redemptionRequests[investmentId].nonce = newNonce;
    redemptionRequests[investmentId].timestamp = block.timestamp;
    emit RedemptionRequestUpdated(msg.sender, investmentId, 0, 0, newNonce);
  }

  function _redeem(
    uint256 investmentId,
    uint256 minUsdAmount,
    bool transferUsd,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal {
    Investment storage investment = investments[investmentId];
    uint256 performanceFeeFundAmount = _calculatePerformanceFee(investmentId);
    uint256 fundAmount = fromBase(investment.initialBaseAmount);
    uint256 usdAmount = ((fundAmount - performanceFeeFundAmount) * aum) /
      totalSupply();
    if (usdAmount < minUsdAmount) {
      revert PriceOutsideTolerance();
    }
    // mark investment as redeemed and lower total investment count
    investment.redeemedTimestamp = block.timestamp;
    investment.redemptionUsdTransferred = transferUsd;
    activeInvestmentCount--;
    activeInvestmentCountPerInvestor[investment.investor]--;
    // burn fund tokens
    _burn(investment.investor, fundAmount);
    if (performanceFeeFundAmount > 0) {
      // mint uncollected performance fee tokens
      _mint(address(this), performanceFeeFundAmount);
    }
    // subtract usd amount from aum
    aum -= usdAmount;
    capitalContributed -= investment.initialUsdAmount;
    if (transferUsd) {
      if (!usingUsdToken) {
        revert NotUsingUsdToken();
      }
      // transfer usd to investor
      _verifyUsdBalance(manager, usdAmount);
      if (permitValue < usdAmount) {
        revert PermitValueMismatch();
      }
      usdToken.permit(
        manager,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      usdToken.transferFrom(manager, investment.investor, usdAmount);
    }
    emit Redeemed(
      investment.investor,
      investmentId,
      fundAmount,
      performanceFeeFundAmount,
      usdAmount
    );
    emit NavUpdated(aum, totalSupply(), '');
    if (activeInvestmentCount == 0) {
      closed = true;
      emit Closed();
    }
  }

  function processRedemptionRequest(
    uint256 investmentId,
    uint256 currentNonce,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public onlyUsingUsdToken onlyManager onlyValidInvestmentId(investmentId) {
    Investment storage investment = investments[investmentId];
    if (investment.redeemedTimestamp != 0) {
      revert InvestmentRedeemed();
    }
    RedemptionRequest storage redemptionRequest = redemptionRequests[
      investmentId
    ];
    if (redemptionRequest.nonce != currentNonce) {
      revert NonceMismatch();
    }
    if (redemptionRequest.deadline == 0) {
      revert NoExistingRequest();
    }
    if (redemptionRequest.deadline < block.timestamp) {
      revert AfterDeadline();
    }
    _redeem(
      investmentId,
      redemptionRequest.minUsdAmount,
      true,
      permitValue,
      permitDeadline,
      v,
      r,
      s
    );
  }

  function addManualRedemption(
    uint256 investmentId,
    bool transferUsd,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public onlyManager onlyValidInvestmentId(investmentId) {
    Investment storage investment = investments[investmentId];
    if (investment.redeemedTimestamp != 0) {
      revert InvestmentRedeemed();
    }
    if (redemptionRequests[investmentId].deadline != 0) {
      uint256 newNonce = redemptionRequests[investmentId].nonce + 1;
      delete redemptionRequests[investmentId];
      redemptionRequests[investmentId].nonce = newNonce;
      redemptionRequests[investmentId].timestamp = block.timestamp;
      emit RedemptionRequestUpdated(
        investment.investor,
        investmentId,
        0,
        0,
        newNonce
      );
    }
    _redeem(investmentId, 1, transferUsd, permitValue, permitDeadline, v, r, s);
  }

  // the usd amount if this investment was redeemed right now
  // used for constructing usd permit signature
  function redemptionUsdAmount(uint256 investmentId)
    public
    view
    onlyValidInvestmentId(investmentId)
    returns (uint256 usdAmount)
  {
    uint256 performanceFeeFundAmount = _calculatePerformanceFee(investmentId);
    uint256 fundAmount = fromBase(investments[investmentId].initialBaseAmount);
    usdAmount = ((fundAmount - performanceFeeFundAmount) * aum) / totalSupply();
  }

  function _processFees(
    uint256 previousAumTimestamp,
    uint256 previousHighWaterPrice
  ) internal {
    uint256 supply = totalSupply();
    uint256 nonFeeSupply = supply - balanceOf(address(this));
    uint256 managementFeeFundAmount = _calculateManagementFee(
      nonFeeSupply,
      previousAumTimestamp
    );

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
    uint256 initialPrice = (investment.initialUsdAmount * 1e18) /
      investment.initialFundAmount;
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
    onlyValidInvestmentId(investmentId)
    returns (uint256)
  {
    return fromBase(investments[investmentId].initialBaseAmount);
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

  function withdrawFees(
    uint256 fundAmount,
    bool transferUsd,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public onlyManager {
    if (!closed && block.timestamp < feeWithdrawnTimestamp + feeTimelock) {
      revert NotPastFeeTimelock();
    }
    feeWithdrawnTimestamp = block.timestamp;
    uint256 usdAmount = (fundAmount * aum) / totalSupply();
    _burn(address(this), fundAmount);
    aum -= usdAmount;
    if (transferUsd) {
      if (!usingUsdToken) {
        revert NotUsingUsdToken();
      }
      if (feeBeneficiary == address(0)) {
        revert FeeBeneficiaryNotSet();
      }
      _verifyUsdBalance(manager, usdAmount);
      if (permitValue < usdAmount) {
        revert PermitValueMismatch();
      }
      usdToken.permit(
        manager,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      usdToken.transferFrom(manager, feeBeneficiary, usdAmount);
      emit FeesWithdrawn(feeBeneficiary, fundAmount, usdAmount);
    } else {
      emit FeesWithdrawn(address(0), fundAmount, usdAmount);
    }
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
    uint256 _minInvestmentAmount
  ) public onlyManager {
    if (_maxInvestors < 1) {
      revert InvalidMaxInvestors(); // Invalid max investors
    }
    maxInvestors = _maxInvestors;
    maxInvestmentsPerInvestor = _maxInvestmentsPerInvestor;
    minInvestmentAmount = _minInvestmentAmount;
  }

  function editFees(uint256 _managementFee, uint256 _performanceFee)
    public
    onlyManager
  {
    if (
      _managementFee > managementFee ||
      _performanceFee > performanceFee ||
      (_managementFee == managementFee && _performanceFee == performanceFee)
    ) {
      revert InvalidFees(); // Invalid fees
    }
    managementFee = _managementFee;
    performanceFee = _performanceFee;
    emit FeesChanged(managementFee, performanceFee);
  }

  function editFeeBeneficiary(address _feeBeneficiary) public onlyManager {
    if (_feeBeneficiary == address(0) || _feeBeneficiary == manager) {
      revert InvalidFeeBeneficiary(); // Invalid fee beneficiary
    }
    feeBeneficiary = _feeBeneficiary;
  }

  function editAumUpdater(address _aumUpdater) public onlyManager {
    aumUpdater = _aumUpdater;
  }

  function _verifyUsdBalance(address from, uint256 amount) internal view {
    if (usdToken.balanceOf(from) < amount) {
      revert InsufficientUsd();
    }
  }

  function _verifyUsdAllowance(address from, uint256 amount) internal view {
    if (usdToken.allowance(from, address(this)) < amount) {
      revert InsufficientUsdApproved();
    }
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    if (from != address(0) && to != address(0)) {
      revert NotTransferable(); // Token is not transferable
    }
  }
}
