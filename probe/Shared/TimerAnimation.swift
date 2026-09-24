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
        + [2, 3, 5, 10, 20].map { "WABlink\($0)-Regular" }
}

/// Таймер, последний глиф которого (лигатура секунд) занимает квадрат size×size.
/// Остальные глифы шрифта пустые и уходят влево за край.
/// Без .fixedSize(): с ним таймер в виджете на домашнем экране пустой, хотя в приложении
/// работает (проверено на симуляторе iOS 26.5, 2026-09-23). Apple советует для таймеров
/// в виджете фиксированный frame + multilineTextAlignment.
struct TimerGlyph: View {
    let date: Date
    let font: String
    let size: CGFloat

    var body: some View {
        Text(date, style: .timer)
            .font(.custom(font, fixedSize: size))
            .frame(width: size * 9, height: size, alignment: .trailing)
            .multilineTextAlignment(.trailing)
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
    var overlap = ProbeConfig.overlap

    var body: some View {
        let dt = 1.0 / Double(fps)
        let font = "WABlink\(cycle)-Regular"
        TimerGlyph(date: ref + dt * Double(phase) - overlap, font: font, size: size)
            .mask { TimerGlyph(date: ref + dt * Double(phase + 1) - 1, font: font, size: size) }
    }
}

/// Вариант A: кадры — цветные SVG-глифы в 2*fps шрифтах.
struct FontFramesAnimation: View {
    let ref: Date
    let size: CGFloat
    var overlap = ProbeConfig.overlap

    var body: some View {
        let fps = ProbeConfig.fps
        let phases = ProbeConfig.fontCycle * fps
        ZStack {
            ForEach(0..<phases, id: \.self) { i in
                // глиф кадра сменяется одновременно с открытием окна
                TimerGlyph(date: ref + Double(i) / Double(fps) - overlap,
                           font: "WAFrame\(i)-Regular", size: size)
                    .mask {
                        PhaseWindow(ref: ref, phase: i, fps: fps, cycle: ProbeConfig.fontCycle,
                                    size: size, overlap: overlap)
                    }
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
    var overlap = ProbeConfig.overlap
    /// Цикл масок, с: делит 60, cycle*fps кратно числу кадров.
    var cycle = ProbeConfig.imageCycle

    var body: some View {
        let fps = ProbeConfig.fps
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
                                PhaseWindow(ref: ref, phase: i, fps: fps, cycle: cycle, size: size,
                                            overlap: overlap)
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

    /// Кадры для проверки длины анимации (make_frames.py, кладутся в LenFrames при сборке).
    static func lengthFrames(_ count: Int) -> [UIImage] {
        (0..<count).compactMap { UIImage(named: "len_\($0).png") }
    }
}
