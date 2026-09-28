"""Покадровые idx в клетках, которые ищутся относительно белого виджета (он едет при свайпе).

python3 cells_track.py VIDEO N name:dx,dy,side [name:dx,dy,side ...]
  N — кадров в петле; dx,dy — смещение клетки от левого верхнего угла виджета в покое, px.
  REST_W (env) — ширина белого виджета в покое, px (по умолчанию 1088); кадры записи,
  где ширина отличается больше чем на 40 px (страница едет), пропускаются.
Печатает частоту смен и шаги в покое (до первого движения), всё сохраняет в VIDEO.cells.json:
[(t, x виджета или None, {name: idx или None})] — вход для edge/hold/freeze-разборов.
"""
import json, os, statistics, sys
from collections import Counter
from pathlib import Path

import cv2, numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze_cells as ac

video = sys.argv[1]; N = int(sys.argv[2])
cells = [(c.split(":")[0], *map(int, c.split(":")[1].split(","))) for c in sys.argv[3:]]
rest_w = int(os.environ.get("REST_W", "1088"))
cap = cv2.VideoCapture(video); last = -1; rows = []
while True:
    ok, f = cap.read()
    if not ok: break
    t = cap.get(cv2.CAP_PROP_POS_MSEC)/1000
    if t <= last: continue
    last = t
    small = cv2.resize(f, (f.shape[1]//4, f.shape[0]//4), interpolation=cv2.INTER_AREA)
    white = (small.min(axis=2) > 240).astype(np.uint8)
    n, lab, st, _ = cv2.connectedComponentsWithStats(white, 8)
    if n <= 1: rows.append((t, None, {})); continue
    k = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
    x, y, w, h = [int(v)*4 for v in st[k, :4]]
    if abs(w - rest_w) > 40: rows.append((t, None, {})); continue
    vals = {}
    for name, dx, dy, s in cells:
        c = f[y+dy:y+dy+s, x+dx:x+dx+s]
        r = ac.inspect_cell(c, "idx", t) if c.shape[:2] == (s, s) else None
        vals[name] = None if r is None else r.index
    rows.append((t, x, vals))
# покой = x у своего значения, до первого движения
xs = Counter(r[1] for r in rows if r[1] is not None); x0 = xs.most_common(1)[0][0]
first_move = next((t for t, x, v in rows if t > 3 and (x is None or abs(x - x0) > 8)), rows[-1][0])
print(f"покой до {first_move:.1f} с, кадров записи {sum(1 for r in rows if r[0] < first_move)}")
for name, *_ in cells:
    seq = [(t, v[name]) for t, x, v in rows if t < first_move and x is not None and v.get(name) is not None]
    ch = [(b[0], (b[1]-a[1]) % N) for a, b in zip(seq, seq[1:]) if a[1] != b[1]]
    dur = seq[-1][0] - seq[0][0]
    iv = [b[0]-a[0] for a, b in zip(ch, ch[1:])]
    print(f"{name}: смен {len(ch)/dur:.2f}/с, шаги {dict(Counter(s for t,s in ch).most_common(4))}, интервал медиана {statistics.median(iv)*1000:.0f} мс")
json.dump(rows, open(video + ".cells.json", "w"))
