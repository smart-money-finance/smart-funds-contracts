import { run, ethers } from 'hardhat'

async function main() {
  await run('compile')
  const accounts = await ethers.getSigners()
  const [sender, sender2, sender3] = accounts
  const FACTORY_ADDRESS = '0x5De1C0D14483e34a26003bDb5C0d729421650342'

  const SMFundFactory = await ethers.getContractFactory('SMFundFactory')
  const factory = await SMFundFactory.connect(sender).attach(FACTORY_ADDRESS)
  console.log('Factory Address: ', factory.address)

  const send = await factory.newFund(
    sender.address,
    sender2.address,
    sender3.address,
    100000,
    10000,
    10000,
    true,
    false,
    'Yield Farming Fund',
    'YFF',
  )
  console.log(send)
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
