import { readdir, readFile, writeFile } from 'fs/promises';
import { join } from 'path';

const contractsPath = join('.', 'artifacts', 'contracts');
readdir(contractsPath, { withFileTypes: true }).then((folders) => {
  for (const folder of folders) {
    if (folder.isDirectory()) {
      const contractPath = join(contractsPath, folder.name);
      readdir(contractPath, { withFileTypes: true }).then((files) => {
        for (const file of files) {
          if (file.isFile()) {
            readFile(join(contractPath, file.name)).then((artifactBuffer) => {
              const artifact = JSON.parse(artifactBuffer.toString());
              const abi = artifact?.abi;
              if (Array.isArray(abi)) {
                const newAbi = abi.filter((val) => val?.type !== 'error');
                writeFile(
                  join('.', 'artifacts', `${file.name}-no-errors.json`),
                  JSON.stringify(newAbi),
                ).then(() => console.log(`filtered ${file.name}`));
              }
            });
          }
        }
      });
    }
  }
});
