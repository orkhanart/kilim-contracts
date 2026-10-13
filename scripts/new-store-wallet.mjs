// Makes the store wallet for mainnet: a fresh wallet used only to pay for the 45 store chunks.
// Run it yourself, in your own terminal:   node contracts/scripts/new-store-wallet.mjs
// You choose a password (typed hidden). The key is created here, encrypted with that password and
// written to ~/.kilim-store/store-keystore.json (readable only by you). Only the address is printed.
// forge reads the file with --keystore on deploy day and asks for the same password once.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../kilim-sealer/package.json', import.meta.url));
const { ethers } = require('ethers');

const dir = join(homedir(), '.kilim-store');
const file = join(dir, 'store-keystore.json');
if (existsSync(file)) {
  console.log(`A store wallet already exists: ${file}. Nothing was changed.`);
  process.exit(1);
}

function ask(prompt) {
  return new Promise((done) => {
    process.stdout.write(prompt);
    const input = process.stdin;
    input.setRawMode(true);
    input.resume();
    input.setEncoding('utf8');
    let text = '';
    const onData = (c) => {
      for (const ch of c) {
        if (ch === '\r' || ch === '\n') {
          input.setRawMode(false); input.pause(); input.off('data', onData);
          process.stdout.write('\n'); return done(text);
        }
        if (ch === '\u0003') { process.stdout.write('\n'); process.exit(130); }
        if (ch === '\u007f') text = text.slice(0, -1); else text += ch;
      }
    };
    input.on('data', onData);
  });
}

const password = await ask('Choose a password for the store wallet (hidden): ');
if (password.length < 10) { console.log('Use at least 10 characters. Nothing was created.'); process.exit(1); }
if ((await ask('Type it again: ')) !== password) { console.log('The two did not match. Nothing was created.'); process.exit(1); }

const wallet = ethers.Wallet.createRandom();
process.stdout.write('Encrypting (a few seconds)… ');
// forge reads the lowercase "crypto" field; ethers writes "Crypto".
const json = (await wallet.encrypt(password)).replace('"Crypto":', '"crypto":');
mkdirSync(dir, { recursive: true, mode: 0o700 });
writeFileSync(file, json, { mode: 0o600, flag: 'wx' });
const back = await ethers.Wallet.fromEncryptedJson(json.replace('"crypto":', '"Crypto":'), password);
if (back.address !== wallet.address) throw new Error('the keystore did not read back');
console.log('done.\n');
console.log(`Store wallet address:  ${wallet.address}`);
console.log(`Encrypted key file:    ${file}`);
console.log('\nFund it with what the store costs at the day\'s gas (225M gas: about 0.04 ETH at 0.2 gwei) plus a margin;');
console.log('before the wallet-freeze day it may come from orkhanart.eth. Unused ETH is sent back after the store.');
console.log('Keep the password: forge asks for it once on deploy day. Use this wallet for nothing else.');
