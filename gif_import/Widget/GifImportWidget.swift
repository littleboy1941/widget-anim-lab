import SwiftUI
import WidgetKit

private struct ImportEntry: TimelineEntry {
    let date: Date
    let message: String
}

private struct ImportProvider: TimelineProvider {
    func placeholder(in context: Context) -> ImportEntry {
        ImportEntry(date: .now, message: "GifImport")
    }

    func getSnapshot(in context: Context, completion: @escaping (ImportEntry) -> Void) {
        completion(ImportEntry(date: .now, message: "GifImport"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ImportEntry>) -> Void) {
        let message: String
        do {
            let snapshot = try FrameStore(groupIdentifier: "group.test").readCurrent()
            message = "Frames: \(snapshot.manifest.frameCount)"
        } catch {
            message = "Store error: \(error.localizedDescription)"
        }
        let entry = ImportEntry(date: .now, message: message)
        completion(Timeline(entries: [entry], policy: .never))
    }
}

private struct ImportWidget: Widget {
    let kind = "GifImportWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ImportProvider()) { entry in
            Text(entry.message)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("GifImport")
        .description("FrameStore compilation probe")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct GifImportWidgetBundle: WidgetBundle {
    var body: some Widget {
        ImportWidget()
    }
}
