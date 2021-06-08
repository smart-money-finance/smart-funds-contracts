// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.4;

// import 'hardhat/console.sol';

contract FeeDividendToken {
  string public name;
  string public symbol;
  uint8 public decimals;

  uint256 internal baseSupply;
  uint256 internal baseScale;
  mapping(address => uint256) internal baseBalanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  event Transfer(address indexed from, address indexed to, uint256 amount);
  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 amount
  );

  event Fees(address indexed to, uint256 amount);
  event Dividends(address indexed from, uint256 amount);

  error DecreasedAllowanceBelowZero();
  error TransferAmountExceedsAllowance();
  error TransferFromZeroAddress();
  error TransferToZeroAddress();
  error TransferAmountExceedsBalance();
  error ApproveFromZeroAddress();
  error ApproveToZeroAddress();
  error MintToZeroAddress();
  error BurnFromZeroAddress();
  error BurnAmountExceedsBalance();
  error InsufficientBalances();
  error InsufficientBalance();

  function _FeeDividendToken_init(
    string memory _name,
    string memory _symbol,
    uint8 _decimals
  ) internal {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
    baseScale = 1e18;
  }

  function fromBase(uint256 amount) internal view returns (uint256) {
    return amount / baseScale;
  }

  function toBase(uint256 amount) internal view returns (uint256) {
    return amount * baseScale;
  }

  function totalSupply() public view returns (uint256) {
    return fromBase(baseSupply);
  }

  function balanceOf(address account) public view returns (uint256) {
    return fromBase(baseBalanceOf[account]);
  }

  function transfer(address recipient, uint256 amount) public returns (bool) {
    _transfer(msg.sender, recipient, amount);
    return true;
  }

  function approve(address spender, uint256 amount) public returns (bool) {
    _approve(msg.sender, spender, amount);
    return true;
  }

  // function increaseAllowance(address spender, uint256 addedAmount)
  //   public
  //   returns (bool)
  // {
  //   _approve(msg.sender, spender, allowance[msg.sender][spender] + addedAmount);
  //   return true;
  // }

  // function decreaseAllowance(address spender, uint256 subtractedAmount)
  //   public
  //   returns (bool)
  // {
  //   uint256 currentAllowance = allowance[msg.sender][spender];
  //   if (currentAllowance < subtractedAmount) {
  //     revert DecreasedAllowanceBelowZero();
  //   }
  //   _approve(msg.sender, spender, currentAllowance - subtractedAmount);
  //   return true;
  // }

  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) public returns (bool) {
    _transfer(sender, recipient, amount);
    uint256 currentAllowance = allowance[sender][msg.sender];
    if (currentAllowance < amount) {
      revert TransferAmountExceedsAllowance();
    }
    _approve(sender, msg.sender, currentAllowance - amount);
    return true;
  }

  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal {
    if (sender == address(0)) {
      revert TransferFromZeroAddress();
    }
    if (recipient == address(0)) {
      revert TransferToZeroAddress();
    }
    _beforeTokenTransfer(sender, recipient, amount);
    uint256 baseAmount = toBase(amount);
    uint256 senderBaseBalance = baseBalanceOf[sender];
    if (senderBaseBalance < baseAmount) {
      revert TransferAmountExceedsBalance();
    }
    baseBalanceOf[sender] = senderBaseBalance - baseAmount;
    baseBalanceOf[recipient] += baseAmount;
    emit Transfer(sender, recipient, amount);
  }

  function _approve(
    address owner,
    address spender,
    uint256 amount
  ) internal {
    if (owner == address(0)) {
      revert ApproveFromZeroAddress();
    }
    if (spender == address(0)) {
      revert ApproveToZeroAddress();
    }
    allowance[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }

  function _mint(address account, uint256 amount) internal {
    if (account == address(0)) {
      revert MintToZeroAddress();
    }
    _beforeTokenTransfer(address(0), account, amount);
    uint256 baseAmountToMint = toBase(amount);
    baseSupply += baseAmountToMint;
    baseBalanceOf[account] += baseAmountToMint;
    emit Transfer(address(0), account, amount);
  }

  function _burn(address account, uint256 amount) internal {
    if (account == address(0)) {
      revert BurnFromZeroAddress();
    }
    _beforeTokenTransfer(account, address(0), amount);
    uint256 baseAmountToBurn = toBase(amount);
    uint256 baseBalance = baseBalanceOf[account];
    if (baseBalance < baseAmountToBurn) {
      revert BurnAmountExceedsBalance();
    }
    baseSupply -= baseAmountToBurn;
    baseBalanceOf[account] = baseBalance - baseAmountToBurn;
    emit Transfer(account, address(0), amount);
  }

  // "to" balance goes up by "amount"
  // all other balances go down proportionally to maintain an unchanged total supply
  // this is equivalent to charging a percent fee on all holders and moving the tokens to a fee wallet
  //
  // Note: there is some math that truncates so totalSupply is not guaranteed to remain exactly unchanged
  // and total balances are not guaranteed to add up to totalSupply exactly
  // but the differences are negligible in terms of USD
  // as long as there are enough decimal points and the token is valued high enough
  function _collectFees(address to, uint256 amount) internal {
    uint256 newFeeBalance = fromBase(baseBalanceOf[to]) + amount;
    uint256 nonFeeBaseSupply = baseSupply - baseBalanceOf[to];
    if (fromBase(nonFeeBaseSupply) <= amount) {
      revert InsufficientBalances();
    }
    // first scale all balances so that the total supply not in the "to" wallet goes down by "amount"
    // Math:
    //
    // amount = (totalSupplyBefore - toBalanceBefore) - (totalSupplyAfter - toBalanceAfter)
    //
    // totalSupply = baseSupply / baseScale
    //
    // toBalance = baseBalanceOf[to] / baseScale
    //
    // nonFeeBaseSupply = baseSupply - baseBalanceOf[to]
    //
    // amount =
    //     ((baseSupply / baseScaleBefore) - (baseBalanceOf[to] / baseScaleBefore)) -
    //         ((baseSupply / baseScaleAfter) - (baseBalanceOf[to] / baseScaleAfter))
    //
    // amount = ((baseSupply - baseBalanceOf[to]) / baseScaleBefore) -
    //     ((baseSupply - baseBalanceOf[to]) / baseScaleAfter)
    //
    // amount = (nonFeeBaseSupply / baseScaleBefore) - (nonFeeBaseSupply / baseScaleAfter)
    //
    // (nonFeeBaseSupply / baseScaleBefore) - amount = (nonFeeBaseSupply / baseScaleAfter)
    //
    // (1 / baseScaleBefore) - (amount / nonFeeBaseSupply) = 1 / baseScaleAfter
    //
    // baseScaleAfter * ((1 / baseScaleBefore) - (amount / nonFeeBaseSupply)) = 1
    //
    // baseScaleAfter = 1 / (((1 / baseScaleBefore) - (amount / nonFeeBaseSupply)))
    baseScale = nonFeeBaseSupply / ((nonFeeBaseSupply / baseScale) - amount);
    // then adjust the "to" wallet's balance to make total supply unchanged
    // which is equivalent to proportionally taking balance from all accounts and moving it to "to"
    uint256 newBaseBalance = toBase(newFeeBalance);
    uint256 baseAmountToMint = newBaseBalance - baseBalanceOf[to];
    baseSupply += baseAmountToMint;
    baseBalanceOf[to] += baseAmountToMint;
    emit Fees(to, amount);
  }

  function _disperseDividends(address from, uint256 amount) internal {
    uint256 dividendBalance = fromBase(baseBalanceOf[from]);
    if (dividendBalance < amount) {
      revert InsufficientBalance();
    }
    uint256 newDividendBalance = dividendBalance - amount;
    uint256 nonDividendBaseSupply = baseSupply - baseBalanceOf[from];
    if (nonDividendBaseSupply == 0) {
      revert InsufficientBalances();
    }
    // same math as above except amount is added to all other balances instead of subtracted
    baseScale =
      nonDividendBaseSupply /
      ((nonDividendBaseSupply / baseScale) + amount);
    // then adjust "from" balance
    uint256 newBaseBalance = toBase(newDividendBalance);
    uint256 baseAmountToBurn = baseBalanceOf[from] - newBaseBalance;
    baseSupply -= baseAmountToBurn;
    baseBalanceOf[from] -= baseAmountToBurn;
    emit Dividends(from, amount);
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual {}
}
