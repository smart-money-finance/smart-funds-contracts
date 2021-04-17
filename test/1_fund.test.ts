import { describe, before } from 'mocha';
import { expect, use } from 'chai';
import { ethers, network } from 'hardhat';
import { Contract, Event } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { step } from 'mocha-steps';
import BigNumber from 'bignumber.js';
import { solidity } from 'ethereum-waffle';

use(solidity);
describe('Fund', () => {
  let usdToken: Contract;
  let factory: Contract;
  let fund: Contract;
  let owner: SignerWithAddress;
  let wallets: SignerWithAddress[];

  before(async () => {
    const UsdToken = await ethers.getContractFactory('TestUSDCoin');
    usdToken = await UsdToken.deploy();
    await usdToken.deployed();

    const SMFund = await ethers.getContractFactory('SMFund');
    const masterFundLibrary = await SMFund.deploy();

    const Factory = await ethers.getContractFactory('SMFundFactory');
    factory = await Factory.deploy(masterFundLibrary.address, usdToken.address);
    await factory.deployed();

    wallets = await ethers.getSigners();
    owner = wallets[0];

    // initialize wallets with usdc
    await usdToken.connect(owner).faucet(ethers.utils.parseUnits('100000', 6));
    await usdToken
      .connect(wallets[2])
      .faucet(ethers.utils.parseUnits('100000', 6));
    await usdToken
      .connect(wallets[3])
      .faucet(ethers.utils.parseUnits('100000', 6));
    await usdToken
      .connect(wallets[4])
      .faucet(ethers.utils.parseUnits('100000', 6));
  });

  step('Should whitelist fund manager', async () => {
    await factory.whitelistMulti([owner.address], ['Bob']);
  });

  step('Should create fund', async () => {
    const initialAum = await usdToken.balanceOf(owner.address);
    const tx = await factory.newFund(
      wallets[1].address,
      [
        1,
        200,
        2000,
        initialAum,
        ethers.constants.MaxUint256,
        20,
        5,
        10000000,
        1,
        1,
      ],
      false,
      'Bobs cool fund',
      'BCF',
      'https://google.com/favicon.ico',
      'bob@bob.com',
      'Bob',
      'Hedge Fund,Test Fund,Other tag',
      '0x00',
    );
    const txResp = await tx.wait();
    const fundAddress = txResp.events.find(
      (event: Event) => event.event === 'FundCreated',
    ).args.fund;
    fund = await ethers.getContractAt('SMFund', fundAddress);
    const request = await fund.investmentRequests(0);
    const investment = await fund.investments(0);
    const initalPrice = ethers.BigNumber.from('10000000000000000'); // $0.01 * 1e18
    expect(await fund.aum()).to.eq(initialAum);
    expect({ ...request }).to.deep.include({
      investor: wallets[1].address,
      usdAmount: initialAum,
      investmentId: ethers.BigNumber.from(0),
      status: 2, // processed
    });
    expect({ ...investment }).to.deep.include({
      investor: wallets[1].address,
      initialUsdAmount: initialAum,
      initialFundAmount: initialAum.mul(100),
      initialHighWaterPrice: initalPrice,
      investmentRequestId: ethers.BigNumber.from(0),
      redeemed: false,
    });
    expect((await fund.whitelist(wallets[1].address)).whitelisted).to.eq(true);
    expect((await fund.whitelist(wallets[1].address)).name).to.eq('Bob');
    expect(await fund.highWaterPrice()).to.eq(initalPrice);
    expect(await fund.activeAndPendingInvestmentCount()).to.eq(1);
    expect(
      await fund.activeAndPendingInvestmentCountPerInvestor(wallets[1].address),
    ).to.eq(1);
    expect(await fund.investorCount()).to.eq(1);
  });

  step('Should whitelist clients', async () => {
    expect((await fund.whitelist(wallets[2].address)).whitelisted).to.eq(false);
    expect((await fund.whitelist(wallets[3].address)).whitelisted).to.eq(false);
    expect((await fund.whitelist(wallets[4].address)).whitelisted).to.eq(false);

    await fund.whitelistMulti(
      [wallets[2].address, wallets[3].address, wallets[4].address],
      ['Sam', 'Bill', 'Jim'],
    );

    expect(await fund.investorCount()).to.eq(4);
    expect((await fund.whitelist(wallets[2].address)).whitelisted).to.eq(true);
    expect((await fund.whitelist(wallets[2].address)).name).to.eq('Sam');
    expect((await fund.whitelist(wallets[3].address)).whitelisted).to.eq(true);
    expect((await fund.whitelist(wallets[3].address)).name).to.eq('Bill');
    expect((await fund.whitelist(wallets[4].address)).whitelisted).to.eq(true);
    expect((await fund.whitelist(wallets[4].address)).name).to.eq('Jim');
    expect((await fund.whitelist(wallets[0].address)).whitelisted).to.eq(false);
    expect((await fund.whitelist(wallets[5].address)).whitelisted).to.eq(false);
  });

  step('Should add usd and update AUM', async () => {
    await usdToken.connect(owner).faucet(ethers.utils.parseUnits('1000', 6));
    const newAum = await usdToken.balanceOf(owner.address);
    const supply = await fund.totalSupply();
    await fund.updateAum(newAum, ethers.constants.MaxUint256, 0, 0, '0x00');
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const price = newAum.mul(ethers.utils.parseUnits('1', 18)).div(supply);
    expect(await fund.aum()).to.eq(newAum);
    expect(await fund.aumTimestamp()).to.eq(timestamp);
    expect(await fund.highWaterPrice()).to.eq(price);
  });

  step('Should request to invest client funds', async () => {
    const amountToInvest = ethers.utils.parseUnits('10000', 6);
    const aumBefore = await fund.aum();
    const supplyBefore = await fund.totalSupply();

    await usdToken
      .connect(wallets[2])
      .approve(factory.address, ethers.constants.MaxUint256);
    await fund
      .connect(wallets[2])
      .requestInvestment(
        amountToInvest,
        '1',
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
      );

    const request = await fund.investmentRequests(1);
    expect(await fund.aum()).to.eq(aumBefore);
    expect(await fund.totalSupply()).to.eq(supplyBefore);
    expect({ ...request }).to.deep.include({
      investor: wallets[2].address,
      usdAmount: amountToInvest,
      investmentId: ethers.BigNumber.from(0),
      status: 0, // pending
    });
    expect(await usdToken.balanceOf(fund.address)).to.eq(amountToInvest);
    expect(await fund.balanceOf(wallets[2].address)).to.eq(0);
  });

  step(
    'Should update AUM and process investment in one transaction',
    async () => {
      const newAum = await usdToken.balanceOf(owner.address);
      const supply = await fund.totalSupply();
      await fund.updateAum(newAum, ethers.constants.MaxUint256, 1, 0, '0x00');
      const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
      const price = newAum.mul(ethers.utils.parseUnits('1', 18)).div(supply);
      const request = await fund.investmentRequests(1);
      const fundMinted = request.usdAmount.mul(supply).div(newAum);
      const investment = await fund.investments(1);
      const aumAfter = await fund.aum();
      const supplyAfter = await fund.totalSupply();
      const priceAfter = aumAfter
        .mul(ethers.utils.parseUnits('1', 18))
        .div(supplyAfter);
      expect(supplyAfter).to.eq(supply.add(fundMinted));
      expect(aumAfter).to.eq(newAum.add(request.usdAmount));
      expect(await fund.aumTimestamp()).to.eq(timestamp);
      expect(await fund.highWaterPrice()).to.eq(price);
      expect({ ...request }).to.deep.include({
        investmentId: ethers.BigNumber.from(1),
        status: 2, // processed
      });
      // console.log(investment.initialHighWaterPrice.toString());
      // console.log(priceAfter.toString());
      expect({ ...investment }).to.deep.include({
        investor: request.investor,
        initialUsdAmount: request.usdAmount,
        initialFundAmount: fundMinted,
        // initialHighWaterPrice: priceAfter,
        investmentRequestId: ethers.BigNumber.from(1),
        redeemed: false,
      });
      expect(await usdToken.balanceOf(fund.address)).to.eq(0);
      expect(await fund.balanceOf(request.investor)).to.eq(fundMinted);
      expect(await fund.activeAndPendingInvestmentCount()).to.eq(2);
      expect(
        await fund.activeAndPendingInvestmentCountPerInvestor(
          wallets[2].address,
        ),
      ).to.eq(1);
    },
  );

  step('Should withdraw accrued fees', async () => {
    const feesFundAmount = await fund.balanceOf(fund.address);
    const usdAmount = feesFundAmount
      .mul(await fund.aum())
      .div(await fund.totalSupply());
    expect(await usdToken.balanceOf(wallets[5].address)).to.eq(0);
    await usdToken.approve(factory.address, ethers.constants.MaxUint256);
    await fund.withdrawFees(wallets[5].address, feesFundAmount);
    expect(await fund.balanceOf(fund.address)).to.eq(0);
    expect(await usdToken.balanceOf(wallets[5].address)).to.eq(usdAmount);
  });

  // step('Should increase time and process fees', async () => {
  //   expect(await usdToken.balanceOf(fund.address)).to.eq(0);
  //   await usdToken.approve(fund.address, ethers.constants.MaxUint256);
  //   const investmentTimestamp = (await fund.investments(1)).timestamp;
  //   const timeSkip = 2592000; // 60 * 60 * 24 * 30 = 30 days in seconds
  //   const fundAmountBefore = await fund.balanceOf(wallets[2].address);
  //   await network.provider.request({
  //     method: 'evm_increaseTime',
  //     params: [timeSkip],
  //   });
  //   await fund.processFees([1], ethers.constants.MaxUint256);
  //   const feeTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
  //   const mgmtFeeFundToken = new BigNumber(feeTimestamp)
  //     .minus(investmentTimestamp.toString())
  //     .div('31557600')
  //     .times('0.02')
  //     .times(fundAmountBefore.toString());
  //   const mgmtFeeUsd = new BigNumber((await fund.aum()).toString())
  //     .times(mgmtFeeFundToken)
  //     .div((await fund.totalSupply()).toString());
  //   // check usd balance of the fund
  //   expect((await usdToken.balanceOf(fund.address)).toString()).to.eq(
  //     mgmtFeeUsd.toFixed(0, BigNumber.ROUND_DOWN),
  //   );
  //   // check fund balance of the investor
  //   expect((await fund.balanceOf(wallets[2].address)).toString()).to.eq(
  //     new BigNumber(fundAmountBefore.toString())
  //       .minus(mgmtFeeFundToken.toFixed(0, BigNumber.ROUND_DOWN))
  //       .toFixed(0, BigNumber.ROUND_DOWN),
  //   );
  // });

  // step('Should update AUM', async () => {
  //   await usdToken
  //     .connect(wallets[3])
  //     .transfer(owner.address, ethers.utils.parseUnits('100', 6));
  //   const newAUM = await usdToken.balanceOf(owner.address);
  //   await fund.updateAum(newAUM, ethers.constants.MaxUint256, '0x00');
  //   expect(await fund.aum()).to.eq(newAUM);
  // });

  // step('Should Process redemption requests', async function () {
  //   const amountToInvest = ethers.utils.parseUnits('10000', 6);

  //   await usdToken
  //     .connect(wallets[4])
  //     .approve(fund.address, ethers.constants.MaxUint256);
  //   await fund
  //     .connect(wallets[4])
  //     .invest(amountToInvest, '1', ethers.constants.MaxUint256);

  //   await debug();
  //   await fund.processRedemptions([1], '1', ethers.constants.MaxUint256);
  //   await debug();
  //   await fund.processRedemptions([2], '1', ethers.constants.MaxUint256);
  //   await debug();
  // });

  // step('Should close fund', async function () {
  //   await debug();
  //   await fund.closeFund();
  //   await debug();
  // });

  const debug = async () => {
    console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6));
    console.log(
      'SUPPLY',
      ethers.utils.formatUnits(await fund.totalSupply(), 6),
    );
    console.log(
      'OWNER',
      ethers.utils.formatUnits(await fund.balanceOf(owner.address), 6),
    );
    console.log(
      'WALLET 1 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[1].address), 6),
    );
    console.log(
      'WALLET 2 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[2].address), 6),
    );
    console.log(
      'WALLET 3 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[3].address), 6),
    );
    console.log(
      'WALLET 4 BALANCE',
      ethers.utils.formatUnits(await fund.balanceOf(wallets[4].address), 6),
    );
  };
});
