"""Номер кадра по углу шарика — для записей, где idx-метки не читаются (тонированный экран:
метки и шарик белые). Клетку ищем по двум белым квадратам-меткам (сторона ~0.2 клетки,
расстояние между левыми краями 0.8 клетки).

python3 ball_track.py VIDEO [N=30] [S=450]
  N — кадров в петле (шарик делает оборот за петлю), S — сторона клетки на записи, px.
Сохраняет VIDEO.ball.json: [(t, x клетки или None, [(кадр, площадь шарика), ...])];
два шарика в одной строке — двоение.
"""
import json, math, sys

import cv2, numpy as np

video = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 30
S = int(sys.argv[3]) if len(sys.argv) > 3 else 450
side = (int(0.17*S), int(0.22*S))   # сторона метки: 75..100 px при S = 450
cap = cv2.VideoCapture(video); last = -1; rows = []
while True:
    ok, f = cap.read()
    if not ok: break
    t = cap.get(cv2.CAP_PROP_POS_MSEC)/1000
    if t <= last: continue
    last = t
    white = (f.min(axis=2) > 235).astype(np.uint8)
    n, lab, st, cen = cv2.connectedComponentsWithStats(white, 8)
    sq = [(int(st[k,0]), int(st[k,1])) for k in range(1, n)
          if side[0] <= st[k,2] <= side[1] and side[0] <= st[k,3] <= side[1]
          and st[k,4] > 0.8*st[k,2]*st[k,3]]
    cell = None
    for x, y in sq:
        if any(abs(x2 - (x + 0.8*S)) <= 12 and abs(y2 - y) <= 8 for x2, y2 in sq):
            cell = (x, y); break
    if cell is None: rows.append((t, None, [])); continue
    x, y = cell
    crop = white[y + int(0.3*S):y + S, max(0, x):x + S]
    m, lab2, st2, cen2 = cv2.connectedComponentsWithStats(crop, 8)
    balls = []
    for k in range(1, m):
        if st2[k, 4] > 400:
            cx, cy = cen2[k][0], cen2[k][1] + 0.3*S
            a = math.atan2(cy - 0.69*S, cx - 0.5*S) % (2*math.pi)
            balls.append((round(a / (2*math.pi) * N) % N, int(st2[k, 4])))
    rows.append((t, x, balls))
json.dump(rows, open(video + ".ball.json", "w")); print(len(rows))
