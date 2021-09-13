import { access, mkdir, writeFile } from 'fs/promises';
import { join } from 'path';

import 'dotenv/config';
import '@nomiclabs/hardhat-waffle';
import '@typechain/hardhat';
import '@openzeppelin/hardhat-upgrades';
import { task, HardhatUserConfig } from 'hardhat/config';
import { TASK_COMPILE } from 'hardhat/builtin-tasks/task-names';

// on every compile, print contract size, and save abi with and without errors to abi/contractname.json
task(TASK_COMPILE, async function (taskArguments, hre, runSuper) {
  await runSuper();
  console.log('Saving ABIs and calculating contract sizes...');
  const artifactNames = await hre.artifacts.getAllFullyQualifiedNames();
  for (const artifactName of artifactNames) {
    if (
      ['Registry', 'Fund', 'TestUSDCoin'].some((contractName) =>
        artifactName.match(contractName),
      )
    ) {
      const artifact = await hre.artifacts.readArtifact(artifactName);
      const abiWithoutErrors = artifact.abi.filter(
        (val) => val?.type !== 'error',
      );
      const abiPath = join('.', 'abi');
      try {
        await access(abiPath);
      } catch {
        await mkdir(abiPath);
      }
      await writeFile(
        join(abiPath, `${artifact.contractName}.json`),
        JSON.stringify(artifact.abi),
      );
      await writeFile(
        join(abiPath, `${artifact.contractName}-no-errors.json`),
        JSON.stringify(abiWithoutErrors),
      );
      const size =
        (artifact.deployedBytecode.replace(/__\$\w*\$__/g, '0'.repeat(40))
          .length -
          2) /
        2;
      if (size > 24576) {
        console.log('WARNING:');
      }
      console.log(`${artifact.contractName}: ${size} bytes`);
    }
  }
});

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
