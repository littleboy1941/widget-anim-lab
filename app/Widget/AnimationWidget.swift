import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetEnvironment {
    static let groupID = "group.widgetlab.app"
    static let kind = "WidgetLabAnimation"
}

struct AnimationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Animation"
    static var defaultQuery = AnimationQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct AnimationQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [AnimationEntity] {
        let store = try ProjectStore(groupIdentifier: WidgetEnvironment.groupID)
        return store.list().filter { identifiers.contains($0.id) }
            .map { AnimationEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [AnimationEntity] {
        let store = try ProjectStore(groupIdentifier: WidgetEnvironment.groupID)
        return store.list().map { AnimationEntity(id: $0.id, name: $0.name) }
    }
}

struct AnimationConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Animated Widget"
    static var description = IntentDescription("Choose an animation from your library.")

    @Parameter(title: "Animation") var animation: AnimationEntity?
    @Parameter(title: "Diagnostics", default: false) var diagnostics: Bool
}

struct AnimationEntry: TimelineEntry {
    let date: Date
    let configuration: AnimationConfigurationIntent
    let snapshot: ProjectSnapshot?
    let failure: ProjectReadError?
}

struct AnimationProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AnimationEntry {
        AnimationEntry(date: .now, configuration: AnimationConfigurationIntent(),
                       snapshot: nil, failure: nil)
    }

    func snapshot(for configuration: AnimationConfigurationIntent,
                  in context: Context) async -> AnimationEntry {
        load(configuration, family: context.family)
    }

    func timeline(for configuration: AnimationConfigurationIntent,
                  in context: Context) async -> Timeline<AnimationEntry> {
        Timeline(entries: [load(configuration, family: context.family)], policy: .never)
    }

    private func load(_ configuration: AnimationConfigurationIntent,
                      family: WidgetFamily) -> AnimationEntry {
        let date = Date()
        // Анимация не выбрана — показываем последнюю сохранённую (удобно сразу после
        // добавления виджета; на этом же держится проверка в CI).
        let latest = (try? ProjectStore(groupIdentifier: WidgetEnvironment.groupID))?
            .list().max { $0.createdAt < $1.createdAt }?.id
        guard let id = configuration.animation?.id ?? latest else {
            return AnimationEntry(date: date, configuration: configuration, snapshot: nil,
                                  failure: .manifestInvalid("no animations yet: import one in the app"))
        }
        let size: WidgetSize
        switch family {
        case .systemSmall: size = .small
        case .systemMedium: size = .medium
        case .systemLarge: size = .large
        default: size = .small
        }
        do {
            let store = try ProjectStore(groupIdentifier: WidgetEnvironment.groupID)
            let snapshot = try store.read(id, size: size)
            return AnimationEntry(date: date, configuration: configuration,
                                  snapshot: snapshot, failure: nil)
        } catch {
            let failure = (error as? ProjectReadError) ??
                .manifestInvalid("read failed: \(error.localizedDescription)")
            if let store = try? ProjectStore(groupIdentifier: WidgetEnvironment.groupID) {
                DiagnosticsLog(root: store.root, maxBytes: store.budget.maxLogBytes).append(
                    event: "widget_read_error", projectID: id,
                    detail: "\(failure.code): \(failure.message)")
            }
            return AnimationEntry(date: date, configuration: configuration,
                                  snapshot: nil, failure: failure)
        }
    }
}

struct AnimationWidgetView: View {
    let entry: AnimationEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                ImageFramesAnimation(reference: entry.date.addingTimeInterval(-60),
                                     variant: snapshot.variant, frames: snapshot.frames)
                    .overlay(alignment: .topLeading) {
                        if entry.configuration.diagnostics {
                            Text("\(snapshot.variant.fps) fps / \(snapshot.variant.slotCount) slots / \(snapshot.variant.cycle)s / \(snapshot.variant.decodedBytes / 1_048_576) MB")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.black)
                                .padding(3)
                                .background(.white.opacity(0.85))
                        }
                    }
                    .containerBackground(for: .widget) {
                        if let bg = snapshot.variant.background {
                            Color(red: Double(bg.red) / 255, green: Double(bg.green) / 255,
                                  blue: Double(bg.blue) / 255)
                        } else {
                            Color.clear
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.failure?.code ?? "NO_ANIMATION")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text(entry.failure?.message ?? "Choose an animation.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .containerBackground(.white, for: .widget)
            }
        }
    }
}

struct AnimationWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetEnvironment.kind,
                               intent: AnimationConfigurationIntent.self,
                               provider: AnimationProvider()) { entry in
            AnimationWidgetView(entry: entry)
        }
        .configurationDisplayName("Animated Widget")
        .description("Play an animation from your library.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct AnimationWidgetBundle: WidgetBundle {
    var body: some Widget { AnimationWidget() }
}
