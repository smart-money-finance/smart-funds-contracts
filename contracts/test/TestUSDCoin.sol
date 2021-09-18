// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.7;

import { ERC20Permit, ERC20 } from '@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol';

contract TestUSDCoin is ERC20Permit {
  constructor() ERC20Permit('USD Coin') ERC20('USD Coin', 'USDC') {}

  function version() public pure returns (string memory) {
    return '1';
  }

  function decimals() public pure override returns (uint8) {
    return 6;
  }

  function faucet(uint256 amount) public {
    _mint(msg.sender, amount);
  }
}
