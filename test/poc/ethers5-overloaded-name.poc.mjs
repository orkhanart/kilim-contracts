// Review PoC (glyphs lens): what the overloaded `name` does to an integrator who loads the verified
// KilimGlyphs ABI into a web3 library. The ABI carries name() (ERC-721 metadata) and name(uint16)
// (the glyph name). On chain both selectors work; the question is which client libraries resolve
// the bare `name` and which do not:
//   1. ethers v5: Contract does not attach ambiguous names as bare properties, so contract.name is
//      undefined and only contract["name()"]() / contract["name(uint16)"](n) work. KilimOneOfOne,
//      which has a single name(), is the control.
//   2. ethers v6: contract.name() resolves (no argument), but contract.name(n) is "ambiguous" because v6
//      lets a trailing argument be an overrides object, so name()+overrides and name(uint16) both fit one
//      argument; the glyph name needs the full signature or a Typed argument.
//   3. viem (optional): encodeFunctionData picks name() for no args and name(uint16) for one.
//   4. The same with ethers v5 and v6 against a live anvil deployment of the real contracts, so the
//      answers are the collection name and a glyph name, not just property checks.
//
//   ETHERS5=/path/to/node_modules/ethers node test/poc/ethers5-overloaded-name.poc.mjs   (from contracts/)
//   VIEM=/path/to/node_modules/viem   adds step 3; --no-chain skips step 4
//
// ethers v5 is not a dependency of this repo: point ETHERS5 at any install of it (npm install ethers@5
// in a scratch directory). ethers v6 is taken from ../registration-relayer or ../afterglow-server.
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil } from '../../scripts/dev/anvil.mjs';
import { deployLocal, artifact } from '../../scripts/dev/deploy.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CONTRACTS = resolve(here, '../..');
const require = createRequire(import.meta.url);
const NAME_SELECTOR = '0x06fdde03';

let failures = 0;
function check(cond, what) {
  console.log(`${cond ? 'ok  ' : 'FAIL'} ${what}`);
  if (!cond) failures++;
}
function loadLib(label, candidates) {
  for (const c of candidates) {
    if (c && existsSync(c)) {
      const lib = require(c);
      console.log(`${label}: ${c} (${require(resolve(c, 'package.json')).version})`);
      return lib;
    }
  }
  return null;
}

