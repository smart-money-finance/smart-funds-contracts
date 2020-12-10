import { describe, it, beforeEach } from 'mocha'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Signer, Contract, Transaction } from 'ethers'
import { BigNumber } from 'bignumber.js'

describe('Fund', function () {
  it('Should set up a fund and take investments', async function () {
    const [owner, ...wallets] = await ethers.getSigners()
    const UsdToken = await ethers.getContractFactory('TestUSDCoin')
    const Factory = await ethers.getContractFactory('SMFundFactory')
    const usdToken = await UsdToken.deploy()
    await usdToken.deployed()
    await usdToken.connect(wallets[2]).faucet('1000000000')
    await usdToken.connect(wallets[3]).faucet('1000000000')
    await usdToken.connect(wallets[4]).faucet('1000000000')
    const factory = await Factory.deploy(usdToken.address)
    await factory.deployed()
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
    const txResp = await tx.wait()
    let fundAddress = ''
    for (const log of txResp.logs) {
      if (log.topics[0] === factory.interface.getEventTopic('FundCreated')) {
        fundAddress = ethers.utils.getAddress(
          ethers.utils.hexStripZeros(log.topics[1]),
        )
        break
      }
    }
    const fund = await ethers.getContractAt('SMFund', fundAddress)

    // console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    // console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    const initialAum = ethers.utils.parseUnits(
      new BigNumber(ethers.utils.formatEther(await wallets[0].getBalance()))
        .times(500)
        .toFixed(),
      6,
    )

    await fund.initialize(
      initialAum,
      wallets[1].address,
      ethers.constants.MaxUint256,
      '0x00',
    )

    // console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    // console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[1].address), 6),
    // )

    await fund.whitelistMulti([
      wallets[2].address,
      wallets[3].address,
      wallets[4].address,
    ])
    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[2].address), 6),
    // )
    await usdToken
      .connect(wallets[2])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[2])
      .invest('100000000', '1', ethers.constants.MaxUint256)
    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[2].address), 6),
    // )

    // console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    // console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[3].address), 6),
    // )
    await usdToken
      .connect(wallets[3])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[3])
      .invest('10000000', '1', ethers.constants.MaxUint256)
    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[3].address), 6),
    // )

    // console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    // console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    await fund.updateAum(
      new BigNumber((await fund.aum()).toString()).times(1.2).toFixed(),
      ethers.constants.MaxUint256,
      '0x00',
    )

    // console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    // console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[4].address), 6),
    // )
    await usdToken
      .connect(wallets[4])
      .approve(fund.address, ethers.constants.MaxUint256)
    await fund
      .connect(wallets[4])
      .invest('10000000', '1', ethers.constants.MaxUint256)
    // console.log(
    //   ethers.utils.formatUnits(await fund.balanceOf(wallets[4].address), 6),
    // )

    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))

    // console.log((await usdToken.balanceOf(owner.address)).toString())

    await usdToken.approve(fund.address, ethers.constants.MaxUint256)
    console.log((await usdToken.balanceOf(owner.address)).toString())
    await fund.processRedemptions([1], '1', ethers.constants.MaxUint256)
    console.log((await usdToken.balanceOf(owner.address)).toString())
    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))
    await fund.processRedemptions([2], '1', ethers.constants.MaxUint256)
    console.log((await usdToken.balanceOf(owner.address)).toString())
    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))
    await fund.processRedemptions([3], '1', ethers.constants.MaxUint256)
    console.log((await usdToken.balanceOf(owner.address)).toString())
    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6))
    console.log('SUPPLY', ethers.utils.formatUnits(await fund.totalSupply(), 6))
  })
})
