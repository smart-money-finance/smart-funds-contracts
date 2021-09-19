import { writeFile } from 'fs/promises';
import { ethers, network } from 'hardhat';
import { BigNumber } from 'bignumber.js';

import { RegistryV0__factory, FundV0__factory } from '../typechain';

enum Action {
  UPDATE_AUM = 'UPDATE_AUM',
  BUY = 'BUY',
}
type Stats = {
  aum: string; // $ no decimals
  supply: string; // 18 decimals
  totalCapitalContributed: string; // 6 decimals?
  capitalContributed?: string; // $ no decimals
  supplyMinted?: string; // 18 decimals
  action: Action;
  // transactionHash?: string;
  // blockNumber?: string;
  user: string; // address
  createdAt: string; // date string with timezone
};
type StatsResp = {
  stats: Stats[];
};

// type RedemptionsResp = {
//   redemptions: { inputAmount: string }[];
// };

async function main() {
  if (network.name !== 'mumbai') {
    throw new Error('Wrong network');
  }
  // const redemptionsResp: RedemptionsResp = await ethers.utils.fetchJson(
  //   'https://api.yff.smartmoney.finance/api/redemptions',
  // );
  // const fundAmountRedeemedByFeeWallet = redemptionsResp.redemptions.reduce(
  //   (acc, cur) => acc.plus(cur.inputAmount),
  //   new BigNumber(0),
  // );
  // console.log(fundAmountRedeemedByFeeWallet.toString());
  // return;
  const statsResp: StatsResp = await ethers.utils.fetchJson(
    'https://api.yff.smartmoney.finance/api/stats',
  );
  const stats = statsResp.stats;
  const buyStats = stats.filter((a) => a.action === Action.BUY);
  buyStats.sort(
    (a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime(),
  );
  // console.log(buyStats);
  const sweepTime = Math.floor(
    new Date('2020-12-22T00:35:03.000Z').getTime() / 1000,
  );
  const sweepPrice = new BigNumber('571365').div('10171362.329841417393167372'); // TODO: check this
  const latestStat = stats.sort(
    (a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime(),
  )[stats.length - 1];
  const nowPrice = new BigNumber(latestStat.aum).div(latestStat.supply);
  // console.log(nowPrice.toString());
  // console.log(
  //   new BigNumber('2821492').div('15994674.94687200340561819').toString(),
  // );
  // console.log(sweepPrice.toString());
  const importedInvestments: {
    investor: string;
    usdAmountRemaining: string;
    lockupTimestamp: string;
    highWaterMark: string;
    originalUsdAmount: string;
    lastFeeSweepTimestamp: string;
  }[] = [];
  let fundAmountSwept = new BigNumber(0);
  buyStats.forEach((buy) => {
    const investedTime = Math.floor(new Date(buy.createdAt).getTime() / 1000);
    const secondsElapsed = sweepTime - investedTime;
    if (secondsElapsed > 0) {
      const capContrib = new BigNumber(buy.capitalContributed || '0');
      const usdMgmtFee = capContrib
        .times(secondsElapsed)
        .times('0.02')
        .div('31557600');
      const fundMgmtFee = usdMgmtFee.div(sweepPrice);
      const fundAmountNetOfMgmtFee = new BigNumber(
        buy.supplyMinted || '0',
      ).minus(fundMgmtFee);
      const usdAmountNetOfMgmtFee = fundAmountNetOfMgmtFee.times(sweepPrice);
      let highWaterMark = capContrib;
      let usdPerfFee = new BigNumber('0');
      let fundPerfFee = new BigNumber('0');
      if (usdAmountNetOfMgmtFee.gt(highWaterMark)) {
        highWaterMark = usdAmountNetOfMgmtFee;
        const usdGainAboveHighWaterMark =
          usdAmountNetOfMgmtFee.minus(capContrib);
        usdPerfFee = usdGainAboveHighWaterMark.times('0.2');
        fundPerfFee = usdPerfFee.div(sweepPrice);
      }
      const swept = fundMgmtFee.plus(fundPerfFee);
      fundAmountSwept = fundAmountSwept.plus(swept);
      const fundAmountRemaining = new BigNumber(buy.supplyMinted || '0').minus(
        swept,
      );
      const usdAmountRemaining = ethers.utils
        .parseUnits(nowPrice.times(fundAmountRemaining).dp(6).toString(), 6)
        .toString();
      const originalUsdAmount = ethers.utils
        .parseUnits(
          new BigNumber(buy.capitalContributed || '0').dp(6).toString(),
          6,
        )
        .toString();
      importedInvestments.push({
        investor: buy.user,
        usdAmountRemaining,
        lockupTimestamp: investedTime.toString(),
        highWaterMark: ethers.utils
          .parseUnits(highWaterMark.dp(6).toString(), 6)
          .toString(),
        originalUsdAmount,
        lastFeeSweepTimestamp: sweepTime.toString(),
      });
    } else {
      const usdAmountRemaining = ethers.utils
        .parseUnits(
          nowPrice
            .times(buy.supplyMinted || '0')
            .dp(6)
            .toString(),
          6,
        )
        .toString();
      const originalUsdAmount = ethers.utils
        .parseUnits(
          new BigNumber(buy.capitalContributed || '0').dp(6).toString(),
          6,
        )
        .toString();
      importedInvestments.push({
        investor: buy.user,
        usdAmountRemaining,
        lockupTimestamp: investedTime.toString(),
        highWaterMark: originalUsdAmount,
        originalUsdAmount,
        lastFeeSweepTimestamp: '0',
      });
    }
  });
  // await writeFile('do.json', JSON.stringify(importedInvestments));
  const fundTokensRedeemedByFeeWallet = '345875';
  const fundAmountRemainingInFeeWallet = fundAmountSwept.minus(
    fundTokensRedeemedByFeeWallet,
  );
  const dollarValueRemainingInFeeWallet = nowPrice.times(
    fundAmountRemainingInFeeWallet,
  );
  // 2020-12-22T00:35:03.000Z
  // 2020-12-22T00:35:03.000Z
  const signers = await ethers.getSigners();
  const registry = RegistryV0__factory.connect(
    '0xC494674A966B136F24a6EDDF396F992a0BfF4409',
    signers[2],
  );
  const tx = await registry.newFund(
    [signers[2].address, ethers.constants.AddressZero],
    [
      '31536000',
      '2592000',
      '200',
      '2000',
      '100',
      '20',
      '10000000000',
      ethers.utils.parseUnits(nowPrice.dp(18).toString(), 18),
      '0',
    ],
    'Yield Farming Fund 2',
    'YFF2',
    'https://yff.smartmoney.finance/static/media/Logo-white.b53e46a0.svg',
    '',
    'Hedge fund',
    true,
  );
  const receipt = await tx.wait();
  const fundAddress = receipt.events?.find(
    (event) => event.event === 'FundCreated',
  )?.args?.fund;
  const fund = FundV0__factory.connect(fundAddress, signers[2]);
  for (const investment of importedInvestments) {
    console.log(investment.lockupTimestamp);
    const tx = await fund.importInvestment(
      investment.investor,
      investment.usdAmountRemaining,
      investment.lockupTimestamp,
      investment.highWaterMark,
      investment.originalUsdAmount,
      investment.lastFeeSweepTimestamp,
    );
    await tx.wait();
    await new Promise((res) => setTimeout(res, 3000));
  }
  const usdRemainingInFeeWallet = ethers.utils.parseUnits(
    dollarValueRemainingInFeeWallet.dp(6).toString(),
    6,
  );
  const tx2 = await fund.addManualInvestment(
    signers[5].address,
    usdRemainingInFeeWallet,
  );
  await tx2.wait();
  console.log('done');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
