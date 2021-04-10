import { describe, before } from 'mocha';
import { ethers } from 'hardhat';
import { Contract } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { step } from 'mocha-steps';

const decimals = 6;

describe('FeeDividendToken', () => {
  let feeToken: Contract;
  let wallets: SignerWithAddress[];

  before(async () => {
    const FeeToken = await ethers.getContractFactory('MockToken');
    feeToken = await FeeToken.deploy('FeeDividendToken', 'FDT', decimals);
    await feeToken.deployed();
    wallets = await ethers.getSigners();
  });

  async function logem() {
    console.log(
      'Total supply: ',
      ethers.utils.formatUnits(await feeToken.totalSupply(), decimals),
    );
    // console.log(
    //   'Suply from  base: ',
    //   ethers.utils.formatUnits(await feeToken.totalSupplyFromBase(), decimals),
    // );
    console.log(
      '0 balance: ',
      ethers.utils.formatUnits(
        await feeToken.balanceOf(wallets[0].address),
        decimals,
      ),
    );
    console.log(
      '1 balance: ',
      ethers.utils.formatUnits(
        await feeToken.balanceOf(wallets[1].address),
        decimals,
      ),
    );
    console.log(
      '2 balance: ',
      ethers.utils.formatUnits(
        await feeToken.balanceOf(wallets[2].address),
        decimals,
      ),
    );
    console.log(
      '3 balance: ',
      ethers.utils.formatUnits(
        await feeToken.balanceOf(wallets[3].address),
        decimals,
      ),
    );
    // console.log('scale: ', (await feeToken.baseScale()).toString());
  }

  step('Mint', async () => {
    await logem();
    const amount = ethers.utils.parseUnits('10', decimals);
    console.log('\nMINT TO WALLET 1: 10 TOKENS');
    await feeToken.mint(wallets[1].address, amount);
    await logem();
  });

  step('Fee sweep', async () => {
    const amount = ethers.utils.parseUnits('1', decimals);
    console.log('\nFEE SWEEP TO WALLET 0: 1 TOKEN');
    await feeToken.collectFees(wallets[0].address, amount);
    await logem();
  });

  step('Mint', async () => {
    const amount = ethers.utils.parseUnits('9', decimals);
    console.log('\nMINT TO WALLET 2: 9 TOKENS');
    await feeToken.mint(wallets[2].address, amount);
    await logem();
  });

  step('Fee sweep', async () => {
    const amount = ethers.utils.parseUnits('2', decimals);
    console.log('\nFEE SWEEP TO WALLET 0: 2 TOKENS');
    await feeToken.collectFees(wallets[0].address, amount);
    await logem();
  });

  step('Mint', async () => {
    const amount = ethers.utils.parseUnits('8', decimals);
    console.log('\nMINT TO WALLET 2: 8 TOKENS');
    await feeToken.mint(wallets[2].address, amount);
    await logem();
  });

  step('Fee sweep', async () => {
    const amount = ethers.utils.parseUnits('3', decimals);
    console.log('\nFEE SWEEP TO WALLET 0: 3 TOKENS');
    await feeToken.collectFees(wallets[0].address, amount);
    await logem();
  });

  step('Burn', async () => {
    const amount = ethers.utils.parseUnits('7', decimals);
    console.log('\nBURN FROM WALLET 2: 7 TOKENS');
    await feeToken.burn(wallets[2].address, amount);
    await logem();
  });

  step('Fee sweep', async () => {
    const amount = ethers.utils.parseUnits('1', decimals);
    console.log('\nFEE SWEEP TO WALLET 0: 1 TOKEN');
    await feeToken.collectFees(wallets[0].address, amount);
    await logem();
  });

  step('Disperse dividends', async () => {
    const amount = ethers.utils.parseUnits('1', decimals);
    console.log('\nDISPERSE 0: 1');
    await feeToken.disperseDividends(wallets[0].address, amount);
    await logem();
  });

  step('Transfer', async () => {
    const amount = ethers.utils.parseUnits('1', decimals);
    console.log('\nTRANSFER 1 TO 0: 1');
    await feeToken.connect(wallets[1]).transfer(wallets[0].address, amount);
    await logem();
  });

  step('Disperse dividends', async () => {
    const amount = ethers.utils.parseUnits('4', decimals);
    console.log('\nDISPERSE FROM WALLET 1: 4 TOKENS');
    await feeToken.disperseDividends(wallets[1].address, amount);
    await logem();
  });

  step('Transfer', async () => {
    const amount = ethers.utils.parseUnits('4.5', decimals);
    console.log('\nTRANSFER FROM WALLET 2 TO WALLET 1: 4.5 TOKENS');
    await feeToken.connect(wallets[2]).transfer(wallets[1].address, amount);
    await logem();
  });

  step('Large amounts minted and sweeped repeatedly', async () => {
    const amount = ethers.utils.parseUnits('100000000', decimals);
    console.log('\nMINT TO WALLET 1: 100000000 TOKENS');
    await feeToken.mint(wallets[1].address, amount);
    await logem();
    console.log('\nMINT TO WALLET 2: 100000000 TOKENS');
    await feeToken.mint(wallets[2].address, amount);
    await logem();
    console.log('\nMINT TO WALLET 3: 100000000 TOKENS');
    await feeToken.mint(wallets[3].address, amount);
    await logem();
    console.log('\nSWEEP FEES 1000 TIMES TO WALLET 0: 100 TOKENS EACH TIME');
    const sweepAmount = ethers.utils.parseUnits('100', decimals);
    for (let i = 0; i < 1000; i++) {
      await feeToken.collectFees(wallets[0].address, sweepAmount);
    }
    await logem();
  });
});
