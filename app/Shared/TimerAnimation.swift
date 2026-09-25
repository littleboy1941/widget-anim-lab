import SwiftUI
import UIKit
import WidgetKit

/// Keep this exact timer layout: .fixedSize() made the home-screen widget blank.
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

struct PhaseWindow: View {
    let reference: Date
    let phase: Int
    let fps: Int
    let cycle: Int
    let size: CGFloat
    let overlap: Double
    /// Длина окна в фазах и запас после конца окна (для запасного слоя). Окно = [начало фазы −
    /// overlap, конец фазы (phase + length) + tail]; длина всего окна не больше 1 с (маска-таймер).
    var length = 1
    var tail = 0.0

    var body: some View {
        let interval = 1.0 / Double(fps)
        let font = "WABlink\(cycle)-Regular"
        TimerGlyph(date: reference + interval * Double(phase) - overlap,
                   font: font, size: size)
            .mask {
                TimerGlyph(date: reference + interval * Double(phase + length) + tail - 1,
                           font: font, size: size)
            }
    }
}

struct WidgetFramePlacement: View {
    let image: UIImage
    let width: Int
    let height: Int
    let pixelArt: Bool
    @Environment(\.displayScale) private var displayScale

    /// Пиксель-арт — как в виджете Мононо: увеличение в целое число раз в ФИЗИЧЕСКИХ
    /// пикселях (≈90 % ширины), прижато к низу. Иначе пиксели разного размера и «мыло».
    private func pixelArtSize(in box: CGSize) -> CGSize? {
        guard pixelArt, width > 0, height > 0, displayScale > 0 else { return nil }
        let byWidth = floor(box.width * displayScale * 0.9 / CGFloat(width))
        let byHeight = floor(box.height * displayScale / CGFloat(height))
        let k = min(byWidth, byHeight)
        guard k >= 1 else { return nil }
        return CGSize(width: CGFloat(width) * k / displayScale,
                      height: CGFloat(height) * k / displayScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let pixelSize = pixelArtSize(in: geometry.size)
            Group {
                if let pixelSize {
                    Image(uiImage: image)
                                .resizable()
                                .interpolation(.none)
                                .widgetAccentedRenderingMode(.fullColor)
                                .frame(width: pixelSize.width, height: pixelSize.height)
                                .frame(width: geometry.size.width, height: geometry.size.height,
                                       alignment: .bottom)
                } else {
                    Image(uiImage: image)
                                .resizable()
                                .interpolation(pixelArt ? .none : .high)
                                .widgetAccentedRenderingMode(.fullColor)
                                .scaledToFit()
                                .padding(12)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}

struct ImageFramesAnimation: View {
    static let stackSize = 40
    let reference: Date
    let variant: WidgetVariant
    let frames: [UIImage]
    /// Запасной слой — копия анимации под основной с широкими окнами (каждая 2-я фаза,
    /// окно 2 фазы + по полфазы запаса). На телефоне (iPhone 12 / iOS 27, 17 Pro Max / iOS 26,
    /// 2026-09-25) все маски основного слоя изредка на 17–50 мс закрыты — без него виджет
    /// вспыхивает пустым. Кадр 0 без маски вместо него давал «телепорт». Слоёв +≈50 %
    /// (учтено в AnimationBudget.maxPhases).
    var fallback = true

    struct Window: Hashable {
        let phase: Int
        var length = 1
        var lead: Double
        var tail = 0.0
    }

    private var mainWindows: [(frame: Int, windows: [Window])] {
        frames.indices.map { index in
            (index, variant.phaseToFrame.indices.filter { variant.phaseToFrame[$0] == index }
                .map { Window(phase: $0, lead: variant.overlapSeconds) })
        }
    }

    private var fallbackWindows: [(frame: Int, windows: [Window])] {
        let half = 0.5 / Double(variant.fps)
        var result: [Int: [Window]] = [:]
        for phase in stride(from: 0, to: variant.phaseToFrame.count, by: 2) {
            result[variant.phaseToFrame[phase], default: []]
                .append(Window(phase: phase, length: 2, lead: half, tail: half))
        }
        return result.keys.sorted().map { ($0, result[$0] ?? []) }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                if fallback {
                    stacks(fallbackWindows, size: geometry.size, side: side)
                }
                stacks(mainWindows, size: geometry.size, side: side)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    /// Стопки по ≤40 слоёв: 160 крупных кадров в ОДНОЙ ZStack ломали анимацию
    /// (2,5 смены/с), те же 160 кадров в 4 стопках по 40 — 8,0/с, 100 % по порядку
    /// (стенд, прогон 36025144578, 2026-09-24).
    private func stacks(_ layers: [(frame: Int, windows: [Window])], size: CGSize,
                        side: CGFloat) -> some View {
        ZStack {
            ForEach(Array(stride(from: 0, to: layers.count, by: Self.stackSize)), id: \.self) { start in
                ZStack {
                    ForEach(start..<min(start + Self.stackSize, layers.count), id: \.self) { position in
                        WidgetFramePlacement(image: frames[layers[position].frame], width: variant.width,
                                             height: variant.height, pixelArt: variant.pixelArt)
                            .mask {
                                ZStack {
                                    ForEach(layers[position].windows, id: \.self) { window in
                                        PhaseWindow(reference: reference, phase: window.phase,
                                                    fps: variant.fps, cycle: variant.cycle,
                                                    size: side, overlap: window.lead,
                                                    length: window.length, tail: window.tail)
                                    }
                                }
                                .frame(width: size.width, height: size.height)
                            }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
    }
}
