import { ethers } from 'hardhat'
import { Contract, Signer } from 'ethers'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'
const { expect } = require('chai')

describe('Fund Factory', function () {
  let sender: SignerWithAddress
  let sender2: SignerWithAddress
  let sender3: SignerWithAddress
  let fundFactory: Contract
  let usdToken: Contract

  beforeEach(async () => {
    const accounts = await ethers.getSigners()
    sender = accounts[0]
    sender2 = accounts[1]
    sender3 = accounts[2]

    const USDToken = await ethers.getContractFactory('ERC20')
    usdToken = await USDToken.deploy('USD', 'USDc')
    await usdToken.deployed()

    const FundFactory = await ethers.getContractFactory('SMFundFactory')
    fundFactory = await FundFactory.deploy(usdToken.address)
  })

  it('should have deployer as owner', async () => {
    expect(await fundFactory.owner()).to.equal(sender.address)
  })

  it('Should create a fund', async () => {
    const send = await fundFactory.newFund(
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
    expect(await fundFactory.fundsLength()).to.equal(1)
  })
})
