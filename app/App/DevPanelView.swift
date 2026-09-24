import SwiftUI

struct DevPanelView: View {
    let settings: EditorSettings
    let importer: any AnimationSource
    let plan: AnimationPlanner.Plan?

    @Environment(\.dismiss) private var dismiss
    @State private var published: ProjectManifest?
    @State private var events: [DiagnosticEvent] = []
    @State private var storageError: AppError?
    @State private var integrity: [WidgetSize: String] = [:]
    @State private var freeBytes: Int64?

    private let budget = AnimationBudget.standard

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("ИСТОЧНИК") {
                        datum("Формат", importer.format.localizedDescription ?? importer.format.identifier)
                        datum("Холст", "\(importer.canvasWidth) × \(importer.canvasHeight)")
                        datum("Байты", "\(importer.fileBytes)")
                        datum("Кадры / длительность", "\(importer.frames.count) / \(seconds(importer.totalDuration)) с")
                        if let video = importer as? VideoSource {
                            datum("FPS источника", String(format: "%.2f", video.nominalFrameRate))
                            datum("Звук", video.hasAudio ? "есть — игнорируется" : "нет")
                        } else if let gif = importer as? GIFImporter {
                            let raw = gif.frames.map(\.rawDuration)
                            datum("Задержки min / max", "\(seconds(raw.min() ?? 0)) / \(seconds(raw.max() ?? 0)) с")
                            datum("Заменено <20 мс", "\(gif.correctedDelayCount)")
                            datum("Прозрачность", gif.hasTransparency ? "да" : "нет")
                        }
                    }
                    section("ПЛАН") {
                        datum("Фрагмент", "\(seconds(settings.fragmentStart))–\(seconds(settings.fragmentEnd)) с")
                        datum("Петля / скорость", "\(loopTitle) / ×\(seconds(settings.speed))")
                        if let plan {
                            datum("fps / N / C", "\(plan.fps) / \(plan.slotCount) / \(plan.cycle)")
                            datum("Фаз / таймеров ≈", "\(plan.phaseCount) / \(plan.timerCount)")
                            datum("Длительность выхода", "\(seconds(plan.outputDuration)) с")
                            datum("Уникальных PNG / повторов", "\(plan.uniqueSourceIndices.count) / \(plan.slotCount - plan.uniqueSourceIndices.count)")
                            let selected = settings.selectedFrameIndices(in: importer)
                            datum("Отброшено из фрагмента", "\(max(0, selected.count - Set(plan.sourceIndices).count))")
                            ForEach(plan.sourceIndices.indices, id: \.self) { slot in
                                datum("Слот \(slot + 1)", "источник \(plan.sourceIndices[slot] + 1)")
                            }
                        } else {
                            AppErrorView(error: AppError(code: "E_PLAN_INVALID", message: "Нет допустимого плана.",
                                                         hint: "Исправьте ленту в редакторе."))
                        }
                    }
                    section("ПАМЯТЬ ПО РАЗМЕРАМ") {
                        ForEach(WidgetSize.allCases, id: \.self) { size in
                            if let geometry = settings.geometry[size], let plan {
                                let pixels = geometry.width * geometry.height
                                let decoded = pixels * 4 * plan.uniqueSourceIndices.count
                                let exceeded = pixels > (budget.maxPixels[size] ?? 0) || decoded > budget.maxDecodedBytes
                                Text("\(size.rawValue.uppercased())  \(geometry.width)×\(geometry.height)×4×\(plan.uniqueSourceIndices.count) = \(ByteCountFormatter.string(fromByteCount: Int64(decoded), countStyle: .memory))")
                                    .foregroundStyle(exceeded ? Color.red : Color.green)
                                    .font(.system(size: 12, design: .monospaced))
                            }
                        }
                        datum("Лимит декодирования", ByteCountFormatter.string(fromByteCount: Int64(budget.maxDecodedBytes), countStyle: .memory))
                    }
                    section("ПУБЛИКАЦИЯ") {
                        datum("ID", settings.id.uuidString)
                        if let published {
                            datum("Поколение", published.generation.uuidString)
                            datum("Manifest", "v\(published.version)")
                            if let saved = events.last(where: {
                                $0.event == "published" && $0.projectID == settings.id &&
                                $0.detail == published.generation.uuidString
                            }) {
                                datum("Записано", saved.time.formatted())
                            }
                            ForEach(WidgetSize.allCases, id: \.self) { size in
                                if let variant = published.variants[size] {
                                    datum(size.rawValue.uppercased(), "\(variant.frames.count) PNG · \(variant.frames.map(\.byteCount).reduce(0, +)) байт")
                                    datum("Проверка \(size.rawValue.uppercased())", integrity[size] ?? "…")
                                }
                            }
                        } else {
                            datum("Статус", "Ещё не опубликован")
                        }
                        if let storageError { AppErrorView(error: storageError) }
                        if let freeBytes {
                            datum("Свободно", ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                        }
                        if let reload = events.last(where: { $0.event == "reload_sent" && $0.projectID == settings.id }) {
                            datum("Reload", reload.time.formatted())
                        }
                    }
                    section("ЖУРНАЛ") {
                        if events.isEmpty { Text("Записей нет").foregroundStyle(.secondary) }
                        ForEach(Array(events.indices.suffix(20).reversed()), id: \.self) { index in
                            let entry = events[index]
                            Text("\(entry.time.formatted())  \(entry.event)  \(entry.detail)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            .background(.black)
            .navigationTitle("DEV · диагностика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Закрыть") { dismiss() } }
            .task { await loadPublication() }
        }
        .preferredColorScheme(.dark)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
    }

    private func datum(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f", value) }

    private var loopTitle: String {
        switch settings.loop {
        case .forward: "обычная"
        case .reverse: "обратная"
        case .pingPong: "туда-обратно"
        }
    }

    private func loadPublication() async {
        do {
            let id = settings.id
            let value = try await Task.detached(priority: .utility) { () -> (ProjectManifest?, [DiagnosticEvent], [WidgetSize: String], Int64?) in
                let store = try ProjectStore(groupIdentifier: AppGroup.identifier)
                let manifest = try store.listing().projects.first { $0.id == id }
                var checks: [WidgetSize: String] = [:]
                if let manifest {
                    for size in manifest.variants.keys {
                        do { _ = try store.read(id, size: size); checks[size] = "OK" }
                        catch { checks[size] = AppError.convert(error).code }
                    }
                }
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: store.root.path)
                let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
                return (manifest, DiagnosticsLog(root: store.root).read(), checks, free)
            }.value
            published = value.0; events = value.1; integrity = value.2; freeBytes = value.3
        } catch {
            storageError = AppError.convert(error)
        }
    }
}
