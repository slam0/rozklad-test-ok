# -*- coding: utf-8 -*-
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import build_all, fake_gtfs
from test_generic import mk


class All(unittest.TestCase):
    def test_dwa_miasta_i_pominiecie_zepsutego(self):
        d = tempfile.mkdtemp()
        w, g, a, t = (os.path.join(d, n) for n in ('w.zip', 'g.zip', 'a.zip', 't.zip'))
        fake_gtfs.make(w)
        mk(g, 's1,,Brama,54.3,18.6,0,,\n', 'R1,6,x,0\n', 'R1,S,T1,Oliwa\n', 'T1,07:00:00,07:00:00,s1,1\n')
        mk(a, 's1,,Rynek,50.06,19.94,0,,\n', 'R1,144,x,3\n', 'R1,S,T1,Prądnik\n', 'T1,10:00:00,10:00:00,s1,1\n')
        mk(t, 's1,,Rynek,50.06,19.94,0,,\n', 'R1,18,x,0\n', 'R1,S,T1,Czyżyny\n', 'T1,11:00:00,11:00:00,s1,1\n')
        cfg = os.path.join(d, 'tools', 'miasta.json')
        os.makedirs(os.path.dirname(cfg))
        json.dump([
            {'id': 'warszawa', 'n': 'Warszawa', 'k': 'Polska', 'root': True, 'required': True, 'generic': False, 'src': [w]},
            {'id': 'gdansk', 'n': 'Gdańsk', 'k': 'Polska', 'generic': True, 'src': [g], 'attr': 'ZTM Gdańsk'},
            {'id': 'krakow', 'n': 'Kraków', 'k': 'Polska', 'generic': True, 'src': [a, t]},
            {'id': 'zepsute', 'n': 'Zepsute', 'k': 'X', 'src': [os.path.join(d, 'nie-ma.zip')]},
        ], open(cfg, 'w'))
        out = os.path.join(d, '_site')
        lst = build_all.main(cfg, out, os.path.join(d, 'work'), log=lambda *x: None)
        self.assertEqual([c['id'] for c in lst], ['warszawa', 'gdansk', 'krakow'])
        m = json.load(open(os.path.join(out, 'miasta.json')))
        self.assertEqual([c['u'] for c in m['c']], ['', 'gdansk/', 'krakow/'])
        self.assertTrue(os.path.isfile(os.path.join(out, 'index.json')))             # Warszawa w katalogu głównym
        for cid in ('gdansk', 'krakow'):
            v = [c for c in m['c'] if c['id'] == cid][0]['v']
            self.assertTrue(os.path.isfile(os.path.join(out, cid, 'index.json')))
            self.assertTrue(os.path.isfile(os.path.join(out, cid, 'd', v, 'svc.json')))
        self.assertEqual([c for c in m['c'] if c['id'] == 'krakow'][0]['m'], 1 | 2)   # autobus + tramwaj

    def test_wymagane_miasto_przerywa(self):
        d = tempfile.mkdtemp()
        cfg = os.path.join(d, 'tools', 'miasta.json'); os.makedirs(os.path.dirname(cfg))
        json.dump([{'id': 'w', 'n': 'W', 'k': 'P', 'root': True, 'required': True, 'src': [os.path.join(d, 'brak.zip')]}], open(cfg, 'w'))
        with self.assertRaises(SystemExit):
            build_all.main(cfg, os.path.join(d, 'o'), os.path.join(d, 'w'), log=lambda *x: None)


if __name__ == '__main__':
    unittest.main()
