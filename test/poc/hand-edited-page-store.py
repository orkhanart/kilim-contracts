#!/usr/bin/env python3
"""Review PoC (oneofone finding, skeptic): a page store whose PREFIX carries '#' and '%', with a manifest
that is self-consistent, as a hand edit of onchain/build-page would leave it.

    python3 contracts/test/poc/hand-edited-page-store.py

Writes onchain/test/fixtures/poc-hash-in-prefix/ (prefix.bin, head.bin, tail.bin, chunks/, manifest.json)
from the synthetic artwork, the placeholder still and the real grids. pack_page.data_url_text refuses the
texts "Kilim #1" and "100% on-chain", so the prefix here is written the way the committed packer wrote it
(json_escape only) and every hash, address and golden is recomputed from those bytes. The forge test
DeployAcceptsHashInPrefix.t.sol then points pageStore at this directory.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'onchain'))
import pack_page as P  # noqa: E402
from pack_glyphs import CHUNK, chunk_records, json_escape, keccak256, hex32, sha256_hex, write_outputs  # noqa: E402

OUT = ROOT / 'onchain' / 'test' / 'fixtures' / 'poc-hash-in-prefix'
NAME, DESCRIPTION, EXTERNAL_URL = 'Kilim #1', '100% on-chain', ''


def main():
    art = (ROOT / 'onchain' / 'test' / 'fixtures' / 'synthetic-artwork.html').read_bytes()
    still = (ROOT / 'onchain' / 'test' / 'fixtures' / 'still-placeholder.png').read_bytes()
    grids = (ROOT / 'onchain' / 'build-glyphs' / 'grids.bin').read_bytes()

    # A clean build gives HEAD, TAIL and the manifest skeleton; the hand edit replaces PREFIX.
    clean = P.build(art, still, grids, 'n', 'd', EXTERNAL_URL)
    manifest = json.loads(clean['manifest.json'])
    head, tail = clean['head.bin'], clean['tail.bin']

    import base64
    prefix = ('{"name":"%s","description":"%s","image":"data:image/png;base64,%s","animation_url":"data:text/html;base64,'
              % (json_escape(NAME), json_escape(DESCRIPTION), base64.b64encode(still).decode('ascii'))).encode('utf-8')
    assert b'#' in prefix and b'%' in prefix
    pieces, records = chunk_records(prefix, 'prefix', CHUNK)
    uri = P.token_uri(prefix, head, tail, grids)
    animation_url = P.animation_url_of(uri, prefix)

    manifest['name'], manifest['description'], manifest['externalUrl'] = NAME, DESCRIPTION, EXTERNAL_URL
    manifest['sections']['prefix'] = {'file': 'prefix.bin', 'size': len(prefix), 'keccak': hex32(keccak256(prefix)),
                                      'sha256': sha256_hex(prefix), 'chunks': records}
    manifest['hashes']['prefixHash'] = manifest['sections']['prefix']['keccak']
    manifest['golden']['tokenURI'] = {'sha256': sha256_hex(uri), 'bytes': len(uri)}
    manifest['golden']['animationUrl'] = {'sha256': sha256_hex(animation_url), 'bytes': len(animation_url)}
    manifest['handEdited'] = 'review PoC: PREFIX holds # and %, every hash recomputed from the edited bytes'

    out = {'prefix.bin': prefix, 'head.bin': head, 'tail.bin': tail,
           'manifest.json': (json.dumps(manifest, indent=1, sort_keys=True) + '\n').encode('utf-8')}
    for rec, piece in zip(records, pieces):
        out[rec['file']] = piece
    for rel, data in clean.items():
        if rel.startswith('chunks/head') or rel.startswith('chunks/tail'):
            out[rel] = data
    write_outputs(OUT, out)
    print('wrote %s: prefix %d bytes (# at %d, %% at %d), tokenURI sha256 %s'
          % (OUT.relative_to(ROOT), len(prefix), prefix.index(b'#'), prefix.index(b'%'), manifest['golden']['tokenURI']['sha256']))


if __name__ == '__main__':
    main()
