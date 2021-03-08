import { run, ethers } from 'hardhat'

async function main() {
  await run('compile')
  const SMFundLibrary = await ethers.getContractFactory('SMFundLibrary')
  const library = await SMFundLibrary.deploy()
  const SMFundFactory = await ethers.getContractFactory('SMFundFactory', {
    libraries: { SMFundLibrary: library.address },
  })
  const factory = await SMFundFactory.deploy(
    '0xd87ba7a50b2e7e660f678a895e4b72e7cb4ccd9c',
  )
  console.log({ factory: factory.address, library: library.address })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
