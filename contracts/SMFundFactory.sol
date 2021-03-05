// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.1;

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/proxy/Clones.sol';

import './SMFund.sol';

contract SMFundFactory is Ownable {
  address public masterFundLibrary;
  ERC20 public usdToken;
  SMFund[] public funds;

  mapping(address => address) public managersToFunds;

  event FundCreated(address indexed fund);

  constructor(address _masterFundLibrary, ERC20 _usdToken) {
    masterFundLibrary = _masterFundLibrary;
    usdToken = _usdToken;
  }

  function newFund(
    address initialInvestor,
    uint256[8] memory uintParams, // timelock, managementFee, performanceFee, initialAum, deadline, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount
    bool signedAum,
    string memory name,
    string memory symbol,
    string calldata logoUrl,
    string calldata initialInvestorName,
    bytes calldata signature
  ) public {
    require(managersToFunds[msg.sender] == address(0), 'F0');
    SMFund fund = SMFund(Clones.clone(masterFundLibrary));
    fund.initialize(
      [msg.sender, initialInvestor],
      uintParams,
      signedAum,
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
