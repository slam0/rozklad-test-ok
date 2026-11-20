# -*- coding: utf-8 -*-
"""Tryb --generic i kilka plików zip na jedno miasto (np. Kraków: autobusy + tramwaje, Boston)."""
import json, os, sys, tempfile, zipfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import build_data


def mk(path, stops, routes, trips, times, cal='S,1,1,1,1,1,1,1,20261101,20261231\n'):
    files = {
        'stops.txt': 'stop_id,stop_code,stop_name,stop_lat,stop_lon,location_type,parent_station,platform_code\n' + stops,
        'routes.txt': 'route_id,route_short_name,route_long_name,route_type\n' + routes,
        'trips.txt': 'route_id,service_id,trip_id,trip_headsign\n' + trips,
        'stop_times.txt': 'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n' + times,
        'calendar.txt': 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n' + cal,
    }
    with zipfile.ZipFile(path, 'w') as z:
        for k, v in files.items():
            z.writestr(k, v.encode('utf-8'))


class Generic(unittest.TestCase):
    def build(self, zips, generic=True):
        d = tempfile.mkdtemp()
        out = os.path.join(d, 'out')
        build_data.build(zips, out, log=lambda *a: None, generic=generic)
        with open(os.path.join(out, 'index.json')) as f:
            return out, json.load(f)

    def test_parent_station_i_sloupki(self):
        d = tempfile.mkdtemp()
        z = os.path.join(d, 'a.zip')
        mk(z,
           'place-pktrm,,Park Street,42.3564,-71.0624,1,,\n'
           'p1,,Park Street,42.3564,-71.0625,0,place-pktrm,Red\n'
           'p2,,Park Street,42.3565,-71.0624,0,place-pktrm,Green\n'
           'b1,,Park Street,42.3564,-71.0625,4,p1,\n'            # strefa wejścia: pomijana
           '77,,Main St,42.40,-71.10,0,,\n'
           '78,,Main St,42.40,-71.10,0,,\n'                      # ta sama nazwa i miejsce: jedna grupa
           '79,,Main St,43.50,-72.20,0,,\n',                     # ta sama nazwa, daleko: osobna grupa
           'R1,Red,Red Line,1\nR2,66,Bus 66,3\n',
           'R1,S,T1,Alewife\nR2,S,T2,Harvard\n',
           'T1,08:00:00,08:00:00,p1,1\nT1,08:10:00,08:10:00,p2,2\nT2,09:00:00,09:00:00,77,1\nT2,09:05:00,09:05:00,79,2\n')
        out, idx = self.build([z])
        names = [g[0] for g in idx['g']]
        self.assertEqual(sorted(names), ['Main St', 'Main St', 'Park Street'])
        park = [g for g in idx['g'] if g[0] == 'Park Street'][0]
        self.assertEqual(len(park[5]), 2)                       # dwa słupki (p1 i p2), bez b1
        self.assertEqual(park[2], 8)                            # tylko metro
        codes = sorted(p[1] for p in park[5])
        self.assertEqual(codes, ['Green', 'Red'])               # platform_code jako numer słupka
        mains = [g for g in idx['g'] if g[0] == 'Main St']
        self.assertEqual(sorted(len(g[5]) for g in mains), [1, 1])   # 77 miał kursy, 78 nie, 79 w innym miejscu

    def test_dwa_pliki_jedno_miasto(self):
        d = tempfile.mkdtemp()
        a, t = os.path.join(d, 'a.zip'), os.path.join(d, 't.zip')
        mk(a, 's1,01,Rynek,50.06,19.94,0,,\n', 'R1,144,x,3\n', 'R1,S,T1,Prądnik\n', 'T1,10:00:00,10:00:00,s1,1\n')
        # w tramwajach te same identyfikatory (s1, R1, S, T1) oznaczają coś innego
        mk(t, 's1,01,Rynek,50.06,19.94,0,,\n', 'R1,18,x,0\n', 'R1,S,T1,Czyżyny\n', 'T1,11:00:00,11:00:00,s1,1\n',
           cal='S,0,0,0,0,0,1,1,20261101,20261231\n')
        out, idx = self.build([a, t])
        g = idx['g']
        self.assertEqual(len(g), 1)                             # jeden przystanek Rynek
        self.assertEqual(g[0][2], 1 | 2)                        # autobus + tramwaj
        self.assertEqual(len(g[0][5]), 2)                       # ale dwa słupki
        v = idx['v']
        svc = json.load(open(os.path.join(out, 'd', v, 'svc.json')))['svc']
        self.assertEqual(len(svc), 2)                           # kalendarze nie zlały się
        lines = set()
        for num, _, _ in g[0][5]:
            for line, head, sv, kd, mins in json.load(open(os.path.join(out, 'd', v, 's', '%d.json' % num)))['g']:
                lines.add((line, head, kd, tuple(mins)))
        self.assertEqual(lines, {('144', 'Prądnik', 'b', (600,)), ('18', 'Czyżyny', 't', (660,))})

    def test_bez_generic_jak_dawniej(self):
        d = tempfile.mkdtemp()
        z = os.path.join(d, 'a.zip')
        mk(z, '700101,01,Centrum,52.1,21.0,0,,\n700102,02,Centrum,52.1,21.0,0,,\n',
           'R1,175,x,3\n', 'R1,S,T1,Lotnisko\n', 'T1,10:00:00,10:00:00,700101,1\nT1,10:05:00,10:05:00,700102,2\n')
        out, idx = self.build([z], generic=False)
        self.assertEqual(len(idx['g']), 1)
        self.assertEqual([p[1] for p in idx['g'][0][5]], ['01', '02'])


if __name__ == '__main__':
    unittest.main()
