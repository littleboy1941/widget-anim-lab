"""Опыт со свайпом (Widget/SwipeWidget.swift, прогон 36146551276, симулятор iOS 26.5, iPhone 11 Pro Max).
Покадровый разбор опыта со свайпом: виджет ищется по белому прямоугольнику
(он едет при свайпе), клетки берутся относительно него."""
import sys, cv2, numpy as np
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import analyze_cells as ac

video = sys.argv[1]
REST_W = 1164 - 78  # ширина виджета в покое, px
# клетки относительно левого верхнего угла виджета (78,199) в покое
A = (125 - 78, 290 - 199, 384, 384)
B = (537 - 78, 430 - 199, 458, 107)
C = (125 - 78, 712 - 199, 990, 518)
cap = cv2.VideoCapture(video)
out = open(video + ".swipe.tsv", "w")
out.write("t\tx\ty\tw\tidx\tblank\tstop_changed\tstop_diff\tred\n")
prev_stop = None
last = -1
while True:
    ok, f = cap.read()
    if not ok: break
    t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
    if t <= last: continue
    last = t
    small = cv2.resize(f, (f.shape[1] // 4, f.shape[0] // 4), interpolation=cv2.INTER_AREA)
    white = (small.min(axis=2) > 240).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(white, 8)
    if n <= 1:
        out.write(f"{t:.4f}\t\t\t\t\t\t\t\t\n"); prev_stop = None; continue
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    x, y, w, h = [int(v) * 4 for v in stats[k, :4]]
    if abs(w - REST_W) > 40 or stats[k, cv2.CC_STAT_AREA] < 20000:
        # виджет обрезан краем экрана или масштабируется — клетки не мерить
        out.write(f"{t:.4f}\t{x}\t{y}\t{w}\t\t\t\t\t\n"); prev_stop = None; continue
    def crop(c):
        cx, cy, cw, ch = c
        return f[y + cy:y + cy + ch, x + cx:x + cx + cw]
    a = crop(A)
    s = ac.inspect_cell(a, "idx", t) if a.shape[:2] == (384, 384) else None
    b = cv2.cvtColor(crop(B), cv2.COLOR_BGR2GRAY)
    diff = ""
    changed = ""
    if prev_stop is not None and b.shape == prev_stop.shape:
        d = float(np.abs(b.astype(np.int16) - prev_stop.astype(np.int16)).mean())
        diff = f"{d:.2f}"; changed = int(d > 1.5)
    prev_stop = b
    c = crop(C)
    red = int(np.count_nonzero((c[:, :, 2] > 200) & (c[:, :, 1] < 110) & (c[:, :, 0] < 110)))
    idx = "" if s is None or s.index is None else s.index
    blank = "" if s is None else int(s.blank)
    out.write(f"{t:.4f}\t{x}\t{y}\t{w}\t{idx}\t{blank}\t{changed}\t{diff}\t{red}\n")
out.close()
print("ok")
