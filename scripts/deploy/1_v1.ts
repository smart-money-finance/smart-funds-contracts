import { run, ethers, network, upgrades } from 'hardhat';

async function main() {
  await run('compile');

  const usdTokenAddress = {
    rinkeby: '0xe3f8c202317F4f273BAf2097DD5bCBd3eBBE9B85',
    goerli: '0xde637d4c445ca2aae8f782ffac8d2971b93a4998',
    mainnet: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    polygon: '0x2791bca1f2de4661ed88a30c99a7a9449aa84174',
    mumbai: '0x3B83F6b38612e0E3357Dc9657f01689dD1e8DADf',
  }[network.name];

  const bypassWhitelist = network.name !== 'mainnet';

  const FundFactory = await ethers.getContractFactory('FundV0');
  const fundProxy = await upgrades.deployProxy(FundFactory, {
    kind: 'uups',
    initializer: false,
  });
  await fundProxy.deployed();

  const fundImplementationAddress =
    await upgrades.erc1967.getImplementationAddress(fundProxy.address);
  // initialize the implementation to mitigate someone else executing functions on it
  const fundImplementation = await ethers.getContractAt(
    'FundV0',
    fundImplementationAddress,
  );
  await fundImplementation.initialize(
    [ethers.constants.AddressZero, ethers.constants.AddressZero],
    [
      0,
      0,
      0,
      0,
      0,
      0,
      ethers.constants.MaxUint256,
      '1000000000000000000000',
      0,
    ],
    '',
    '',
    '',
    '',
    '',
    false,
    `${ethers.constants.AddressZero.slice(0, -1)}1`,
    ethers.constants.AddressZero,
    ethers.constants.AddressZero,
  );

  const RegistryFactory = await ethers.getContractFactory('RegistryV0');
  const Registry = await upgrades.deployProxy(
    RegistryFactory,
    [fundImplementationAddress, usdTokenAddress, bypassWhitelist],
    {
      kind: 'uups',
    },
  );
  await Registry.deployed();

  console.log({
    registry: Registry.address,
    unusedFundProxy: fundProxy.address,
    existingUsdToken: usdTokenAddress,
    registryDeployBlockNumber: Registry.deployTransaction.blockNumber,
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
