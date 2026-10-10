// PoC for the review finding "tokenURI(1) is `data:application/json;utf8,` + raw JSON, a form OpenSea's
// metadata-storage page does not list, and the contract has no metadata setter". What can be checked
// from here, against the packed store (onchain/build-page, onchain/build-glyphs):
//   1. the exact answer the contract gives (assembled as onchain/test/page.test.mjs does, sha256 against
//      the packer's golden) goes through the WHATWG data: URL processor (Node's fetch, the same algorithm
//      browsers use), comes back as application/json, and its animation_url decodes to the packed page;
//   2. why: `;utf8` is not an RFC 2397 parameter (those are attribute=value), and the WHATWG MIME parser
//      drops it, so the media type is plain application/json; the raw form's real hazard, a '#' (fragment)
//      or '%XX' (percent-decoding) in the text, is what the packer refuses;
//   3. (network) a mainnet collection OpenSea renders today answers the same 27-byte prefix: Pandora
//      (ERC-404, 0x9E9F…0413) returns `data:application/json;utf8,{"name": "Pandora #1",…` with a Color
//      trait and no hosted baseTokenURI, and opensea.io/item/ethereum/0x9e9f…0413/1 shows that name and
//      trait. OpenSea's own contract-level-metadata page and ERC-7572 (written at OpenSea) use `;utf8,`.
// Re-checked 10 October 2026 (second skeptic round): the OpenSea item page, opened in a browser, lists the
// trait "COLOR Purple, 1,943, 20%" under Traits; with baseTokenURI empty that value can only have been
// read from the `;utf8,` data URI (the name alone would not prove it: "<Collection> #<id>" is also
// OpenSea's fallback name when metadata fails). docs.opensea.io/docs/metadata-storage names only the
// base64 form and never says "utf8"; docs.opensea.io/docs/contract-level-metadata and EIP-7572 (Finzer,
// Atallah, Ghods) both write `string.concat("data:application/json;utf8,", json)`. Neither OpenSea page
// mentions a size limit, an iframe or a sandbox; media-and-traits says an animation_url "can also point
// to an HTML page" with scripts supported. What is still not shown anywhere: THIS token, ~897 KB, on a
// real marketplace; that is checklists/1-pre-deploy.md ("written confirmation", "Marketplaces on a testnet").
// Run from contracts/: node test/poc/utf8-datauri.mjs   (RPC=<url> picks the node, NO_NETWORK=1 skips 3)
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MIMEType } from 'node:util';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const sha256 = (d) => '0x' + createHash('sha256').update(d).digest('hex');
const SCHEME = 'data:application/json;utf8,'; // 27 bytes, KilimOneOfOne.SCHEME
const HEX_CHARS = 65_536;

const pageDir = process.env.KILIM_PAGE_STORE || here('../../../onchain/build-page');
const gridsFile = process.env.KILIM_GLYPH_STORE
  ? join(process.env.KILIM_GLYPH_STORE, 'grids.bin') : here('../../../onchain/build-glyphs/grids.bin');
const manifest = JSON.parse(readFileSync(join(pageDir, 'manifest.json'), 'utf8'));
const grids = readFileSync(gridsFile);
assert.equal(manifest.grids.sha256, sha256(grids), 'the page store was packed against other grids');
const read = (n) => readFileSync(join(pageDir, n));
const prefix = read('prefix.bin'); const head = read('head.bin'); const tail = read('tail.bin');

// 1. The answer, assembled the way the contract does it, checked against the packer's golden.
const pad = (3 - (head.length + HEX_CHARS + 1) % 3) % 3;
const piece = Buffer.concat([head, Buffer.from(grids.toString('hex'), 'ascii'), Buffer.from("'"), Buffer.alloc(pad, 0x20)]);
const encoded = piece.toString('base64');
const tokenURI = SCHEME + prefix.toString('utf8') + encoded + tail.toString('ascii') + '"}';
assert.equal(sha256(Buffer.from(tokenURI, 'utf8')), manifest.golden.tokenURI.sha256, 'assembled tokenURI differs from the golden');
console.log(`tokenURI: ${Buffer.byteLength(tokenURI)} bytes, sha256 matches the packer golden ${manifest.golden.tokenURI.sha256}`);

