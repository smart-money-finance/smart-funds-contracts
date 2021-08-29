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
    UsdToken: usdTokenAddress,
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
