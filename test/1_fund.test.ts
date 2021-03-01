import { describe, before } from 'mocha'
import { expect } from 'chai'
import { ethers, network } from 'hardhat'
import { Contract, Event } from 'ethers'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'
import { step } from 'mocha-steps'
import BigNumber from 'bignumber.js'

describe('Fund', () => {
  let usdToken: Contract
  let factory: Contract
  let fund: Contract
  let owner: SignerWithAddress
  let wallets: SignerWithAddress[]

  before(async () => {
    const UsdToken = await ethers.getContractFactory('TestUSDCoin')
    usdToken = await UsdToken.deploy()
    await usdToken.deployed()

    const Library = await ethers.getContractFactory('SMFundLibrary')
    const library = await Library.deploy()

    const Factory = await ethers.getContractFactory('SMFundFactory', {
      libraries: { SMFundLibrary: library.address },
    })
    factory = await Factory.deploy(usdToken.address)
    await factory.deployed()

    wallets = await ethers.getSigners()
    owner = wallets[0]

    // initialize wallets with usdc
    await usdToken.connect(owner).faucet(ethers.utils.parseUnits('100000', 6))
    await usdToken
      .connect(wallets[2])
      .faucet(ethers.utils.parseUnits('100000', 6))
    await usdToken
      .connect(wallets[3])
      .faucet(ethers.utils.parseUnits('100000', 6))
    await usdToken
      .connect(wallets[4])
      .faucet(ethers.utils.parseUnits('100000', 6))
  })

  step('Should create fund', async () => {
    const initialAum = await usdToken.balanceOf(owner.address)
    const tx = await factory.newFund(
      owner.address,
      [false, true],
      [1, 200, 2000, initialAum, ethers.constants.MaxUint256, 20, 5, 10000000],
      'Bobs cool fund',
      'BCF',
      'https://google.com/favicon.ico',
      'Bob',
      '0x00',
    )
    const txResp = await tx.wait()
    const fundAddress = txResp.events.find(
      (event: Event) => event.event === 'FundCreated',
    ).args.fund
    fund = await ethers.getContractAt('SMFund', fundAddress)
    expect(await fund.aum()).to.eq(initialAum)
  })

  // step('Should initialize AUM', async () => {
  //   const initialAum = await usdToken.balanceOf(owner.address)

  //   await fund.initialize(
  //     1,
  //     200,
  //     2000,
  //     true,
  //     initialAum,
  //     wallets[1].address,
  //     'Bob',
  //     ethers.constants.MaxUint256,
  //     '0x00',
  //   )
  //   expect(await fund.aum()).to.eq(initialAum)
  // })

  step('Should whitelist clients', async () => {
    expect((await fund.whitelist(wallets[2].address)).whitelisted).to.eq(false)
    expect((await fund.whitelist(wallets[3].address)).whitelisted).to.eq(false)
    expect((await fund.whitelist(wallets[4].address)).whitelisted).to.eq(false)

    await fund.whitelistMulti(
      [wallets[2].address, wallets[3].address, wallets[4].address],
      ['Sam', 'Bill', 'Jim'],
    )

    expect((await fund.whitelist(wallets[2].address)).whitelisted).to.eq(true)
    expect((await fund.whitelist(wallets[3].address)).whitelisted).to.eq(true)
    expect((await fund.whitelist(wallets[4].address)).whitelisted).to.eq(true)
  })

  step('Should invest client funds', async () => {
    const amountToInvest = ethers.utils.parseUnits('10000', 6)
    const aumBefore = await fund.aum()
    const supplyBefore = await fund.totalSupply()
    const mintedTokens = amountToInvest.mul(supplyBefore).div(aumBefore)

    expect(await fund.balanceOf(wallets[2].address)).to.eq(0)

    await usdToken
      .connect(wallets[2])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[2])
      .invest(amountToInvest, '1', ethers.constants.MaxUint256)

    const clientBalanceAfter = await fund.balanceOf(wallets[2].address)
    expect(clientBalanceAfter).to.eq(mintedTokens)
    expect(await fund.aum()).to.eq(aumBefore.add(amountToInvest))
    expect(await fund.totalSupply()).to.eq(supplyBefore.add(mintedTokens))
  })

  step('Should increase time and process fees', async () => {
    expect(await usdToken.balanceOf(fund.address)).to.eq(0)
    await usdToken.approve(fund.address, ethers.constants.MaxUint256)
    const investmentTimestamp = (await fund.investments(1)).timestamp
    const timeSkip = 2592000 // 60 * 60 * 24 * 30 = 30 days in seconds
    const fundAmountBefore = await fund.balanceOf(wallets[2].address)
    await network.provider.request({
      method: 'evm_increaseTime',
      params: [timeSkip],
    })
    await fund.processFees([1], ethers.constants.MaxUint256)
    const feeTimestamp = (await ethers.provider.getBlock('latest')).timestamp
    const mgmtFeeFundToken = new BigNumber(feeTimestamp)
      .minus(investmentTimestamp.toString())
      .div('31557600')
      .times('0.02')
      .times(fundAmountBefore.toString())
    const mgmtFeeUsd = new BigNumber((await fund.aum()).toString())
      .times(mgmtFeeFundToken)
      .div((await fund.totalSupply()).toString())
    // check usd balance of the fund
    expect((await usdToken.balanceOf(fund.address)).toString()).to.eq(
      mgmtFeeUsd.toFixed(0, BigNumber.ROUND_DOWN),
    )
    // check fund balance of the investor
    expect((await fund.balanceOf(wallets[2].address)).toString()).to.eq(
      new BigNumber(fundAmountBefore.toString())
        .minus(mgmtFeeFundToken.toFixed(0, BigNumber.ROUND_DOWN))
        .toFixed(0, BigNumber.ROUND_DOWN),
    )
  })

  step('Should update AUM', async () => {
    await usdToken
      .connect(wallets[3])
      .transfer(owner.address, ethers.utils.parseUnits('100', 6))
    const newAUM = await usdToken.balanceOf(owner.address)
    await fund.updateAum(newAUM, ethers.constants.MaxUint256, '0x00')
    expect(await fund.aum()).to.eq(newAUM)
  })

  step('Should Process redemption requests', async function () {
    const amountToInvest = ethers.utils.parseUnits('10000', 6)

    await usdToken
      .connect(wallets[4])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[4])
      .invest(amountToInvest, '1', ethers.constants.MaxUint256)

    await debug()
    await fund.processRedemptions([1], '1', ethers.constants.MaxUint256)
    await debug()
    await fund.processRedemptions([2], '1', ethers.constants.MaxUint256)
    await debug()
  })

  step('Should close fund', async function () {
    await debug()
    await fund.closeFund()
    await debug()
  })

  const debug = async () => {
    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))
    console.log(
      'OWNER',
      ethers.utils.formatUnits(await fund.balanceOf(owner.address), 6),
    )
    console.log(
      'WALLET 1 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[1].address), 6),
    )
    console.log(
      'WALLET 2 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[2].address), 6),
    )
    console.log(
      'WALLET 3 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[3].address), 6),
    )
    console.log(
      'WALLET 4 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[4].address), 6),
    )
  }
})
