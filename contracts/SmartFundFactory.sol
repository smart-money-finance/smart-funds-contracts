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
  mapping(address => address) public managerToFund;
  bool public bypassWhitelist;

  event ManagerWhitelisted(address indexed manager, string name);
  event FundCreated(address indexed fund);

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
    address[3] memory addressParams, // initialInvestor, aumUpdater, feeBeneficiary
    uint256[10] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock, redemptionWaitingPeriod
    bool signedAum,
    string memory name,
    string memory symbol,
    string memory logoUrl,
    string memory contactInfo,
    string memory initialInvestorName,
    string memory tags,
    bytes memory signature
  ) public {
    require(managerToFund[msg.sender] == address(0), 'F0'); // This address already manages a fund
    require(bypassWhitelist || managerWhitelist[msg.sender].whitelisted, 'F3'); // Not whitelisted as a fund manager
    SmartFund fund = SmartFund(Clones.clone(masterFundLibrary));
    fund.initialize(
      addressParams,
      uintParams,
      signedAum,
      name,
      symbol,
      logoUrl,
      contactInfo,
      initialInvestorName,
      tags,
      signature,
      msg.sender
    );
    funds.push(fund);
    managerToFund[msg.sender] = address(fund);
    emit FundCreated(address(fund));
  }

  function usdTransferFrom(
    address from,
    address to,
    uint256 amount
  ) public {
    require(msg.sender == managerToFund[SmartFund(msg.sender).manager()], 'F1'); // Only callable by funds
    usdToken.transferFrom(from, to, amount);
  }

  function whitelistMulti(address[] calldata managers, string[] calldata names)
    public
    onlyOwner
  {
    for (uint256 i = 0; i < managers.length; i++) {
      require(!managerWhitelist[managers[i]].whitelisted, 'F2'); // Manager is already whitelisted
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
}
