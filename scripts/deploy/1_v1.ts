import { run, ethers, network } from 'hardhat';

async function main() {
  await run('compile');
  const SmartFund = await ethers.getContractFactory('SmartFund');
  const masterFundLibrary = await SmartFund.deploy();
  const SmartFundFactory = await ethers.getContractFactory('SmartFundFactory');
  const factory = await SmartFundFactory.deploy(
    masterFundLibrary.address,
    {
      rinkeby: '0xe3f8c202317F4f273BAf2097DD5bCBd3eBBE9B85',
      goerli: '0xde637d4c445ca2aae8f782ffac8d2971b93a4998',
      mainnet: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
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
