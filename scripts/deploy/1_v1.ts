import { run, ethers, network, upgrades } from 'hardhat';

async function main() {
  await run('compile');

  const usdTokenAddress = {
    rinkeby: '0xe3f8c202317F4f273BAf2097DD5bCBd3eBBE9B85',
    goerli: '0xde637d4c445ca2aae8f782ffac8d2971b93a4998',
    mainnet: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    polygon: '0x2791bca1f2de4661ed88a30c99a7a9449aa84174',
  }[network.name];

  const bypassWhitelist = network.name !== 'mainnet';

  const FundFactory = await ethers.getContractFactory('FundV0');
  const fundProxy = await upgrades.deployProxy(FundFactory, {
    kind: 'uups',
    initializer: false,
  });
  await fundProxy.deployed();
  // storage slot of implementation is
  // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1))
  // see EIP-1967
  const fundImplementationHex = await ethers.provider.getStorageAt(
    fundProxy.address,
    ethers.utils.hexValue(
      ethers.BigNumber.from(
        ethers.utils.keccak256(
          ethers.utils.toUtf8Bytes('eip1967.proxy.implementation'),
        ),
      ).sub(1),
    ),
  );
  const fundImplementationAddress = ethers.utils.hexStripZeros(
    fundImplementationHex,
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
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
