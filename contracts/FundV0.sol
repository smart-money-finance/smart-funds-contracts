// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import { UUPSUpgradeable } from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import { ERC20VotesUpgradeable } from '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol';
import { ERC20Permit } from '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';

import { RegistryV0 } from './RegistryV0.sol';

/*
Upgrade notes:
Use openzeppelin hardhat upgrades package
Storage layout cannot change but can be added to at the end
version function must return hardcoded incremented version
*/

contract FundV0 is ERC20VotesUpgradeable, UUPSUpgradeable {
  RegistryV0 internal _registry;
  ERC20Permit internal _usdToken;

  // set during onboarding
  address internal _manager;
  address internal _custodian; // holds fund's assets
  address internal _aumUpdater; // can update fund's aum
  address internal _feeBeneficiary; // usd is sent to this address on fee withdrawal
  uint256 internal _timelock; // how long in seconds that investments are locked up
  uint256 internal _feeSweepInterval; // how long in seconds between fee processing, not enforced but stored to show investors
  uint256 internal _managementFee; // basis points per year
  uint256 internal _performanceFee; // basis points
  uint256 internal _maxInvestors;
  uint256 internal _maxInvestmentsPerInvestor;
  uint256 internal _minInvestmentAmount; // in usd token decimals
  uint256 internal _initialPrice; // starting token price in (usd / token) * 1e6
  string internal _logoUrl;
  string internal _contactInfo;
  string internal _tags;
  bool internal _usingUsdToken; // enables requests, allows transferring usd on redemption and fee withdrawal

  struct Nav {
    uint256 aum;
    uint256 supply;
    uint256 totalCapitalContributed; // amount contributed, adds by cost basis when investment happens, subtracts by cost basis when a redemption happens
    uint256 timestamp; // block timestamp
    string ipfsHash; // points to asset tracking json blob or blank
  }
  Nav[] internal _navs; // append only, existing data is never modified. pushed every time aum or supply changes, can be multiple times per block so timestamps can show up more than once
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
  mapping(address => Investor) internal _investorInfo;
  address[] internal _investors; // append only list of investors, added to when whitelisted unless that investor has an investorId that matches, which means they were whitelisted and then blacklisted and they're already in this array
  uint256 internal _investorCount; // count of currently whitelisted investors, for maintaining max limit
  event Whitelisted(address indexed investor);
  event Blacklisted(address indexed investor);

  struct InvestmentConstants {
    // constants
    address investor; // if this is the fund manager, burns and mints go to the fund contract, not the manager, and lockup is not enforced
    uint256 timestamp; // timestamp of investment or when imported
    uint256 lockupTimestamp; // timestamp of investment or original investment if imported, for comparing to timelock
    uint256 initialUsdAmount; // dollar value at time of investment
    uint256 initialFundAmount; // tokens minted at time of investment
    uint256 initialHighWaterMark; // same as initialUsdAmount unless imported
    uint256 managementFeeCostBasis; // dollar value used for calculating management fees. same as initialUsdAmount unless imported
    uint256 investmentRequestId; // id of the request that started it, or max uint if it's a manual investment
    bool usdTransferred; // whether usd was transferred through the fund contract at time of investment
    bool imported; // whether investment was imported from a previous fund
    string notes; // notes to attach to a manual or imported investment for manager record keeping
  }
  struct Investment {
    InvestmentConstants constants;
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
  }
  Investment[] internal _investments;
  uint256 internal _activeInvestmentCount; // number of open investments
  bool internal _doneImportingInvestments; // set true after the first manual aum update or non-imported investment
  event Invested(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed investmentRequestId,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 initialHighWaterMark,
    uint256 managementFeeCostBasis,
    uint256 lockupTimestamp,
    bool imported,
    bool usdTransferred,
    string notes
  );
  event DoneImportingInvestments();

  // TODO: add a grouping ID?
  struct FeeSweep {
    uint256 investmentId;
    uint256 highWaterMark; // new high water mark
    uint256 usdManagementFee; // usd for management fee
    uint256 usdPerformanceFee; // usd for performance fee
    uint256 fundManagementFee; // fund tokens pulled out corresponding to above usd fee
    uint256 fundPerformanceFee; // fund tokens pulled out to match above
    uint256 timestamp;
  }
  FeeSweep[] internal _feeSweeps; // append only, existing data is never modified
  uint256 internal _lastFeeSweepEndedTimestamp; // timestamp of end of last fee sweep
  uint256 internal _investmentsSweptSinceStarted; // number of investments that have been swept in the currently active sweep. when this equals activeInvestmentCount, the sweep is complete
  bool internal _feeSweeping; // set true when we start sweeping, false when done. this is in case fee sweeps take more than one transaction. all sweeps must happen at the same NAV, so no other manager actions can happen until all fees have been wept once started
  event FeesSwept(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed feeSweepId,
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
  }
  FeeWithdrawal[] internal _feeWithdrawals; // append only, existing data is never modified
  uint256 internal _feesSweptNotWithdrawn; // total count of fund tokens swept that hasn't yet been withdrawn, this is to ensure the manager doesn't withdraw fund tokens from his own investments
  event FeesWithdrawn(
    uint256 indexed feeWithdrawalId,
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
  }
  InvestmentRequest[] internal _investmentRequests; // append only, existing data is never modified except for investmentId and processed if succeeded
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
    uint256 investmentId;
    uint256 minUsdAmount; // min usd amount to net after fees
    uint256 deadline;
    uint256 timestamp;
    uint256 redemptionId; // max uint until request is processed and a redemption happens
  }
  RedemptionRequest[] internal _redemptionRequests; // append only, existing data is never modified except for processed
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
    uint256 investmentId;
    uint256 redemptionRequestId; // max uint if manual
    uint256 fundAmount;
    uint256 usdAmount;
    uint256 timestamp;
    bool usdTransferred;
  }
  Redemption[] internal _redemptions; // append only, existing data is never modified
  event Redeemed(
    address indexed investor,
    uint256 indexed investmentId,
    uint256 indexed redemptionId,
    uint256 redemptionRequestId, // max uint if manual
    uint256 fundAmount,
    uint256 usdAmount,
    bool usdTransferred
  );

  bool internal _closed; // set true after last investment redeems
  event Closed();

  event FeesChanged(uint256 managementFee, uint256 performanceFee);
  event FundDetailsChanged(string logoUrl, string contactInfo, string tags);
  event InvestorLimitsChanged(
    uint256 maxInvestors,
    uint256 maxInvestmentsPerInvestor,
    uint256 minInvestmentAmount,
    uint256 timelock,
    uint256 feeSweepInterval
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
  error NotInvestmentOwner();
  error InvestmentRedeemed();
  error InvestmentLockedUp();
  error FeeBeneficiaryNotSet();
  // error InvalidFees();
  error NotTransferable();
  error NotUsingUsdToken();
  error InvalidMaxAmount();
  error PriceOutsideTolerance();
  error NoExistingRequest();
  // error InsufficientUsd();
  // error InsufficientUsdApproved();
  error PermitValueMismatch();
  error InvalidInvestmentId();
  error InvalidUpgrade();
  error InvalidMinInvestmentAmount();
  error InvalidInitialPrice();
  error InvalidAmountReturnedZero();
  error FeeSweeping();
  error InvalidTimelock();
  error NotEnoughFees();
  error NoLongerImportingInvestments();
  error ManagerCannotCreateRequests();
  error RequestOutOfDate();
  error CannotTransferUsdToManager();
  error AlreadySweepedThisPeriod();

  function initialize(
    address[2] memory addressParams, // _aumUpdater, _feeBeneficiary
    uint256[9] memory uintParams, // _timelock, _feeSweepInterval, _managementFee, _performanceFee, _maxInvestors, _maxInvestmentsPerInvestor, _minInvestmentAmount, _initialPrice, initialAum
    string memory name,
    string memory symbol,
    string memory newLogoUrl,
    string memory newContactInfo,
    string memory newTags,
    bool usingUsdToken,
    address manager,
    RegistryV0 registry,
    ERC20Permit usdToken
  ) public initializer {
    // called in order of inheritance, using _unchained version to avoid double calling
    __ERC1967Upgrade_init_unchained();
    __UUPSUpgradeable_init_unchained();
    __EIP712_init_unchained(name, '1');
    __Context_init_unchained();
    __ERC20_init_unchained(name, symbol);
    __ERC20Permit_init_unchained(name);
    __ERC20Votes_init_unchained();
    _registry = registry;
    _usdToken = usdToken;
    _manager = manager;
    _custodian = manager;
    _aumUpdater = addressParams[0];
    _feeBeneficiary = addressParams[1];
    if (_feeBeneficiary == _custodian) {
      revert InvalidFeeBeneficiary();
    }
    _timelock = uintParams[0];
    _feeSweepInterval = uintParams[1];
    _managementFee = uintParams[2];
    _performanceFee = uintParams[3];
    _maxInvestors = uintParams[4];
    _maxInvestmentsPerInvestor = uintParams[5];
    _minInvestmentAmount = uintParams[6];
    if (_minInvestmentAmount < 1e6) {
      revert InvalidMinInvestmentAmount();
    }
    _initialPrice = uintParams[7];
    if (_initialPrice < 1e4 || _initialPrice > 1e9) {
      revert InvalidInitialPrice();
    }
    // initial aum
    if (uintParams[8] > 0) {
      _addToWhitelist(_manager);
      uint256 usdAmount = uintParams[8];
      _addInvestment(
        _manager,
        block.timestamp,
        usdAmount,
        _calcFundAmount(usdAmount),
        block.timestamp,
        usdAmount,
        usdAmount,
        type(uint256).max,
        false,
        false,
        ''
      );
    }
    _logoUrl = newLogoUrl;
    _contactInfo = newContactInfo;
    _tags = newTags;
    _usingUsdToken = usingUsdToken;
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
      newVersion > _registry.latestFundVersion() ||
      address(_registry.fundImplementations(newVersion)) !=
      newFundImplementation
    ) {
      revert InvalidUpgrade();
    }
  }

  function _onlyManager() internal view {
    if (msg.sender != _manager) {
      revert ManagerOnly();
    }
  }

  modifier onlyManager() {
    _onlyManager();
    _;
  }

  function _notManager() internal view {
    if (msg.sender == _manager) {
      revert ManagerCannotCreateRequests();
    }
  }

  modifier notManager() {
    _notManager();
    _;
  }

  modifier onlyAumUpdater() {
    if (msg.sender != _aumUpdater) {
      revert AumUpdaterOnly();
    }
    _;
  }

  function _onlyWhitelisted() internal view {
    if (!_investorInfo[msg.sender].whitelisted) {
      revert WhitelistedOnly();
    }
  }

  modifier onlyWhitelisted() {
    _onlyWhitelisted();
    _;
  }

  function _notFeeSweeping() internal view {
    if (_feeSweeping) {
      revert FeeSweeping();
    }
  }

  modifier notFeeSweeping() {
    _notFeeSweeping();
    _;
  }

  function _notClosed() internal view {
    if (_closed) {
      revert FundClosed();
    }
  }

  modifier notClosed() {
    _notClosed();
    _;
  }

  function _onlyUsingUsdToken() internal view {
    if (!_usingUsdToken) {
      revert NotUsingUsdToken();
    }
  }

  modifier onlyUsingUsdToken() {
    _onlyUsingUsdToken();
    _;
  }

  function _onlyValidInvestmentId(uint256 investmentId) internal view {
    if (investmentId >= _investments.length) {
      revert InvalidInvestmentId();
    }
  }

  modifier onlyValidInvestmentId(uint256 investmentId) {
    _onlyValidInvestmentId(investmentId);
    _;
  }

  modifier notDoneImporting() {
    if (_doneImportingInvestments) {
      revert NoLongerImportingInvestments();
    }
    _;
  }

  function _stopImportingInvestments() internal {
    if (!_doneImportingInvestments) {
      _doneImportingInvestments = true;
      emit DoneImportingInvestments();
    }
  }

  modifier stopImportingInvestments() {
    _stopImportingInvestments();
    _;
  }

  function logoUrl() public view returns (string memory) {
    return _logoUrl;
  }

  function contactInfo() public view returns (string memory) {
    return _contactInfo;
  }

  function tags() public view returns (string memory) {
    return _tags;
  }

  function fundVars()
    public
    view
    returns (
      address manager,
      address custodian,
      address aumUpdater,
      address feeBeneficiary,
      uint256 timelock,
      uint256 feeSweepInterval,
      uint256 managementFee,
      uint256 performanceFee,
      uint256 maxInvestors,
      uint256 maxInvestmentsPerInvestor,
      uint256 minInvestmentAmount,
      uint256 initialPrice,
      bool usingUsdToken
    )
  {
    return (
      _manager,
      _custodian,
      _aumUpdater,
      _feeBeneficiary,
      _timelock,
      _feeSweepInterval,
      _managementFee,
      _performanceFee,
      _maxInvestors,
      _maxInvestmentsPerInvestor,
      _minInvestmentAmount,
      _initialPrice,
      _usingUsdToken
    );
  }

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function _calcFundAmount(uint256 usdAmount)
    internal
    view
    returns (uint256 fundAmount)
  {
    if (_navs.length > 0) {
      // use latest aum and supply
      Nav storage nav = _navs[_navs.length - 1];
      fundAmount = (usdAmount * nav.supply) / nav.aum;
    } else {
      // use initial price
      fundAmount = usdAmount / _initialPrice;
    }
  }

  function _calcUsdAmount(uint256 fundAmount)
    internal
    view
    returns (uint256 usdAmount)
  {
    if (_navs.length > 0) {
      // use latest aum and supply
      Nav storage nav = _navs[_navs.length - 1];
      usdAmount = (fundAmount * nav.aum) / nav.supply;
    } else {
      // use initial price
      usdAmount = fundAmount * _initialPrice;
    }
  }

  function _addNav(
    uint256 newAum,
    uint256 newTotalCapitalContributed,
    string memory ipfsHash
  ) internal {
    uint256 navId = _navs.length;
    _navs.push(
      Nav({
        aum: newAum,
        supply: totalSupply(),
        totalCapitalContributed: newTotalCapitalContributed,
        timestamp: block.timestamp,
        ipfsHash: ipfsHash
      })
    );
    emit NavUpdated(
      navId,
      newAum,
      totalSupply(),
      newTotalCapitalContributed,
      ipfsHash
    );
  }

  function updateAum(uint256 aum, string memory ipfsHash)
    public
    notClosed
    onlyAumUpdater
    stopImportingInvestments
    notFeeSweeping
  {
    if (_investments.length == 0) {
      revert NotActive(); // Fund cannot have AUM until the first investment is made
    }
    _addNav(aum, _navs[_navs.length - 1].totalCapitalContributed, ipfsHash);
  }

  function whitelistMulti(address[] memory newInvestors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < newInvestors.length; i++) {
      _addToWhitelist(newInvestors[i]);
    }
  }

  function _addToWhitelist(address investor) internal {
    if (_investorCount >= _maxInvestors) {
      revert TooManyInvestors(); // Too many investors
    }
    if (_investorInfo[investor].whitelisted) {
      revert AlreadyWhitelisted();
    }
    if (investor == _manager) {
      revert InvalidInvestor();
    }
    if (
      _investors.length <= _investorInfo[investor].investorId ||
      _investors[_investorInfo[investor].investorId] != investor
    ) {
      _investorInfo[investor].investorId = _investors.length;
      _investors.push(investor);
    }
    _investorCount++;
    _investorInfo[investor].whitelisted = true;
    _investorInfo[investor].investmentRequestId = type(uint256).max;
    emit Whitelisted(investor);
  }

  function blacklistMulti(address[] memory blacklistedInvestors)
    public
    notClosed
    onlyManager
  {
    for (uint256 i = 0; i < blacklistedInvestors.length; i++) {
      address investor = blacklistedInvestors[i];
      if (_investorInfo[investor].activeInvestmentCount > 0) {
        revert InvestorIsActive();
      }
      if (!_investorInfo[investor].whitelisted) {
        revert NotInvestor();
      }
      _investorCount--;
      uint256 investmentRequestId = _investorInfo[investor].investmentRequestId;
      if (
        investmentRequestId != type(uint256).max &&
        _investmentRequests[investmentRequestId].investor == investor
      ) {
        _investorInfo[investor].investmentRequestId = type(uint256).max;
        emit InvestmentRequestCanceled(msg.sender, investmentRequestId);
      }
      _investorInfo[investor].whitelisted = false;
      emit Blacklisted(investor);
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
  ) public onlyWhitelisted notManager {
    if (
      update &&
      _investorInfo[msg.sender].investmentRequestId == type(uint256).max
    ) {
      revert NoExistingRequest();
    }
    if (usdAmount < _minInvestmentAmount) {
      revert InvestmentTooSmall();
    }
    if (maxFundAmount <= minFundAmount) {
      revert InvalidMaxAmount();
    }
    _usdToken.permit(msg.sender, address(this), usdAmount, deadline, v, r, s);
    uint256 investmentRequestId = _investmentRequests.length;
    _investmentRequests.push(
      InvestmentRequest({
        investor: msg.sender,
        usdAmount: usdAmount,
        minFundAmount: minFundAmount,
        maxFundAmount: maxFundAmount,
        deadline: deadline,
        timestamp: block.timestamp,
        investmentId: type(uint256).max
      })
    );
    _investorInfo[msg.sender].investmentRequestId = investmentRequestId;
    emit InvestmentRequested(
      msg.sender,
      investmentRequestId,
      usdAmount,
      minFundAmount,
      maxFundAmount,
      deadline
    );
  }

  function cancelInvestmentRequest() public {
    uint256 currentInvestmentRequestId = _investorInfo[msg.sender]
      .investmentRequestId;
    if (currentInvestmentRequestId == type(uint256).max) {
      revert NoExistingRequest();
    }
    _investorInfo[msg.sender].investmentRequestId = type(uint256).max;
    emit InvestmentRequestCanceled(msg.sender, currentInvestmentRequestId);
  }

  function _addInvestment(
    address investor,
    uint256 timestamp,
    uint256 usdAmount,
    uint256 fundAmount,
    uint256 lockupTimestamp,
    uint256 highWaterMark,
    uint256 managementFeeCostBasis,
    uint256 investmentRequestId,
    bool transferUsd,
    bool imported,
    string memory notes
  ) internal notFeeSweeping notClosed {
    if (usdAmount == 0 || fundAmount == 0) {
      revert InvalidAmountReturnedZero();
    }
    if (
      _investorInfo[investor].activeInvestmentCount >=
      _maxInvestmentsPerInvestor
    ) {
      revert MaxInvestmentsReached();
    }
    if (transferUsd) {
      // _verifyUsdBalance(investor, usdAmount);
      // _verifyUsdAllowance(investor, usdAmount);
      _usdToken.transferFrom(investor, _custodian, usdAmount);
    }
    _mint(investor == _manager ? address(this) : investor, fundAmount);
    {
      Investment storage investment = _investments.push();
      investment.constants.investor = investor;
      investment.constants.timestamp = timestamp;
      investment.constants.lockupTimestamp = lockupTimestamp;
      investment.constants.initialUsdAmount = usdAmount;
      investment.constants.initialFundAmount = fundAmount;
      investment.constants.initialHighWaterMark = highWaterMark;
      investment.constants.managementFeeCostBasis = managementFeeCostBasis;
      investment.constants.investmentRequestId = investmentRequestId;
      investment.constants.usdTransferred = transferUsd;
      investment.constants.imported = imported;
      investment.constants.notes = notes;
      investment.remainingFundAmount = fundAmount;
      // investment.usdManagementFeesSwept= 0;
      // investment.usdPerformanceFeesSwept= 0;
      // investment.fundManagementFeesSwept= 0;
      // investment.fundPerformanceFeesSwept= 0;
      investment.highWaterMark = highWaterMark;
      // investment.feeSweepIds= new uint256[](0);
      // investment.feeSweepsCount= 0;
      investment.redemptionRequestId = type(uint256).max;
      investment.redemptionId = type(uint256).max;
      // investment.redeemed= false;
    }
    _activeInvestmentCount++;
    _investorInfo[investor].activeInvestmentCount++;
    _investorInfo[investor].investmentIds.push(_investments.length - 1);
    emit Invested(
      investor,
      _investments.length - 1,
      investmentRequestId,
      usdAmount,
      fundAmount,
      highWaterMark,
      managementFeeCostBasis,
      lockupTimestamp,
      imported,
      transferUsd,
      notes
    );
    uint256 newAum = usdAmount;
    uint256 newTotalCapitalContributed = usdAmount;
    if (_navs.length > 0) {
      Nav storage nav = _navs[_navs.length - 1];
      newAum += nav.aum;
      newTotalCapitalContributed += nav.totalCapitalContributed;
    }
    _addNav(newAum, newTotalCapitalContributed, '');
  }

  function processInvestmentRequest(uint256 investmentRequestId)
    public
    onlyUsingUsdToken
    onlyManager
    stopImportingInvestments
  {
    if (investmentRequestId >= _investmentRequests.length) {
      revert NoExistingRequest();
    }
    InvestmentRequest storage investmentRequest = _investmentRequests[
      investmentRequestId
    ];
    if (!_investorInfo[investmentRequest.investor].whitelisted) {
      revert NotInvestor();
    }
    if (
      _investorInfo[investmentRequest.investor].investmentRequestId !=
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
      block.timestamp,
      investmentRequest.usdAmount,
      fundAmount,
      block.timestamp,
      investmentRequest.usdAmount,
      investmentRequest.usdAmount,
      investmentRequestId,
      true,
      false,
      ''
    );
    investmentRequest.investmentId = _investments.length - 1;
    _investorInfo[investmentRequest.investor].investmentRequestId = type(
      uint256
    ).max;
  }

  function addManualInvestment(
    address investor,
    uint256 usdAmount,
    string memory notes
  ) public onlyManager stopImportingInvestments {
    if (!_investorInfo[investor].whitelisted) {
      _addToWhitelist(investor);
    }
    _addInvestment(
      investor,
      block.timestamp,
      usdAmount,
      _calcFundAmount(usdAmount),
      block.timestamp,
      usdAmount,
      usdAmount,
      type(uint256).max,
      false,
      false,
      notes
    );
  }

  function importInvestment(
    address investor,
    uint256 usdAmountRemaining,
    uint256 lockupTimestamp,
    uint256 highWaterMark,
    uint256 originalUsdAmount,
    uint256 lastFeeSweepTimestamp,
    string memory notes
  ) public onlyManager notDoneImporting {
    if (!_investorInfo[investor].whitelisted) {
      _addToWhitelist(investor);
    }
    _addInvestment(
      investor,
      lastFeeSweepTimestamp,
      usdAmountRemaining,
      _calcFundAmount(usdAmountRemaining),
      lockupTimestamp,
      highWaterMark,
      originalUsdAmount,
      type(uint256).max,
      false,
      true,
      notes
    );
  }

  function createOrUpdateRedemptionRequest(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline,
    bool update // used to prevent race conditions
  ) public onlyWhitelisted onlyValidInvestmentId(investmentId) notManager {
    Investment storage investment = _investments[investmentId];
    if (update && investment.redemptionRequestId == type(uint256).max) {
      revert NoExistingRequest();
    }
    if (investment.constants.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redemptionId != type(uint256).max) {
      revert InvestmentRedeemed();
    }
    if (investment.constants.lockupTimestamp + _timelock > block.timestamp) {
      revert InvestmentLockedUp();
    }
    if (deadline < block.timestamp) {
      revert AfterDeadline();
    }
    uint256 redemptionRequestId = _redemptionRequests.length;
    investment.redemptionRequestId = redemptionRequestId;
    _redemptionRequests.push(
      RedemptionRequest({
        investmentId: investmentId,
        minUsdAmount: minUsdAmount,
        deadline: deadline,
        timestamp: block.timestamp,
        redemptionId: type(uint256).max
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
    onlyValidInvestmentId(investmentId)
  {
    Investment storage investment = _investments[investmentId];
    if (investment.constants.investor != msg.sender) {
      revert NotInvestmentOwner();
    }
    if (investment.redemptionId != type(uint256).max) {
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
  ) internal onlyManager notFeeSweeping stopImportingInvestments {
    _processFeesOnInvestment(investmentId);
    Investment storage investment = _investments[investmentId];
    uint256 usdAmount = _calcUsdAmount(investment.remainingFundAmount);
    if (usdAmount < minUsdAmount) {
      revert PriceOutsideTolerance();
    }
    _burn(
      investment.constants.investor == _manager
        ? address(this)
        : investment.constants.investor,
      investment.remainingFundAmount
    );
    uint256 redemptionId = _redemptions.length;
    investment.redemptionId = redemptionId;
    _activeInvestmentCount--;
    _investorInfo[investment.constants.investor].activeInvestmentCount--;
    if (transferUsd) {
      if (!_usingUsdToken) {
        revert NotUsingUsdToken();
      }
      // transfer usd to investor
      // _verifyUsdBalance(_custodian, usdAmount);
      if (permitValue < usdAmount) {
        revert PermitValueMismatch();
      }
      _usdToken.permit(
        _custodian,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      _usdToken.transferFrom(
        _custodian,
        investment.constants.investor,
        usdAmount
      );
    }
    _redemptions.push(
      Redemption({
        investmentId: investmentId,
        redemptionRequestId: redemptionRequestId,
        fundAmount: investment.remainingFundAmount,
        usdAmount: usdAmount,
        timestamp: block.timestamp,
        usdTransferred: transferUsd
      })
    );
    emit Redeemed(
      investment.constants.investor,
      investmentId,
      redemptionId,
      redemptionRequestId,
      investment.remainingFundAmount,
      usdAmount,
      transferUsd
    );
    Nav storage nav = _navs[_navs.length - 1];
    _addNav(
      nav.aum - usdAmount,
      nav.totalCapitalContributed - investment.constants.initialUsdAmount,
      ''
    );
    if (_activeInvestmentCount == 0) {
      _closed = true;
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
  ) public onlyUsingUsdToken {
    if (redemptionRequestId >= _redemptionRequests.length) {
      revert NoExistingRequest();
    }
    RedemptionRequest storage redemptionRequest = _redemptionRequests[
      redemptionRequestId
    ];
    Investment storage investment = _investments[
      redemptionRequest.investmentId
    ];
    if (investment.redemptionId != type(uint256).max) {
      revert InvestmentRedeemed();
    }
    if (investment.redemptionRequestId != redemptionRequestId) {
      revert RequestOutOfDate();
    }
    if (redemptionRequest.deadline < block.timestamp) {
      revert AfterDeadline();
    }
    redemptionRequest.redemptionId = _redemptions.length;
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
  ) public onlyValidInvestmentId(investmentId) {
    Investment storage investment = _investments[investmentId];
    if (investment.constants.investor == _manager && transferUsd) {
      revert CannotTransferUsdToManager();
    }
    if (investment.redemptionId != type(uint256).max) {
      revert InvestmentRedeemed();
    }
    uint256 redemptionRequestId = investment.redemptionRequestId;
    if (redemptionRequestId != type(uint256).max) {
      investment.redemptionRequestId = type(uint256).max;
      emit RedemptionRequestCanceled(
        investment.constants.investor,
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
    (, uint256 fundManagementFee, , uint256 fundPerformanceFee, , ) = _calcFees(
      investmentId
    );
    usdAmount = _calcUsdAmount(
      _investments[investmentId].remainingFundAmount -
        fundManagementFee -
        fundPerformanceFee
    );
  }

  function processFees(uint256[] memory investmentIds)
    public
    onlyManager
    stopImportingInvestments
  {
    if (!_feeSweeping) {
      _feeSweeping = true;
      emit FeeSweepStarted();
    }
    for (uint256 i = 0; i < investmentIds.length; i++) {
      _processFeesOnInvestment(investmentIds[i]);
      _investmentsSweptSinceStarted++;
    }
    if (_investmentsSweptSinceStarted == _activeInvestmentCount) {
      _feeSweeping = false;
      _lastFeeSweepEndedTimestamp = block.timestamp;
      _investmentsSweptSinceStarted = 0;
      emit FeeSweepEnded();
    }
  }

  function _calcFees(uint256 investmentId)
    internal
    view
    returns (
      uint256 usdManagementFee,
      uint256 fundManagementFee,
      uint256 usdPerformanceFee,
      uint256 fundPerformanceFee,
      uint256 highWaterMark,
      uint256 lastSweepTimestamp
    )
  {
    Investment storage investment = _investments[investmentId];
    // if there was a fee sweep already, use the timestamp of the latest one instead
    if (investment.feeSweepsCount > 0) {
      lastSweepTimestamp = _feeSweeps[
        investment.feeSweepIds[investment.feeSweepsCount - 1]
      ].timestamp;
    } else {
      lastSweepTimestamp = investment.constants.timestamp;
    }

    // calc management fee
    usdManagementFee =
      (investment.constants.managementFeeCostBasis *
        ((block.timestamp - lastSweepTimestamp) * _managementFee)) /
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
      usdPerformanceFee = (usdGainAboveHighWatermark * _performanceFee) / 10000;
      fundPerformanceFee = _calcFundAmount(usdPerformanceFee);
    }
  }

  function _processFeesOnInvestment(uint256 investmentId)
    internal
    onlyValidInvestmentId(investmentId)
  {
    (
      uint256 usdManagementFee,
      uint256 fundManagementFee,
      uint256 usdPerformanceFee,
      uint256 fundPerformanceFee,
      uint256 highWaterMark,
      uint256 lastSweepTimestamp
    ) = _calcFees(investmentId);
    if (lastSweepTimestamp > _lastFeeSweepEndedTimestamp) {
      revert AlreadySweepedThisPeriod();
    }
    Investment storage investment = _investments[investmentId];
    address burnFrom = investment.constants.investor;
    if (burnFrom == _manager) {
      burnFrom = address(this);
    }
    _burn(burnFrom, fundManagementFee);
    _mint(address(this), fundManagementFee);
    _burn(burnFrom, fundPerformanceFee);
    _mint(address(this), fundPerformanceFee);
    uint256 feeSweepId = _feeSweeps.length;
    uint256 fundAmount = fundManagementFee + fundPerformanceFee;
    _feesSweptNotWithdrawn += fundAmount;
    investment.remainingFundAmount -= fundAmount;
    investment.usdManagementFeesSwept += usdManagementFee;
    investment.usdPerformanceFeesSwept += usdPerformanceFee;
    investment.fundManagementFeesSwept += fundManagementFee;
    investment.fundPerformanceFeesSwept += fundPerformanceFee;
    investment.highWaterMark = highWaterMark;
    investment.feeSweepsCount++;
    investment.feeSweepIds.push(feeSweepId);
    _feeSweeps.push(
      FeeSweep({
        investmentId: investmentId,
        highWaterMark: highWaterMark,
        usdManagementFee: usdManagementFee,
        usdPerformanceFee: usdPerformanceFee,
        fundManagementFee: fundManagementFee,
        fundPerformanceFee: fundPerformanceFee,
        timestamp: block.timestamp
      })
    );
    emit FeesSwept(
      investment.constants.investor,
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
    if (fundAmount > _feesSweptNotWithdrawn) {
      revert NotEnoughFees();
    }
    _feesSweptNotWithdrawn -= fundAmount;
    uint256 usdAmount = _calcUsdAmount(fundAmount);
    _burn(address(this), fundAmount);
    if (transferUsd) {
      if (!_usingUsdToken) {
        revert NotUsingUsdToken();
      }
      if (_feeBeneficiary == address(0)) {
        revert FeeBeneficiaryNotSet();
      }
      // _verifyUsdBalance(_custodian, usdAmount);
      if (permitValue < usdAmount) {
        revert PermitValueMismatch();
      }
      _usdToken.permit(
        _custodian,
        address(this),
        permitValue,
        permitDeadline,
        v,
        r,
        s
      );
      _usdToken.transferFrom(_custodian, _feeBeneficiary, usdAmount);
    }
    _feeWithdrawals.push(
      FeeWithdrawal({
        to: _feeBeneficiary,
        fundAmount: fundAmount,
        usdAmount: usdAmount,
        usdTransferred: transferUsd,
        timestamp: block.timestamp
      })
    );
    emit FeesWithdrawn(
      _feeWithdrawals.length - 1,
      _feeBeneficiary,
      fundAmount,
      usdAmount,
      transferUsd
    );
    Nav storage nav = _navs[_navs.length - 1];
    _addNav(nav.aum - usdAmount, nav.totalCapitalContributed, '');
  }

  function editFundDetails(
    string memory newLogoUrl,
    string memory newContactInfo,
    string memory newTags
  ) public onlyManager {
    _logoUrl = newLogoUrl;
    _contactInfo = newContactInfo;
    _tags = newTags;
    emit FundDetailsChanged(newLogoUrl, newContactInfo, newTags);
  }

  function editInvestorLimits(
    uint256 newMaxInvestors,
    uint256 newMaxInvestmentsPerInvestor,
    uint256 newMinInvestmentAmount,
    uint256 newTimelock,
    uint256 newFeeSweepInterval
  ) public onlyManager {
    if (newMaxInvestors < 1) {
      revert InvalidMaxInvestors(); // Invalid max investors
    }
    if (newMinInvestmentAmount < 1e6) {
      revert InvalidMinInvestmentAmount();
    }
    // make sure lockup can only be lowered
    if (_timelock > newTimelock) {
      revert InvalidTimelock();
    }
    _maxInvestors = newMaxInvestors;
    _maxInvestmentsPerInvestor = newMaxInvestmentsPerInvestor;
    _minInvestmentAmount = newMinInvestmentAmount;
    _timelock = newTimelock;
    _feeSweepInterval = newFeeSweepInterval;
    emit InvestorLimitsChanged(
      newMaxInvestors,
      newMaxInvestmentsPerInvestor,
      newMinInvestmentAmount,
      newTimelock,
      newFeeSweepInterval
    );
  }

  // function editFees(uint256 newManagementFee, uint256 newPerformanceFee)
  //   public
  //   onlyManager
  //   notFeeSweeping
  // {
  //   // make sure fees either stayed the same or went down
  //   if (newManagementFee > _managementFee || newPerformanceFee > _performanceFee) {
  //     revert InvalidFees(); // Invalid fees
  //   }
  //   _managementFee = newManagementFee;
  //   _performanceFee = newPerformanceFee;
  //   emit FeesChanged(newManagementFee, newPerformanceFee);
  // }

  function editFeeBeneficiary(address newFeeBeneficiary) public onlyManager {
    if (newFeeBeneficiary == address(0) || newFeeBeneficiary == _custodian) {
      revert InvalidFeeBeneficiary(); // Invalid fee beneficiary
    }
    _feeBeneficiary = newFeeBeneficiary;
    emit FeeBeneficiaryChanged(newFeeBeneficiary);
  }

  function editAumUpdater(address newAumUpdater) public onlyManager {
    _aumUpdater = newAumUpdater;
    emit AumUpdaterChanged(newAumUpdater);
  }

  // function _verifyUsdBalance(address from, uint256 amount) internal view {
  //   if (_usdToken.balanceOf(from) < amount) {
  //     revert InsufficientUsd();
  //   }
  // }

  // function _verifyUsdAllowance(address from, uint256 amount) internal view {
  //   if (_usdToken.allowance(from, address(this)) < amount) {
  //     revert InsufficientUsdApproved();
  //   }
  // }

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
}
