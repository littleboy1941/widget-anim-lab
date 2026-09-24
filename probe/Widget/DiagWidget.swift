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

/// Двоение на смене кадра: те же анимации с разным перекрытием окон, с.
/// На домашнем экране при 0,03 с двоение ~4 с из 20 (прогон 2026-09-23).
struct OverlapWidgetView: View {
    let entry: ProbeEntry

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.bundledFrames()
        Grid(horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                ForEach([0, 0.01, 0.02], id: \.self) { ov in
                    DiagCell(title: "B \(ov)") {
                        ImageFramesAnimation(ref: ref, size: 80, frames: frames, overlap: ov)
                    }
                }
            }
            GridRow {
                ForEach([0, 0.01, 0.02], id: \.self) { ov in
                    DiagCell(title: "A \(ov)") {
                        FontFramesAnimation(ref: ref, size: 80, overlap: ov)
                    }
                }
            }
            GridRow {
                DiagCell(title: "timer sys") {
                    Text(ref, style: .timer).font(.system(size: 20)).monospacedDigit()
                }
                DiagCell(title: "B 0.03") {
                    ImageFramesAnimation(ref: ref, size: 80, frames: frames, overlap: 0.03)
                }
                DiagCell(title: "A 0.03") {
                    FontFramesAnimation(ref: ref, size: 80, overlap: 0.03)
                }
            }
        }
        .containerBackground(.white, for: .widget)
    }
}

/// Потолок длины: одна анимация B из N кадров 150×150, цикл масок C с, C*fps = N фаз,
/// 2 таймера на фазу. Снизу системный таймер (виджет живой?) и число загруженных кадров.
struct LengthWidgetView: View {
    let entry: ProbeEntry
    let count: Int

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.lengthFrames(count)
        let cycle = max(1, count / ProbeConfig.fps)
        VStack(spacing: 2) {
            ImageFramesAnimation(ref: ref, size: 128, frames: frames, overlap: 0.02,
                                 cycle: count == 12 ? 3 : cycle)
            HStack(spacing: 6) {
                Text(ref, style: .timer)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
                Text("\(frames.count)f")
                    .font(.system(size: 11))
            }
        }
        .containerBackground(.white, for: .widget)
    }
}

struct DiagProbeWidget: Widget {
    private static var lengthCount: Int? {
        Variant.mode.hasPrefix("len") ? Int(Variant.mode.dropFirst(3)) : nil
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DiagProbe", provider: ProbeProvider()) { entry in
            if let n = Self.lengthCount {
                LengthWidgetView(entry: entry, count: n)
            } else if Variant.mode == "overlap" {
                OverlapWidgetView(entry: entry)
            } else {
                DiagWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Probe 0: \(Variant.mode)")
        .supportedFamilies(Self.lengthCount == nil ? [.systemLarge] : [.systemSmall])
    }
}
