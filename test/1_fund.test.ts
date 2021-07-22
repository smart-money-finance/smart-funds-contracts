import { describe, before } from 'mocha';
import { expect, use } from 'chai';
import { ethers, network } from 'hardhat';
import { BigNumberish, Event, Signature } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { step } from 'mocha-steps';
import { solidity } from 'ethereum-waffle';
import { TestUSDCoin, SmartFundFactory, SmartFund } from '../typechain';

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
describe('Fund', () => {
  let usdToken: TestUSDCoin;
  let factory: SmartFundFactory;
  let fund: SmartFund;
  let owner: SignerWithAddress;
  let wallets: SignerWithAddress[];

  before(async () => {
    const UsdToken = await ethers.getContractFactory('TestUSDCoin');
    const usdTokenContract = await UsdToken.deploy();
    usdToken = (await usdTokenContract.deployed()) as TestUSDCoin;

    const SmartFund = await ethers.getContractFactory('SmartFund');
    const masterFundLibrary = await SmartFund.deploy();

    const Factory = await ethers.getContractFactory('SmartFundFactory');
    const factoryContract = await Factory.deploy(
      masterFundLibrary.address,
      usdToken.address,
      true,
    );
    factory = (await factoryContract.deployed()) as SmartFundFactory;

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
    await factory.whitelistMulti([owner.address]);
  });

  step('Should create fund', async () => {
    const tx = await factory.newFund(
      [owner.address, wallets[5].address],
      [1, 200, 2000, 20, 5, 1, 1],
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
    fund = (await ethers.getContractAt('SmartFund', fundAddress)) as SmartFund;
    const initialPrice = ethers.BigNumber.from('10000000000000000'); // $0.01 * 1e18
    expect(await fund.aum()).to.eq(0);
    expect(await fund.highWaterPrice()).to.eq(initialPrice);
    expect(await fund.activeInvestmentCount()).to.eq(0);
    expect(
      await fund.activeInvestmentCountPerInvestor(wallets[1].address),
    ).to.eq(0);
    expect(await fund.investorCount()).to.eq(0);
    await debug();
  });

  step('Should whitelist clients', async () => {
    expect(await fund.whitelist(wallets[1].address)).to.eq(false);
    expect(await fund.whitelist(wallets[2].address)).to.eq(false);
    expect(await fund.whitelist(wallets[3].address)).to.eq(false);
    expect(await fund.whitelist(wallets[4].address)).to.eq(false);

    await fund.whitelistMulti([
      wallets[1].address,
      wallets[2].address,
      wallets[3].address,
      wallets[4].address,
    ]);

    expect(await fund.investorCount()).to.eq(4);
    expect(await fund.whitelist(wallets[1].address)).to.eq(true);
    expect(await fund.whitelist(wallets[2].address)).to.eq(true);
    expect(await fund.whitelist(wallets[3].address)).to.eq(true);
    expect(await fund.whitelist(wallets[4].address)).to.eq(true);
    expect(await fund.whitelist(wallets[0].address)).to.eq(false);
    expect(await fund.whitelist(wallets[5].address)).to.eq(false);
  });

  step('Should request to invest client funds', async () => {
    const amountToInvest = ethers.utils.parseUnits('10000', 6);
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
      .updateInvestmentRequest(
        amountToInvest,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        0,
        signature.v,
        signature.r,
        signature.s,
      );
    const request = await fund.investmentRequests(wallets[2].address);
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
    const amountToInvest = ethers.utils.parseUnits('10000', 6);
    const aumBefore = await fund.aum();
    const supplyBefore = await fund.totalSupply();
    expect(await fund.aum()).to.eq(aumBefore);
    expect(await fund.totalSupply()).to.eq(supplyBefore);
    await fund.processInvestmentRequest(wallets[2].address, 1);
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const aumAfter = await fund.aum();
    const supplyAfter = await fund.totalSupply();
    const price = aumAfter
      .mul(ethers.utils.parseUnits('1', 18))
      .div(supplyAfter);
    const investment = await fund.investments(0);
    const request = investment.investmentRequest;
    const fundMinted = request.usdAmount.mul(supplyAfter).div(aumAfter);
    expect(await fund.aum()).to.eq(amountToInvest);
    const blankRequest = await fund.investmentRequests(wallets[2].address);
    expect({ ...blankRequest }).to.deep.include({
      usdAmount: ethers.BigNumber.from(0),
      minFundAmount: ethers.BigNumber.from(0),
      maxFundAmount: ethers.BigNumber.from(0),
      deadline: ethers.BigNumber.from(0),
      timestamp: ethers.BigNumber.from(timestamp),
    });
    expect(await fund.highWaterPrice()).to.eq(price);
    const priceAfter = aumAfter
      .mul(ethers.utils.parseUnits('1', 18))
      .div(supplyAfter);
    expect({ ...investment }).to.deep.include({
      investor: wallets[2].address,
      initialUsdAmount: request.usdAmount,
      initialFundAmount: fundMinted,
      initialHighWaterPrice: priceAfter,
      usdTransferred: true,
      timestamp: ethers.BigNumber.from(timestamp),
      redeemedTimestamp: ethers.BigNumber.from(0),
      redemptionUsdTransferred: false,
    });
    expect(await usdToken.balanceOf(fund.address)).to.eq(0);
    expect(await fund.balanceOf(investment.investor)).to.eq(fundMinted);
    expect(await fund.activeInvestmentCount()).to.eq(1);
    expect(
      await fund.activeInvestmentCountPerInvestor(wallets[2].address),
    ).to.eq(1);
    await debug();
  });

  step('Should update AUM', async () => {
    const newAum = await usdToken.balanceOf(owner.address);
    const supply = await fund.totalSupply();
    await fund.updateAum(newAum, '');
    const timestamp = (await ethers.provider.getBlock('latest')).timestamp;
    const aumAfter = await fund.aum();
    const supplyAfter = await fund.totalSupply();
    expect(supplyAfter).to.eq(supply);
    expect(aumAfter).to.eq(newAum);
    expect(await fund.aumTimestamp()).to.eq(timestamp);
    await debug();
  });

  step('Should withdraw accrued fees', async () => {
    const feesFundAmount = await fund.balanceOf(fund.address);
    const usdAmount = feesFundAmount
      .mul(await fund.aum())
      .div(await fund.totalSupply());
    expect(await usdToken.balanceOf(wallets[5].address)).to.eq(0);
    const signature = await signPermit(
      owner,
      usdToken,
      network.config.chainId || 1,
      fund.address,
      usdAmount,
      ethers.constants.MaxUint256,
    );
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
    const request = await fund.investmentRequests(wallets[3].address);
    expect({ ...request }).to.deep.include({
      usdAmount: ethers.BigNumber.from(0),
      minFundAmount: ethers.BigNumber.from(0),
      maxFundAmount: ethers.BigNumber.from(0),
      deadline: ethers.BigNumber.from(0),
      timestamp: ethers.BigNumber.from(0),
      nonce: ethers.BigNumber.from(0),
    });
    const signature = await signPermit(
      wallets[3],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      100,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[3])
      .updateInvestmentRequest(
        100,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        0,
        signature.v,
        signature.r,
        signature.s,
      );
    const request1 = await fund.investmentRequests(wallets[3].address);
    const timestamp1 = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request1 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(100),
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp1),
      nonce: ethers.BigNumber.from(1),
    });
    const signature2 = await signPermit(
      wallets[3],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      210,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[3])
      .updateInvestmentRequest(
        210,
        1,
        ethers.constants.MaxUint256,
        ethers.constants.MaxUint256,
        1,
        signature2.v,
        signature2.r,
        signature2.s,
      );
    const request2 = await fund.investmentRequests(wallets[3].address);
    const timestamp2 = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request2 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(210),
      minFundAmount: ethers.BigNumber.from(1),
      maxFundAmount: ethers.constants.MaxUint256,
      deadline: ethers.constants.MaxUint256,
      timestamp: ethers.BigNumber.from(timestamp2),
      nonce: ethers.BigNumber.from(2),
    });
    const signature3 = await signPermit(
      wallets[3],
      usdToken,
      network.config.chainId || 1,
      fund.address,
      0,
      ethers.constants.MaxUint256,
    );
    await fund
      .connect(wallets[3])
      .cancelInvestmentRequest(
        ethers.constants.MaxUint256,
        signature3.v,
        signature3.r,
        signature3.s,
      );
    const request3 = await fund.investmentRequests(wallets[3].address);
    const timestamp3 = (await ethers.provider.getBlock('latest')).timestamp;
    expect({ ...request3 }).to.deep.include({
      usdAmount: ethers.BigNumber.from(0),
      minFundAmount: ethers.BigNumber.from(0),
      maxFundAmount: ethers.BigNumber.from(0),
      deadline: ethers.BigNumber.from(0),
      timestamp: ethers.BigNumber.from(timestamp3),
      nonce: ethers.BigNumber.from(3),
    });
  });

  step('Should manually redeem', async () => {
    expect(await fund.activeInvestmentCount()).to.eq(1);
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
    expect(await fund.activeInvestmentCount()).to.eq(0);
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
          .updateInvestmentRequest(
            100,
            1,
            ethers.constants.MaxUint256,
            ethers.constants.MaxUint256,
            0,
            signature.v,
            signature.r,
            signature.s,
          ),
      ).to.be.revertedWith('FundClosed');
    },
  );

  // step('Should manual redeem and fail', async () => {
  //   await expect(fund.addManualRedemption(1, true)).to.be.revertedWith(
  //     'OpenRequestsPreventClosing',
  //   );
  // });
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
