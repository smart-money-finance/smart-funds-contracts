import { describe, it, beforeEach } from 'mocha'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Contract, BigNumber } from 'ethers'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'
import { step } from 'mocha-steps'

function expandTo18Decimals(n: number | string) {
  return BigNumber.from(n).mul(BigNumber.from(10).pow(18))
}
function expandTo6Decimals(n: number | string) {
  return BigNumber.from(n).mul(BigNumber.from(10).pow(6))
}

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

    const Factory = await ethers.getContractFactory('SMFundFactory')
    factory = await Factory.deploy(usdToken.address)
    await factory.deployed()

    wallets = await ethers.getSigners()
    owner = wallets[0]
    wallets.shift()

    // initialize wallets with usdc
    await usdToken.connect(wallets[2]).faucet(expandTo6Decimals('1000000000'))
    await usdToken.connect(wallets[3]).faucet(expandTo6Decimals('1000000000'))
    await usdToken.connect(wallets[4]).faucet(expandTo6Decimals('1000000000'))
  })

  step('Should create fund', async () => {
    const tx = await factory.newFund(
      owner.address,
      wallets[0].address,
      owner.address,
      1,
      100,
      400,
      true,
      false,
      'Bobs cool fund',
      'BCF',
    )
    let fundAddress = ''
    const txResp = await tx.wait()
    for (const log of txResp.logs) {
      if (log.topics[0] === factory.interface.getEventTopic('FundCreated')) {
        fundAddress = ethers.utils.getAddress(
          ethers.utils.hexStripZeros(log.topics[1]),
        )
        break
      }
    }
    fund = await ethers.getContractAt('SMFund', fundAddress)
  })

  step('Should initialize AUM', async () => {
    const initialAum = await wallets[0].getBalance()

    await fund.initialize(
      initialAum,
      wallets[1].address,
      ethers.constants.MaxUint256,
      '0x00',
    )
    expect(await fund.aum()).to.eq(initialAum)
  })

  step('Should whitelist clients', async () => {
    expect(await fund.whitelist(wallets[2].address)).to.eq(false)
    expect(await fund.whitelist(wallets[3].address)).to.eq(false)
    expect(await fund.whitelist(wallets[4].address)).to.eq(false)

    await fund.whitelistMulti([
      wallets[2].address,
      wallets[3].address,
      wallets[4].address,
    ])

    expect(await fund.whitelist(wallets[2].address)).to.eq(true)
    expect(await fund.whitelist(wallets[3].address)).to.eq(true)
    expect(await fund.whitelist(wallets[4].address)).to.eq(true)
  })

  step('Should invest client funds', async () => {
    const amountToInvest = expandTo6Decimals(100)
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

  step('Should update AUM', async () => {
    const newAUM = (await fund.aum()).mul(2)
    await fund.updateAum(newAUM, ethers.constants.MaxUint256, '0x00')
    expect(await fund.aum()).to.eq(newAUM)
  })

  it('Should Process redemption requests', async function () {
    const amountToInvest = expandTo6Decimals(100)

    await usdToken
      .connect(wallets[4])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[4])
      .invest(amountToInvest, '1', ethers.constants.MaxUint256)

    await debug()
    await usdToken.approve(fund.address, ethers.constants.MaxUint256)
    await fund.processRedemptions([1], '1', ethers.constants.MaxUint256)
    await debug()
    await fund.processRedemptions([2], '1', ethers.constants.MaxUint256)
    await debug()
    await fund.processRedemptions([3], '1', ethers.constants.MaxUint256)
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
