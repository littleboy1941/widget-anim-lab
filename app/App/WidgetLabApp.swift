import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

@main
struct WidgetLabApp: App {
    var body: some Scene {
        WindowGroup { ProjectListView() }
    }
}

struct ProjectListView: View {
    @State private var projects: [ProjectManifest] = []
    @State private var status = ""
    private let groupID = "group.widgetlab.app"

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects, id: \.id) { project in
                    VStack(alignment: .leading) {
                        Text(project.name)
                        Text(project.id.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("Animations")
            .toolbar {
                Button("Import test GIF") { importTestGIF() }
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        do { projects = try ProjectStore(groupIdentifier: groupID).list() }
        catch { status = error.localizedDescription }
    }

    private func importTestGIF() {
        do {
            guard let url = Bundle.main.url(forResource: "test", withExtension: "gif") else {
                status = "Test GIF missing from app bundle"
                return
            }
            let importer = try GIFImporter(url: url)
            let store = try ProjectStore(groupIdentifier: groupID)
            let durations = importer.frames.map(\.duration)
            let plans = try AnimationPlanner.allPlans(
                durations: durations, speed: 1, mode: .forward,
                pixelsPerFrame: 140 * 140, budget: store.budget)
            guard let plan = AnimationPlanner.defaultPlan(
                from: plans.filter { $0.uniqueSourceIndices.count >= 2 },
                durations: durations, speed: 1, mode: .forward) else {
                status = "No valid animation plan"
                return
            }
            var variants: [WidgetSize: VariantDraft] = [:]
            for (size, side) in [(WidgetSize.small, 100), (.medium, 120), (.large, 140)] {
                var png: [Data] = []
                for sourceIndex in plan.uniqueSourceIndices {
                    let source = try importer.thumbnail(at: sourceIndex, maxPixelSize: side)
                    var options = FrameProcessor.Options()
                    options.size = side
                    let frame = try FrameProcessor.process(source, options: options)
                    let bytes = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(
                        bytes as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                        throw ProjectReadError.frameInvalid("PNG encoder unavailable")
                    }
                    CGImageDestinationAddImage(destination, frame, nil)
                    guard CGImageDestinationFinalize(destination) else {
                        throw ProjectReadError.frameInvalid("PNG encode failed")
                    }
                    png.append(bytes as Data)
                }
                variants[size] = VariantDraft(width: side, height: side, fps: plan.fps,
                    cycle: plan.cycle, slotCount: plan.slotCount,
                    phaseToFrame: plan.phaseToFrame,
                    overlapSeconds: store.budget.overlapSeconds,
                    background: nil, pixelArt: false, pngData: png)
            }
            let draft = ProjectDraft(id: UUID(), name: "Test GIF", createdAt: .now,
                                     variants: variants)
            try store.publish(draft)
            WidgetCenter.shared.reloadAllTimelines()
            status = ""
            refresh()
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }
}
