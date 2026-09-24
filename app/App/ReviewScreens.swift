import SwiftUI
import WidgetKit
import UIKit

struct ReviewView: View {
    let id: UUID
    let onSaved: () -> Void
    @State private var settings: EditorSettings?
    @State private var importer: GIFImporter?
    @State private var plan: AnimationPlanner.Plan?
    @State private var included = Set(WidgetSize.allCases)
    @State private var error: AppError?
    @State private var progress = 0.0
    @State private var publishing = false
    @State private var worker: Task<Void, Never>?
    @State private var seamImages: [UIImage] = []
    @State private var seamDifferent = false

    private var sizeErrors: [WidgetSize: AppError] {
        guard let settings, let plan else { return [:] }
        return Dictionary(uniqueKeysWithValues: WidgetSize.allCases.compactMap { size in
            RenderPipeline.sizeError(size, settings: settings, plan: plan).map { (size, $0) }
        })
    }

    private var canSave: Bool {
        plan != nil && !included.isEmpty && included.allSatisfy { sizeErrors[$0] == nil } && !publishing
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("ЧТО ИЗМЕНИТСЯ ОТНОСИТЕЛЬНО ИСХОДНИКА")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                if let settings, let importer, let plan {
                    if settings.fragmentStart > 0 || settings.fragmentEnd < importer.totalDuration {
                        compromise(String(format: "Взят фрагмент %.2f–%.2f с из %.2f с",
                                          settings.fragmentStart, settings.fragmentEnd, importer.totalDuration))
                    }
                    let selected = settings.selectedFrameIndices(in: importer)
                    let dropped = max(0, selected.count - Set(plan.sourceIndices).count)
                    if dropped > 0 { compromise("Отброшено \(dropped) исходных кадров") }
                    if Set(selected.map { importer.frames[$0].duration.rounded(to: 3) }).count > 1 {
                        compromise("Неравномерные задержки выровнены до \(plan.fps) fps")
                    }
                    if settings.speed != 1 { compromise("Скорость ×\(String(format: "%.2f", settings.speed))") }
                    if importer.correctedDelayCount > 0 {
                        compromise("\(importer.correctedDelayCount) коротких задержек → 100 мс")
                    }
                    if seamImages.count == 2 {
                        Text("СТЫК ПЕТЛИ: ПОСЛЕДНИЙ → ПЕРВЫЙ")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(seamImages.indices, id: \.self) { index in
                                Image(uiImage: seamImages[index]).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 110)
                            }
                        }
                        if seamDifferent {
                            compromise("На стыке возможен скачок. Попробуйте петлю «туда-обратно».")
                        }
                    }
                    Text("РАЗМЕРЫ").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(WidgetSize.allCases, id: \.self) { size in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(size.rawValue.uppercased(), isOn: Binding(
                                get: { included.contains(size) },
                                set: { enabled in
                                    if enabled { included.insert(size) } else { included.remove(size) }
                                }))
                            if let failure = sizeErrors[size] {
                                AppErrorView(error: failure)
                                HStack {
                                    Button("Снизить разрешение") { fixResolution(size) }
                                    Button("План «Надёжно»") { reliablePlan() }
                                }.font(.caption)
                            } else {
                                Text("OK · \(settings.geometry[size]?.width ?? 0) × \(settings.geometry[size]?.height ?? 0)")
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.green)
                            }
                        }
                        .padding(12).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("Если размер выключен, его виджет покажет понятную ошибку. Предыдущая версия остаётся рабочей до успешной публикации.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if error == nil {
                    ProgressView("Проверяю…")
                }
                if let error { AppErrorView(error: error) }
                if publishing {
                    ProgressView(value: progress)
                    Button("Отменить") { worker?.cancel(); publishing = false }
                }
                Button("Сохранить") { publish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .frame(maxWidth: .infinity)
            }.padding(16)
        }
        .background(.black)
        .navigationTitle("Проверка")
        .task(id: id) { await load() }
        .onDisappear { worker?.cancel() }
    }

    private func compromise(_ value: String) -> some View {
        Text("• " + value).font(.callout)
    }

    private func load() async {
        do {
            let result = try await Task.detached(priority: .utility) { () -> (EditorSettings, GIFImporter) in
                let documents = try ProjectDocuments()
                let settings = try documents.load(id)
                return (settings, try GIFImporter(url: documents.sourceURL(settings)))
            }.value
            settings = result.0; importer = result.1
            refreshPlan()
            if let plan, let firstIndex = plan.sourceIndices.first,
               let lastIndex = plan.sourceIndices.last {
                let value = try? await Task.detached(priority: .utility) { () -> (Data, Data) in
                    let last = try RenderPipeline.previewFrame(importer: result.1,
                        settings: result.0, size: .small, sourceIndex: lastIndex)
                    let first = try RenderPipeline.previewFrame(importer: result.1,
                        settings: result.0, size: .small, sourceIndex: firstIndex)
                    return (last, first)
                }.value
                if let value, let last = UIImage(data: value.0), let first = UIImage(data: value.1) {
                    seamImages = [last, first]
                    seamDifferent = value.0 != value.1
                }
            }
        } catch { self.error = AppError.convert(error) }
    }

    private func refreshPlan() {
        guard let settings, let importer else { return }
        do { plan = try settings.resolvedPlan(importer: importer); error = nil }
        catch { plan = nil; error = AppError.convert(error) }
    }

    private func fixResolution(_ size: WidgetSize) {
        guard var settings, let plan, var geometry = settings.geometry[size] else { return }
        let pixelBudget = AnimationBudget.standard.maxPixels[size] ?? 1
        let memoryPixels = AnimationBudget.standard.maxDecodedBytes /
            max(1, 4 * plan.uniqueSourceIndices.count)
        let allowed = max(1, min(pixelBudget, memoryPixels))
        let current = max(1, geometry.width * geometry.height)
        let scale = min(0.9, sqrt(Double(allowed) / Double(current)) * 0.98)
        geometry.width = max(32, Int(Double(geometry.width) * scale))
        geometry.height = max(32, Int(Double(geometry.height) * scale))
        settings.geometry[size] = geometry
        self.settings = settings
        do { try ProjectDocuments().save(settings); refreshPlan() }
        catch { error = AppError.convert(error) }
    }

    private func reliablePlan() {
        guard var settings, let importer else { return }
        do {
            let plans = try settings.availablePlans(importer: importer)
            guard let choice = plans.min(by: { $0.phaseCount < $1.phaseCount }) else {
                throw AppError(code: "E_PLAN_INVALID", message: "Нет допустимого плана.",
                               hint: "Вернитесь в редактор и сократите ленту.")
            }
            settings.selectedPlan = PlanChoice(choice)
            try ProjectDocuments().save(settings)
            self.settings = settings
            refreshPlan()
        } catch { self.error = AppError.convert(error) }
    }

    private func publish() {
        guard canSave, let settings else { return }
        publishing = true; progress = 0; error = nil
        let sizes = included
        worker = Task.detached(priority: .userInitiated) {
            do {
                let documents = try ProjectDocuments()
                let importer = try GIFImporter(url: documents.sourceURL(settings))
                let draft = try RenderPipeline.makeDraft(importer: importer,
                    settings: settings, sizes: sizes) { value in
                    Task { @MainActor in progress = value }
                }
                try Task.checkCancellation()
                let store = try ProjectStore(groupIdentifier: "group.widgetlab.app")
                try store.publish(draft)
                WidgetCenter.shared.reloadAllTimelines()
                DiagnosticsLog(root: store.root).append(event: "reload_sent", projectID: id,
                                                      detail: Date().description)
                await MainActor.run { publishing = false; onSaved() }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { publishing = false; self.error = value }
            }
        }
    }
}

struct DoneView: View {
    let id: UUID
    let onLibrary: () -> Void
    @State private var manifest: ProjectManifest?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("\(manifest?.name ?? "Анимация") сохранена").font(.title2.bold())
            if let manifest {
                Text("Размеры: \(manifest.variants.keys.map { $0.rawValue.uppercased() }.sorted().joined(separator: ", ")) · поколение \(manifest.generation.uuidString.prefix(8))")
                    .font(.caption.monospaced())
            }
            step(1, "Зажмите пустое место на домашнем экране.")
            step(2, "«Изменить» → «Добавить виджет» → WidgetLab.")
            step(3, "Зажмите виджет → «Изменить виджет» → Animation: выберите эту анимацию.")
            Text("Пример ошибки виджета:").font(.caption).foregroundStyle(.secondary)
            Text("PROJECT_DELETED\nProject deleted. Choose another animation.")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
            Spacer()
            Button("В библиотеку", action: onLibrary).buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.black)
        .navigationTitle("Готово")
        .task {
            manifest = try? ProjectStore(groupIdentifier: "group.widgetlab.app").list().first { $0.id == id }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.title3.bold()).foregroundStyle(.blue).frame(width: 25)
            Text(text)
        }
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
