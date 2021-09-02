// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import { Initializable } from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { ERC20VotesUpgradeable, ERC20Upgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol';
import { ERC20Permit } from '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';

import { RegistryV0 } from './RegistryV0.sol';

/*
Upgrade notes:
Use openzeppelin hardhat upgrades package
Storage layout cannot change but can be added to at the end
version function must return hardcoded incremented version
*/

contract FundV0 is Initializable, ERC20VotesUpgradeable, UUPSUpgradeable {
  RegistryV0 public registry;
  ERC20Permit public usdToken;

  // set during onboarding
  address public manager;
  address public custodian; // holds fund's assets
  address public aumUpdater; // can update fund's aum
  address public feeBeneficiary; // usd is sent to this address on fee withdrawal
  uint256 public timelock; // how long in seconds that investments are locked up
  uint256 public feeTimelock; // how long in seconds the manager has to wait between processing fees
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals
  uint256 public initialPrice; // starting token price in (usd / token) * 1e6
  string public logoUrl;
  string public contactInfo;
  string public tags;
  bool public usingUsdToken; // enables requests, allows transferring usd on redemption and fee withdrawal

  struct Nav {
    uint256 aum;
    uint256 supply;
    uint256 totalCapitalContributed; // amount contributed, adds by cost basis when investment happens, subtracts by cost basis when a redemption happens
    uint256 timestamp; // block timestamp
    string ipfsHash; // points to asset tracking json blob or blank
  }
  Nav[] public navs; // append only, existing data is never modified. pushed every time aum or supply changes, can be multiple times per block so timestamps can show up more than once
  event NavUpdated(
    uint256 navId,
    uint256 aum,
    uint256 supply,
    uint256 totalCapitalContributed,
    string ipfsHash
  );

  struct Investor {
    bool whitelisted; // allowed to invest or not
    uint256 investorId; // index in investors array
    uint256 activeInvestmentCount; // number of open investments to enforce maximum
    uint256 investmentRequestId; // id of open investment request, or max uint if none
    uint256[] investmentIds; // all investment ids, open or not
  }
  mapping(address => Investor) public investorInfo;
  address[] public investors; // append only list of investors, added to when whitelisted unless that investor has an investorId that matches, which means they were whitelisted and then blacklisted and they're already in this array
  uint256 public investorCount; // count of currently whitelisted investors, for maintaining max limit
  event Whitelisted(address indexed investor);
  event Blacklisted(address indexed investor);

  struct Investment {
    // constants
    address investor; // if this is the fund manager, burns and mints go to the fund contract, not the manager, and lockup is not enforced
    uint256 timestamp; // timestamp of investment or when imported
    uint256 lockupTimestamp; // timestamp of investment or original investment if imported, for comparing to timelock
    uint256 initialUsdAmount; // dollar value at time of investment
    uint256 initialFundAmount; // tokens minted at time of investment
    uint256 initialHighWaterMark; // same as initialUsdAmount unless imported
    uint256 managementFeeCostBasis; // dollar value used for calculating management fees. same as initialUsdAmount unless imported
    uint256 investmentRequestId; // id of the request that started it, or max uint if it's a manual investment
    uint256 navId; // nav id right before investment processed
    bool usdTransferred; // whether usd was transferred through the fund contract at time of investment
    bool imported; // whether investment was imported from a previous fund
    // fee related variables
    uint256 remainingFundAmount; // tokens remaining after past fee sweeps
    uint256 usdManagementFeesSwept; // total usd paid for management fees
    uint256 usdPerformanceFeesSwept; // total usd paid for performance fees
    uint256 fundManagementFeesSwept; // total fund tokens paid for management fees, can differ wildly from above because of price changes
    uint256 fundPerformanceFeesSwept; // total fund tokens paid for performance fees
    uint256 highWaterMark; // cannot charge performance fee unless investment value is higher than this at time of fee processing, pull out management fees before comparing
    uint256[] feeSweepIds; // ids of all fee sweeps that have occurred on this investment, use latest one to get timestamp of latest sweep
    uint256 feeSweepsCount; // number of fee sweeps that have occurred, equal to length of feeSweepIds
    // redemption related variables
    uint256 redemptionRequestId; // id of current redemption request or max uint if no request
    uint256 redemptionId; // id of redemption if redeemed, otherwise max uint
    bool redeemed;
  }
  Investment[] public investments;
  uint256 public activeInvestmentCount; // number of open investments
  bool public doneImportingInvestments; // set true after the first manual aum update or non-imported investment
  event Invested(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed investmentRequestId,
    uint256 usdAmount,
    uint256 fundAmount,
    bool imported,
    uint256 initialHighWaterMark,
    uint256 managementFeeCostBasis,
    uint256 lockupTimestamp
  );

  // TODO: add a grouping ID?
  struct FeeSweep {
    address investor;
    uint256 investmentId;
    uint256 navId; // nav id right before sweep
    uint256 highWaterMark; // new high water mark
    uint256 usdManagementFee; // usd for management fee
    uint256 usdPerformanceFee; // usd for performance fee
    uint256 fundManagementFee; // fund tokens pulled out corresponding to above usd fee
    uint256 fundPerformanceFee; // fund tokens pulled out to match above
    uint256 timestamp;
  }
  FeeSweep[] public feeSweeps; // append only, existing data is never modified
  uint256 public lastFeeSweepEndedTimestamp; // timestamp of end of last fee sweep
  uint256 public investmentsSweptSinceStarted; // number of investments that have been swept in the currently active sweep. when this equals activeInvestmentCount, the sweep is complete
  bool public feeSweeping; // set true when we start sweeping, false when done. this is in case fee sweeps take more than one transaction. all sweeps must happen at the same NAV, so no other manager actions can happen until all fees have been wept once started
  event FeesSwept(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 feeSweepId,
    uint256 highWaterMark,
    uint256 usdManagementFee,
    uint256 usdPerformanceFee,
    uint256 fundManagementFee,
    uint256 fundPerformanceFee
  );
  event FeeSweepStarted();
  event FeeSweepEnded();

  struct FeeWithdrawal {
    address to; // fee beneficiary
    uint256 fundAmount; // tokens burned
    uint256 usdAmount;
    bool usdTransferred;
    uint256 timestamp;
    uint256 navId;
  }
  FeeWithdrawal[] public feeWithdrawals; // append only, existing data is never modified
  uint256 public feesSweptNotWithdrawn; // total count of fund tokens swept that hasn't yet been withdrawn, this is to ensure the manager doesn't withdraw fund tokens from his own investments
  event FeesWithdrawn(
    address to,
    uint256 fundAmount,
    uint256 usdAmount,
    bool usdTransferred
  );

  struct InvestmentRequest {
    address investor;
    uint256 usdAmount;
    uint256 minFundAmount; // min fund tokens to mint otherwise revert
    uint256 maxFundAmount; // max fund tokens to mint otherwise revert
    uint256 deadline; // must be processed by deadline or revert
    uint256 timestamp;
    uint256 investmentId; // max uint until request is processed and an investment is made
    bool processed;
  }
  InvestmentRequest[] public investmentRequests; // append only, existing data is never modified except for investmentId and processed if succeeded
  event InvestmentRequested(
    address indexed investor,
    uint256 indexed investmentRequestId,
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 deadline
  );
  event InvestmentRequestCanceled(
    address indexed investor,
    uint256 indexed investmentRequestId
  );

  struct RedemptionRequest {
    address investor;
    uint256 investmentId;
    uint256 minUsdAmount; // min usd amount to net after fees
    uint256 deadline;
    uint256 timestamp;
    bool processed;
  }
  RedemptionRequest[] public redemptionRequests; // append only, existing data is never modified except for processed
  event RedemptionRequested(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed redemptionRequestId,
    uint256 minUsdAmount,
    uint256 deadline
  );
  event RedemptionRequestCanceled(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed redemptionRequestId
  );

  struct Redemption {
    address investor;
    uint256 investmentId;
    uint256 redemptionRequestId; // max uint if manual
    uint256 navId;
    uint256 fundAmount;
    uint256 usdAmount;
    uint256 timestamp;
    bool usdTransferred;
  }
  Redemption[] public redemptions; // append only, existing data is never modified
  event Redeemed(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed redemptionRequestId, // max uint if manual
    uint256 fundAmount,
    uint256 usdAmount,
    bool usdTransferred
  );

  bool public closed; // set true after last investment redeems
  event Closed();

  event FeesChanged(uint256 managementFee, uint256 performanceFee);
  event FundDetailsChanged(string logoUrl, string contactInfo, string tags);
  event InvestorLimitsChanged(
    uint256 maxInvestors,
    uint256 maxInvestmentsPerInvestor,
    uint256 minInvestmentAmount,
    uint256 timelock
  );
  event FeeBeneficiaryChanged(address feeBeneficiary);
  event AumUpdaterChanged(address aumUpdater);

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
  error InsufficientUsd();
  error InsufficientUsdApproved();
  error PermitValueMismatch();
  error InvalidInvestmentId();
  error InvalidUpgrade();
  error InvalidMinInvestmentAmount();
  error InvalidInitialPrice();
  error InvalidAmountReturnedZero();
  error FeeSweeping();
  error InvalidTimelock();
  error NotEnoughFees();
  error DoneImportingInvestments();
  error ManagerCannotCreateRequests();
  error RequestOutOfDate();
  error CannotTransferUsdToManager();

  function initialize(
    address[2] memory addressParams, // aumUpdater, feeBeneficiary
    uint256[9] memory uintParams, // timelock, feeTimelock, managementFee, performanceFee, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, initialPrice, initialAum
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory _contactInfo,
    string memory _tags,
    bool _usingUsdToken,
    address _manager
  ) public initializer {
    // called in order of inheritance, using _unchained version to avoid double calling
    __ERC1967Upgrade_init_unchained();
    __UUPSUpgradeable_init_unchained();
    __EIP712_init_unchained(name, '1');
    __Context_init_unchained();
    __ERC20_init_unchained(name, symbol);
    __ERC20Permit_init_unchained(name);
    __ERC20Votes_init_unchained();
    registry = RegistryV0(msg.sender);
    usdToken = registry.usdToken();
    manager = _manager;
    custodian = _manager;
    aumUpdater = addressParams[0];
    feeBeneficiary = addressParams[1];
    if (feeBeneficiary == custodian) {
      revert InvalidFeeBeneficiary();
    }
    timelock = uintParams[0];
    feeTimelock = uintParams[1];
    managementFee = uintParams[2];
    performanceFee = uintParams[3];
    maxInvestors = uintParams[4];
    maxInvestmentsPerInvestor = uintParams[5];
    minInvestmentAmount = uintParams[6];
    if (minInvestmentAmount < 1e6) {
      revert InvalidMinInvestmentAmount();
    }
    initialPrice = uintParams[7];
    if (initialPrice < 1e4 || initialPrice > 1e9) {
      revert InvalidInitialPrice();
    }
    // initial aum
    if (uintParams[8] > 0) {
      // TODO:
      // _addInvestment(uintParams[8]);
      doneImportingInvestments = true;
    }
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
    usingUsdToken = _usingUsdToken;
  }

  function version() public pure returns (uint256) {
    return 0;
  }

  function _authorizeUpgrade(address newFundImplementation)
    internal
    view
    override
    onlyManager
  {
    uint256 newVersion = FundV0(newFundImplementation).version();
    if (
      newVersion > registry.latestFundVersion() ||
      address(registry.fundImplementations(newVersion)) != newFundImplementation
    ) {
      revert InvalidUpgrade();
    }
  }

  modifier onlyManager() {
    if (msg.sender != manager) {
      revert ManagerOnly();
    }
    _;
  }

  modifier notManager() {
    if (msg.sender == manager) {
      revert ManagerCannotCreateRequests();
    }
    _;
  }

  modifier onlyAumUpdater() {
    if (msg.sender != aumUpdater) {
      revert AumUpdaterOnly();
    }
    _;
  }

  modifier onlyWhitelisted() {
    if (!investorInfo[msg.sender].whitelisted) {
      revert WhitelistedOnly();
    }
    _;
  }

  modifier notFeeSweeping() {
    if (feeSweeping) {
      revert FeeSweeping();
    }
    _;
  }

  modifier notClosed() {
    if (closed) {
      revert FundClosed();
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

  modifier notDoneImporting() {
    if (doneImportingInvestments) {
      revert DoneImportingInvestments();
    }
    _;
  }

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function navsLength() public view returns (uint256) {
    return navs.length;
  }

  function investorsLength() public view returns (uint256) {
    return investors.length;
  }

  function investmentsLength() public view returns (uint256) {
    return investments.length;
  }

  function feeSweepsLength() public view returns (uint256) {
    return feeSweeps.length;
  }

  function feeWithdrawalsLength() public view returns (uint256) {
    return feeWithdrawals.length;
  }

  function investmentRequestsLength() public view returns (uint256) {
    return investmentRequests.length;
  }

  function redemptionRequestsLength() public view returns (uint256) {
    return redemptionRequests.length;
  }

  function redemptionsLength() public view returns (uint256) {
    return redemptions.length;
  }

  function _calcFundAmount(uint256 usdAmount)
    internal
    view
    returns (uint256 fundAmount)
  {
    if (navs.length > 0) {
      // use latest aum and supply
      Nav storage nav = navs[navs.length - 1];
      fundAmount = (usdAmount * nav.supply) / nav.aum;
    } else {
      // use initial price
      fundAmount = usdAmount / initialPrice;
    }
    if (fundAmount == 0) {
      revert InvalidAmountReturnedZero();
    }
  }

  function _calcUsdAmount(uint256 fundAmount)
    internal
    view
    returns (uint256 usdAmount)
  {
    if (navs.length > 0) {
      // use latest aum and supply
      Nav storage nav = navs[navs.length - 1];
      usdAmount = (fundAmount * nav.aum) / nav.supply;
    } else {
      // use initial price
      usdAmount = fundAmount * initialPrice;
    }
    if (usdAmount == 0) {
      revert InvalidAmountReturnedZero();
    }
  }

  function _addNav(
    uint256 newAum,
    uint256 newTotalCapitalContributed,
    string memory ipfsHash
  ) internal {
    uint256 supply = totalSupply();
    uint256 navId = navs.length;
    navs.push(
      Nav({
        aum: newAum,
        supply: supply,
        totalCapitalContributed: newTotalCapitalContributed,
        timestamp: block.timestamp,
        ipfsHash: ipfsHash
      })
    );
    emit NavUpdated(
      navId,
      newAum,
      supply,
      newTotalCapitalContributed,
      ipfsHash
    );
  }

  function _addFeeWithdrawal(
    address to,
    uint256 fundAmount,
    uint256 usdAmount,
    bool usdTransferred
  ) internal {
    feeWithdrawals.push(
      FeeWithdrawal({
        to: to,
        fundAmount: fundAmount,
        usdAmount: usdAmount,
        usdTransferred: usdTransferred,
        timestamp: block.timestamp,
        navId: navs.length // TODO: safety check?
      })
    );
    emit FeesWithdrawn(to, fundAmount, usdAmount, usdTransferred);
  }

  function updateAum(uint256 _aum, string calldata ipfsHash)
    public
    notClosed
    onlyAumUpdater
  {
    if (investments.length == 0) {
      revert NotActive(); // Fund cannot have AUM until the first investment is made
    }
    if (!doneImportingInvestments) {
      doneImportingInvestments = true;
    }
    _addNav(_aum, navs[navs.length - 1].totalCapitalContributed, ipfsHash);
  }

  function whitelistMulti(address[] calldata _investors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < _investors.length; i++) {
      _addToWhitelist(_investors[i]);
    }
  }

  function _addToWhitelist(address investor) internal {
    if (investorCount >= maxInvestors) {
      revert TooManyInvestors(); // Too many investors
    }
    if (investorInfo[investor].whitelisted) {
      revert AlreadyWhitelisted();
    }
    if (investor == manager) {
      revert InvalidInvestor();
    }
    if (investors[investorInfo[investor].investorId] != investor) {
      investorInfo[investor].investorId = investors.length;
      investors.push(investor);
    }
    investorCount++;
    investorInfo[investor].whitelisted = true;
    investorInfo[investor].investmentRequestId = type(uint256).max;
    emit Whitelisted(investor);
  }

  function blacklistMulti(address[] calldata _investors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < _investors.length; i++) {
      address investor = _investors[i];
      if (investorInfo[investor].activeInvestmentCount > 0) {
        revert InvestorIsActive();
      }
      if (!investorInfo[investor].whitelisted) {
        revert NotInvestor();
      }
      investorCount--;
      uint256 investmentRequestId = investorInfo[investor].investmentRequestId;
      if (
        investmentRequestId != type(uint256).max &&
        investmentRequests[investmentRequestId].investor == investor
      ) {
        investorInfo[investor].investmentRequestId = type(uint256).max;
        emit InvestmentRequestCanceled(msg.sender, investmentRequestId);
      }
      investorInfo[investor].whitelisted = false;
      emit Blacklisted(investors[i]);
    }
  }

  // create a new request where one doesn't already exist or update an existing one
  // bool update prevents race conditions where investor wants to update and manager wants to process
  function createOrUpdateInvestmentRequest(
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 deadline,
    bool update,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public notClosed onlyUsingUsdToken onlyWhitelisted notManager {
    if (
      update &&
      investorInfo[msg.sender].investmentRequestId == type(uint256).max
    ) {
      revert NoExistingRequest();
    }
    if (
      investorInfo[msg.sender].activeInvestmentCount >=
      maxInvestmentsPerInvestor
    ) {
      revert MaxInvestmentsReached();
    }
    if (usdAmount < 1 || usdAmount < minInvestmentAmount) {
      revert InvestmentTooSmall();
    }
    if (minFundAmount == 0) {
      revert MinAmountZero();
    }
    if (maxFundAmount <= minFundAmount) {
      revert InvalidMaxAmount();
    }
    if (deadline < block.timestamp) {
      revert AfterDeadline();
    }
    _verifyUsdBalance(msg.sender, usdAmount);
    usdToken.permit(msg.sender, address(this), usdAmount, deadline, v, r, s);
    uint256 investmentRequestId = investmentRequests.length;
    investmentRequests.push(
      InvestmentRequest({
        investor: msg.sender,
        usdAmount: usdAmount,
        minFundAmount: minFundAmount,
        maxFundAmount: maxFundAmount,
        deadline: deadline,
        timestamp: block.timestamp,
        investmentId: type(uint256).max,
        processed: false
      })
    );
    emit InvestmentRequested(
      msg.sender,
      investmentRequestId,
      usdAmount,
      minFundAmount,
      maxFundAmount,
      deadline
    );
  }

  function cancelInvestmentRequest(
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public notClosed onlyUsingUsdToken onlyWhitelisted notManager {
    uint256 currentInvestmentRequestId = investorInfo[msg.sender]
      .investmentRequestId;
    if (currentInvestmentRequestId == type(uint256).max) {
      revert NoExistingRequest();
    }
    usdToken.permit(msg.sender, address(this), 0, permitDeadline, v, r, s);
    investorInfo[msg.sender].investmentRequestId = type(uint256).max;
    emit InvestmentRequestCanceled(msg.sender, currentInvestmentRequestId);
  }

  function _addInvestment(
    address investor,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 lockupTimestamp,
    uint256 highWaterMark,
    uint256 managementFeeCostBasis,
    uint256 investmentRequestId,
    bool transferUsd,
    bool imported
  ) internal {
    if (
      investorInfo[investor].activeInvestmentCount >= maxInvestmentsPerInvestor
    ) {
      revert MaxInvestmentsReached();
    }
    if (transferUsd) {
      _verifyUsdBalance(investor, usdAmount);
      _verifyUsdAllowance(investor, usdAmount);
      usdToken.transferFrom(investor, custodian, usdAmount);
    }
    if (investor == manager) {
      _mint(address(this), fundAmount);
    } else {
      _mint(investor, fundAmount);
    }
    // TODO: move this into a modifier somehow?
    if (!imported && !doneImportingInvestments) {
      doneImportingInvestments = true;
    }
    uint256 investmentId = investments.length;
    uint256 navId = type(uint256).max;
    if (navs.length > 0) {
      navId = navs.length - 1;
    }
    investments.push(
      Investment({
        investor: investor,
        timestamp: block.timestamp,
        lockupTimestamp: lockupTimestamp,
        initialUsdAmount: usdAmount,
        initialFundAmount: fundAmount,
        initialHighWaterMark: highWaterMark,
        managementFeeCostBasis: managementFeeCostBasis,
        investmentRequestId: investmentRequestId,
        navId: navId,
        usdTransferred: transferUsd,
        imported: imported,
        remainingFundAmount: fundAmount,
        usdManagementFeesSwept: 0,
        usdPerformanceFeesSwept: 0,
        fundManagementFeesSwept: 0,
        fundPerformanceFeesSwept: 0,
        highWaterMark: highWaterMark,
        feeSweepIds: new uint256[](0), // TODO: look into whether this is right
        feeSweepsCount: 0,
        redemptionRequestId: type(uint256).max,
        redemptionId: type(uint256).max,
        redeemed: false
      })
    );
    activeInvestmentCount++;
    investorInfo[investor].activeInvestmentCount++;
    investorInfo[investor].investmentIds.push(investmentId);
    emit Invested(
      investor,
      investmentId,
      investmentRequestId,
      usdAmount,
      fundAmount,
      imported,
      highWaterMark,
      managementFeeCostBasis,
      lockupTimestamp
    );
    uint256 newAum = usdAmount;
    uint256 newTotalCapitalContributed = usdAmount;
    if (navs.length > 0) {
      Nav storage nav = navs[navs.length - 1];
      newAum += nav.aum;
      newTotalCapitalContributed += nav.totalCapitalContributed;
    }
    _addNav(newAum, newTotalCapitalContributed, '');
  }

  function processInvestmentRequest(uint256 investmentRequestId)
    public
    notClosed
    onlyUsingUsdToken
    onlyManager
  {
    if (investmentRequestId >= investmentRequests.length) {
      revert NoExistingRequest();
    }
    InvestmentRequest storage investmentRequest = investmentRequests[
      investmentRequestId
    ];
    if (!investorInfo[investmentRequest.investor].whitelisted) {
      revert NotInvestor();
    }
    if (
      investorInfo[investmentRequest.investor].investmentRequestId !=
      investmentRequestId
    ) {
      revert RequestOutOfDate();
    }
    if (investmentRequest.deadline < block.timestamp) {
      revert AfterDeadline();
    }
    uint256 fundAmount = _calcFundAmount(investmentRequest.usdAmount);
    if (
      fundAmount < investmentRequest.minFundAmount ||
      fundAmount > investmentRequest.maxFundAmount
    ) {
      revert PriceOutsideTolerance();
    }
    _addInvestment(
      investmentRequest.investor,
      investmentRequest.usdAmount,
      fundAmount,
      block.timestamp,
      investmentRequest.usdAmount,
      investmentRequest.usdAmount,
      investmentRequestId,
      true,
      false
    );
    investmentRequest.processed = true;
    investmentRequest.investmentId = investments.length - 1;
    investorInfo[investmentRequest.investor].investmentRequestId = type(uint256)
      .max;
  }

  function addManualInvestment(address investor, uint256 usdAmount)
    public
    notClosed
    onlyManager
  {
    if (!investorInfo[investor].whitelisted) {
      _addToWhitelist(investor);
    }
    uint256 fundAmount = _calcFundAmount(usdAmount);
    _addInvestment(
      investor,
      usdAmount,
      fundAmount,
      block.timestamp,
      usdAmount,
      usdAmount,
      type(uint256).max,
      false,
      false
    );
  }

  function importInvestment(
    address investor,
    uint256 usdAmountRemaining,
    uint256 lockupTimestamp,
    uint256 highWaterMark,
    uint256 originalUsdAmount
  ) public notClosed onlyManager notDoneImporting {
    if (!investorInfo[investor].whitelisted) {
      _addToWhitelist(investor);
    }
    uint256 fundAmount = _calcFundAmount(usdAmountRemaining);
    _addInvestment(
      investor,
      usdAmountRemaining,
      fundAmount,
      lockupTimestamp,
      highWaterMark,
      originalUsdAmount,
      type(uint256).max,
      false,
      true
    );
  }

  function createOrUpdateRedemptionRequest(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline,
    bool update // used to prevent race conditions
  )
    public
    notClosed
    onlyUsingUsdToken
    onlyWhitelisted
    onlyValidInvestmentId(investmentId)
    notManager
  {
    Investment storage investment = investments[investmentId];
    if (update && investment.redemptionRequestId == type(uint256).max) {
      revert NoExistingRequest();
    }
    if (investment.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redeemed) {
      revert InvestmentRedeemed();
    }
    if (investment.lockupTimestamp + timelock > block.timestamp) {
      revert InvestmentLockedUp();
    }
    if (minUsdAmount < 1) {
      revert MinAmountZero();
    }
    if (deadline < block.timestamp) {
      revert AfterDeadline();
    }
    uint256 redemptionRequestId = redemptionRequests.length;
    investment.redemptionRequestId = redemptionRequestId;
    redemptionRequests.push(
      RedemptionRequest({
        investor: msg.sender,
        investmentId: investmentId,
        minUsdAmount: minUsdAmount,
        deadline: deadline,
        timestamp: block.timestamp,
        processed: false
      })
    );
    emit RedemptionRequested(
      msg.sender,
      investmentId,
      redemptionRequestId,
      minUsdAmount,
      deadline
    );
  }

  function cancelRedemptionRequest(uint256 investmentId)
    public
    onlyUsingUsdToken
    onlyWhitelisted
    onlyValidInvestmentId(investmentId)
    notManager
  {
    Investment storage investment = investments[investmentId];
    if (investment.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redeemed) {
      revert InvestmentRedeemed();
    }
    uint256 currentRedemptionRequestId = investment.redemptionRequestId;
    if (currentRedemptionRequestId == type(uint256).max) {
      revert NoExistingRequest();
    }
    investment.redemptionRequestId = type(uint256).max;
    emit RedemptionRequestCanceled(
      msg.sender,
      investmentId,
      currentRedemptionRequestId
    );
  }

  function _redeem(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 redemptionRequestId,
    bool transferUsd,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal {
    _processFeesOnInvestment(investmentId, false);
    Investment storage investment = investments[investmentId];
    uint256 usdAmount = _calcUsdAmount(investment.remainingFundAmount);
    if (usdAmount < minUsdAmount) {
      revert PriceOutsideTolerance();
    }
    if (investment.investor == manager) {
      _burn(address(this), investment.remainingFundAmount);
    } else {
      _burn(investment.investor, investment.remainingFundAmount);
    }
    uint256 redemptionId = redemptions.length;
    investment.redeemed = true;
    investment.redemptionId = redemptionId;
    activeInvestmentCount--;
    investorInfo[investment.investor].activeInvestmentCount--;
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
        custodian,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      usdToken.transferFrom(custodian, investment.investor, usdAmount);
    }
    redemptions.push(
      Redemption({
        investor: investment.investor,
        investmentId: investmentId,
        redemptionRequestId: redemptionRequestId,
        navId: navs.length - 1,
        fundAmount: investment.remainingFundAmount,
        usdAmount: usdAmount,
        timestamp: block.timestamp,
        usdTransferred: transferUsd
      })
    );
    emit Redeemed(
      investment.investor,
      investmentId,
      redemptionRequestId,
      investment.remainingFundAmount,
      usdAmount,
      transferUsd
    );
    Nav storage nav = navs[navs.length - 1];
    _addNav(
      nav.aum - usdAmount,
      nav.totalCapitalContributed - investment.initialUsdAmount,
      ''
    );
    if (activeInvestmentCount == 0) {
      closed = true;
      emit Closed();
    }
  }

  function processRedemptionRequest(
    uint256 redemptionRequestId,
    uint256 permitValue,
    uint256 permitDeadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public notClosed onlyUsingUsdToken onlyManager {
    if (redemptionRequestId >= redemptionRequests.length) {
      revert NoExistingRequest();
    }
    RedemptionRequest storage redemptionRequest = redemptionRequests[
      redemptionRequestId
    ];
    Investment storage investment = investments[redemptionRequest.investmentId];
    if (investment.redeemed) {
      revert InvestmentRedeemed();
    }
    if (investment.redemptionRequestId != redemptionRequestId) {
      revert RequestOutOfDate();
    }
    if (redemptionRequest.deadline < block.timestamp) {
      revert AfterDeadline();
    }
    _redeem(
      redemptionRequest.investmentId,
      redemptionRequest.minUsdAmount,
      redemptionRequestId,
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
    if (investment.investor == manager && transferUsd) {
      revert CannotTransferUsdToManager();
    }
    if (investment.redeemed) {
      revert InvestmentRedeemed();
    }
    uint256 redemptionRequestId = investment.redemptionRequestId;
    if (redemptionRequestId != type(uint256).max) {
      investment.redemptionRequestId = type(uint256).max;
      emit RedemptionRequestCanceled(
        investment.investor,
        investmentId,
        redemptionRequestId
      );
    }
    _redeem(
      investmentId,
      1,
      type(uint256).max,
      transferUsd,
      permitValue,
      permitDeadline,
      v,
      r,
      s
    );
  }

  // the usd amount if this investment was redeemed right now
  // used for constructing usd permit signature
  function redemptionUsdAmount(uint256 investmentId)
    public
    view
    onlyValidInvestmentId(investmentId)
    returns (uint256 usdAmount)
  {
    (, uint256 fundManagementFee, , uint256 fundPerformanceFee, ) = _calcFees(
      investmentId,
      false
    );
    usdAmount = _calcUsdAmount(
      investments[investmentId].remainingFundAmount -
        fundManagementFee -
        fundPerformanceFee
    );
  }

  function processFees(uint256[] calldata investmentIds) public onlyManager {
    if (!doneImportingInvestments) {
      doneImportingInvestments = true;
    }
    if (!feeSweeping) {
      feeSweeping = true;
      emit FeeSweepStarted();
    }
    if (block.timestamp < lastFeeSweepEndedTimestamp + feeTimelock) {
      revert NotPastFeeTimelock();
    }
    for (uint256 i = 0; i < investmentIds.length; i++) {
      _processFeesOnInvestment(investmentIds[i], true);
      investmentsSweptSinceStarted++;
      if (investmentsSweptSinceStarted == activeInvestmentCount) {
        feeSweeping = false;
        lastFeeSweepEndedTimestamp = block.timestamp;
        investmentsSweptSinceStarted = 0;
        emit FeeSweepEnded();
      }
    }
  }

  function _calcFees(uint256 investmentId, bool enforceFeeTimelock)
    internal
    view
    returns (
      uint256 usdManagementFee,
      uint256 fundManagementFee,
      uint256 usdPerformanceFee,
      uint256 fundPerformanceFee,
      uint256 highWaterMark
    )
  {
    Investment storage investment = investments[investmentId];
    uint256 lastSweepTimestamp = investment.timestamp;
    // if there was a fee sweep already, use the timestamp of the latest one instead
    if (investment.feeSweepsCount > 0) {
      lastSweepTimestamp = feeSweeps[
        investment.feeSweepIds[investment.feeSweepsCount - 1]
      ].timestamp;
    }
    if (
      enforceFeeTimelock &&
      (block.timestamp < lastSweepTimestamp + feeTimelock ||
        lastSweepTimestamp >= lastFeeSweepEndedTimestamp)
    ) {
      revert NotPastFeeTimelock(); // TODO: maybe a separate error to pass the specific investment id back?
    }
    // calc management fee
    usdManagementFee =
      (investment.managementFeeCostBasis *
        ((block.timestamp - lastSweepTimestamp) * managementFee)) /
      10000 /
      365.25 days;
    fundManagementFee = _calcFundAmount(usdManagementFee);
    uint256 fundAmountNetOfManagementFee = investment.remainingFundAmount -
      fundManagementFee;
    uint256 usdAmountNetOfManagementFee = _calcUsdAmount(
      fundAmountNetOfManagementFee
    );
    highWaterMark = investment.highWaterMark;
    // calc perf fee if value went above previous high water mark
    if (usdAmountNetOfManagementFee > investment.highWaterMark) {
      highWaterMark = usdAmountNetOfManagementFee;
      uint256 usdGainAboveHighWatermark = usdAmountNetOfManagementFee -
        investment.highWaterMark;
      usdPerformanceFee = (usdGainAboveHighWatermark * performanceFee) / 10000;
      fundPerformanceFee = _calcFundAmount(usdPerformanceFee);
    }
  }

  function _processFeesOnInvestment(
    uint256 investmentId,
    bool enforceFeeTimelock
  ) internal onlyValidInvestmentId(investmentId) {
    (
      uint256 usdManagementFee,
      uint256 fundManagementFee,
      uint256 usdPerformanceFee,
      uint256 fundPerformanceFee,
      uint256 highWaterMark
    ) = _calcFees(investmentId, enforceFeeTimelock);
    Investment storage investment = investments[investmentId];
    if (investment.investor == manager) {
      _burn(address(this), fundManagementFee);
    } else {
      _burn(investment.investor, fundManagementFee);
    }
    _mint(address(this), fundManagementFee);
    if (investment.investor == manager) {
      _burn(address(this), fundPerformanceFee);
    } else {
      _burn(investment.investor, fundPerformanceFee);
    }
    _mint(address(this), fundPerformanceFee);
    uint256 feeSweepId = feeSweeps.length;
    uint256 fundAmount = fundManagementFee + fundPerformanceFee;
    investment.remainingFundAmount -= fundAmount;
    investment.usdManagementFeesSwept += usdManagementFee;
    investment.usdPerformanceFeesSwept += usdPerformanceFee;
    investment.fundManagementFeesSwept += fundManagementFee;
    investment.fundPerformanceFeesSwept += fundPerformanceFee;
    investment.highWaterMark = highWaterMark;
    investment.feeSweepsCount++;
    investment.feeSweepIds.push(feeSweepId);
    feeSweeps.push(
      FeeSweep({
        investor: investment.investor,
        investmentId: investmentId,
        navId: navs.length - 1, // TODO: safety check?
        highWaterMark: highWaterMark,
        usdManagementFee: usdManagementFee,
        usdPerformanceFee: usdPerformanceFee,
        fundManagementFee: fundManagementFee,
        fundPerformanceFee: fundPerformanceFee,
        timestamp: block.timestamp
      })
    );
    emit FeesSwept(
      investment.investor,
      investmentId,
      feeSweepId,
      highWaterMark,
      usdManagementFee,
      usdPerformanceFee,
      fundManagementFee,
      fundPerformanceFee
    );
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
    if (fundAmount > feesSweptNotWithdrawn) {
      revert NotEnoughFees();
    }
    feesSweptNotWithdrawn -= fundAmount;
    uint256 usdAmount = _calcUsdAmount(fundAmount);
    _burn(address(this), fundAmount);
    address to;
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
        custodian,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      usdToken.transferFrom(custodian, feeBeneficiary, usdAmount);
      to = feeBeneficiary;
    }
    _addFeeWithdrawal(feeBeneficiary, fundAmount, usdAmount, transferUsd);
    // TODO: add safety check, maybe refactor
    Nav storage nav = navs[navs.length - 1];
    _addNav(nav.aum - usdAmount, nav.totalCapitalContributed, '');
  }

  function editFundDetails(
    string calldata _logoUrl,
    string calldata _contactInfo,
    string calldata _tags
  ) public onlyManager {
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
    emit FundDetailsChanged(logoUrl, contactInfo, tags);
  }

  function editInvestorLimits(
    uint256 _maxInvestors,
    uint256 _maxInvestmentsPerInvestor,
    uint256 _minInvestmentAmount,
    uint256 _timelock
  ) public onlyManager {
    if (_maxInvestors < 1) {
      revert InvalidMaxInvestors(); // Invalid max investors
    }
    if (_minInvestmentAmount < 1e6) {
      revert InvalidMinInvestmentAmount();
    }
    // make sure lockup can only be lowered
    if (_timelock > timelock) {
      revert InvalidTimelock();
    }
    maxInvestors = _maxInvestors;
    maxInvestmentsPerInvestor = _maxInvestmentsPerInvestor;
    minInvestmentAmount = _minInvestmentAmount;
    timelock = _timelock;
    emit InvestorLimitsChanged(
      maxInvestors,
      maxInvestmentsPerInvestor,
      minInvestmentAmount,
      timelock
    );
  }

  function editFees(uint256 _managementFee, uint256 _performanceFee)
    public
    onlyManager
  {
    // make sure fees either stayed the same or went down
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
    if (_feeBeneficiary == address(0) || _feeBeneficiary == custodian) {
      revert InvalidFeeBeneficiary(); // Invalid fee beneficiary
    }
    feeBeneficiary = _feeBeneficiary;
    emit FeeBeneficiaryChanged(feeBeneficiary);
  }

  function editAumUpdater(address _aumUpdater) public onlyManager {
    aumUpdater = _aumUpdater;
    emit AumUpdaterChanged(aumUpdater);
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
  ) internal override {
    super._beforeTokenTransfer(from, to, amount);
    if (from != address(0) && to != address(0)) {
      revert NotTransferable(); // Token is not transferable
    }
  }

  // TODO: may not need these 3? test without them
  // function _afterTokenTransfer(
  //   address from,
  //   address to,
  //   uint256 amount
  // ) internal override {
  //   super._afterTokenTransfer(from, to, amount);
  // }

  // function _mint(address to, uint256 amount) internal override {
  //   super._mint(to, amount);
  // }

  // function _burn(address account, uint256 amount) internal override {
  //   super._burn(account, amount);
  // }
}
