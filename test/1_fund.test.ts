import { describe, before } from 'mocha';
import { expect, use } from 'chai';
import { ethers, network, upgrades } from 'hardhat';
import { BigNumberish, Event, Signature } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { step } from 'mocha-steps';
import { solidity } from 'ethereum-waffle';
import {
  TestUSDCoin__factory,
  TestUSDCoin,
  RegistryV0__factory,
  RegistryV0,
  FundV0__factory,
  FundV0,
} from '../typechain';

async function signPermit(
  wallet: SignerWithAddress,
  token: TestUSDCoin,
  chainId: BigNumberish,
  spender: string,
  value: BigNumberish,
  deadline: BigNumberish,
): Promise<Signature> {
  const rawSignature = await wallet._signTypedData(
    {
      name: await token.name(),
      version: await token.version(),
      chainId,
      verifyingContract: token.address,
    },
    {
      Permit: [
        {
          name: 'owner',
          type: 'address',
        },
        {
          name: 'spender',
          type: 'address',
        },
        {
          name: 'value',
          type: 'uint256',
        },
        {
          name: 'nonce',
          type: 'uint256',
        },
        {
          name: 'deadline',
          type: 'uint256',
        },
      ],
    },
    {
      owner: wallet.address,
      spender,
      value,
      nonce: await token.nonces(wallet.address),
      deadline,
    },
  );
  return ethers.utils.splitSignature(rawSignature);
}

use(solidity);

describe('Fund upgradeability', () => {
  let usdToken: TestUSDCoin;
  let registry: RegistryV0;
  let fund: FundV0;
  let owner: SignerWithAddress;
  let wallets: SignerWithAddress[];

  before(async () => {
    wallets = await ethers.getSigners();
    owner = wallets[0];

    const UsdToken = await ethers.getContractFactory('TestUSDCoin');
    const usdTokenContract = await UsdToken.deploy();
    await usdTokenContract.deployed();
    // usdToken = usdTokenContract as TestUSDCoin;
    usdToken = TestUSDCoin__factory.connect(usdTokenContract.address, owner);

    const FundFactory = await ethers.getContractFactory('FundV0');
    const fundProxy = await upgrades.deployProxy(FundFactory, {
      kind: 'uups',
      initializer: false,
    });
    await fundProxy.deployed();
    // storage slot of implementation is
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))
    // see EIP-1967
    const fundImplementationHex = await ethers.provider.getStorageAt(
      fundProxy.address,
      ethers.utils.hexValue(
        ethers.BigNumber.from(
          ethers.utils.keccak256(
            ethers.utils.toUtf8Bytes('eip1967.proxy.implementation'),
          ),
        ).sub(1),
      ),
    );
    const fundImplementationAddress = ethers.utils.hexStripZeros(
      fundImplementationHex,
    );

    const RegistryFactory = await ethers.getContractFactory('RegistryV0');
    const Registry = await upgrades.deployProxy(
      RegistryFactory,
      [fundImplementationAddress, usdToken.address, false],
      {
        kind: 'uups',
      },
    );
    await Registry.deployed();
    // registry = Registry as RegistryV0;
    registry = RegistryV0__factory.connect(Registry.address, owner);

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
    await registry.whitelistMulti([owner.address]);
  });

  step('Should create new fund', async () => {
    const FundFactory = await ethers.getContractFactory('FundV0');
    const fundInstance = await FundFactory.deploy();
    await fundInstance.deployed();
    fund = FundV0__factory.connect(fundInstance.address, owner);
    const tx = await registry.newFund(
      [owner.address, wallets[5].address],
      [1, 200, 2000, 20, 5, 1, 1e6, 1e5, 0],
      'Bobs cool fund',
      'BCF',
      'https://google.com/favicon.ico',
      'bob@bob.com',
      'Hedge Fund,Test Fund,Other tag',
      true,
    );

    const txResp = await tx.wait();
    const fundAddress = txResp.events?.find(
      (event: Event) => event.event === 'FundCreated',
    )?.args?.fund;
    fund = (await ethers.getContractAt('FundV0', fundAddress)) as FundV0;
    fund = FundV0__factory.connect(fundAddress, owner);
    const initialPrice = ethers.BigNumber.from('10000000000000000'); // $0.01 * 1e18
    expect(await fund.initialPrice()).to.eq(1e5);
    await expect(fund.navs(0)).to.be.reverted; // no nav set yet
    expect(await fund.investorCount()).to.eq(0);
    expect(await fund.activeInvestmentCount()).to.eq(0);

    expect(await fund.investorCount()).to.eq(0);
    // // await debug();
  });
});

