import { ethers, network } from 'hardhat';

import { RegistryV0__factory, FundV0__factory } from '../typechain';

async function main() {
  if (network.name !== 'mumbai') {
    throw new Error('Wrong network');
  }
  const signers = await ethers.getSigners();
  const registry = RegistryV0__factory.connect(
    '0xc1088D454EfF781881f45ca1a6078Ae8Ca5f283a',
    signers[5],
  );
  const tx = await registry.newFund(
    [signers[5].address, signers[6].address],
    [
      '31536000',
      '2592000',
      '200',
      '2000',
      '100',
      '20',
      '10000000000',
      '178300',
      '0',
    ],
    'Yield Farming Fund',
    'YFF',
    'https://yff.smartmoney.finance/static/media/Logo-white.b53e46a0.svg',
    '',
    'Hedge fund',
    true,
  );
  const receipt = await tx.wait();
  const fundAddress = receipt.events?.find(
    (event) => event.event === 'FundCreated',
  )?.args?.fund;
  const fund = FundV0__factory.connect(fundAddress, signers[5]);
  // TODO: fill this in
  const investments = [
    {
      investor: '',
      usdAmount: '',
      timestamp: '',
      highWaterMark: '',
      costBasis: '',
      lastFeeTimestamp: '',
    },
  ];
  for (const investment of investments) {
    await fund.importInvestment(
      investment.investor,
      investment.usdAmount,
      investment.timestamp,
      investment.highWaterMark,
      investment.costBasis,
      investment.lastFeeTimestamp,
    );
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
