// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.3;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

contract FeeToken is IERC20 {
  string public name;
  string public symbol;
  uint8 public decimals;

  uint256 private baseSupply;
  uint256 public override totalSupply;
  uint256 private baseScale = 1e18;
  mapping(address => uint256) private baseBalanceOf;
  mapping(address => mapping(address => uint256)) public override allowance;

  event Fees(address indexed to, uint256 value);

  constructor(
    string memory _name,
    string memory _symbol,
    uint8 _decimals
  ) {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
  }

  function fromBase(uint256 amount) private view returns (uint256) {
    return (amount * baseScale) / 1e18;
  }

  function toBase(uint256 amount) private view returns (uint256) {
    return (amount * 1e18) / baseScale;
  }

  function balanceOf(address account) public view override returns (uint256) {
    return fromBase(baseBalanceOf[account]);
  }

  function transfer(address recipient, uint256 amount)
    public
    override
    returns (bool)
  {
    _transfer(msg.sender, recipient, amount);
    return true;
  }

  function approve(address spender, uint256 amount)
    public
    override
    returns (bool)
  {
    _approve(msg.sender, spender, amount);
    return true;
  }

  function increaseAllowance(address spender, uint256 addedValue)
    public
    returns (bool)
  {
    _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
    return true;
  }

  function decreaseAllowance(address spender, uint256 subtractedValue)
    public
    returns (bool)
  {
    uint256 currentAllowance = allowance[msg.sender][spender];
    require(
      currentAllowance >= subtractedValue,
      'ERC20: decreased allowance below zero'
    );
    _approve(msg.sender, spender, currentAllowance - subtractedValue);
    return true;
  }

  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) public override returns (bool) {
    _transfer(sender, recipient, amount);
    uint256 currentAllowance = allowance[sender][msg.sender];
    require(
      currentAllowance >= amount,
      'ERC20: transfer amount exceeds allowance'
    );
    _approve(sender, msg.sender, currentAllowance - amount);
    return true;
  }

  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) private {
    require(sender != address(0), 'ERC20: transfer from the zero address');
    require(recipient != address(0), 'ERC20: transfer to the zero address');
    uint256 baseAmount = toBase(amount);
    uint256 senderBaseBalance = baseBalanceOf[sender];
    require(
      senderBaseBalance >= baseAmount,
      'ERC20: transfer amount exceeds balance'
    );
    baseBalanceOf[sender] = senderBaseBalance - baseAmount;
    baseBalanceOf[recipient] += baseAmount;
    emit Transfer(sender, recipient, amount);
  }

  function _approve(
    address owner,
    address spender,
    uint256 amount
  ) private {
    require(owner != address(0), 'ERC20: approve from the zero address');
    require(spender != address(0), 'ERC20: approve to the zero address');

    allowance[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }

  function _mint(address account, uint256 amount) private {
    require(account != address(0), 'ERC20: mint to the zero address');
    uint256 baseAmount = toBase(amount);
    baseSupply += baseAmount;
    totalSupply += amount;
    baseBalanceOf[account] += baseAmount;
    emit Transfer(address(0), account, amount);
  }

  function _burn(address account, uint256 amount) private {
    require(account != address(0), 'ERC20: burn from the zero address');

    uint256 baseAmount = toBase(amount);
    uint256 baseBalance = baseBalanceOf[account];
    require(baseBalance >= baseAmount, 'ERC20: burn amount exceeds balance');
    baseSupply -= baseAmount;
    totalSupply -= amount;
    baseBalanceOf[account] = baseBalance - baseAmount;
    emit Transfer(account, address(0), amount);
  }

  function collectFees(address account, uint256 amount) public {
    // baseScale =
    //   (((baseSupply * baseScale) / 1e18 - amount) * 1e18) /
    //   baseSupply;
    baseScale = baseScale - ((amount * 1e18) / baseSupply);
    uint256 baseAmount = toBase(amount);
    baseSupply += baseAmount;
    baseBalanceOf[account] += baseAmount;
    emit Fees(account, amount);
  }

  // Mock only
  // function mint(address account, uint256 amount) public {
  //   _mint(account, amount);
  // }

  // function burn(address account, uint256 amount) public {
  //   _burn(account, amount);
  // }

  // function transferInternal(
  //   address from,
  //   address to,
  //   uint256 value
  // ) public {
  //   _transfer(from, to, value);
  // }

  // function approveInternal(
  //   address owner,
  //   address spender,
  //   uint256 value
  // ) public {
  //   _approve(owner, spender, value);
  // }

  // Test only
  function faucet(uint256 amount) public {
    _mint(msg.sender, amount);
  }
}
