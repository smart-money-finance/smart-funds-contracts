// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import './FundV0.sol';

/*
Upgrade notes:
Use openzeppelin hardhat upgrades package
Storage layout cannot change but can be added to at the end
version function must return hardcoded incremented version
*/

contract RegistryV0 is UUPSUpgradeable, OwnableUpgradeable {
  ERC20Permit public usdToken;
  uint256 public latestFundVersion;
  FundV0[] public fundImplementations;
  address[] public funds;

  mapping(address => bool) public managerWhitelist;
  bool public bypassWhitelist;
  mapping(address => address) public managerToFund;

  event NewFundImplementation(FundV0 fundImplementation, uint256 version);
  event ManagerWhitelisted(address indexed manager);
  event FundCreated(address indexed fund);

  error ManagerAlreadyHasFund();
  error NotWhitelisted();
  error ManagerAlreadyWhitelisted();
  error VersionMismatch();

  function initialize(
    FundV0 fundImplementation,
    ERC20Permit _usdToken,
    bool _bypassWhitelist
  ) public initializer {
    __Ownable_init();
    addNewFundImplementation(fundImplementation);
    usdToken = _usdToken;
    bypassWhitelist = _bypassWhitelist;
  }

  function version() public pure returns (uint256) {
    return 0;
  }

  function _authorizeUpgrade(address newRegistryImplementation)
    internal
    override
    onlyOwner
  {}

  function addNewFundImplementation(FundV0 fundImplementation)
    public
    onlyOwner
  {
    latestFundVersion = fundImplementations.length;
    if (latestFundVersion != fundImplementation.version()) {
      revert VersionMismatch();
    }
    fundImplementations.push(fundImplementation);
    emit NewFundImplementation(fundImplementation, latestFundVersion);
  }

  function newFund(
    address[2] memory addressParams, // aumUpdater, feeBeneficiary
    uint256[7] memory uintParams, // timelock, managementFee, performanceFee, maxInvestors, maxInvestmentsPerInvestor, minInvestmentAmount, feeTimelock
    string memory name,
    string memory symbol,
    string memory logoUrl,
    string memory contactInfo,
    string memory tags,
    bool usingUsdToken
  ) public {
    if (managerToFund[msg.sender] != address(0)) {
      revert ManagerAlreadyHasFund(); // Manager already has a fund
    }
    if (!(bypassWhitelist || managerWhitelist[msg.sender])) {
      revert NotWhitelisted(); // Not whitelisted as a fund manager
    }
    ERC1967Proxy fundProxy = new ERC1967Proxy(
      address(fundImplementations[latestFundVersion]),
      abi.encodeWithSignature(
        'initialize(address[2],uint256[7],string,string,string,string,string,bool,address)',
        addressParams,
        uintParams,
        name,
        symbol,
        logoUrl,
        contactInfo,
        tags,
        usingUsdToken,
        msg.sender
      )
    );
    address fundAddress = address(fundProxy);
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
