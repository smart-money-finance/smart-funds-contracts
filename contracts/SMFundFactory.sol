// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import './SMFund.sol';

contract SMFundFactory is Context, Ownable {
  ERC20 public immutable usdToken;
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
    address manager = _msgSender();
    require(managersToFunds[manager] == address(0), 'F0');
    SMFund fund =
      new SMFund(
        [manager, initialInvestor],
        boolParams,
        uintParams,
        name,
        symbol,
        logoUrl,
        initialInvestorName,
        signature
      );
    funds.push(fund);
    managersToFunds[manager] = address(fund);
    emit FundCreated(address(fund));
  }

  function allFunds() public view returns (SMFund[] memory) {
    return funds;
  }

  function fundsLength() public view returns (uint256) {
    return funds.length;
  }
}
