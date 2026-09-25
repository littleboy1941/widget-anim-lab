// Опыт 2026-09-25 (гибрид): анимация на приватном _clockHandRotationEffect (ClockHandRotationKit
// 1.1.0, MIT) — как у конкурентов (TapeKit) и личного виджета. Эффект работает только в сборках
// SDK ≤ 26.0 (Xcode 26.0.1): workflow private-probe.yml. Кадры — дуги огромного радиуса,
// которые система вращает сама; приём Widgetnimation (MIT).
// По умолчанию две клетки 16/30 fps для свайпов. Variant.mode = p{fps}n{N}s{pt}k{k}[g{batch}]
// выбирает одну capacity-анимацию с глобальными индексами дуг и петлёй N/fps секунд.
#if PRIVATE_EXPERIMENTS
import ClockHandRotationKit
import SwiftUI
import WidgetKit

private struct ArcSliceMask: Shape {
    let startAngle: Double
    let endAngle: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
        return path
    }
}

struct RotationFramesAnimation: View {
    let frames: [UIImage]
    let fps: Int
    let size: CGFloat
    var radiusMultiplier: CGFloat = 50
    var groupSize: Int = 0
    /// Сдвиг дуг, градусы. Геометрия (гипотеза, проверяет опыт combo): вращение θ = 360°·frac(t/T)
    /// по часам, видна точка круга «вверху», поэтому без сдвига кадр i виден при
    /// t·fps ≡ i − N/4 (mod N); сдвиг −90° совмещает кадр i с t·fps ∈ [i, i+1), как у таймеров.
    var shift: Double = 0

    private func frameLayer(_ index: Int, radius: CGFloat, angle: Double,
                            period: Double) -> some View {
        Image(uiImage: frames[index])
            .resizable()
            .frame(width: size, height: size)
            .mask(
                ArcSliceMask(startAngle: shift - angle * Double(index + 1),
                             endAngle: shift - angle * Double(index), radius: radius)
                    .stroke(Color.white,
                            style: StrokeStyle(lineWidth: size * 1.5, lineCap: .butt),
                            antialiased: false)
                    .frame(width: size, height: size)
                    .clockHandRotationEffect(period: .custom(period))
                    .offset(y: radius)
            )
    }

