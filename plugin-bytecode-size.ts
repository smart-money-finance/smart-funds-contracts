import { task } from 'hardhat/config';
import { TASK_COMPILE } from 'hardhat/builtin-tasks/task-names';

// on every compile, print contract size
task(TASK_COMPILE, async function (taskArguments, hre, runSuper) {
  await runSuper();
  console.log('Calculating contract sizes...');
  const artifactNames = await hre.artifacts.getAllFullyQualifiedNames();
  for (const artifactName of artifactNames) {
    if (
      ['Registry', 'Fund', 'TestUSDCoin'].some((contractName) =>
        artifactName.match(contractName),
      )
    ) {
      const artifact = await hre.artifacts.readArtifact(artifactName);
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
