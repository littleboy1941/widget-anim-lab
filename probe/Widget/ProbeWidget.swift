// Два виджета для проверки на телефоне: вариант A (цветные шрифты) и B (картинки под масками).
// Timeline — одна запись, .never: после первой отрисовки код расширения не нужен.
import SwiftUI
import WidgetKit

struct ProbeEntry: TimelineEntry {
    let date: Date
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: .now)], policy: .never))
    }
}

struct ProbeWidgetView: View {
    let entry: ProbeEntry
    let useFonts: Bool

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let ref = entry.date - 60
            Group {
                if useFonts {
                    FontFramesAnimation(ref: ref, size: side)
                } else {
                    ImageFramesAnimation(ref: ref, size: side, frames: ImageFramesAnimation.bundledFrames())
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct FontsProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FontsProbe", provider: ProbeProvider()) { entry in
            ProbeWidgetView(entry: entry, useFonts: true)
        }
        .configurationDisplayName("Probe A: fonts")
        .supportedFamilies([.systemSmall])
    }
}

struct ImagesProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ImagesProbe", provider: ProbeProvider()) { entry in
            ProbeWidgetView(entry: entry, useFonts: false)
        }
        .configurationDisplayName("Probe B: images")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ProbeWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Первым — диагностика: UI-тест в симуляторе добавляет первый виджет из галереи.
        DiagProbeWidget()
        #if LENGTH_EXPERIMENTS
        // CI length matrix and the grp80 IPA: 5 experiments + 3 existing = 8.
        Len160SmallWidget()
        Len80Cycle20Widget()
        Split160Widget()
        Group80Widget()
        Group160Widget()
        #else
        // Keep the original memory gallery in ordinary builds.
        Mem300Widget()
        Mem510Widget()
        Mem746Widget()
        Mem1000Widget()
        Mem1118Widget()
        #endif
        ImagesProbeWidget()
        FontsProbeWidget()
    }
}
