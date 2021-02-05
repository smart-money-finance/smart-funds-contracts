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
    address manager,
    address aumUpdater,
    bool signedAum,
    string calldata name,
    string calldata symbol,
    string calldata logoUrl
  ) public {
    require(
      managersToFunds[manager] == address(0),
      'Manager already used for a fund'
    );
    SMFund fund =
      new SMFund(manager, aumUpdater, signedAum, name, symbol, logoUrl);
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
