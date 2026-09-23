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
        ImagesProbeWidget()
        FontsProbeWidget()
    }
}
