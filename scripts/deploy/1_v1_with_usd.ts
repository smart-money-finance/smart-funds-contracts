import { run, ethers, network, upgrades } from 'hardhat';

async function main() {
  await run('compile');
  const TestUSDCoin = await ethers.getContractFactory('TestUSDCoin');
  const usdToken = await TestUSDCoin.deploy();

  const usdTokenAddress = usdToken.address;

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
    UsdToken: usdTokenAddress,
    registryDeployBlockNumber: Registry.deployTransaction.blockNumber,
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
