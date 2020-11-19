import '@nomiclabs/hardhat-waffle'
import { HardhatUserConfig } from 'hardhat/config'

const config: HardhatUserConfig = {
  solidity: {
    version: '0.6.12',
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
}

export default config
