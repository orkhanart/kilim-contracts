#!/usr/bin/env python3
"""Review PoC (packers finding, skeptic): the deploy script never reads the manifests' record of the
artist's file. This writes copies of onchain/build-glyphs and onchain/build-page whose manifests have
no `source` / `artwork` / `still` / `loaderTemplate` entries at all; every chunk, hash, address and
golden is byte for byte the real store's. DeployIgnoresSourceHash.t.sol then deploys both phases from
these copies. If the script consulted those keys, parseJson would revert on the missing path.

    python3 contracts/test/poc/stale-source-store.py

Writes onchain/test/fixtures/poc-stale-source/{glyphs,page}/. Also prints the measurement behind the
finding: the sha256 the glyph manifest recorded for the artist's page against the page on disk, and
whether a fresh pack of that page gives the same grids.bin and names.bin.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'onchain'))
from pack_glyphs import build as build_glyphs  # noqa: E402

OUT = ROOT / 'onchain' / 'test' / 'fixtures' / 'poc-stale-source'
ARTIST_PAGE = ROOT / 'research' / 'motifs' / 'curate' / 'living-language-v3' / 'index.html'


def copy_store(src, dst, drop):
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    manifest = json.loads((dst / 'manifest.json').read_text())
    for key in drop:
        manifest.pop(key, None)
    manifest['handEdited'] = 'review PoC: the file-of-origin records were removed; nothing else changed'
    (dst / 'manifest.json').write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')
    return manifest


def main():
    glyphs = copy_store(ROOT / 'onchain' / 'build-glyphs', OUT / 'glyphs', ('source',))
    page = copy_store(ROOT / 'onchain' / 'build-page', OUT / 'page', ('artwork', 'still', 'loaderTemplate'))
    assert 'source' not in glyphs and 'artwork' not in page
    print('wrote %s: glyph manifest without .source, page manifest without .artwork/.still/.loaderTemplate'
          % OUT.relative_to(ROOT))

    # The measurement: what the real glyph manifest recorded against the artist's page on disk.
    real = json.loads((ROOT / 'onchain' / 'build-glyphs' / 'manifest.json').read_text())
    recorded = real['source']
    if ARTIST_PAGE.is_file():
        html = ARTIST_PAGE.read_bytes()
        actual = '0x' + hashlib.sha256(html).hexdigest()
        print('recorded source.sha256 %s (%d bytes)' % (recorded['sha256'], recorded['size']))
        print('on-disk page sha256    %s (%d bytes)' % (actual, len(html)))
        fresh = build_glyphs(html, real['description'], ARTIST_PAGE.name)
        same = all(fresh[f] == (ROOT / 'onchain' / 'build-glyphs' / f).read_bytes()
                   for f in ('grids.bin', 'names.bin'))
        print('fresh pack of the on-disk page gives the same grids.bin and names.bin: %s' % same)
        print('source record matches the page on disk: %s' % (actual == recorded['sha256']))
    else:
        print('artist page not present at %s; measurement skipped' % ARTIST_PAGE.relative_to(ROOT))


if __name__ == '__main__':
    main()
