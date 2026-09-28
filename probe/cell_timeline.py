"""Покадровая лента одной неподвижной клетки: прогоны одинакового состояния (idx / BLANK / ?).
Для записей экрана с телефона — видно пустые вспышки, шаги назад, стоп-кадры.

python3 cell_timeline.py VIDEO X Y W H
  X Y W H — клетка на записи, px. Сохраняет VIDEO.rows.npy: (t, idx или -1, blank, mixed, mean).
"""
import sys
from pathlib import Path

import cv2, numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze_cells as ac

video, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:6])
cap = cv2.VideoCapture(video)
rows = []
last = -1
while True:
    ok, f = cap.read()
    if not ok: break
    t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
    if t <= last: continue
    last = t
    crop = f[y:y+h, x:x+w]
    s = ac.inspect_cell(crop, "idx", t)
    # «на месте»: рамка виджета вокруг клетки тёмно-серая, фон экрана чёрный
    mean = float(crop.mean())
    rows.append((t, s.index, s.blank, s.mixed_marker, mean))
cap.release()
# сжать в прогоны одинакового состояния
def state(r):
    if r[1] is not None: return f"{r[1]:02d}"
    return "BLANK" if r[2] else "?"
runs = []
for r in rows:
    st = state(r)
    if runs and runs[-1][0] == st:
        runs[-1][2] = r[0]; runs[-1][3] += 1
    else:
        runs.append([st, r[0], r[0], 1, r[4]])
np.save(video + ".rows.npy", np.array([(r[0], -1 if r[1] is None else r[1], r[2], r[3], r[4]) for r in rows], dtype=float))
for st, a, b, n, m in runs:
    print(f"{a:7.3f} {st:>5} x{n:<3} mean={m:5.0f}")
