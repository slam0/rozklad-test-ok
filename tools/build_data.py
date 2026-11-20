#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Dzieli duży plik GTFS (warsaw.zip) na małe pliki, które telefon może pobrać
pojedynczo ze strony na GitHub Pages:

  index.json              lista przystanków (do wyszukiwania na stronie)
  d/<v>/svc.json          kalendarze kursowania (wspólne dla wszystkich słupków)
  d/<v>/s/<numer>.json    odjazdy z jednego słupka

Użycie:  python3 build_data.py plik.zip [plik2.zip ...] katalog_wyjsciowy [--generic]
(--generic: przystanki grupowane wg parent_station albo nazwy i położenia,
 dla feedów innych niż warszawski; kilka plików zip = jedno miasto, np. autobusy i tramwaje osobno)
Format plików jest opisany w README (sekcja "Strona z danymi").
"""
import csv
import io
import json
import os
import shutil
import sys
import unicodedata
import zipfile
from array import array
from datetime import datetime, timezone

KB = {'b': 1, 't': 2, 'p': 4, 'm': 8}
DAYS = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday']


def kind(route_type):
    """route_type z GTFS -> b/t/p/m (tak samo jak w generatorze)."""
    try:
        v = int(route_type)
    except (TypeError, ValueError):
        return 'b'
    if v in (1, 12) or 400 <= v < 500:
        return 'm'
    if v in (0, 5) or 900 <= v < 1000:
        return 't'
    if v == 2 or 100 <= v < 200 or 300 <= v < 400:
        return 'p'
    return 'b'


def norm(s):
    s = s.lower().replace('ł', 'l')
    s = unicodedata.normalize('NFD', s)
    return ''.join(c for c in s if not unicodedata.combining(c))


def is6(sid):
    return len(sid) == 6 and sid.isdigit()


def pole_code(stop_id, stop_code):
    if stop_code:
        return stop_code
    return stop_id[4:] if is6(stop_id) else stop_id


def rows(z, name):
    """Czyta plik CSV z zipa i zwraca (słownik nazw kolumn, iterator wierszy)."""
    try:
        raw = z.open(name)
    except KeyError:
        return None, iter(())
    rd = csv.reader(io.TextIOWrapper(raw, encoding='utf-8-sig', newline=''))
    try:
        head = next(rd)
    except StopIteration:
        return {}, iter(())
    return {h.strip(): i for i, h in enumerate(head)}, rd


def minutes(t):
    if not t:
        return None
    p = t.strip().split(':')
    try:
        return int(p[0]) * 60 + int(p[1])
    except (ValueError, IndexError):
        return None


def open_zips(paths):
    """Lista (prefiks, ZipFile). Przy kilku plikach identyfikatory dostają prefiks "0:", "1:"...,
    żeby autobusy i tramwaje z osobnych plików nie zlały się ze sobą."""
    if isinstance(paths, (str, bytes, os.PathLike)):
        paths = [paths]
    paths = list(paths)
    return [(('%d:' % i if len(paths) > 1 else ''), zipfile.ZipFile(p)) for i, p in enumerate(paths)]


def num_key(v):
    try:
        return '%.2f,%.2f' % (float(v[0]), float(v[1]))
    except (TypeError, ValueError, IndexError):
        return ''


def build(zip_path, out_dir, now=None, log=print, generic=False):
    now = now or datetime.now(timezone.utc)
    version = now.strftime('%Y%m%d%H%M')
    zs = open_zips(zip_path)

    # --- przystanki -> grupy ----------------------------------------------
    # Warszawa: nazwa + pierwsze 4 cyfry numeru. generic: parent_station albo nazwa + okolica (~1 km).
    groups = {}      # klucz -> grupa
    order = []
    pole_of = {}     # stop_id -> słupek
    for pre, z in zs:
        H, rd = rows(z, 'stops.txt')
        allrows = [x for x in rd if x]
        def col(x, name):
            return x[H[name]].strip() if name in H and H[name] < len(x) else ''
        station = {}
        if generic:
            for x in allrows:
                if col(x, 'location_type') == '1':
                    station[pre + col(x, 'stop_id')] = x
        for x in allrows:
            sid = col(x, 'stop_id')
            nm = col(x, 'stop_name')
            if not sid or not nm:
                continue
            lat, lon = col(x, 'stop_lat'), col(x, 'stop_lon')
            if generic:
                if col(x, 'location_type') not in ('', '0'):
                    continue
                par = pre + col(x, 'parent_station')
                if col(x, 'parent_station') and par in station:
                    st = station[par]
                    gk = 'P|' + par
                    gname = col(st, 'stop_name') or nm
                    glat, glon = col(st, 'stop_lat') or lat, col(st, 'stop_lon') or lon
                else:
                    gk = nm + '|' + num_key((lat, lon))
                    gname, glat, glon = nm, lat, lon
                code = col(x, 'stop_code') or col(x, 'platform_code') or (sid if len(sid) <= 8 else '')
            else:
                gk = nm + '|' + sid[:4] if is6(sid) else nm
                gname, glat, glon = nm, lat, lon
                code = pole_code(sid, col(x, 'stop_code'))
            g = groups.get(gk)
            if g is None:
                g = groups[gk] = {'n': gname, 'lat': glat, 'lon': glon, 'poles': []}
                order.append(g)
            p = {'id': pre + sid, 'c': code, 'm': 0, 'data': {}}
            g['poles'].append(p)
            pole_of[pre + sid] = p
    if not order:
        raise SystemExit('W pliku nie ma przystanków (stops.txt) - to na pewno GTFS?')
    log('przystanki: %d grup, %d słupków' % (len(order), len(pole_of)))

    # --- trasy, kursy ------------------------------------------------------
    route = {}
    rtypes = {}
    for pre, z in zs:
        H, rd = rows(z, 'routes.txt')
        for x in rd:
            if not x:
                continue
            rtypes[x[H['route_type']]] = rtypes.get(x[H['route_type']], 0) + 1
            rid = pre + x[H['route_id']]
            short = x[H['route_short_name']] if 'route_short_name' in H else ''
            if not short and 'route_long_name' in H:
                short = x[H['route_long_name']]
            route[rid] = (short or rid, kind(x[H['route_type']]))
    log('linie wg route_type: ' + ', '.join('%s=%d(%s)' % (k, v, kind(k)) for k, v in sorted(rtypes.items())))

    services = []        # lista kalendarzy
    sidx = {}
    tg_list = []         # (linia, kierunek, numer kalendarza, rodzaj)
    tg_idx = {}
    trip_tg = {}
    for pre, z in zs:
        H, rd = rows(z, 'trips.txt')
        for x in rd:
            if not x:
                continue
            r = route.get(pre + x[H['route_id']])
            if r is None:
                continue
            sv = pre + x[H['service_id']]
            if sv not in sidx:
                sidx[sv] = len(services)
                services.append({'d': [0] * 7, 's': '', 'e': '', 'a': [], 'r': []})
            head = x[H['trip_headsign']] if 'trip_headsign' in H else ''
            key = (r[0], head, sidx[sv], r[1])
            i = tg_idx.get(key)
            if i is None:
                i = tg_idx[key] = len(tg_list)
                tg_list.append(key)
            trip_tg[pre + x[H['trip_id']]] = i
    log('kursy: %d, odmian: %d, kalendarzy: %d' % (len(trip_tg), len(tg_list), len(services)))

    # --- kalendarze --------------------------------------------------------
    end = ''
    for pre, z in zs:
        H, rd = rows(z, 'calendar.txt')
        for x in rd:
            if not x:
                continue
            k = sidx.get(pre + x[H['service_id']])
            if k is None:
                continue
            s_ = services[k]
            s_['d'] = [int(x[H[d]]) for d in DAYS]
            s_['s'] = x[H['start_date']]
            s_['e'] = x[H['end_date']]
            if s_['e'] > end:
                end = s_['e']
        H, rd = rows(z, 'calendar_dates.txt')
        for x in rd:
            if not x:
                continue
            k = sidx.get(pre + x[H['service_id']])
            if k is None:
                continue
            d = x[H['date']]
            add = x[H['exception_type']] == '1'
            services[k]['a' if add else 'r'].append(d)
            if add and d > end:
                end = d

    # --- godziny odjazdów --------------------------------------------------
    n = 0
    for pre, z in zs:
        H, rd = rows(z, 'stop_times.txt')
        it, is_, dt, at = H['trip_id'], H['stop_id'], H.get('departure_time'), H.get('arrival_time')
        for x in rd:
            pole = pole_of.get(pre + x[is_])
            if pole is None:
                continue
            tg = trip_tg.get(pre + x[it])
            if tg is None:
                continue
            m = minutes(x[dt]) if dt is not None else None
            if m is None and at is not None:
                m = minutes(x[at])
            if m is None:
                continue
            arr = pole['data'].get(tg)
            if arr is None:
                arr = pole['data'][tg] = array('i')
            arr.append(m)
            pole['m'] |= KB[tg_list[tg][3]]
            n += 1
    log('odjazdów: %d' % n)

    # --- zapis -------------------------------------------------------------
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    ddir = os.path.join(out_dir, 'd', version)
    sdir = os.path.join(ddir, 's')
    os.makedirs(sdir)

    def dump(path, obj):
        with open(path, 'w', encoding='ascii') as f:
            json.dump(obj, f, ensure_ascii=True, separators=(',', ':'))

    gen = now.strftime('%Y-%m-%d')
    dump(os.path.join(ddir, 'svc.json'), {'gen': gen, 'end': end, 'svc': services})

    index = []
    num = 0
    order = [g for g in order if any(p['m'] for p in g['poles'])]
    order.sort(key=lambda g: (norm(g['n']), g['n']))
    for g in order:
        poles = []
        gm = 0
        for p in sorted(g['poles'], key=lambda p: p['c']):
            if not p['m']:
                continue
            groups_out = []
            for tg in sorted(p['data'], key=lambda t: (tg_list[t][3], tg_list[t][0], tg_list[t][1], tg_list[t][2])):
                line, head, sv, kd = tg_list[tg]
                groups_out.append([line, head, sv, kd, sorted(set(p['data'][tg]))])
            dump(os.path.join(sdir, '%d.json' % num), {'n': g['n'], 'c': p['c'], 'g': groups_out})
            poles.append([num, p['c'], p['m']])
            gm |= p['m']
            num += 1
        k = norm(g['n'])
        index.append([g['n'], '' if k == g['n'].lower() else k, gm, g['lat'][:8], g['lon'][:8], poles])
    dump(os.path.join(out_dir, 'index.json'), {'v': version, 'gen': gen, 'end': end, 'g': index})
    log('zapisano: %d przystanków, %d słupków, wersja %s' % (len(index), num, version))
    log('przystanki wg rodzaju: ' + ', '.join('%s=%d' % (n, sum(1 for g in index if g[2] & b))
                                              for n, b in (('autobus', 1), ('tramwaj', 2), ('pociąg', 4), ('metro', 8))))
    return version


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != '--generic']
    if len(args) < 2:
        sys.exit('Użycie: build_data.py plik.zip [plik2.zip ...] katalog_wyjsciowy [--generic]')
    build(args[:-1], args[-1], generic='--generic' in sys.argv)
