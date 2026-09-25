#!/bin/bash
# В ClockHandRotationKit 1.1.0 нет среза для симулятора, только ios-arm64.
# Копируем его и переписываем платформу в Mach-O на iOS Simulator: на Apple Silicon
# arm64-код тот же, отличается только пометка. Символы и вызовы не трогаем.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf chrk Frameworks
git clone -q --depth 1 --branch 1.1.0 https://github.com/octree/ClockHandRotationKit chrk
mkdir -p Frameworks
cp -R chrk/ClockHandRotationKit.xcframework/ios-arm64/ClockHandRotationKit.framework Frameworks/
FW=Frameworks/ClockHandRotationKit.framework
BIN=$FW/ClockHandRotationKit

echo "== было"; xcrun vtool -show-build "$BIN"
xcrun vtool -set-build-version iossim 14.0 15.5 -replace -output "$BIN.sim" "$BIN" \
  || xcrun vtool -set-build-version 7 14.0 15.5 -replace -output "$BIN.sim" "$BIN"
mv "$BIN.sim" "$BIN"
echo "== стало"; xcrun vtool -show-build "$BIN"

plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' "$FW/Info.plist"
plutil -replace DTPlatformName -string iphonesimulator "$FW/Info.plist" || true

M=$FW/Modules/ClockHandRotationKit.swiftmodule
sed 's/-target arm64-apple-ios14.0 /-target arm64-apple-ios14.0-simulator /' \
  "$M/arm64-apple-ios.swiftinterface" > "$M/arm64-apple-ios-simulator.swiftinterface"
cp "$M/arm64-apple-ios.swiftdoc" "$M/arm64-apple-ios-simulator.swiftdoc"
grep -- "-target" "$M/arm64-apple-ios-simulator.swiftinterface"

codesign -f -s - "$FW"
echo "== импорт эффекта в бинарнике"
nm -u "$BIN" | grep -i clockHand || { echo "grep не нашёл, первые импорты:"; nm -u "$BIN" | head -40; } || true
