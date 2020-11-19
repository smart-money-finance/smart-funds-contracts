// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.12;

import '@openzeppelin/contracts/GSN/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import './SMFund.sol';

contract SMFundFactory is Context, Ownable {
  ERC20 public immutable usdToken;
  SMFund[] public funds;

  event FundCreated(address indexed fund);

  constructor(ERC20 _usdToken) public {
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
    string calldata symbol,
    uint256 initialAum,
    address initialInvestor,
    uint256 deadline,
    bytes memory signature
  ) public {
    require(initialAum > 0, "Initial AUM can't be 0");
    require(manager != feeWallet, "Manager and fee can't be same");
    SMFund fund = new SMFund(
      manager,
      feeWallet,
      aumUpdater,
      timelock,
      managementFee,
      performanceFee,
      investmentsEnabled,
      signedAum,
      name,
      symbol,
      initialAum,
      initialInvestor,
      deadline,
      signature
    );
    funds.push(fund);
    emit FundCreated(address(fund));
  }
}
