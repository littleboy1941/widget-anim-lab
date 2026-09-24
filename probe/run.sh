#!/bin/bash
# Проверка на самом новом симуляторе iOS:
# 1) внутри приложения: варианты images и fonts, видео 8 с и разбор;
# 2) на домашнем экране: UI-тест ставит виджет «Probe B», видео 10 с и разбор.
set -uo pipefail
cd "$(dirname "$0")"
MARKERS=$1

read -r RT RTVER < <(xcrun simctl list runtimes -j | python3 -c '
import json, sys
import os
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["name"].startswith("iOS") and r.get("isAvailable")]
# RUNTIME_PREFIX (например "26.") — взять самый новый iOS этой ветки, иначе самый новый вообще
pre = os.environ.get("RUNTIME_PREFIX", "")
rs = [r for r in rs if r["version"].startswith(pre)] or sys.exit("нет рантайма iOS " + pre)
rs.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(rs[-1]["identifier"], rs[-1]["version"])')
DT=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rt = sys.argv[1]
r = [r for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == rt][0]
ph = [d for d in r.get("supportedDeviceTypes", []) if d["name"].startswith("iPhone") and "Pro" in d["name"]]
print(ph[-1]["identifier"])' "$RT")
echo "== runtime $RT ($RTVER), device $DT"

DEV=$(xcrun simctl create "FontProbe" "$DT" "$RT")
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b > /dev/null
sleep 10

OUT="$PWD/out/ios$RTVER"
mkdir -p "$OUT"

record() {  # $1 — имя, $2 — секунды
  xcrun simctl io "$DEV" screenshot "$OUT/$1.png"
  xcrun simctl io "$DEV" recordVideo --codec=h264 --force "$OUT/$1.mp4" > "$OUT/$1_rec.txt" 2>&1 &
  local rec=$!
  # запись стартует не сразу: ждём строку «Recording started», иначе видео короче заданного
  for _ in $(seq 1 20); do grep -q "Recording started" "$OUT/$1_rec.txt" && break; sleep 0.5; done
  sleep "$2"
  kill -INT $rec
  wait $rec
  sleep 2  # файл дописывается после выхода
  echo "== $1 ($RTVER)" | tee -a "$OUT/result.txt"
  # разбор всего экрана долгий (на домашнем экране упирался в лимит задания);
  # клетки разбираются локально: analyze_cells.py
  [ -n "${NO_ANALYZE:-}" ] || swift analyze_video.swift "$OUT/$1.mp4" "$MARKERS" 2>/dev/null | tee -a "$OUT/result.txt"
}

xcrun simctl install "$DEV" out/FontProbe.app
APP_VARIANTS="images fonts"
[ -n "${SKIP_APP:-}" ] && APP_VARIANTS=""
for V in $APP_VARIANTS; do
  xcrun simctl launch --terminate-running-process --stdout="$OUT/app_${V}_stdout.txt" \
    "$DEV" com.widgetlab.fontprobe "$V"
  sleep 4
  record "app_$V" 8
  cat "$OUT/app_${V}_stdout.txt" | tee -a "$OUT/result.txt"
  xcrun simctl terminate "$DEV" com.widgetlab.fontprobe || true
done

if [ -n "${SKIP_APP:-}" ]; then
  # Без предварительного запуска приложения виджета не было в галерее (прогон 35969981596,
  # «No Results»): система не успевает зарегистрировать расширение. Запускаем и ждём.
  xcrun simctl launch "$DEV" com.widgetlab.fontprobe images > /dev/null
  sleep 20
  xcrun simctl terminate "$DEV" com.widgetlab.fontprobe || true
  sleep 5
fi
echo "== UI-тест: ставим виджет на домашний экран"
xcodebuild test -project FontProbe.xcodeproj -scheme FontProbe -destination "id=$DEV" \
  -derivedDataPath build_test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
  > "$OUT/uitest.log" 2>&1
echo "UI-тест: код $?" | tee -a "$OUT/result.txt"
grep -E "Test Case|error|failed|passed" "$OUT/uitest.log" | tail -20
xcrun simctl terminate "$DEV" com.widgetlab.fontprobe 2>/dev/null || true
# даём системе время заменить заглушку живым виджетом
sleep 60
record "home_widget" 20
# падения расширения и его сообщения — если виджета нет в галерее или он пустой
mkdir -p "$OUT/crash"
find ~/Library/Logs/DiagnosticReports -name "*FontProbe*" -exec cp {} "$OUT/crash/" \; 2>/dev/null
perl -e 'alarm 180; exec @ARGV' xcrun simctl spawn "$DEV" log show --last 10m --style compact   --predicate 'process CONTAINS "FontProbe" OR eventMessage CONTAINS "fontprobe"'   > "$OUT/widget_log.txt" 2>&1 || true
wc -l "$OUT/widget_log.txt"; ls "$OUT/crash"
xcrun simctl shutdown "$DEV" || true
