// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/cryptography/ECDSA.sol';

import './SMFund.sol';

struct Investment {
  address investor;
  uint256 initialUsdAmount;
  uint256 usdManagementFeesCollected;
  uint256 usdPerformanceFeesCollected;
  uint256 initialFundAmount;
  uint256 fundAmount;
  uint256 timestamp;
  uint256 lastFeeTimestamp;
  bool redeemed;
}

library SMFundLibrary {
  using SafeMath for uint256;
  using ECDSA for bytes32;

  function verifyAumSignature(
    bool signedAum,
    address sender,
    address _signer,
    address manager,
    uint256 aum,
    uint256 deadline,
    bytes memory signature
  ) public pure {
    if (!signedAum) {
      require(sender == manager, 'L0');
    } else if (sender == manager) {
      bytes32 message = keccak256(abi.encode(manager, aum, deadline));
      address signer = message.toEthSignedMessageHash().recover(signature);
      require(signer == _signer, 'L1');
    } else {
      require(sender == _signer, 'L2');
    }
  }

  function calculateManagementFee(
    Investment storage investment,
    uint256 managementFee,
    uint256 aum,
    uint256 totalSupply
  ) public view returns (uint256 usdManagementFee, uint256 fundManagementFee) {
    // calculate management fee % of current fund tokens scaled over the time since last fee withdrawal
    fundManagementFee = block
      .timestamp
      .sub(investment.timestamp)
      .mul(managementFee)
      .mul(investment.fundAmount)
      .div(3652500 days); // management fee is over a whole year (365.25 days) and denoted in basis points so also need to divide by 10000, do it in one operation to save a little gas

    // calculate the usd value of the management fee being pulled
    usdManagementFee = fundManagementFee.mul(aum).div(totalSupply);
  }

  function calculatePerformanceFee(
    Investment storage investment,
    uint256 performanceFee,
    uint256 aum,
    uint256 totalSupply
  )
    public
    view
    returns (uint256 usdPerformanceFee, uint256 fundPerformanceFee)
  {
    // usd value of the investment
    uint256 currentUsdValue = aum.mul(investment.fundAmount).div(totalSupply);
    uint256 totalUsdPerformanceFee = 0;
    if (currentUsdValue > investment.initialUsdAmount) {
      // calculate current performance fee from initial usd value of investment to current usd value
      totalUsdPerformanceFee = currentUsdValue
        .sub(investment.initialUsdAmount)
        .mul(performanceFee)
        .div(10000);
    }
    // if we're over the high water mark, meaning more performance fees are owed than have previously been collected
    if (totalUsdPerformanceFee > investment.usdPerformanceFeesCollected) {
      usdPerformanceFee = totalUsdPerformanceFee.sub(
        investment.usdPerformanceFeesCollected
      );
      fundPerformanceFee = totalSupply.mul(usdPerformanceFee).div(aum);
    }
  }

  function highWaterMark(Investment storage investment, uint256 performanceFee)
    public
    view
    returns (uint256 usdValue)
  {
    usdValue = investment
      .usdPerformanceFeesCollected
      .mul(10000)
      .div(performanceFee)
      .add(investment.initialUsdAmount);
  }
}
