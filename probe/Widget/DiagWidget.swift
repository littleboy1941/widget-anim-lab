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

/// Five length experiments share one layout, so the screenshot crop differs
/// only for the 64 pt small-image variant. All labels are outside the animation.
struct LengthExperimentView: View {
    let entry: ProbeEntry
    let mode: String

    private var count: Int { mode == "len80c20" || mode == "grp80" ? 80 : 160 }
    private var side: CGFloat { mode == "len160s" ? 64 : 128 }
    private var prefix: String {
        switch mode {
        case "len160s": return "lens"
        case "len80c20", "grp80": return "slow"
        default: return "len"
        }
    }

    @ViewBuilder private func animation(ref: Date, frames: [UIImage]) -> some View {
        switch mode {
        case "len160s":
            ImageFramesAnimation(ref: ref, size: side, frames: frames,
                                 overlap: 0.02, cycle: 20)
        case "len80c20":
            ImageFramesAnimation(ref: ref, size: side, frames: frames,
                                 overlap: 0.02, cycle: 20, fps: 4)
        case "split160":
            SplitImageFramesAnimation(ref: ref, size: side, frames: frames)
        case "grp80":
            GroupedImageFramesAnimation(ref: ref, size: side, frames: frames, cycle: 10)
        default:
            GroupedImageFramesAnimation(ref: ref, size: side, frames: frames, cycle: 20)
        }
    }

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.experimentFrames(count, prefix: prefix)
        VStack(spacing: 2) {
            animation(ref: ref, frames: frames)
            HStack(spacing: 6) {
                Text(ref, style: .timer)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
                Text("\(frames.count)f")
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

struct Len160SmallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Len160Small", provider: ProbeProvider()) {
            LengthExperimentView(entry: $0, mode: "len160s")
        }
        .configurationDisplayName("Len 160 small")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct Len80Cycle20Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Len80Cycle20", provider: ProbeProvider()) {
            LengthExperimentView(entry: $0, mode: "len80c20")
        }
        .configurationDisplayName("Len 80 cycle 20")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct Split160Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Split160", provider: ProbeProvider()) {
            LengthExperimentView(entry: $0, mode: "split160")
        }
        .configurationDisplayName("Split 160")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct Group80Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Group80", provider: ProbeProvider()) {
            LengthExperimentView(entry: $0, mode: "grp80")
        }
        .configurationDisplayName("Grouped 80")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct Group160Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Group160", provider: ProbeProvider()) {
            LengthExperimentView(entry: $0, mode: "grp160")
        }
        .configurationDisplayName("Grouped 160")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

/// Замер памяти: 40 кадров side×side px, декодированные ≈ side²·4·40 байт
/// (300 → 14 МБ, 510 → 42, 746 → 89, 1000 → 160, 1118 → 200). Показ 300 pt.
struct MemoryWidgetView: View {
    let entry: ProbeEntry
    let side: Int

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.memoryFrames(side: side)
        let mb = Double(side * side * 4 * frames.count) / 1_048_576
        VStack(spacing: 4) {
            ImageFramesAnimation(ref: ref, size: 300, frames: frames, overlap: 0.02, cycle: 5)
            HStack(spacing: 8) {
                Text(ref, style: .timer)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .leading)
                Text("\(frames.count)f \(side)px \(Int(mb))MB")
                    .font(.system(size: 13))
            }
        }
        .containerBackground(.white, for: .widget)
    }
}

// Отдельные виджеты для телефона: на устройстве лимит памяти расширения настоящий,
// в симуляторе может не соблюдаться. Названия — только литералы.
struct Mem300Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Mem300", provider: ProbeProvider()) { MemoryWidgetView(entry: $0, side: 300) }
            .configurationDisplayName("Mem 300px 14MB").supportedFamilies([.systemLarge])
    }
}

struct Mem510Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Mem510", provider: ProbeProvider()) { MemoryWidgetView(entry: $0, side: 510) }
            .configurationDisplayName("Mem 510px 42MB").supportedFamilies([.systemLarge])
    }
}

struct Mem746Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Mem746", provider: ProbeProvider()) { MemoryWidgetView(entry: $0, side: 746) }
            .configurationDisplayName("Mem 746px 89MB").supportedFamilies([.systemLarge])
    }
}

struct Mem1000Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Mem1000", provider: ProbeProvider()) { MemoryWidgetView(entry: $0, side: 1000) }
            .configurationDisplayName("Mem 1000px 160MB").supportedFamilies([.systemLarge])
    }
}

struct Mem1118Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Mem1118", provider: ProbeProvider()) { MemoryWidgetView(entry: $0, side: 1118) }
            .configurationDisplayName("Mem 1118px 200MB").supportedFamilies([.systemLarge])
    }
}

struct DiagProbeWidget: Widget {
    private static var experimentMode: String? {
        ["len160s", "len80c20", "split160", "grp80", "grp160"]
            .contains(Variant.mode) ? Variant.mode : nil
    }
    private static var lengthCount: Int? {
        Variant.mode.hasPrefix("len") ? Int(Variant.mode.dropFirst(3)) : nil
    }
    private static var memorySide: Int? {
        Variant.mode.hasPrefix("mem") ? Int(Variant.mode.dropFirst(3)) : nil
    }

    var body: some WidgetConfiguration {
        let configuration = StaticConfiguration(kind: "DiagProbe", provider: ProbeProvider()) { entry in
            if let mode = Self.experimentMode {
                LengthExperimentView(entry: entry, mode: mode)
            } else if let side = Self.memorySide {
                MemoryWidgetView(entry: entry, side: side)
            } else if let n = Self.lengthCount {
                LengthWidgetView(entry: entry, count: n)
            } else if Variant.mode == "overlap" {
                OverlapWidgetView(entry: entry)
            } else {
                DiagWidgetView(entry: entry)
            }
        }
        // Только постоянная строка: с подстановкой ("Probe 0: \(Variant.mode)") WidgetKit
        // падает на assert в body, и виджета нет в галерее (прогон 35971719005).
        .configurationDisplayName("Probe 0")
        .supportedFamilies(Self.lengthCount == nil && Self.experimentMode == nil
                           ? [.systemLarge] : [.systemSmall])
        #if LENGTH_EXPERIMENTS
        return configuration.contentMarginsDisabled()
        #else
        return configuration
        #endif
    }
}