describe('Fund', () => {
  let usdToken: TestUSDCoin;
  let fund: FundV0;
  let owner: SignerWithAddress;
  let wallets: SignerWithAddress[];

  before(async () => {
    wallets = await ethers.getSigners();
    owner = wallets[0];

    const UsdToken = await ethers.getContractFactory('TestUSDCoin');
    const usdTokenContract = await UsdToken.deploy();
    await usdTokenContract.deployed();
    // usdToken = usdTokenContract as TestUSDCoin;
    usdToken = TestUSDCoin__factory.connect(usdTokenContract.address, owner);

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

  // step('Should whitelist fund manager', async () => {
  //   await registry.whitelistMulti([owner.address]);
  // });

  step('Should create new fund', async () => {
    const FundFactory = await ethers.getContractFactory('FundV0');
    const fundInstance = await FundFactory.deploy();
    await fundInstance.deployed();
    fund = FundV0__factory.connect(fundInstance.address, owner);

    await fund.initialize(
      [owner.address, wallets[5].address],
      [1, 200, 2000, 20, 5, 1, 1e6, 1e5, 0],
      'Bobs cool fund',
      'BCF',
      'https://google.com/favicon.ico',
      'bob@bob.com',
      'Hedge Fund,Test Fund,Other tag',
      true,
      owner.address,
      ethers.constants.AddressZero,
      usdToken.address,
    );

    expect(await fund.initialPrice()).to.eq(1e5);
    await expect(fund.navs(0)).to.be.reverted; // no nav set yet
    expect(await fund.investorCount()).to.eq(0);
    expect(await fund.activeInvestmentCount()).to.eq(0);

    expect(await fund.investorCount()).to.eq(0);
    // // await debug();
  });

  step('Should whitelist clients', async () => {
    expect((await fund.investorInfo(wallets[1].address)).whitelisted).to.eq(
      false,
    );
    expect((await fund.investorInfo(wallets[2].address)).whitelisted).to.eq(
      false,
    );
    expect((await fund.investorInfo(wallets[3].address)).whitelisted).to.eq(
      false,
    );
    expect((await fund.investorInfo(wallets[4].address)).whitelisted).to.eq(
      false,
    );
    await fund.whitelistMulti([
      wallets[1].address,
      wallets[2].address,
      wallets[3].address,
      wallets[4].address,
    ]);
    expect(await fund.investorCount()).to.eq(4);
    expect((await fund.investorInfo(wallets[1].address)).whitelisted).to.eq(
      true,
    );
    expect((await fund.investorInfo(wallets[2].address)).whitelisted).to.eq(
      true,
    );
    expect((await fund.investorInfo(wallets[3].address)).whitelisted).to.eq(
      true,
    );
    expect((await fund.investorInfo(wallets[4].address)).whitelisted).to.eq(
      true,
    );
    expect((await fund.investorInfo(wallets[0].address)).whitelisted).to.eq(
      false,
    );
    expect((await fund.investorInfo(wallets[5].address)).whitelisted).to.eq(
      false,
    );
  });

  step('Should request to invest client funds', async () => {
    const amountToInvest = ethers.utils.parseUnits('5000', 6);
    const signature = await signPermit(
      wallets[2],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      amountToInvest,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[2])
      .createOrUpdateInvestmentRequest(
        amountToInvest,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        false,
        signature.v,
        signature.r,
        signature.s,
      );
    const request = await fund.investmentRequests(0);
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request }).to.deep.include({
      usdAmount: amountToInvest,
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp),
    });
    expect(await usdToken.balanceOf(fund.address)).to.eq(0);
    expect(await fund.balanceOf(wallets[2].address)).to.eq(0);
  });

  step('Should process investment request', async () => {
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const amountToInvest = ethers.utils.parseUnits('5000', 6);
    const navLength = await fund.navsLength();
    expect(navLength).to.eq(0);
    const aumBefore = ethers.BigNumber.from(0);
    const supplyBefore = await fund.totalSupply();
    expect(supplyBefore).to.eq(0);
    const investmentRequest = await fund.investmentRequests(0);
    console.log(investmentRequest);
    console.log(await fund.investorInfo(wallets[2].address));

    await fund.processInvestmentRequest(0);
    const navLengthAfter = await fund.navsLength();
    const aumAfter = (await fund.navs(navLengthAfter.sub(1))).aum;
    const supplyAfter = await fund.totalSupply();

    expect(aumAfter).to.eq(investmentRequest.usdAmount.add(aumBefore));
    const investment = await fund.investments(0);
    const fundMinted = investment.constants.initialUsdAmount
      .mul(supplyAfter)
      .div(aumAfter);
    expect(aumAfter).to.eq(amountToInvest);
    const request = await fund.investmentRequests(0);
    expect({ ...request }).to.deep.include({
      usdAmount: amountToInvest,
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      investmentId: ethers.BigNumber.from(0),
    });
    expect(investment.highWaterMark).to.eq(aumAfter);
    // const priceAfter = aumAfter
    //   .mul(ethers.utils.parseUnits('1', 18))
    //   .div(supplyAfter);
    // expect({ ...investment }).to.deep.include({
    //   investor: wallets[2].address,
    //   initialUsdAmount: request.usdAmount,
    //   initialFundAmount: fundMinted,
    //   initialHighWaterPrice: aumAfter,
    // });
    expect(await usdToken.balanceOf(fund.address)).to.eq(0);
    expect(await fund.balanceOf(investment.constants.investor)).to.eq(
      fundMinted,
    );
    expect(await fund.activeInvestmentCount()).to.eq(1);

    // await debug();
  });

  step('Should add manual investment and not change price', async () => {
    const navLength = await fund.navsLength();
    const navBefore = await fund.navs(navLength.sub(1));
    const aumBefore = navBefore.aum;
    const supplyBefore = await fund.totalSupply();
    const priceBefore = aumBefore.div(supplyBefore);
    const amountToInvest = ethers.utils.parseUnits('5000', 6);
    await fund.addManualInvestment(wallets[4].address, amountToInvest, '');
    const investmentsLength = await fund.investmentsLength();
    expect(investmentsLength).to.eq(2);
    const navLength1 = await fund.navsLength();
    const navAfter = await fund.navs(navLength1.sub(1));
    const aumAfter = navAfter.aum;
    const supplyAfter = await fund.totalSupply();
    const priceAfter = aumAfter.div(supplyAfter);
    expect(priceAfter).to.eq(priceBefore);
    expect(await fund.balanceOf(wallets[4].address)).to.eq(
      supplyAfter.sub(supplyBefore),
    );
  });

  step('Should update AUM', async () => {
    const newAum = await usdToken.balanceOf(owner.address);
    const supply = await fund.totalSupply();
    await fund.updateAum(newAum, '');
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const navLength = await fund.navsLength();
    const nav = await fund.navs(navLength.sub(1));
    const aumAfter = nav.aum;
    const supplyAfter = await fund.totalSupply();
    expect(supplyAfter).to.eq(supply);
    expect(aumAfter).to.eq(newAum);
    expect(nav.timestamp).to.eq(timestamp);
    // await debug();
  });

  step('Should withdraw accrued fees', async () => {
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    console.log(timestamp);
    const timeSkip = 2592000; // 60 * 60 * 24 * 30 = 30 days in seconds
    await network.provider.send('evm_increaseTime', [timeSkip]);
    await network.provider.send('evm_mine');

    // const timestamp2 = (await ethers.provider.getBlock('latest')).timestamp;
    // const lastFeeSweepEndedTimestamp = await fund.lastFeeSweepEndedTimestamp();
    // const feeTimelock = await fund.feeTimelock();
    // const investment = await fund.investments(0);
    // const lastSweepTimestamp = investment.constants.timestamp;
    // console.log(timestamp2);
    // console.log(feeTimelock.toString());
    // console.log(lastSweepTimestamp.add(feeTimelock).toString());
    // console.log(lastSweepTimestamp.add(feeTimelock).gte(timestamp2));
    // console.log(
    //   'lastFeeSweepEndedTimestamp',
    //   lastFeeSweepEndedTimestamp.toString(),
    // );
    // console.log('lastSweepTimestamp', lastSweepTimestamp.toString());
    // console.log('feeTimelock', feeTimelock.toString());
    // console.log('add them', feeTimelock.add(lastSweepTimestamp).toString());
    // console.log('timestamp', timestamp2);
    // console.log(lastSweepTimestamp.gte(lastFeeSweepEndedTimestamp));
    const investment = await fund.investments(1);
    console.log(investment);
    await fund.processFees([0, 1]);
    const feesFundAmount = await fund.balanceOf(fund.address);
    const navLength = await fund.navsLength();
    const nav = await fund.navs(navLength.sub(1));
    const usdAmount = feesFundAmount.mul(nav.aum).div(await fund.totalSupply());
    expect(await usdToken.balanceOf(wallets[5].address)).to.eq(0);
    const signature = await signPermit(
      owner,
      usdToken,
      network.config.chainId || 1,
      fund.address,
      usdAmount,
      ethers.constants.MaxUint256,
    );
    // console.log(usdAmount.toString());
    // console.log(feesFundAmount.toString());
    // console.log(await fund.feesSweptNotWithdrawn());
    // console.log(await usdToken.balanceOf(fund.address));
    // console.log((await fund.balanceOf(fund.address)).toString());
    await fund.withdrawFees(
      feesFundAmount,
      true,
      usdAmount,
      ethers.constants.MaxUint256,
      signature.v,
      signature.r,
      signature.s,
    );
    expect(await fund.balanceOf(fund.address)).to.eq(0);
    expect(await usdToken.balanceOf(wallets[5].address)).to.eq(usdAmount);
  });

  step('Should create, update, and cancel investment request', async () => {
    const signature = await signPermit(
      wallets[3],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      1e6,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[3])
      .createOrUpdateInvestmentRequest(
        1e6,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        false,
        signature.v,
        signature.r,
        signature.s,
      );
    const request1 = await fund.investmentRequests(1);
    const timestamp1 = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request1 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(1e6),
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp1),
    });
    const signature2 = await signPermit(
      wallets[3],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      2e6,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[3])
      .createOrUpdateInvestmentRequest(
        2e6,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        true,
        signature2.v,
        signature2.r,
        signature2.s,
      );
    const request2 = await fund.investmentRequests(2);
    const timestamp2 = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request2 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(2e6),
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp2),
    });

    await fund.connect(wallets[3]).cancelInvestmentRequest();
    const investor = await fund.investorInfo(wallets[3].address);
    expect(investor.investmentRequestId).to.eq(ethers.constants.MaxUint256);
    const request3 = await fund.investmentRequests(2);
    expect({ ...request3 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(2e6),
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp2),
    });
  });

  step('Should manually redeem', async () => {
    //TODO: Fix so redemptions can happen without time elapsing
    expect(await fund.activeInvestmentCount()).to.eq(2);
    const timeSkip = 86400; // 60 * 60 * 24 = 1 day in seconds
    await network.provider.send('evm_increaseTime', [timeSkip]);
    await network.provider.send('evm_mine');
    const permitAmount = await fund.redemptionUsdAmount(0);
    const signature = await signPermit(
      owner,
      usdToken,
      network.config.chainId || 1,
      fund.address,
      permitAmount,
      ethers.constants.MaxUint256,
    );
    await fund.addManualRedemption(
      0,
      true,
      permitAmount,
      ethers.constants.MaxUint256,
      signature.v,
      signature.r,
      signature.s,
    );
    // expect(await fund.activeInvestmentCount()).to.eq(1);
  });

  step(
    'Should add investment request and fail due to closed fund',
    async () => {
      const signature = await signPermit(
        wallets[3],
        usdToken,
        network.config.chainId || 1,
        fund.address,
        100,
        ethers.constants.MaxUint256,
      );
      await expect(
        fund
          .connect(wallets[3])
          .createOrUpdateInvestmentRequest(
            100,
            1,
            ethers.constants.MaxUint256,
            ethers.constants.MaxUint256,
            false,
            signature.v,
            signature.r,
            signature.s,
          ),
      ).to.be.reverted;
    },
  );

  step('Should manual redeem and fail', async () => {
    const signature = await signPermit(
      owner,
      usdToken,
      network.config.chainId || 1,
      fund.address,
      100,
      ethers.constants.MaxUint256,
    );
    await expect(
      fund.addManualRedemption(
        0,
        true,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        signature.v,
        signature.r,
        signature.s,
      ),
    ).to.be.revertedWith('InvestmentRedeemed');
  });

  step('Should increase time and process fees', async () => {
    expect(await usdToken.balanceOf(fund.address)).to.eq(0);
    console.log((await usdToken.balanceOf(owner.address)).toString());
    await usdToken.approve(fund.address, ethers.constants.MaxUint256);
    const navLength = await fund.navsLength();
    const investmentLength = await fund.investmentsLength();
    console.log(navLength);
    console.log(investmentLength);
    const investment = await fund.investments(0);
    // console.log(investment);

    const investmentTimestamp = investment.constants.timestamp;
    const timeSkip = 2592000; // 60 * 60 * 24 * 30 = 30 days in seconds
    const fundAmountBefore = await fund.balanceOf(wallets[2].address);
    await network.provider.request({
      method: 'evm_increaseTime',
      params: [timeSkip],
    });
    await fund.processFees([0]);
    // const feeTimestamp = (await ethers.provider.getBlock('latest')).timestamp;
    // const mgmtFeeFundToken = ethers.BigNumber.from(feeTimestamp)
    //   .sub(investmentTimestamp.toString())
    //   .div('31557600')
    //   .mul('0.02')
    //   .mul(fundAmountBefore.toString());
    // const navLength = await fund.navsLength();
    // const mgmtFeeUsd = ethers.BigNumber.from(
    //   (await fund.navs(navLength.sub(1))).toString(),
    // )
    //   .mul(mgmtFeeFundToken)
    //   .div((await fund.totalSupply()).toString());
    // // check usd balance of the fund
    // expect((await usdToken.balanceOf(fund.address)).toString()).to.eq(
    //   mgmtFeeUsd,
    //   // .toFixed(0, ethers.BigNumber.ROUND_DOWN),
    // );
    // // check fund balance of the investor
    // expect((await fund.balanceOf(wallets[2].address)).toString()).to.eq(
    //   ethers.BigNumber.from(fundAmountBefore.toString()).sub(
    //     mgmtFeeFundToken,
    //     // .toFixed(0, BigNumber.ROUND_DOWN)
    //   ),
    //   // .toFixed(0, BigNumber.ROUND_DOWN)
    // );
  });

  // step('Should update AUM', async () => {
  //   await usdToken
  //     .connect(wallets[3])
  //     .transfer(owner.address, ethers.utils.parseUnits('100', 6));
  //   const newAUM = await usdToken.balanceOf(owner.address);
  //   await fund.updateAum(newAUM, '0x00');
  //   const navLength = await fund.navsLength();
  //   expect(await fund.navs(navLength.sub(1))).to.eq(newAUM);
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

  // const debug = async () => {
  //   console.log('AUM', ethers.utils.formatUnits(await fund.aum(), 6));
  //   console.log(
  //     'SUPPLY',
  //     ethers.utils.formatUnits(await fund.totalSupply(), 6),
  //   );
  //   console.log(
  //     'OWNER',
  //     ethers.utils.formatUnits(await fund.balanceOf(owner.address), 6),
  //   );
  //   console.log(
  //     'WALLET 1 BALANCE',
  //     ethers.utils.formatUnits(await fund.balanceOf(wallets[1].address), 6),
  //   );
  //   console.log(
  //     'WALLET 2 BALANCE',
  //     ethers.utils.formatUnits(await fund.balanceOf(wallets[2].address), 6),
  //   );
  //   console.log(
  //     'WALLET 3 BALANCE',
  //     ethers.utils.formatUnits(await fund.balanceOf(wallets[3].address), 6),
  //   );
  //   console.log(
  //     'WALLET 4 BALANCE',
  //     ethers.utils.formatUnits(await fund.balanceOf(wallets[4].address), 6),
  //   );
  // };
});
