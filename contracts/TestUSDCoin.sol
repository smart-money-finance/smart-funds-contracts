// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.7.5;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TestUSDCoin is ERC20 {
  constructor() ERC20('USD Coin', 'USDC') {
    _setupDecimals(6);
  }

  function faucet(uint256 amount) public {
    _mint(msg.sender, amount);
  }
}
