// Диагностика отрисовки на домашнем экране.
// Прогон 2026-09-23: картинка, системный таймер и статичная лигатура нашего шрифта рисуются,
// а на первом таймере с нашим шрифтом (Font.custom(_, fixedSize:) + .fixedSize()) отрисовка
// обрывается — всё после него не видно. Клетки стоят по возрастанию риска: первая
// сломанная клетка покажет, какое отличие от раскладки Bryce виновато.
import SwiftUI
import WidgetKit

struct DiagCell<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 2) {
            content
                .frame(width: 80, height: 80)
                .background(Color.gray.opacity(0.25))
                .clipped()
            Text(title)
                .font(.system(size: 9))
                .lineLimit(1)
        }
    }
}

/// Таймер, последний глиф которого стоит в квадрате side×side. Варианты раскладки:
/// `fixedFont` — Font.custom(_, fixedSize:) вместо size:, `fixedSizeModifier` — .fixedSize().
struct DiagTimer: View {
    let date: Date
    let font: String
    let side: CGFloat
    let fixedFont: Bool
    let fixedSizeModifier: Bool

    var body: some View {
        let text = Text(date, style: .timer)
            .font(fixedFont ? .custom(font, fixedSize: side) : .custom(font, size: side))
        Group {
            if fixedSizeModifier {
                text.lineLimit(1).fixedSize()
                    .frame(width: side * 9, height: side, alignment: .trailing)
            } else {
                text.frame(width: side * 9, height: side, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
        .offset(x: -side * 4)
        .frame(width: side, height: side)
    }
}

struct DiagWidgetView: View {
    let entry: ProbeEntry

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.bundledFrames()
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                DiagCell(title: "1 timer sys") {
                    Text(ref, style: .timer).font(.system(size: 20)).monospacedDigit()
                }
                DiagCell(title: "2 image") {
                    if let f = frames.first {
                        Image(uiImage: f).resizable().interpolation(.none)
                    } else {
                        Text("nil").foregroundStyle(.red)
                    }
                }
                DiagCell(title: "3 bryce layout") {
                    DiagTimer(date: ref, font: "WABlink3-Regular", side: 80, fixedFont: false, fixedSizeModifier: false)
                }
            }
            GridRow {
                DiagCell(title: "4 fixedSize font") {
                    DiagTimer(date: ref, font: "WABlink3-Regular", side: 80, fixedFont: true, fixedSizeModifier: false)
                }
                DiagCell(title: "5 .fixedSize()") {
                    DiagTimer(date: ref, font: "WABlink3-Regular", side: 80, fixedFont: false, fixedSizeModifier: true)
                }
                DiagCell(title: "6 svg glyph") {
                    DiagTimer(date: ref, font: "WAFrame0-Regular", side: 80, fixedFont: false, fixedSizeModifier: false)
                }
            }
            GridRow {
                DiagCell(title: "7 window") {
                    Color.red.mask {
                        PhaseWindow(ref: ref, phase: 0, fps: ProbeConfig.fps, cycle: ProbeConfig.imageCycle, size: 80)
                    }
                }
                DiagCell(title: "8 anim B") {
                    ImageFramesAnimation(ref: ref, size: 80, frames: frames)
                }
                DiagCell(title: "9 anim A") {
                    FontFramesAnimation(ref: ref, size: 80)
                }
            }
        }
        .containerBackground(.white, for: .widget)
    }
}

struct DiagProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DiagProbe", provider: ProbeProvider()) { entry in
            DiagWidgetView(entry: entry)
        }
        .configurationDisplayName("Probe 0: diag")
        .supportedFamilies([.systemLarge])
    }
}