const res = await fetch(tokenURI); // undici: the WHATWG "data: URL processor"
assert.equal(res.status, 200);
const type = res.headers.get('content-type');
assert.ok(type.startsWith('application/json'), `content-type is ${type}`);
const meta = await res.json();
assert.equal(meta.name, manifest.name);
assert.equal(meta.description, manifest.description);
assert.ok(meta.image.startsWith('data:image/png;base64,'));
assert.equal(sha256(Buffer.from(meta.animation_url, 'ascii')), manifest.golden.animationUrl.sha256);
const art = await fetch(meta.animation_url);
const page = Buffer.from(await art.arrayBuffer());
assert.equal(sha256(page), manifest.golden.page.sha256, 'animation_url does not decode to the packed page');
console.log(`fetch(tokenURI): content-type ${type}; name ${JSON.stringify(meta.name)}; image ${meta.image.slice(0, 22)}…;`
  + ` animation_url ${meta.animation_url.length} chars -> fetch(): ${art.headers.get('content-type')}, ${page.length} bytes = animation.html`);

// 2. Why parsers take it: the MIME parser skips a parameter with no '='; the body must carry no '#' or '%'.
const mime = new MIMEType('application/json;utf8');
assert.equal(mime.essence, 'application/json');
assert.equal([...mime.params].length, 0);
console.log(`MIMEType('application/json;utf8'): essence ${mime.essence}, params ${[...mime.params].length} (";utf8" is dropped, not an attribute=value)`);
const url = new URL(tokenURI);
assert.equal(url.hash, '');
assert.ok(!prefix.includes('#') && !prefix.includes('%'), "PREFIX carries '#' or '%' raw in the URL");
assert.ok(!tokenURI.includes('#') && !tokenURI.includes('%'));
console.log(`new URL(tokenURI): no fragment, no '#' or '%' anywhere in ${tokenURI.length} chars (pack_page.py refuses them in the texts)`);

// 3. The same prefix from a collection OpenSea renders today.
if (!process.env.NO_NETWORK) {
  const rpc = process.env.RPC || 'https://ethereum-rpc.publicnode.com';
  const PANDORA = '0x9E9FbDE7C7a83c43913BddC8779158F1368F0413';
  const call = async (data) => {
    const r = await fetch(rpc, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: PANDORA, data }, 'latest'] }),
    }).then((x) => x.json());
    if (r.error) throw new Error('eth_call failed: ' + JSON.stringify(r.error));
    const h = r.result.slice(2);
    const len = parseInt(h.slice(64, 128), 16);
    return Buffer.from(h.slice(128, 128 + len * 2), 'hex').toString('utf8');
  };
  const theirs = await call('0xc87b56dd' + '1'.padStart(64, '0')); // tokenURI(1)
  const base = await call('0xd547cfb7'); // baseTokenURI(): empty, so the data URI is what every indexer reads
  assert.equal(base, '');
  assert.equal(theirs.slice(0, SCHEME.length), SCHEME);
  assert.equal(tokenURI.slice(0, SCHEME.length), SCHEME);
  // What a comma-splitting indexer reads (Zora's offchain adapter does this): the raw body as JSON.
  const lenient = JSON.parse(theirs.slice(SCHEME.length));
  // What the strict WHATWG processor reads: Pandora's own text holds '#' ("Pandora #1"), which starts a
  // fragment, so fetch() cuts the body there and the JSON fails. OpenSea renders the token regardless.
  let strict;
  try { strict = JSON.stringify(await (await fetch(theirs)).json()); } catch (e) { strict = 'fails: ' + e.message; }
  console.log(`Pandora #1 (mainnet ${PANDORA}, baseTokenURI empty): the same ${SCHEME.length}-byte prefix ${JSON.stringify(SCHEME)};`
    + ` body as JSON: name ${JSON.stringify(lenient.name)}, attributes ${JSON.stringify(lenient.attributes)}; WHATWG fetch() ${strict}`);
  console.log('OpenSea shows that name and trait: https://opensea.io/item/ethereum/0x9e9fbde7c7a83c43913bddc8779158f1368f0413/1');
  console.log("The 1/1 holds no '#', so it reads the same on both paths; Pandora reads only on the lenient one and still renders.");
}
console.log('ok');
