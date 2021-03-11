import { run, ethers } from 'hardhat';

async function main() {
  await run('compile');
  const SMFund = await ethers.getContractFactory('SMFund');
  const masterFundLibrary = await SMFund.deploy();
  const SMFundFactory = await ethers.getContractFactory('SMFundFactory');
  const factory = await SMFundFactory.deploy(
    masterFundLibrary.address,
    '0xde637d4c445ca2aae8f782ffac8d2971b93a4998',
  );
  console.log(factory.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
