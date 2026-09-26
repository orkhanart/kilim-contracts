import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const vendor = resolve(root, 'vendor/thirdweb');
const manifest = JSON.parse(readFileSync(resolve(vendor, 'manifest.json'), 'utf8'));
const snapshot = readFileSync(resolve(vendor, manifest.snapshot), 'utf8');
const adaptation = readFileSync(resolve(root, manifest.adaptation), 'utf8');
const sha256 = (data) => createHash('sha256').update(data).digest('hex');

if (sha256(snapshot) !== manifest.sourceSha256) throw new Error('Upstream audit snapshot hash mismatch.');
if (sha256(readFileSync(resolve(vendor, 'LICENSE'))) !== manifest.licenseSha256) {
  throw new Error('Upstream license hash mismatch.');
}

// Compare the entire declared function, allowing formatting changes only. The snapshot itself
// is checked against the SHA-256 published in the named audit; it is never compiled or deployed.
function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw new Error(`Missing upstream function ${name}.`);
  const bodyStart = source.indexOf('{', start);
  let depth = 0;
  for (let i = bodyStart; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1).replace(/\s+/g, '');
  }
  throw new Error(`Unterminated function ${name}.`);
}

for (const name of manifest.unchangedFunctions) {
  if (extractFunction(snapshot, name) !== extractFunction(adaptation, name)) {
    throw new Error(`${name} differs from the audited reference. Update the review and provenance.`);
  }
}
for (const source of [snapshot, adaptation]) {
  if (!/uint64\s+private\s+constant\s+MAX_BPS\s*=\s*10_000\s*;/.test(source)) {
    throw new Error('Upstream bid predicate denominator has changed.');
  }
}
console.log('Verified thirdweb audit-reference SHA-256, license, denominator and unchanged bid predicate.');
