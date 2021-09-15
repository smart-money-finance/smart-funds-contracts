import { access, mkdir, writeFile } from 'fs/promises';
import { join } from 'path';

import { task } from 'hardhat/config';
import { TASK_COMPILE } from 'hardhat/builtin-tasks/task-names';

// on every compile, print contract size, and save abi with and without errors to abi/contractname.json
task(TASK_COMPILE, async function (taskArguments, hre, runSuper) {
  await runSuper();
  console.log('Saving ABIs...');
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
    }
  }
});
