import AppIntents
import SwiftUI
import WidgetKit

private enum WidgetEnvironment {
    static var groupID: String { AppGroup.identifier }
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
        return try store.listing().projects.filter { identifiers.contains($0.id) }
            .map { AnimationEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [AnimationEntity] {
        let store = try ProjectStore(groupIdentifier: WidgetEnvironment.groupID)
        return try store.listing().projects.map { AnimationEntity(id: $0.id, name: $0.name) }
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
        let size: WidgetSize
        switch family {
        case .systemSmall: size = .small
        case .systemMedium: size = .medium
        case .systemLarge: size = .large
        default: size = .small
        }
        do {
            let store = try ProjectStore(groupIdentifier: WidgetEnvironment.groupID)
            let latest: UUID?
            var listingFailure: ProjectReadError?
            if configuration.animation == nil {
                let listing = try store.listing()
                latest = listing.projects.max { $0.createdAt < $1.createdAt }?.id
                listingFailure = listing.diagnostics.values.first
            } else { latest = nil }
            guard let id = configuration.animation?.id ?? latest else {
                return AnimationEntry(date: date, configuration: configuration, snapshot: nil,
                    failure: listingFailure ?? .manifestInvalid("no animations yet: import one in the app"))
            }
            let snapshot = try store.read(id, size: size)
            return AnimationEntry(date: date, configuration: configuration,
                                  snapshot: snapshot, failure: nil)
        } catch {
            let failure = (error as? ProjectReadError) ??
                .manifestInvalid("read failed: \(error.localizedDescription)")
            if let store = try? ProjectStore(groupIdentifier: WidgetEnvironment.groupID) {
                DiagnosticsLog(root: store.root, maxBytes: store.budget.maxLogBytes).append(
                    event: "widget_read_error", projectID: configuration.animation?.id,
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
                    .modifier(WidgetBackground(color: snapshot.variant.background))
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

/// Без цветного фона — системное стекло тем же модификатором, что у виджета Мононо.
private struct WidgetBackground: ViewModifier {
    let color: CanvasColor?

    func body(content: Content) -> some View {
        if let color {
            content.containerBackground(Color(red: Double(color.red) / 255,
                                              green: Double(color.green) / 255,
                                              blue: Double(color.blue) / 255), for: .widget)
        } else {
            content.containerBackground(.fill.tertiary, for: .widget)
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
        // поля убраны: пиксель-арт ставится сам (≈90 % ширины, к низу), остальное — с отступом 12
        .contentMarginsDisabled()
    }
}

@main
struct AnimationWidgetBundle: WidgetBundle {
    var body: some Widget { AnimationWidget() }
}