    var body: some View {
        let radius = size * radiusMultiplier
        let angle = 360.0 / Double(max(1, frames.count))
        let period = Double(frames.count) / Double(fps)
        let batch = groupSize > 0 ? groupSize : max(1, frames.count)
        let groups = (frames.count + batch - 1) / batch
        ZStack {
            ForEach(0..<groups, id: \.self) { group in
                ZStack {
                    ForEach(group * batch..<min((group + 1) * batch, frames.count), id: \.self) { index in
                        frameLayer(index, radius: radius, angle: angle, period: period)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

private struct CapacityMode {
    let fps: Int
    let count: Int
    let size: Int
    let radiusMultiplier: Int
    let groupSize: Int

    init?(_ raw: String) {
        let scanner = Scanner(string: raw)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("p") != nil, let fps = scanner.scanInt(),
              scanner.scanString("n") != nil, let count = scanner.scanInt(),
              scanner.scanString("s") != nil, let size = scanner.scanInt(),
              scanner.scanString("k") != nil, let radiusMultiplier = scanner.scanInt()
        else { return nil }
        var groupSize = 0
        if scanner.scanString("g") != nil {
            guard let parsed = scanner.scanInt(), parsed > 0 else { return nil }
            groupSize = parsed
        }
        guard scanner.isAtEnd, fps > 0, count > 0, count <= 4096,
              size >= 32, size <= 320, radiusMultiplier > 0 else { return nil }
        self.fps = fps
        self.count = count
        self.size = size
        self.radiusMultiplier = radiusMultiplier
        self.groupSize = groupSize
    }
}

private struct PrivateCapacityView: View {
    let mode: CapacityMode

    var body: some View {
        let frames = ImageFramesAnimation.experimentFrames(mode.count, prefix: "cap")
        VStack(spacing: 4) {
            if frames.count == mode.count {
                RotationFramesAnimation(frames: frames, fps: mode.fps,
                                        size: CGFloat(mode.size),
                                        radiusMultiplier: CGFloat(mode.radiusMultiplier),
                                        groupSize: mode.groupSize)
            } else {
                Text("Missing frames \(frames.count)/\(mode.count)")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

struct PrivateExperimentView: View {
    let entry: SwipeEntry

    var body: some View {
        HStack(spacing: 12) {
            RotationFramesAnimation(frames: ImageFramesAnimation.experimentFrames(16, prefix: "fps16"),
                                    fps: 16, size: 128)
            RotationFramesAnimation(frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                    fps: 30, size: 128)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

/// Гибрид «таймеры сверху, вращение снизу» (опыт 2026-09-25). Верхний слой — таймеры-маски
/// (до 30 fps в покое), каждый кадр дополнительно под вращающимися «воротами», открытыми
/// в его слот ± margin кадров. При свайпе таймеры замирают, ворота закрывают застывший кадр,
/// и виден нижний слой — вращение (~12,5 обновлений/с, живёт при свайпе).
struct GatedTimerFramesAnimation: View {
    let ref: Date
    let frames: [UIImage]
    let fps: Int
    let size: CGFloat
    let shift: Double
    var margin = 2.5
    /// true — сначала ворота-вращение, потом таймеры (comboR); false — наоборот (combo1).
    var gateFirst = false

    var body: some View {
        let count = frames.count
        let cycle = 2
        let phases = cycle * fps
        let radius = size * 50
        let angle = 360.0 / Double(max(1, count))
        let period = Double(count) / Double(fps)
        ZStack {
            RotationFramesAnimation(frames: frames, fps: fps, size: size, shift: shift)
            ForEach(0..<count, id: \.self) { j in
                let gate = ArcSliceMask(startAngle: shift - angle * (Double(j) + 1 + margin),
                                        endAngle: shift - angle * (Double(j) - margin), radius: radius)
                    .stroke(Color.white,
                            style: StrokeStyle(lineWidth: size * 1.5, lineCap: .butt),
                            antialiased: false)
                    .frame(width: size, height: size)
                    .clockHandRotationEffect(period: .custom(period))
                    .offset(y: radius)
                let windows = ZStack {
                    ForEach(Array(stride(from: j, to: phases, by: count)), id: \.self) { p in
                        PhaseWindow(ref: ref, phase: p, fps: fps, cycle: cycle, size: size, overlap: 0)
                    }
                }
                let image = Image(uiImage: frames[j]).resizable().frame(width: size, height: size)
                if gateFirst {
                    image.mask(gate).mask(windows)
                } else {
                    image.mask(windows).mask(gate)
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// Четыре клетки 30 fps × 30 кадров, петля 1 с: только таймеры | только вращение (без сдвига)
/// комбо со сдвигом −90° | комбо без сдвига. Опорная дата таймеров — целая минута.
struct ComboExperimentView: View {
    let entry: SwipeEntry

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.experimentFrames(30, prefix: "fps30")
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ImageFramesAnimation(ref: ref, size: 150, frames: frames, overlap: 0, cycle: 2, fps: 30)
                RotationFramesAnimation(frames: frames, fps: 30, size: 150)
            }
            HStack(spacing: 12) {
                GatedTimerFramesAnimation(ref: ref, frames: frames, fps: 30, size: 150, shift: -90)
                GatedTimerFramesAnimation(ref: ref, frames: frames, fps: 30, size: 150, shift: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

/// Одна клетка комбо 30 fps (combo1 = сдвиг −90°, combo0 = без сдвига). Четыре клетки
/// сразу (combo) система не отрисовала — всю запись заглушка (прогон 36160471686).
struct ComboSingleView: View {
    let entry: SwipeEntry
    let shift: Double

    var body: some View {
        GatedTimerFramesAnimation(ref: entry.date - 60,
                                  frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                  fps: 30, size: 150, shift: shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(.white, for: .widget)
    }
}

struct PrivateProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrivateProbe", provider: SwipeProvider()) { entry in
            if Variant.mode == "timers30" {
                // контроль: только таймеры 30 fps в сборке Xcode 26.0.1 (mix и комбо не рисовались)
                ImageFramesAnimation(ref: entry.date - 60, size: 150,
                                     frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                     overlap: 0, cycle: 2, fps: 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .containerBackground(.white, for: .widget)
            } else if Variant.mode == "mix" {
                // таймеры и вращение рядом, без вложения: рисует ли система вообще такое сочетание
                HStack(spacing: 12) {
                    ImageFramesAnimation(ref: entry.date - 60, size: 150,
                                         frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                         overlap: 0, cycle: 2, fps: 30)
                    RotationFramesAnimation(frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                            fps: 30, size: 150)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(.white, for: .widget)
            } else if Variant.mode == "comboR" {
                GatedTimerFramesAnimation(ref: entry.date - 60,
                                          frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                          fps: 30, size: 150, shift: -90, gateFirst: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .containerBackground(.white, for: .widget)
            } else if Variant.mode == "combo1" || Variant.mode == "combo0" {
                ComboSingleView(entry: entry, shift: Variant.mode == "combo1" ? -90 : 0)
            } else if Variant.mode == "combo" {
                ComboExperimentView(entry: entry)
            } else if let mode = CapacityMode(Variant.mode) {
                PrivateCapacityView(mode: mode)
            } else {
                PrivateExperimentView(entry: entry)
            }
        }
        .configurationDisplayName("Probe 0")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
#endif