const ethers5 = loadLib('ethers v5', [process.env.ETHERS5]);
if (!ethers5 || !/^5\./.test(ethers5.version?.replace(/^ethers\//, '') ?? '')) {
  console.error('set ETHERS5 to a node_modules/ethers directory holding ethers v5');
  process.exit(2);
}
const ethers6 = loadLib('ethers v6', [
  process.env.ETHERS6,
  resolve(CONTRACTS, '../registration-relayer/node_modules/ethers'),
  resolve(CONTRACTS, '../afterglow-server/node_modules/ethers'),
]);
const viem = loadLib('viem', [process.env.VIEM]);

const glyphsAbi = artifact('KilimGlyphs').abi;
const oneOfOneAbi = artifact('KilimOneOfOne').abi;
const dupes = (abi) => {
  const seen = {};
  for (const f of abi) if (f.type === 'function') (seen[f.name] ??= []).push(`${f.name}(${f.inputs.map((i) => i.type).join(',')})`);
  return Object.entries(seen).filter(([, s]) => s.length > 1).map(([n, s]) => `${n}: ${s.join(' | ')}`);
};
console.log(`\nKilimGlyphs duplicated names: ${dupes(glyphsAbi).join('; ')}`);
console.log(`KilimOneOfOne duplicated names: ${dupes(oneOfOneAbi).join('; ') || '(none)'}`);

// ---------------------------------------------------------------- 1. ethers v5, no provider
console.log('\n1. ethers v5 Contract (no provider)');
const ZERO = '0x0000000000000000000000000000000000000001';
{
  const g = new ethers5.Contract(ZERO, glyphsAbi);
  const o = new ethers5.Contract(ZERO, oneOfOneAbi);
  check(typeof g.name === 'undefined', `KilimGlyphs: contract.name is ${typeof g.name}`);
  check(typeof g['name()'] === 'function', 'KilimGlyphs: contract["name()"] is a function');
  check(typeof g['name(uint16)'] === 'function', 'KilimGlyphs: contract["name(uint16)"] is a function');
  check(typeof g.functions.name === 'undefined', `KilimGlyphs: contract.functions.name is ${typeof g.functions.name}`);
  check(typeof g.safeTransferFrom === 'undefined', `KilimGlyphs: contract.safeTransferFrom is ${typeof g.safeTransferFrom} (the standard ERC-721 overload, same rule)`);
  check(typeof g.symbol === 'function' && typeof g.tokenURI === 'function', 'KilimGlyphs: symbol and tokenURI attach as bare names');
  check(typeof o.name === 'function', `KilimOneOfOne (control, one name()): contract.name is ${typeof o.name}`);
  let thrown = '';
  try { g.interface.getFunction('name'); } catch (e) { thrown = e.message; }
  check(/multiple matching functions/i.test(thrown), `KilimGlyphs: interface.getFunction("name") throws: ${thrown.split('(')[0].trim()}`);
  check(g.interface.getFunction('name()').name === 'name' && g.interface.getSighash('name()') === NAME_SELECTOR, 'KilimGlyphs: interface.getFunction("name()") resolves to 0x06fdde03');
  let typeError = '';
  try { g.name(); } catch (e) { typeError = e.message; }
  check(/not a function/.test(typeError), `KilimGlyphs: contract.name() throws TypeError: ${typeError}`);
}

// ---------------------------------------------------------------- 2. ethers v6, no runner
console.log('\n2. ethers v6 Contract (no runner)');
if (ethers6) {
  const g = new ethers6.Contract(ZERO, glyphsAbi);
  check(typeof g.name === 'function', `KilimGlyphs: contract.name is ${typeof g.name}`);
  check(g.name.getFragment().format('sighash') === 'name()', `KilimGlyphs: contract.name.getFragment() -> ${g.name.getFragment().format('sighash')}`);
  let oneArg = '';
  try { oneArg = g.name.getFragment(1).format('sighash'); } catch (e) { oneArg = `throws: ${e.shortMessage ?? e.message}`; }
  check(/ambiguous/i.test(oneArg), `KilimGlyphs: contract.name.getFragment(1) ${oneArg}`);
  check(g.name.getFragment(ethers6.Typed.uint16(1)).format('sighash') === 'name(uint16)', 'KilimGlyphs: contract.name.getFragment(Typed.uint16(1)) -> name(uint16)');
  check(typeof g['name(uint16)'] === 'function', 'KilimGlyphs: contract["name(uint16)"] is a function');
  let thrown = '';
  try { void g.name.fragment; } catch (e) { thrown = e.shortMessage ?? e.message; }
  check(/ambiguous/i.test(thrown), `KilimGlyphs: contract.name.fragment (no args) throws: ${thrown}`);
} else {
  console.log('skipped: no ethers v6 install found');
}

// ---------------------------------------------------------------- 3. viem
console.log('\n3. viem encodeFunctionData');
if (viem) {
  const noArgs = viem.encodeFunctionData({ abi: glyphsAbi, functionName: 'name' });
  const oneArg = viem.encodeFunctionData({ abi: glyphsAbi, functionName: 'name', args: [1] });
  check(noArgs === NAME_SELECTOR, `functionName "name", no args -> ${noArgs}`);
  check(oneArg.slice(0, 10) === viem.toFunctionSelector('name(uint16)'), `functionName "name", args [1] -> ${oneArg.slice(0, 10)} (name(uint16))`);
} else {
  console.log('skipped: set VIEM to a node_modules/viem directory to run it');
}

// ---------------------------------------------------------------- 4. live calls on anvil
console.log('\n4. live calls against a fresh anvil deployment');
if (process.argv.includes('--no-chain')) {
  console.log('skipped (--no-chain)');
} else {
  const anvil = await startAnvil({ port: 0 });
  try {
    const d = await deployLocal(anvil.rpcUrl);
    console.log(`glyphs ${d.glyphs}, oneOfOne ${d.oneOfOne}`);
    const p5 = new ethers5.providers.JsonRpcProvider(anvil.rpcUrl);
    const g5 = new ethers5.Contract(d.glyphs, glyphsAbi, p5);
    const o5 = new ethers5.Contract(d.oneOfOne, oneOfOneAbi, p5);
    check((await g5['name()']()) === 'Motif Bazaar', 'v5: glyphs["name()"]() -> "Motif Bazaar"');
    const glyph1 = await g5['name(uint16)'](1);
    check(typeof glyph1 === 'string' && glyph1.length > 0, `v5: glyphs["name(uint16)"](1) -> "${glyph1}"`);
    check((await o5.name()) === 'The Unwoven Kilim', 'v5: oneOfOne.name() -> "The Unwoven Kilim" (no overload, bare name works)');
    let typeError = '';
    try { await g5.name(); } catch (e) { typeError = e.message; }
    check(/not a function/.test(typeError), `v5: glyphs.name() -> TypeError: ${typeError}`);
    // The raw selector, the way an indexer or token tracker reads it.
    const raw = await p5.call({ to: d.glyphs, data: NAME_SELECTOR });
    check(ethers5.utils.defaultAbiCoder.decode(['string'], raw)[0] === 'Motif Bazaar', 'raw eth_call 0x06fdde03 -> "Motif Bazaar"');

    if (ethers6) {
      const p6 = new ethers6.JsonRpcProvider(anvil.rpcUrl, undefined, { staticNetwork: true });
      const g6 = new ethers6.Contract(d.glyphs, glyphsAbi, p6);
      check((await g6.name()) === 'Motif Bazaar', 'v6: glyphs.name() -> "Motif Bazaar"');
      let ambiguous = '';
      try { await g6.name(1); } catch (e) { ambiguous = e.shortMessage ?? e.message; }
      check(/ambiguous/i.test(ambiguous), `v6: glyphs.name(1) throws: ${ambiguous}`);
      check((await g6['name(uint16)'](1)) === glyph1, `v6: glyphs["name(uint16)"](1) -> "${glyph1}"`);
      check((await g6.name(ethers6.Typed.uint16(1))) === glyph1, `v6: glyphs.name(Typed.uint16(1)) -> "${glyph1}"`);
      p6.destroy();
    }
  } finally {
    await anvil.stop();
  }
}

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
