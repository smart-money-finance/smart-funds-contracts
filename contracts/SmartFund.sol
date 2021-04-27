// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.3;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol';

import './FeeDividendToken.sol';
import './SmartFundFactory.sol';

// import 'hardhat/console.sol';

// TODO:
// figure out how to allow selling of parts of investments
// maybe close out an investment and open a new one with the remaining amount after fee extraction?
// maybe link them together so client can know which ones are splits of others
// also consider solutions to wallet loss/theft, should manager have admin power to reassign investments to different addresses?

contract SmartFund is Initializable, FeeDividendToken {
  SmartFundFactory internal factory;
  ERC20 internal usdToken;
  address public manager;
  address public aumUpdater;
  address public feeBeneficiary;
  uint256 public timelock;
  uint256 public managementFee; // basis points per year
  uint256 public performanceFee; // basis points
  uint256 public feeTimelock;
  uint256 public redemptionWaitingPeriod;
  bool public signedAum;
  string public logoUrl;
  string public contactInfo;
  string public tags;
  uint256 public maxInvestors;
  uint256 public maxInvestmentsPerInvestor;
  uint256 public minInvestmentAmount; // in usd token decimals

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
    uint256 performanceFeeFundAmount, // will be 0 unless this investment was made after the last high water mark happened
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
  event NewHighWaterPrice(uint256 indexed price);

  function initialize(
    address[3] memory addressParams, // initialInvestor, aumUpdater, feeBeneficiary
    uint256[10] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock, redemptionWaitingPeriod
    bool _signedAum,
    string memory name,
    string memory symbol,
    string memory _logoUrl,
    string memory _contactInfo,
    string memory initialInvestorName,
    string memory _tags,
    bytes memory signature,
    address _manager
  ) public initializer onlyBefore(uintParams[4]) {
    _FeeDividendToken_init(name, symbol, 6);
    require(uintParams[3] > 0, 'S0'); // Initial AUM must be greater than 0
    factory = SmartFundFactory(msg.sender);
    usdToken = factory.usdToken();
    manager = _manager;
    aumUpdater = addressParams[1];
    feeBeneficiary = addressParams[2];
    signedAum = _signedAum;
    timelock = uintParams[0];
    managementFee = uintParams[1];
    performanceFee = uintParams[2];
    feeTimelock = uintParams[8];
    redemptionWaitingPeriod = uintParams[9];
    maxInvestors = uintParams[5];
    maxInvestmentsPerInvestor = uintParams[6];
    minInvestmentAmount = uintParams[7];
    logoUrl = _logoUrl;
    contactInfo = _contactInfo;
    tags = _tags;
    aumTimestamp = block.timestamp;
    highWaterPrice = 1e16; // initial price of $0.01
    highWaterPriceTimestamp = block.timestamp;
    _addToWhitelist(addressParams[0], initialInvestorName);
    _addInvestmentRequest(
      addressParams[0],
      uintParams[3],
      1,
      type(uint256).max,
      block.timestamp + 24 hours
    );
    _addInvestment(0);
    nextInvestmentRequestIndex = 1;
    _verifyAumSignature(manager, uintParams[4], signature);
    emit NewHighWaterPrice(highWaterPrice);
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

  function updateAum(
    uint256 _aum,
    uint256 deadline,
    uint256 earlyInvestmentsToProcess,
    uint256 earlyRedemptionsToProcess,
    bytes calldata signature
  ) public onlyBefore(deadline) {
    uint256 previousAumTimestamp = aumTimestamp;
    uint256 previousHighWaterPrice = highWaterPrice;
    aum = _aum;
    aumTimestamp = block.timestamp;
    _verifyAumSignature(msg.sender, deadline, signature);
    uint256 supply = totalSupply();
    emit NavUpdated(_aum, supply);
    uint256 price = (aum * 1e18) / supply;
    if (price > highWaterPrice) {
      highWaterPrice = price;
      highWaterPriceTimestamp = block.timestamp;
      emit NewHighWaterPrice(highWaterPrice);
    }
    _processFees(previousAumTimestamp, previousHighWaterPrice);
    _processInvestments(earlyInvestmentsToProcess);
    _processRedemptions(earlyRedemptionsToProcess);
  }

  function _processInvestments(uint256 investmentsToProcess) internal {
    investmentsToProcess += 5;
    for (uint256 i = 0; i < investmentsToProcess; i++) {
      if (nextInvestmentRequestIndex == investmentRequests.length) {
        return;
      }
      _addInvestment(nextInvestmentRequestIndex);
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
      _redeem(nextRedemptionRequestIndex);
      nextRedemptionRequestIndex++;
    }
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

  function blacklistMultiAndForceRedeem(
    address[] calldata investors,
    uint256[] calldata investmentIdsToRedeem
  ) public onlyManager {
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
    for (uint256 i = 0; i < investmentIdsToRedeem.length; i++) {
      _addRedemptionRequest(investmentIdsToRedeem[i], 1);
    }
  }

  function requestInvestment(
    uint256 usdAmount,
    uint256 minFundAmount,
    uint256 maxFundAmount,
    uint256 investmentDeadline,
    uint256 deadline
  ) public onlyWhitelisted onlyBefore(deadline) {
    require(
      activeAndPendingInvestmentCountPerInvestor[msg.sender] <
        maxInvestmentsPerInvestor,
      'S11' // Investor has reached max investment limit
    );
    require(usdAmount >= minInvestmentAmount, 'S9'); // Less than minimum investment amount
    require(minFundAmount > 0, 'S10'); // Minimum fund amount returned must be greater than 0
    require(investmentDeadline >= block.timestamp + 24 hours, 'S35'); // Investment deadline too short
    require(
      redemptionRequests.length == 0 ||
        redemptionRequests[redemptionRequests.length - 1].investmentId != 0,
      'S47'
    ); // Fund is in the process of closing
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
        investmentId: 0,
        status: RequestStatus.Pending
      })
    );
    // only skip transferring on the initial investment
    if (investmentRequests.length > 1) {
      factory.usdTransferFrom(investor, address(this), usdAmount);
    }
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
  ) public onlyWhitelisted onlyBefore(deadline) {
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
  }

  function requestRedemption(
    uint256 investmentId,
    uint256 minUsdAmount,
    uint256 deadline
  ) public onlyBefore(deadline) {
    Investment storage investment = investments[investmentId];
    require(investment.investor == msg.sender, 'S13'); // Investor does not own that investment
    _addRedemptionRequest(investmentId, minUsdAmount);
  }

  function _addRedemptionRequest(uint256 investmentId, uint256 minUsdAmount)
    internal
  {
    Investment storage investment = investments[investmentId];
    require(investment.redeemed == false, 'S14'); // Investment already redeemed
    require(investment.timestamp + timelock <= block.timestamp, 'S15'); // Investment is still locked up
    require(minUsdAmount > 0, 'S39'); // Min amount must be greater than 0
    require(
      redemptionRequests.length == 0 ||
        redemptionRequests[redemptionRequests.length - 1].investmentId != 0,
      'S46'
    ); // Fund is in the process of closing
    require(investmentId != 0 || activeAndPendingInvestmentCount == 1, 'S40'); // Initial investment can only be redeemed after all other investments
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

  function _addInvestment(uint256 investmentRequestId) internal {
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
            initialBaseAmount: toBase(fundAmount),
            initialHighWaterPrice: highWaterPrice,
            timestamp: block.timestamp,
            investmentRequestId: investmentRequestId,
            redemptionRequestId: 0,
            redeemed: false
          })
        );
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
    activeAndPendingInvestmentCount--;
    activeAndPendingInvestmentCountPerInvestor[investmentRequest.investor]--;
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
      uint256 performanceFeeFundAmount =
        _calculatePerformanceFee(redemptionRequest.investmentId);
      uint256 fundAmount = fromBase(investment.initialBaseAmount);
      uint256 usdAmount =
        ((fundAmount - performanceFeeFundAmount) * aum) / totalSupply();
      if (usdAmount >= redemptionRequest.minUsdAmount) {
        // success
        // mark investment as redeemed and lower total investment count
        investment.redeemed = true;
        activeAndPendingInvestmentCount--;
        activeAndPendingInvestmentCountPerInvestor[investment.investor]--;
        redemptionRequest.status = RequestStatus.Processed;
        // burn fund tokens
        _burn(investment.investor, fundAmount);
        if (performanceFeeFundAmount > 0) {
          // mint performance fee tokens
          _mint(address(this), performanceFeeFundAmount);
        }
        // subtract usd amount from aum
        aum -= usdAmount;
        if (redemptionRequest.investmentId != 0) {
          // transfer usd to investor
          require(
            usdToken.balanceOf(manager) >= usdAmount &&
              usdToken.allowance(manager, address(factory)) >= usdAmount,
            'S42'
          ); // Not enough usd tokens available and approved
          factory.usdTransferFrom(manager, investment.investor, usdAmount);
        }
        emit Redeemed(
          investment.investor,
          fundAmount,
          performanceFeeFundAmount,
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

  function withdrawFees(address to, uint256 fundAmount) public {
    require(msg.sender == manager || msg.sender == feeBeneficiary, 'S49'); // Manager or fee beneficiary only
    require(block.timestamp >= feeWithdrawnTimestamp + feeTimelock, 'S44'); // Can't withdraw fees yet
    require(to != manager, 'S45'); // Can't withdraw fees to fund manager wallet
    feeWithdrawnTimestamp = block.timestamp;
    uint256 usdAmount = (fundAmount * aum) / totalSupply();
    _burn(address(this), fundAmount);
    aum -= usdAmount;
    require(
      usdToken.balanceOf(manager) >= usdAmount &&
        usdToken.allowance(manager, address(factory)) >= usdAmount,
      'S43'
    ); // Not enough usd tokens available and approved
    factory.usdTransferFrom(manager, to, usdAmount);
    emit FeesWithdrawn(to, fundAmount, usdAmount);
    emit NavUpdated(aum, totalSupply());
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

  function editFees(
    uint256 _managementFee,
    uint256 _performanceFee,
    address _feeBeneficiary
  ) public onlyManager {
    require(
      _managementFee <= managementFee && _performanceFee <= performanceFee,
      'S48'
    ); // Can't increase fees
    managementFee = _managementFee;
    performanceFee = _performanceFee;
    feeBeneficiary = _feeBeneficiary;
  }

  function editAumUpdater(address _aumUpdater) public onlyManager {
    aumUpdater = _aumUpdater;
  }

  function _verifyAumSignature(
    address sender,
    uint256 deadline,
    bytes memory signature
  ) internal view {
    if (!signedAum) {
      require(sender == manager || sender == aumUpdater, 'S28'); // Manager or AUM updater only
    } else if (sender == manager || sender == aumUpdater) {
      bytes32 message = keccak256(abi.encode(sender, aum, deadline));
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

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);
    require(from == address(0) || to == address(0), 'S26'); // Token is not transferable
  }
}
