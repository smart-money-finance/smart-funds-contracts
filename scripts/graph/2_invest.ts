import { run, network, ethers } from 'hardhat';
import { BigNumberish, Event, Signature } from 'ethers';

import {
  TestUSDCoin__factory,
  TestUSDCoin,
  RegistryV0__factory,
  FundV0__factory,
} from '../../typechain';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';

async function signPermit(
  wallet: SignerWithAddress,
  token: TestUSDCoin,
  chainId: BigNumberish,
  spender: string,
  value: BigNumberish,
  deadline: BigNumberish,
): Promise<Signature> {
  const rawSignature = await wallet._signTypedData(
    {
      name: await token.name(),
      version: await token.version(),
      chainId,
      verifyingContract: token.address,
    },
    {
      Permit: [
        {
          name: 'owner',
          type: 'address',
        },
        {
          name: 'spender',
          type: 'address',
        },
        {
          name: 'value',
          type: 'uint256',
        },
        {
          name: 'nonce',
          type: 'uint256',
        },
        {
          name: 'deadline',
          type: 'uint256',
        },
      ],
    },
    {
      owner: wallet.address,
      spender,
      value,
      nonce: await token.nonces(wallet.address),
      deadline,
    },
  );
  return ethers.utils.splitSignature(rawSignature);
}

async function main() {
  await run('compile');
  const wallets = await ethers.getSigners();
  const registryAddress = {
    mumbai: '0x4469429a66F469de7D035C22f302d67ed92aC4aa',
  }[network.name];

  if (!registryAddress) {
    console.log('invalid network');
    return;
  }

  // Create a fund
  const registry = RegistryV0__factory.connect(registryAddress, wallets[0]);

  const fundAddress = '0x49fa3abc2b03d9e1e65b7a4615ba6e2bc02e4062'; // update
  const fund = FundV0__factory.connect(fundAddress, wallets[0]);

  //give investor 1 some usdc
  const usdTokenAddress = await registry.usdToken();
  const usdToken = TestUSDCoin__factory.connect(usdTokenAddress, wallets[1]);
  usdToken.connect(wallets[1]).faucet(ethers.utils.parseUnits('100000', 6));

  //sign a message
  const amountToInvest = ethers.utils.parseUnits('10000', 6);
  const signature = await signPermit(
    wallets[1],
    usdToken,
    network.config.chainId || 1,
    fund.address,
    amountToInvest,
    ethers.constants.MaxUint256,
  );

  // request investment
  await fund
    .connect(wallets[1])
    .createOrUpdateInvestmentRequest(
      amountToInvest,
      1,
      ethers.constants.MaxUint256,
      ethers.constants.MaxUint256,
      false,
      signature.v,
      signature.r,
      signature.s,
    );

  // process investment
  // await fund.connect(wallets[0]).processInvestmentRequest(0);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
