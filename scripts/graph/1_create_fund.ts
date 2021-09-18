import { run, network, ethers } from 'hardhat';
import { Event } from 'ethers';

import { RegistryV0__factory, FundV0__factory } from '../../typechain';

async function main() {
  await run('compile');
  const wallets = await ethers.getSigners();
  const registryAddress = {
    mumbai: '0x4469429a66F469de7D035C22f302d67ed92aC4aa',
  }[network.name];

  if (!registryAddress) {
    console.log('invalid network');
    return;
  }

  // Create a fund
  const registry = RegistryV0__factory.connect(registryAddress, wallets[0]);
  const tx = await registry.newFund(
    [wallets[0].address, wallets[5].address],
    [1, 200, 2000, 20, 5, 10, 1e6, 1e5, 0],
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
  const fund = FundV0__factory.connect(fundAddress, wallets[0]);

  // whitelist members
  await fund.whitelistMulti([
    wallets[1].address,
    wallets[2].address,
    wallets[3].address,
    wallets[4].address,
  ]);

  console.log(fundAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
