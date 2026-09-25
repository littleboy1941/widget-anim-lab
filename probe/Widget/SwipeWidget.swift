// Опыт 2026-09-25: на телефоне анимация на таймерах замирает, пока идёт переход домашнего
// экрана (свайп страницы, возврат из приложения), потом прыгает; приватное вращение стрелки —
// нет. Большой виджет, три клетки, чтобы сравнить на одной записи:
//   A — наши таймеры-маски, 16 fps, 16 кадров с idx-метками (make_frames.py);
//   B — Text с форматом stopwatch (iOS 18, до сотых долей секунды);
//   C — полосы ProgressView(timerInterval:), по 4 с каждая, 15 полос на минуту.
// Разбор записи — probe/analyze_swipe.py.
import SwiftUI
import WidgetKit

struct SwipeEntry: TimelineEntry {
    let date: Date
}

struct SwipeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SwipeEntry { SwipeEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (SwipeEntry) -> Void) {
        completion(SwipeEntry(date: .now))
    }

    /// Запись в начале каждой минуты: полосы C привязаны к своей минуте.
    /// Сдвиг опорной даты A на целые 60 с фазу анимации не меняет (петля 1 с).
    func getTimeline(in context: Context, completion: @escaping (Timeline<SwipeEntry>) -> Void) {
        let minute = Calendar.current.dateInterval(of: .minute, for: .now)?.start ?? .now
        let entries = (0..<30).map { SwipeEntry(date: minute.addingTimeInterval(Double($0) * 60)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct SwipeExperimentView: View {
    let entry: SwipeEntry

    var body: some View {
        let ref = entry.date - 60
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ImageFramesAnimation(ref: ref, size: 128,
                                     frames: ImageFramesAnimation.experimentFrames(16, prefix: "fps16"),
                                     overlap: 0.01, cycle: 2, fps: 16)
                    .frame(width: 128, height: 128)
                Text(.currentDate, format: .stopwatch(startingAt: ref, maxPrecision: .milliseconds(10)))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .frame(width: 190, height: 128, alignment: .leading)
            }
            VStack(spacing: 2) {
                ForEach(0..<15, id: \.self) { k in
                    let start = entry.date.addingTimeInterval(Double(4 * k))
                    ProgressView(timerInterval: start...start.addingTimeInterval(4), countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
                    .tint(.red)
                }
            }
            .frame(width: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

struct SwipeProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SwipeProbe", provider: SwipeProvider()) {
            SwipeExperimentView(entry: $0)
        }
        .configurationDisplayName("Probe 0")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
