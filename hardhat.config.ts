import 'dotenv/config';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import '@openzeppelin/hardhat-upgrades';
import { HardhatUserConfig } from 'hardhat/config';

const config: HardhatUserConfig = {
  networks: {
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
      url: 'https://rpc-mumbai.maticvigil.com',
      accounts: { mnemonic: process.env.MNEMONIC },
    },
    polygon: {
      url: 'https://rpc-mainnet.maticvigil.com',
      accounts: { mnemonic: process.env.MNEMONIC },
    },
  },
  solidity: {
    version: '0.8.7',
    settings: { optimizer: { enabled: true, runs: 200 } },
  },
};

export default config;
