import 'dotenv/config'
import '@nomiclabs/hardhat-waffle'
import { HardhatUserConfig } from 'hardhat/config'

const config: HardhatUserConfig = {
  networks: {
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
  },
  solidity: {
    version: '0.8.1',
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
}

export default config
