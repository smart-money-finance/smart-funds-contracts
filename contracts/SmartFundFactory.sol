// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.4;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/proxy/Clones.sol';

import './SmartFund.sol';

contract SmartFundFactory is Ownable {
  address internal masterFundLibrary;
  ERC20 public usdToken;
  SmartFund[] public funds;

  struct Manager {
    bool whitelisted;
    string name;
  }
  mapping(address => Manager) public managerWhitelist;
  bool public bypassWhitelist;
  mapping(address => address) public custodianToFund;

  event ManagerWhitelisted(address indexed manager, string name);
  event FundCreated(address indexed fund);

  error CustodianUsed();
  error NotWhitelisted();
  error SenderIsNotFund();
  error ManagerAlreadyWhitelisted();

  constructor(
    address _masterFundLibrary,
    ERC20 _usdToken,
    bool _bypassWhitelist
  ) {
    masterFundLibrary = _masterFundLibrary;
    usdToken = _usdToken;
    bypassWhitelist = _bypassWhitelist;
  }

  function newFund(
    address[4] memory addressParams, // initialInvestor, aumUpdater, feeBeneficiary, custodian
    uint256[9] memory uintParams, // timelock, managementFee, performanceFee, initialAum, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock, redemptionWaitingPeriod
    bool[2] memory boolParams, // investmentRequestsEnabled, redemptionRequestsEnabled
    string memory name,
    string memory symbol,
    string memory logoUrl,
    string memory contactInfo,
    string memory initialInvestorName,
    string memory tags,
    string memory aumIpfsHash
  ) public {
    if (custodianToFund[addressParams[3]] != address(0)) {
      revert CustodianUsed(); // Custodian is already used for another fund
    }
    if (!(bypassWhitelist || managerWhitelist[msg.sender].whitelisted)) {
      revert NotWhitelisted(); // Not whitelisted as a fund manager
    }
    SmartFund fund = SmartFund(Clones.clone(masterFundLibrary));
    fund.initialize(
      addressParams,
      uintParams,
      boolParams,
      name,
      symbol,
      logoUrl,
      contactInfo,
      initialInvestorName,
      tags,
      aumIpfsHash,
      msg.sender
    );
    funds.push(fund);
    custodianToFund[addressParams[3]] = address(fund);
    emit FundCreated(address(fund));
  }

  function usdTransferFrom(
    address from,
    address to,
    uint256 amount
  ) public {
    if (msg.sender != custodianToFund[SmartFund(msg.sender).custodian()]) {
      revert SenderIsNotFund(); // Only callable by funds
    }
    usdToken.transferFrom(from, to, amount);
  }

  function whitelistMulti(address[] calldata managers, string[] calldata names)
    public
    onlyOwner
  {
    for (uint256 i = 0; i < managers.length; i++) {
      if (managerWhitelist[managers[i]].whitelisted) {
        revert ManagerAlreadyWhitelisted(); // Manager is already whitelisted
      }
      managerWhitelist[managers[i]] = Manager({
        whitelisted: true,
        name: names[i]
      });
      emit ManagerWhitelisted(managers[i], names[i]);
    }
  }

  function allFunds() public view returns (SmartFund[] memory) {
    return funds;
  }

  function enableBypassWhitelist() public onlyOwner {
    bypassWhitelist = true;
  }
}
