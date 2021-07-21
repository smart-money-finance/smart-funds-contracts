import { run, ethers, network } from 'hardhat';

async function main() {
  await run('compile');
  const SmartFund = await ethers.getContractFactory('SmartFund');
  const masterFundLibrary = await SmartFund.deploy();
  const SmartFundFactory = await ethers.getContractFactory('SmartFundFactory');
  const factory = await SmartFundFactory.deploy(
    masterFundLibrary.address,
    {
      rinkeby: '0x2A20b20689f856478D864241Df8Ae9063c34e701',
      goerli: '0xde637d4c445ca2aae8f782ffac8d2971b93a4998',
      mainnet: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      polygon: '0x2791bca1f2de4661ed88a30c99a7a9449aa84174',
    }[network.name], // USDC address
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
