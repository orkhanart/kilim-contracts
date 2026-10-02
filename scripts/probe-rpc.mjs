// How much gas each RPC endpoint lets an eth_call use, measured without deploying anything.
//
//   pnpm probe:rpc [--chain 1] [--out audit/rpc-gas-caps.txt] [--no-defaults] [https://… …]
//
// tokenURI is an eth_call, not a transaction: the 1/1 needs ~22.4M gas and the heaviest artwork
// ~30.4M (docs/RENDERER.md). A marketplace or wallet whose node caps eth_call below that shows a
// blank token. Most callers send no gas field, so the node's default cap is what counts.
//
// Each probe is an eth_call with no "to": the node runs the data as contract-creation code and
// returns what it returns. So nothing needs to exist on-chain, and every node can answer.
//   GASLEFT  5a 5f 52 60 20 5f f3       returns the gas left at its first instruction. The call's
//                                       gas is that plus the 53,116 spent before it (21,000 base,
//                                       32,000 create, 112 calldata, 2 initcode word, 2 GAS).
//   BURNER   5b 5a 62 0186a0 10 5f 57 … loops until under 100,000 gas is left, then returns it,
//                                       so the node really executes (not just accepts) the gas.
import { writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export const GASLEFT = '0x5a5f5260205ff3';
export const BURNER = '0x5b5a620186a0105f575a5f5260205ff3';
export const BEFORE_FIRST_GAS = 53_116n;
export const NEEDS = [
  { name: 'the 1/1', gas: 22_400_000n },
  { name: 'the heaviest artwork', gas: 30_400_000n },
];
const ASKS = [30_000_000n, 50_000_000n];
const BURNS = [23_000_000n, 31_000_000n];
export const DEFAULT_URLS = [
  'https://ethereum-rpc.publicnode.com',
  'https://eth.llamarpc.com',
  'https://eth.drpc.org',
  'https://1rpc.io/eth',
  'https://rpc.flashbots.net',
  'https://rpc.mevblocker.io',
  'https://eth.merkle.io',
  'https://mainnet.gateway.tenderly.co',
  'https://eth-mainnet.public.blastapi.io',
  'https://cloudflare-eth.com',
  'https://rpc.ankr.com/eth',
];

/** The gas a GASLEFT probe was given, from its 32-byte answer. */
export function gasFromAnswer(hex) {
  if (typeof hex !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(hex)) throw new Error(`unexpected answer ${String(hex).slice(0, 80)}`);
  return BigInt(hex) + BEFORE_FIRST_GAS;
}

/** Leading URL credentials and query keys never reach the report. */
export function redact(url) {
  try {
    const u = new URL(url);
    const tail = u.pathname.length > 12 ? u.pathname.slice(0, 8) + '…' : u.pathname;
    return u.origin + (tail === '/' ? '' : tail) + (u.search ? '?…' : '');
  } catch { return '(bad url)'; }
}

async function rpc(url, method, params, timeoutMs) {
  const t0 = performance.now();
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const ms = Math.round(performance.now() - t0);
  const text = await response.text();
  let body;
  try { body = JSON.parse(text); } catch { throw Object.assign(new Error(`HTTP ${response.status}: ${text.slice(0, 120).replace(/\s+/g, ' ')}`), { ms }); }
  if (body.error) throw Object.assign(new Error(String(body.error.message || JSON.stringify(body.error)).slice(0, 160)), { ms });
  return { result: body.result, ms };
}
const hexGas = (g) => '0x' + g.toString(16);
const m = (g) => (Number(g) / 1e6).toFixed(Number(g) % 1e6 ? 2 : 0) + 'M';

/** Probe one endpoint. Never throws: every failure is part of the answer. */
export async function probe(url, { chainId = 1, timeoutMs = 25_000 } = {}) {
  const out = { url: redact(url), chainOk: false, defaultCap: null, asks: [], burns: [], error: null };
  try {
    const id = Number((await rpc(url, 'eth_chainId', [], timeoutMs)).result);
    if (id !== chainId) { out.error = `chain ${id}, expected ${chainId}`; return out; }
    out.chainOk = true;
  } catch (e) { out.error = e.message; return out; }
  try {
    const { result, ms } = await rpc(url, 'eth_call', [{ data: GASLEFT }, 'latest'], timeoutMs);
    out.defaultCap = gasFromAnswer(result); out.defaultMs = ms;
  } catch (e) { out.defaultError = e.message; }
  for (const gas of ASKS) {
    try {
      const { result } = await rpc(url, 'eth_call', [{ data: GASLEFT, gas: hexGas(gas) }, 'latest'], timeoutMs);
      out.asks.push({ gas, got: gasFromAnswer(result) });
    } catch (e) { out.asks.push({ gas, error: e.message }); }
  }
  for (const gas of BURNS) {
    try {
      const { result, ms } = await rpc(url, 'eth_call', [{ data: BURNER, gas: hexGas(gas) }, 'latest'], timeoutMs);
      const left = BigInt(result);
      out.burns.push({ gas, ok: left < 100_000n, ms });
    } catch (e) { out.burns.push({ gas, error: e.message, ms: e.ms }); }
  }
  return out;
}

/** What each measurement means for Kilim's tokens. */
export function verdicts(p) {
  if (!p.chainOk) return ['unreachable or wrong chain'];
  const lines = [];
  for (const need of NEEDS) {
    const byDefault = p.defaultCap !== null && p.defaultCap >= need.gas;
    const burned = p.burns.find((b) => b.gas >= need.gas && b.ok);
    const askedFor = p.asks.find((a) => a.gas >= need.gas && a.got !== undefined && a.got >= need.gas);
    if (byDefault && burned) lines.push(`${need.name}: renders, even for callers that send no gas field`);
    else if (burned || askedFor) lines.push(`${need.name}: renders only for callers that ask for ${m(need.gas)}+ gas; the default cap is ${p.defaultCap === null ? 'unknown' : m(p.defaultCap)}`);
    else lines.push(`${need.name}: BLANK here (cannot run ${m(need.gas)} of gas)`);
  }
  return lines;
}

export function report(results, { date, chainId }) {
  const rows = [`eth_call gas caps, chain ${chainId}, ${date}`, `Measured by pnpm probe:rpc (contracts/scripts/probe-rpc.mjs). Needs: ` +
    NEEDS.map((n) => `${n.name} ~${m(n.gas)}`).join(', ') + '.', ''];
  for (const p of results) {
    rows.push(p.url);
    if (!p.chainOk) { rows.push(`  error: ${p.error}`, ''); continue; }
    rows.push(`  default cap (no gas field): ${p.defaultCap === null ? 'error: ' + p.defaultError : m(p.defaultCap) + ` (${p.defaultCap})`}`);
    for (const a of p.asks) rows.push(`  asked ${m(a.gas)}: ${a.error ? 'error: ' + a.error : 'got ' + m(a.got)}`);
    for (const b of p.burns) rows.push(`  burn ${m(b.gas)}: ${b.error ? 'error: ' + b.error : b.ok ? 'ran it all' : 'stopped early'}${b.ms !== undefined ? ` in ${b.ms} ms` : ''}`);
    for (const v of verdicts(p)) rows.push('  => ' + v);
    rows.push('');
  }
  return rows.join('\n');
}

async function main() {
  const args = process.argv.slice(2);
  const value = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  const flags = new Set(['--chain', '--out', '--timeout']);
  const urls = args.filter((a, i) => /^https?:\/\//.test(a) && !flags.has(args[i - 1]));
  const chainId = Number(value('--chain') ?? 1);
  const timeoutMs = Number(value('--timeout') ?? 25) * 1000;
  const list = [...(args.includes('--no-defaults') ? [] : DEFAULT_URLS), ...urls];
  if (!list.length) { console.error('probe-rpc: no endpoints'); process.exit(1); }
  const results = await Promise.all(list.map((u) => probe(u, { chainId, timeoutMs })));
  const text = report(results, { date: new Date().toISOString().slice(0, 10), chainId });
  console.log(text);
  const out = value('--out');
  if (out) { writeFileSync(resolve(process.cwd(), out), text + '\n'); console.log(`wrote ${out}`); }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(here, 'probe-rpc.mjs')) main();
