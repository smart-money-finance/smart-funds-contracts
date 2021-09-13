// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import { FundV0 } from '../FundV0.sol';

// make internal functions and vars public so they can be tested easier
contract TestFundV0 is FundV0 {
  function navs(uint256 id) public view returns (Nav memory) {
    return _navs[id];
  }

  function navsLength() public view returns (uint256) {
    return _navs.length;
  }

  function investments(uint256 id) public view returns (Investment memory) {
    return _investments[id];
  }

  function investmentsLength() public view returns (uint256) {
    return _investments.length;
  }

  function feeSweeps(uint256 id) public view returns (FeeSweep memory) {
    return _feeSweeps[id];
  }

  function feeSweepsLength() public view returns (uint256) {
    return _feeSweeps.length;
  }

  function feeWithdrawals(uint256 id)
    public
    view
    returns (FeeWithdrawal memory)
  {
    return _feeWithdrawals[id];
  }

  function feeWithdrawalsLength() public view returns (uint256) {
    return _feeWithdrawals.length;
  }

  function investmentRequests(uint256 id)
    public
    view
    returns (InvestmentRequest memory)
  {
    return _investmentRequests[id];
  }

  function investmentRequestsLength() public view returns (uint256) {
    return _investmentRequests.length;
  }

  function redemptionRequests(uint256 id)
    public
    view
    returns (RedemptionRequest memory)
  {
    return _redemptionRequests[id];
  }

  function redemptionRequestsLength() public view returns (uint256) {
    return _redemptionRequests.length;
  }

  function redemptions(uint256 id) public view returns (Redemption memory) {
    return _redemptions[id];
  }

  function redemptionsLength() public view returns (uint256) {
    return _redemptions.length;
  }

  function investorCount() public view returns (uint256) {
    return _investorCount;
  }

  function activeInvestmentCount() public view returns (uint256) {
    return _activeInvestmentCount;
  }

  function doneImportingInvestments() public view returns (bool) {
    return _doneImportingInvestments;
  }

  function lastFeeSweepEndedTimestamp() public view returns (uint256) {
    return _lastFeeSweepEndedTimestamp;
  }

  function investmentsSweptSinceStarted() public view returns (uint256) {
    return _investmentsSweptSinceStarted;
  }

  function feeSweeping() public view returns (bool) {
    return _feeSweeping;
  }

  function feesSweptNotWithdrawn() public view returns (uint256) {
    return _feesSweptNotWithdrawn;
  }

  function closed() public view returns (bool) {
    return _closed;
  }

  function investorInfo(address investor)
    public
    view
    returns (Investor memory)
  {
    return _investorInfo[investor];
  }

  function investors(uint256 id) public view returns (address) {
    return _investors[id];
  }

  function investorsLength() public view returns (uint256) {
    return _investors.length;
  }

  function manager() public view returns (address) {
    return _manager;
  }

  function custodian() public view returns (address) {
    return _custodian;
  }

  function aumUpdater() public view returns (address) {
    return _aumUpdater;
  }

  function feeBeneficiary() public view returns (address) {
    return _feeBeneficiary;
  }

  function timelock() public view returns (uint256) {
    return _timelock;
  }

  function feeSweepInterval() public view returns (uint256) {
    return _feeSweepInterval;
  }

  function managementFee() public view returns (uint256) {
    return _managementFee;
  }

  function performanceFee() public view returns (uint256) {
    return _performanceFee;
  }

  function maxInvestors() public view returns (uint256) {
    return _maxInvestors;
  }

  function maxInvestmentsPerInvestor() public view returns (uint256) {
    return _maxInvestmentsPerInvestor;
  }

  function minInvestmentAmount() public view returns (uint256) {
    return _minInvestmentAmount;
  }

  function initialPrice() public view returns (uint256) {
    return _initialPrice;
  }

  function usingUsdToken() public view returns (bool) {
    return _usingUsdToken;
  }
}
