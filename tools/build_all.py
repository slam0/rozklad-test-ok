#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Buduje dane wszystkich miast z tools/miasta.json do katalogu strony:

  <out>/miasta.json          lista miast dla aplikacji (nazwa, kraj, wersja danych, rodzaje, źródło)
  <out>/index.json, d/...    Warszawa (w katalogu głównym, tak jak w starszych wersjach aplikacji)
  <out>/<id>/index.json ...  pozostałe miasta, każde w swoim folderze

Użycie:  python3 build_all.py miasta.json katalog_wyjsciowy [katalog_roboczy]
Miasto z "required": true musi się udać, z pozostałych błędnego pomijamy (strona i tak się zbuduje).
"""
import json
import os
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_data

UA = 'Rozklad-iOS6 (GitHub Actions)'
MAX_ZIP = 400 * 1024 * 1024     # bezpiecznik: większego pliku nie bierzemy


def fetch(src, dest, tries=4, log=print):
    """Pobiera src (adres http/https albo ścieżkę pliku) do dest. True gdy się udało."""
    if not src.startswith(('http://', 'https://')):
        try:
            shutil.copyfile(src, dest)
            return True
        except OSError as e:
            log('  nie ma pliku: %s' % e)
            return False
    for i in range(tries):
        try:
            req = urllib.request.Request(src, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=120) as r, open(dest, 'wb') as f:
                n = 0
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    n += len(b)
                    if n > MAX_ZIP:
                        raise IOError('plik za duży')
                    f.write(b)
            return True
        except Exception as e:      # sieć bywa kapryśna
            log('  próba %d/%d nieudana: %s' % (i + 1, tries, e))
            time.sleep(5 * (i + 1) if not src.startswith('file') else 0)
    return False


def pick_newest(urls, today=None):
    """Z adresów plików z datą w nazwie (GTFS_2025_12_01.zip) wybiera ostatni, który już obowiązuje.
    Gdy żaden jeszcze nie obowiązuje, bierze najstarszy z przyszłych."""
    today = today or datetime.now(timezone.utc).strftime('%Y%m%d')
    dated = []
    for u in urls:
        m = re.search(r'(20\d\d)[_.-]?(\d\d)[_.-]?(\d\d)', os.path.basename(urllib.parse.urlparse(u).path))
        if m:
            dated.append((''.join(m.groups()), u))
    if not dated:
        return None
    dated.sort()
    started = [d for d in dated if d[0] <= today]
    return (started[-1] if started else dated[0])[1]


def resolve_listing(spec, log=print):
    """Strona z listą plików z datami w nazwach (bez stałego adresu): znajduje adres najnowszego pliku."""
    page = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'rozklad-listing.html')
    if not fetch(spec['listing'], page, log=log):
        return None
    with open(page, encoding='utf-8', errors='replace') as f:
        html = f.read()
    rx = re.compile(spec.get('match', r'\.zip'), re.I)
    urls = [urllib.parse.urljoin(spec['listing'], h) for h in re.findall(r'href=["\']([^"\']+)["\']', html, re.I)]
    urls = [u for u in urls if rx.search(u) and u.lower().split('?')[0].endswith('.zip')]
    best = pick_newest(urls)
    log('  na liście %d plików, wybrano: %s' % (len(urls), best))
    return best


def copy_into(src_dir, dst_dir):
    for root, _, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        target = dst_dir if rel == '.' else os.path.join(dst_dir, rel)
        os.makedirs(target, exist_ok=True)
        for f in files:
            shutil.copyfile(os.path.join(root, f), os.path.join(target, f))


def main(cfg_path, out_dir, work_dir=None, log=print):
    with open(cfg_path, encoding='utf-8') as f:
        cities = json.load(f)
    base = os.path.dirname(os.path.dirname(os.path.abspath(cfg_path)))    # korzeń repozytorium (dla "fallback")
    work_dir = work_dir or os.path.join(out_dir + '_work')
    os.makedirs(work_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)
    listing = []
    for c in cities:
        cid = c['id']
        log('== %s' % c['n'])
        zips = []
        ok = True
        for i, src in enumerate(c['src']):
            if isinstance(src, dict):           # {"listing": adres strony, "match": wyrażenie}
                src = resolve_listing(src, log=log)
                if not src:
                    ok = False
                    break
            dest = os.path.join(work_dir, '%s-%d.zip' % (cid, i))
            if not fetch(src, dest, log=log):
                fb = c.get('fallback')
                fb = os.path.join(base, fb) if fb else None
                if fb and os.path.isfile(fb):
                    log('  używam pliku zapasowego %s' % c['fallback'])
                    shutil.copyfile(fb, dest)
                else:
                    ok = False
                    break
            zips.append(dest)
        try:
            if not ok:
                raise RuntimeError('nie udało się pobrać danych')
            tmp = os.path.join(work_dir, 'out-' + cid)
            if os.path.isdir(tmp):
                shutil.rmtree(tmp)
            build_data.build(zips, tmp, generic=bool(c.get('generic', True)), log=log)
        except (Exception, SystemExit) as e:
            if c.get('required'):
                raise SystemExit('Miasto %s jest wymagane, a się nie udało: %s' % (c['n'], e))
            log('  POMIJAM %s: %s' % (c['n'], e))
            continue
        with open(os.path.join(tmp, 'index.json'), encoding='utf-8') as f:
            idx = json.load(f)
        mask = 0
        for g in idx['g']:
            mask |= g[2]
        dest_dir = out_dir if c.get('root') else os.path.join(out_dir, cid)
        copy_into(tmp, dest_dir)
        listing.append({'id': cid, 'n': c['n'], 'k': c['k'], 'u': '' if c.get('root') else cid + '/',
                        'v': idx['v'], 'end': idx['end'], 'm': mask, 's': len(idx['g']), 'a': c.get('attr', '')})
        shutil.rmtree(tmp)
    with open(os.path.join(out_dir, 'miasta.json'), 'w', encoding='utf-8') as f:
        json.dump({'gen': datetime.now(timezone.utc).strftime('%Y-%m-%d'), 'c': listing}, f,
                  ensure_ascii=False, separators=(',', ':'))
    log('miasta: %s' % ', '.join(x['n'] for x in listing))
    return listing


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit('Użycie: build_all.py miasta.json katalog_wyjsciowy [katalog_roboczy]')
    main(*sys.argv[1:4])
