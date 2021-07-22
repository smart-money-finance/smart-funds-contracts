// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.6;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';
import '@openzeppelin/contracts/proxy/Clones.sol';

import './SmartFund.sol';

contract SmartFundFactory is Ownable {
  address internal masterFundLibrary;
  ERC20Permit public usdToken;
  address[] public funds;

  mapping(address => bool) public managerWhitelist;
  bool public bypassWhitelist;
  mapping(address => address) public managerToFund;

  event ManagerWhitelisted(address indexed manager);
  event FundCreated(address indexed fund);

  error ManagerAlreadyHasFund();
  error NotWhitelisted();
  error ManagerAlreadyWhitelisted();

  constructor(
    address _masterFundLibrary,
    ERC20Permit _usdToken,
    bool _bypassWhitelist
  ) {
    masterFundLibrary = _masterFundLibrary;
    usdToken = _usdToken;
    bypassWhitelist = _bypassWhitelist;
  }

  function newFund(
    address[2] memory addressParams, // aumUpdater, feeBeneficiary
    uint256[7] memory uintParams, // timelock, managementFee, performanceFee, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock
    string memory name,
    string memory symbol,
    string memory logoUrl,
    string memory contactInfo,
    string memory tags,
    bool useUsdToken
  ) public {
    if (managerToFund[msg.sender] != address(0)) {
      revert ManagerAlreadyHasFund(); // Manager already has a fund
    }
    if (!(bypassWhitelist || managerWhitelist[msg.sender])) {
      revert NotWhitelisted(); // Not whitelisted as a fund manager
    }
    SmartFund fund = SmartFund(Clones.clone(masterFundLibrary));
    fund.initialize(
      addressParams,
      uintParams,
      name,
      symbol,
      logoUrl,
      contactInfo,
      tags,
      useUsdToken,
      msg.sender
    );
    address fundAddress = address(fund);
    funds.push(fundAddress);
    managerToFund[msg.sender] = fundAddress;
    emit FundCreated(fundAddress);
  }

  function whitelistMulti(address[] calldata managers) public onlyOwner {
    for (uint256 i = 0; i < managers.length; i++) {
      if (managerWhitelist[managers[i]]) {
        revert ManagerAlreadyWhitelisted(); // Manager is already whitelisted
      }
      managerWhitelist[managers[i]] = true;
      emit ManagerWhitelisted(managers[i]);
    }
  }

  function allFunds() public view returns (address[] memory) {
    return funds;
  }

  function enableBypassWhitelist() public onlyOwner {
    bypassWhitelist = true;
  }
}
