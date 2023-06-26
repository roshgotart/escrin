import { CryptoKey } from '@cloudflare/workers-types/experimental';

import * as sapphire from '@oasisprotocol/sapphire-paratime';
import { ethers } from 'ethers';
import createKeccakHash from 'keccak';

import { AttestationToken, AttestationTokenFactory, Lockbox, LockboxFactory } from '@escrin/evm';

import { Cacheable, Module, RpcError } from '.';

type Registration = AttestationToken.RegistrationStruct;

export type InitOpts = {
  web3GatewayUrl: string;
  attokAddr: string;
  lockboxAddr: string;
  debug?: Partial<{
    nowrap: boolean;
  }>;
};

export const INIT_SAPPHIRE: InitOpts = {
  web3GatewayUrl: 'https://sapphire.oasis.io',
  attokAddr: '0x96c1D1913310ACD921Fc4baE081CcDdD42374C36',
  lockboxAddr: '0x53FE9042cbB6B9773c01F678F7c0439B09EdCeB3',
};

export const INIT_SAPPHIRE_TESTNET: InitOpts = {
  web3GatewayUrl: 'https://testnet.sapphire.oasis.dev',
  attokAddr: '0x960bEAcD9eFfE69e692f727F52Da7DF3601dc80f',
  lockboxAddr: '0x68D4f98E5cd2D8d2C6f03c095761663Bf1aA8442',
};

export default function make(optsOrNet: InitOpts | 'mainnet' | 'testnet', gasKey: string): Module {
  const opts =
    optsOrNet === 'mainnet'
      ? INIT_SAPPHIRE
      : optsOrNet === 'testnet'
      ? INIT_SAPPHIRE_TESTNET
      : optsOrNet;
  const provider = new ethers.providers.JsonRpcProvider(opts.web3GatewayUrl);
  const gasWallet = new ethers.Wallet(gasKey).connect(provider);
  let localWallet = ethers.Wallet.createRandom().connect(provider);
  localWallet = opts.debug?.nowrap ? localWallet : sapphire.wrap(localWallet);
  const attok = AttestationTokenFactory.connect(opts.attokAddr, gasWallet);
  const lockbox = LockboxFactory.connect(opts.lockboxAddr, localWallet);

  return {
    async getKey(id: string): Promise<Cacheable<CryptoKey>> {
      if (id !== 'omni') throw new RpcError(404, `unknown key \`${id}\``);

      const oneHourFromNow = Math.floor(Date.now() / 1000) + 60 * 60;
      let currentBlock = await provider.getBlock('latest');
      const prevBlock = await provider.getBlock(currentBlock.number - 1);
      const registration: Registration = {
        baseBlockHash: prevBlock.hash,
        baseBlockNumber: prevBlock.number,
        expiry: oneHourFromNow,
        registrant: localWallet.address,
        tokenExpiry: oneHourFromNow,
      };
      const quote = await mockQuote(registration);
      const tcbId = await sendAttestation(attok.connect(localWallet), quote, registration);

      const key = await getOrCreateKey(lockbox, gasWallet, tcbId);

      return new Cacheable(key, new Date(oneHourFromNow));
    },
  };
}

async function mockQuote(registration: Registration): Promise<Uint8Array> {
  const coder = ethers.utils.defaultAbiCoder;
  const measurementHash = '0xc275e487107af5257147ce76e1515788118429e0caa17c04d508038da59d5154'; // static random bytes. this is just a key in a key-value store.
  const regTypeDef =
    'tuple(uint256 baseBlockNumber, bytes32 baseBlockHash, uint256 expiry, uint256 registrant, uint256 tokenExpiry)'; // TODO: keep this in sync with the actual typedef
  const regBytesHex = coder.encode([regTypeDef], [registration]);
  const regBytes = Buffer.from(ethers.utils.arrayify(regBytesHex));
  return ethers.utils.arrayify(
    coder.encode(
      ['bytes32', 'bytes32'],
      [measurementHash, createKeccakHash('keccak256').update(regBytes).digest()],
    ),
  );
}

async function sendAttestation(
  attok: AttestationToken,
  quote: Uint8Array,
  reg: Registration,
): Promise<string> {
  const expectedTcbId = await attok.callStatic.getTcbId(quote);
  if (await attok.callStatic.isAttested(reg.registrant, expectedTcbId)) return expectedTcbId;
  const tx = await attok.attest(quote, reg, { gasLimit: 10_000_000 });
  const receipt = await tx.wait();
  if (receipt.status !== 1) throw new Error('attestation tx failed');
  let tcbId = '';
  for (const event of receipt.events ?? []) {
    if (event.event !== 'Attested') continue;
    tcbId = event.args!.tcbId;
  }
  if (!tcbId) throw new Error('could not retrieve attestation id');
  await waitForConfirmation(attok.provider, receipt);
  return tcbId;
}

async function waitForConfirmation(
  provider: ethers.providers.Provider,
  receipt: ethers.ContractReceipt,
): Promise<void> {
  const { chainId } = await provider.getNetwork();
  if (chainId !== 0x5afe && chainId !== 0x5aff) return;
  const getCurrentBlock = () => provider.getBlock('latest');
  let currentBlock = await getCurrentBlock();
  while (currentBlock.number <= receipt.blockNumber + 1) {
    await new Promise((resolve) => setTimeout(resolve, 3_000));
    currentBlock = await getCurrentBlock();
  }
}

async function getOrCreateKey(
  lockbox: Lockbox,
  gasWallet: ethers.Wallet,
  tcbId: string,
): Promise<CryptoKey> {
  let keyHex = await lockbox.callStatic.getKey(tcbId);
  if (!/^(0x)?0+$/.test(keyHex)) return importKey(keyHex);
  const tx = await lockbox
    .connect(gasWallet)
    .createKey(tcbId, crypto.getRandomValues(new Uint8Array(32)), { gasLimit: 10_000_000 });
  const receipt = await tx.wait();
  await waitForConfirmation(lockbox.provider, receipt);
  keyHex = await lockbox.callStatic.getKey(tcbId);
  return importKey(keyHex);
}

async function importKey(keyHex: string): Promise<CryptoKey> {
  const key = ethers.utils.arrayify(keyHex);
  const exportable = true;
  return crypto.subtle.importKey('raw', key, 'HKDF', exportable, ['deriveKey', 'deriveBits']);
}
