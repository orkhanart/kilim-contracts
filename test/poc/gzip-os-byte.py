#!/usr/bin/env python3
"""Skeptic PoC (packers lens): the gzip header the 1/1 packer writes must not depend on the Python
that runs it.

Before 3.11, gzip.compress(data, 9, mtime=0) wrote the gzip OS byte as 0xFF itself; from 3.11 it
delegates to zlib.compress(wbits=31), and zlib writes the platform's OS code (19 on macOS, 3 on
Linux). The deflate body is the same; one header byte differs, which is enough to change TAIL,
tailHash and golden.tokenURI.sha256, so a repack on another Python fails `pack_page.py --check`
against a store packed elsewhere. pack_page.gzip_bytes writes the header itself (…02ff) so every
Python packs the same bytes; this script shows both behaviours side by side on the interpreter
that runs it. Run it under each Python you have, e.g.

    for py in /usr/bin/python3 python3.11 python3.12; do $py -I contracts/test/poc/gzip-os-byte.py; done

Exit 0 when the packer's output is the fixed header and matches the existing onchain/build-page
(when that store exists); 1 otherwise. Reads only; writes nothing.
"""
import gzip
import json
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'onchain'))
import pack_page as P  # noqa: E402

FIXTURES = ROOT / 'onchain/test/fixtures'
STORE = ROOT / 'onchain/build-page'
GRIDS = ROOT / 'onchain/build-motifs/grids.bin'
FIXED_HEADER = b'\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff'


def main():
    artwork = (FIXTURES / 'lean.html').read_bytes()
    still = (FIXTURES / 'still-placeholder.png').read_bytes()
    grids = GRIDS.read_bytes() if GRIDS.exists() else bytes(range(256)) * 128
    ver = sys.version.split()[0]
    print('python %s (%s), zlib %s / runtime %s' % (ver, sys.executable, zlib.ZLIB_VERSION, zlib.ZLIB_RUNTIME_VERSION))

    module = gzip.compress(artwork, P.GZIP_LEVEL, mtime=0)      # what pack_page did before the fix
    packer = P.gzip_bytes(artwork)                               # what it does now
    print('gzip.compress(mtime=0) header  %s   OS byte %d' % (module[:10].hex(), module[9]))
    print('pack_page.gzip_bytes   header  %s   OS byte %d' % (packer[:10].hex(), packer[9]))
    print('deflate body and trailer identical: %s; both gunzip to the artwork: %s' % (
        module[10:] == packer[10:], gzip.decompress(module) == artwork and gzip.decompress(packer) == artwork))

    ok = packer[:10] == FIXED_HEADER
    name, desc = 'The Unwoven Kilim', 'A generative ASCII carpet drawn from the 1,024 Kilim motifs.'
    fixed = json.loads(P.build(artwork, still, grids, name, desc, artwork_name='lean.html',
                               still_name='still-placeholder.png')['manifest.json'])
    print('packer tailHash %s golden %s' % (fixed['hashes']['tailHash'], fixed['golden']['tokenURI']['sha256']))
    if module[:10] != packer[:10]:
        keep = P.gzip_bytes
        P.gzip_bytes = lambda d: gzip.compress(d, P.GZIP_LEVEL, mtime=0)
        old = json.loads(P.build(artwork, still, grids, name, desc, artwork_name='lean.html',
                                 still_name='still-placeholder.png')['manifest.json'])
        P.gzip_bytes = keep
        print('with the gzip module instead: tailHash %s golden %s  <- this Python would have packed these' % (
            old['hashes']['tailHash'], old['golden']['tokenURI']['sha256']))

    if STORE.exists() and GRIDS.exists():
        existing = json.loads((STORE / 'manifest.json').read_text())
        if existing['artwork']['sha256'] == fixed['artwork']['sha256'] and existing['still']['sha256'] == fixed['still']['sha256']:
            same = existing['hashes']['tailHash'] == fixed['hashes']['tailHash']
            print('onchain/build-page tailHash %s: %s' % (existing['hashes']['tailHash'], 'same' if same else 'DIFFERS'))
            ok = ok and same
        else:
            print('onchain/build-page was packed from other inputs; not compared')
    print('RESULT: %s' % ('fixed header, reproducible on this Python' if ok else 'NOT reproducible'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
