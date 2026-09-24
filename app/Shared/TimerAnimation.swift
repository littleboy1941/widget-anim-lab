import SwiftUI
import UIKit

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

    var body: some View {
        let interval = 1.0 / Double(fps)
        let font = "WABlink\(cycle)-Regular"
        TimerGlyph(date: reference + interval * Double(phase) - overlap,
                   font: font, size: size)
            .mask {
                TimerGlyph(date: reference + interval * Double(phase + 1) - 1,
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
                                .frame(width: pixelSize.width, height: pixelSize.height)
                                .frame(width: geometry.size.width, height: geometry.size.height,
                                       alignment: .bottom)
                } else {
                    Image(uiImage: image)
                                .resizable()
                                .interpolation(pixelArt ? .none : .high)
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

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            // Стопки по ≤40 слоёв: 160 крупных кадров в ОДНОЙ ZStack ломали анимацию
            // (2,5 смены/с), те же 160 кадров в 4 стопках по 40 — 8,0/с, 100 % по порядку
            // (стенд, прогон 36025144578, 2026-09-24).
            ZStack {
                ForEach(Array(stride(from: 0, to: frames.count, by: Self.stackSize)), id: \.self) { start in
                    ZStack {
                        ForEach(start..<min(start + Self.stackSize, frames.count), id: \.self) { index in
                            WidgetFramePlacement(image: frames[index], width: variant.width,
                                                 height: variant.height, pixelArt: variant.pixelArt)
                                .mask {
                                    ZStack {
                                        ForEach(variant.phaseToFrame.indices.filter {
                                            variant.phaseToFrame[$0] == index
                                        }, id: \.self) { phase in
                                            PhaseWindow(reference: reference, phase: phase,
                                                        fps: variant.fps, cycle: variant.cycle,
                                                        size: side, overlap: variant.overlapSeconds)
                                        }
                                    }
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}
