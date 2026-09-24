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

struct ImageFramesAnimation: View {
    let reference: Date
    let variant: WidgetVariant
    let frames: [UIImage]

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(frames.indices, id: \.self) { index in
                    Image(uiImage: frames[index])
                        .resizable()
                        .interpolation(variant.pixelArt ? .none : .high)
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
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
            .clipped()
        }
    }
}
