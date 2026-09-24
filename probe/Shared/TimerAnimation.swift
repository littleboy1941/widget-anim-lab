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
        + [2, 3, 5, 10, 20, 30, 60].map { "WABlink\($0)-Regular" }
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
            .font(.custom(font, size: size))
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

/// Bryce's two-stack selector: P frame timers, P-1 phase masks, one
/// whole-second mask. The topmost active frame wins, so a one-second blink
/// suffices for every phase instead of intersecting two timers per phase.
/// P=2*fps; the number of timers is exactly 2*P: 96/120/32 at 24/30/8 fps.
struct BryceFontFramesAnimation: View {
    let ref: Date
    let size: CGFloat
    let fps: Int
    let prefix: String
    var overlap: TimeInterval = 0.01

    private func frame(_ i: Int) -> some View {
        TimerGlyph(date: ref + Double(i) / Double(fps) - overlap,
                   font: "\(prefix)\(i)-Regular", size: size)
    }

    private func blink(_ i: Int) -> some View {
        TimerGlyph(date: ref + Double(i) / Double(fps) - overlap,
                   font: "WABlink2-Regular", size: size)
    }

    var body: some View {
        ZStack {
            ZStack {
                frame(0)
                ForEach(1..<fps, id: \.self) { i in
                    frame(i).mask { blink(i) }
                }
            }
            ZStack {
                ForEach(fps..<(2 * fps), id: \.self) { i in
                    frame(i).mask { blink(i) }
                }
            }
            .mask {
                TimerGlyph(date: ref + 1, font: "WABlink2-Regular", size: size)
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
    var fps = ProbeConfig.fps

    var body: some View {
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

    static func experimentFrames(_ count: Int, prefix: String) -> [UIImage] {
        (0..<count).compactMap { UIImage(named: "\(prefix)_\($0).png") }
    }

    /// Кадры для замера памяти: 40 штук side×side (make_frames.py, MemFrames).
    static func memoryFrames(side: Int) -> [UIImage] {
        (0..<40).compactMap { UIImage(named: "mem\(side)_\($0).png") }
    }
}

/// Independent stacks retain global phase numbers and share the cycle clock.
struct SplitImageFramesAnimation: View {
    let ref: Date
    let size: CGFloat
    let frames: [UIImage]
    var fps = 8
    var cycle = 20
    var stackSize = 40

    var body: some View {
        ZStack {
            ForEach(0..<((frames.count + stackSize - 1) / stackSize), id: \.self) { stack in
                ZStack {
                    ForEach(0..<stackSize, id: \.self) { local in
                        let i = stack * stackSize + local
                        if i < frames.count {
                            Image(uiImage: frames[i])
                                .resizable()
                                .interpolation(.none)
                                .frame(width: size, height: size)
                                .mask {
                                    PhaseWindow(ref: ref, phase: i, fps: fps, cycle: cycle,
                                                size: size, overlap: 0.02)
                                }
                        }
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

/// One fractional-second gate shared by all frames with index % fps == slot.
/// WABlink2 fires for one second every two seconds. The two PhaseWindows cover
/// slot j in both seconds of that cycle, for 4 timers per slot.
struct FractionWindow: View {
    let ref: Date
    let slot: Int
    let fps: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            PhaseWindow(ref: ref, phase: slot, fps: fps, cycle: 2,
                        size: size, overlap: 0.02)
            PhaseWindow(ref: ref, phase: slot + fps, fps: fps, cycle: 2,
                        size: size, overlap: 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// One WABlink<C> timer per frame selects its whole second; a shared gate on
/// the outer ZStack selects the fractional slot. For 80/160 frames at 8 fps:
/// 80/160 second timers + 8 * (2 windows * 2 timers) = 112/192 timers.
/// Fraction windows overlap by 0.02 s within a second. A one-timer second
/// gate is exactly 1 s wide, so at integer-second boundaries (also the
/// transition between slots 7 and 0) adjacent gates merely touch. Their
/// independent timer updates can still expose a brief blank there.
struct GroupedImageFramesAnimation: View {
    let ref: Date
    let size: CGFloat
    let frames: [UIImage]
    let cycle: Int
    private var fps: Int { 8 }

    var body: some View {
        ZStack {
            ForEach(0..<fps, id: \.self) { slot in
                ZStack {
                    ForEach(0..<(frames.count / fps), id: \.self) { second in
                        let i = second * fps + slot
                        Image(uiImage: frames[i])
                            .resizable()
                            .interpolation(.none)
                            .frame(width: size, height: size)
                            .mask {
                                TimerGlyph(date: ref + Double(second),
                                           font: "WABlink\(cycle)-Regular", size: size)
                            }
                    }
                }
                .frame(width: size, height: size)
                .mask { FractionWindow(ref: ref, slot: slot, fps: fps, size: size) }
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}
