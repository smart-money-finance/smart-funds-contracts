// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.3;

import './FeeDividendToken.sol';

contract MockToken is FeeDividendToken {
  constructor(
    string memory name,
    string memory symbol,
    uint8 decimals
  ) FeeDividendToken(name, symbol, decimals) {}

  // Mock only for zeppelin tests
  function mint(address account, uint256 amount) public {
    _mint(account, amount);
  }

  function burn(address account, uint256 amount) public {
    _burn(account, amount);
  }

  function transferInternal(
    address from,
    address to,
    uint256 amount
  ) public {
    _transfer(from, to, amount);
  }

  function approveInternal(
    address owner,
    address spender,
    uint256 amount
  ) public {
    _approve(owner, spender, amount);
  }

  // Test only
  function collectFees(address to, uint256 amount) public {
    _collectFees(to, amount);
  }

  function disperseDividends(address from, uint256 amount) public {
    _disperseDividends(from, amount);
  }
}
