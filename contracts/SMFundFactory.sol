// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.1;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import './SMFund.sol';

contract SMFundFactory is Ownable {
  ERC20 public usdToken;
  SMFund[] public funds;

  mapping(address => address) public managersToFunds;

  event FundCreated(address indexed fund);

  constructor(ERC20 _usdToken) {
    usdToken = _usdToken;
  }

  function newFund(
    address initialInvestor,
    bool[2] memory boolParams, // signedAum, investmentsEnabled
    uint256[8] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount
    string memory name,
    string memory symbol,
    string calldata logoUrl,
    string calldata initialInvestorName,
    bytes calldata signature
  ) public {
    require(managersToFunds[msg.sender] == address(0), 'F0');
    SMFund fund =
      new SMFund(
        [msg.sender, initialInvestor],
        boolParams,
        uintParams,
        name,
        symbol,
        logoUrl,
        initialInvestorName,
        signature
      );
    funds.push(fund);
    managersToFunds[msg.sender] = address(fund);
    emit FundCreated(address(fund));
  }

  function allFunds() public view returns (SMFund[] memory) {
    return funds;
  }

  function fundsLength() public view returns (uint256) {
    return funds.length;
  }
}
