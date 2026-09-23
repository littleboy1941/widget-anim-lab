// Анимация на публичных API: система сама перерисовывает Text(date, style: .timer)
// раз в секунду, а шрифт превращает последние две цифры секунд в глиф.
// Подробности схемы — в fontgen.py.
import SwiftUI
import UIKit

enum ProbeConfig {
    static let fps = 8
    static let frameCount = 12
    /// Вариант A (цветные SVG-шрифты, как у Bryce): цикл масок 2 с, 2*fps фаз.
    static let fontCycle = 2
    /// Вариант B (картинки под масками): цикл C с, C*fps фаз, C*fps кратно числу кадров, C делит 60.
    static let imageCycle = 3
    /// Новое окно открывается раньше, чем закрывается старое: без этого при смене кадра
    /// иногда виден пустой экран (старое окно и новое переключают разные таймеры,
    /// и перерисовка приходит не строго одновременно). Проверено в симуляторе 2026-09-23.
    static let overlap = 0.03

    static let fontNames = (0..<(fontCycle * fps)).map { "WAFrame\($0)-Regular" }
        + ["WABlink\(fontCycle)-Regular", "WABlink\(imageCycle)-Regular"]
}

/// Таймер, последний глиф которого (лигатура секунд) занимает квадрат size×size.
/// Остальные глифы шрифта пустые и уходят влево за край.
struct TimerGlyph: View {
    let date: Date
    let font: String
    let size: CGFloat

    var body: some View {
        Text(date, style: .timer)
            .font(.custom(font, fixedSize: size))
            .lineLimit(1)
            .fixedSize()
            .frame(width: size * 9, height: size, alignment: .trailing)
            .offset(x: -size * 4)
            .frame(width: size, height: size)
    }
}

/// Маска, открытая на [phase/fps - overlap, (phase+1)/fps) по модулю цикла:
/// пересечение двух мигающих таймеров, каждый горит 1 с из цикла.
struct PhaseWindow: View {
    let ref: Date
    let phase: Int
    let fps: Int
    let cycle: Int
    let size: CGFloat

    var body: some View {
        let dt = 1.0 / Double(fps)
        let font = "WABlink\(cycle)-Regular"
        TimerGlyph(date: ref + dt * Double(phase) - ProbeConfig.overlap, font: font, size: size)
            .mask { TimerGlyph(date: ref + dt * Double(phase + 1) - 1, font: font, size: size) }
    }
}

/// Вариант A: кадры — цветные SVG-глифы в 2*fps шрифтах.
struct FontFramesAnimation: View {
    let ref: Date
    let size: CGFloat

    var body: some View {
        let fps = ProbeConfig.fps
        let phases = ProbeConfig.fontCycle * fps
        ZStack {
            ForEach(0..<phases, id: \.self) { i in
                // глиф кадра сменяется одновременно с открытием окна
                TimerGlyph(date: ref + Double(i) / Double(fps) - ProbeConfig.overlap,
                           font: "WAFrame\(i)-Regular", size: size)
                    .mask { PhaseWindow(ref: ref, phase: i, fps: fps, cycle: ProbeConfig.fontCycle, size: size) }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// Вариант B: кадры — обычные картинки, шрифт только открывает нужную в нужный момент.
struct ImageFramesAnimation: View {
    let ref: Date
    let size: CGFloat
    let frames: [UIImage]

    var body: some View {
        let fps = ProbeConfig.fps
        let cycle = ProbeConfig.imageCycle
        let phases = cycle * fps
        ZStack {
            ForEach(0..<frames.count, id: \.self) { f in
                Image(uiImage: frames[f])
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size, height: size)
                    .mask {
                        ZStack {
                            ForEach(Array(stride(from: f, to: phases, by: frames.count)), id: \.self) { i in
                                PhaseWindow(ref: ref, phase: i, fps: fps, cycle: cycle, size: size)
                            }
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    static func bundledFrames() -> [UIImage] {
        (0..<ProbeConfig.frameCount).compactMap { UIImage(named: "frame_\($0).png") }
    }
}
