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

  event FundCreated(address indexed fund);

  constructor(ERC20 _usdToken) {
    usdToken = _usdToken;
  }

  function newFund(
    address manager,
    address feeWallet,
    address aumUpdater,
    uint256 timelock,
    uint256 managementFee,
    uint256 performanceFee,
    bool investmentsEnabled,
    bool signedAum,
    string calldata name,
    string calldata symbol
  ) public {
    require(manager != feeWallet, "Manager and fee can't be same");
    SMFund fund =
      new SMFund(
        manager,
        feeWallet,
        aumUpdater,
        timelock,
        managementFee,
        performanceFee,
        investmentsEnabled,
        signedAum,
        name,
        symbol
      );
    funds.push(fund);
    emit FundCreated(address(fund));
  }

  function allFunds() public view returns (SMFund[] memory) {
    return funds;
  }

  function fundsLength() public view returns (uint256) {
    return funds.length;
  }
}
