import { run, ethers, network } from 'hardhat';

async function main() {
  await run('compile');
  const SmartFund = await ethers.getContractFactory('SmartFund');
  const masterFundLibrary = await SmartFund.deploy();
  const TestUSDCoin = await ethers.getContractFactory('TestUSDCoin');
  const usdToken = await TestUSDCoin.deploy();
  const SmartFundFactory = await ethers.getContractFactory('SmartFundFactory');
  const factory = await SmartFundFactory.deploy(
    masterFundLibrary.address,
    usdToken.address,
    network.name !== 'mainnet', // whether to bypass global manager whitelist
  );
  console.log(factory.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
