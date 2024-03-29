import 'dotenv/config';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import '@openzeppelin/hardhat-upgrades';
import { HardhatUserConfig } from 'hardhat/config';

import './plugin-abi-export';
import './plugin-bytecode-size';

const config: HardhatUserConfig = {
  networks: {
    hardhat: { allowUnlimitedContractSize: true },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    goerli: {
      url: `https://goerli.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    mumbai: {
      chainId: 80001,
      url: `https://polygon-mumbai.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    polygon: {
      chainId: 137,
      url: `https://polygon-mainnet.infura.io/v3/${process.env.INFURA_KEY}`,
      accounts: { mnemonic: process.env.MNEMONIC },
    },
  },
  solidity: {
    version: '0.8.7',
    settings: { optimizer: { enabled: true, runs: 1 } },
  },
};

export default config;
