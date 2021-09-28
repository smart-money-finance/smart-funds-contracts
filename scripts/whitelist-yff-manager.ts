import { ethers, network } from 'hardhat';

import { RegistryV0__factory } from '../typechain';

async function main() {
  if (network.name !== 'polygon') {
    throw new Error('Wrong network');
  }
  const signers = await ethers.getSigners();
  const managerSigner = signers[0];
  const registry = RegistryV0__factory.connect(
    '0x9190c668DAAfEf6336E00E7EbdAd565e2Df257Fd',
    managerSigner,
  );
  const tx = await registry.whitelistMulti([
    '0xfc117cb4c186586f415cEbaaa0644aA0aD530B8A',
  ]);
  await tx.wait();
  console.log('done');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
