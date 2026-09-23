// Разбор записи экрана симулятора: какой кадр анимации виден в каждый момент.
// В каждом тестовом кадре своя цветная метка (цвета — из fontgen.py) и тёмный шарик.
// Неподвижный фон (обои домашнего экрана) вычитается: для каждого цвета берём минимум
// по всей записи. Считаем частоту смены кадров, порядок (+1 по модулю L),
// пустые моменты (ни одной метки — мигание) и двоение шарика.
// Запуск: swift analyze_video.swift video.mp4 "255,0,0;255,128,0;..."
import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let markers: [(Int, Int, Int)] = args[2].split(separator: ";").map {
    let c = $0.split(separator: ",").map { Int($0)! }
    return (c[0], c[1], c[2])
}
let L = markers.count

let asset = AVURLAsset(url: url)
guard let track = asset.tracks(withMediaType: .video).first else {
    print("нет видеодорожки"); exit(1)
}
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
reader.add(output)
reader.startReading()

func near(_ r: Int, _ g: Int, _ b: Int, _ c: (Int, Int, Int), _ tol: Int) -> Bool {
    abs(r - c.0) + abs(g - c.1) + abs(b - c.2) < tol
}

// counts[0..<L] — метки, counts[L] — шарик
var raw: [(t: Double, counts: [Int])] = []
while let sb = output.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var counts = [Int](repeating: 0, count: L + 1)
    // верхние 7% — статус-бар, пропускаем
    for y in stride(from: h * 7 / 100, to: h, by: 3) {
        for x in stride(from: 0, to: w, by: 3) {
            let p = base + y * bpr + x * 4
            let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
            if near(r, g, b, (40, 40, 40), 50) { counts[L] += 1; continue }
            for k in 0..<L where near(r, g, b, markers[k], 90) { counts[k] += 1; break }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    raw.append((t, counts))
}
guard raw.count > 2 else { print("мало кадров видео: \(raw.count)"); exit(1) }

let baseline = (0...L).map { k in raw.map { $0.counts[k] }.min()! }
let samples: [(t: Double, idx: Int, ball: Int)] = raw.map { s in
    let c = (0..<L).map { s.counts[$0] - baseline[$0] }
    let best = c.indices.max { c[$0] < c[$1] }!
    return (s.t, c[best] > 150 ? best : -1, s.counts[L])
}

let duration = samples.last!.t - samples.first!.t
var good = 0, bad: [Int] = [], advance = 0
var lastValid = samples.first { $0.idx >= 0 }?.idx ?? -1
var changeTimes: [Double] = []
for s in samples where s.idx >= 0 && s.idx != lastValid {
    let d = (s.idx - lastValid + L) % L
    if d == 1 { good += 1 } else { bad.append(d) }
    advance += d
    changeTimes.append(s.t)
    lastValid = s.idx
}
// пустые моменты: сколько раз и сколько длились (до следующего кадра видео)
var blanks = 0, blankTime = 0.0
for (i, s) in samples.enumerated() where s.idx < 0 && i + 1 < samples.count {
    blanks += 1
    blankTime += samples[i + 1].t - s.t
}
// Двоение: тёмных пикселей заметно больше обычного (шарик виден всегда, фон вычитать нельзя)
let balls = samples.map(\.ball).sorted()
let median = balls[balls.count / 2]
var doubled = 0, doubledTime = 0.0
for (i, s) in samples.enumerated() where median > 0 && Double(s.ball) > 1.4 * Double(median) && i + 1 < samples.count {
    doubled += 1
    doubledTime += samples[i + 1].t - s.t
}
let gaps = zip(changeTimes.dropFirst(), changeTimes).map { $0 - $1 }.sorted()
let gapMedian = gaps.isEmpty ? 0 : gaps[gaps.count / 2]

print(String(format: "кадров видео %d за %.1f с", samples.count, duration))
print(String(format: "продвижение анимации %d кадров → %.1f кадра/с", advance, Double(advance) / max(duration, 0.001)))
print("шагов +1: \(good), с пропуском/назад: \(bad.count) \(bad.prefix(20))")
print(String(format: "интервал между сменами: медиана %.3f с, максимум %.3f с", gapMedian, gaps.last ?? 0))
print(String(format: "пустых моментов (мигание): %d, суммарно %.3f с", blanks, blankTime))
print(String(format: "двоение (два кадра сразу): %d, суммарно %.3f с (медиана шарика %d)", doubled, doubledTime, median))
print("последовательность: " + samples.prefix(90).map { $0.idx < 0 ? "-" : String($0.idx) }.joined(separator: " "))
