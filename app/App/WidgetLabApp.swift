import SwiftUI
import UIKit
import WidgetKit

@main
struct WidgetLabApp: App {
    var body: some Scene {
        WindowGroup { ProjectListView().preferredColorScheme(.dark) }
    }
}

enum AppRoute: Hashable {
    case importSource, analysis(UUID), editor(UUID), review(UUID), done(UUID)
}

struct AppErrorView: View {
    let error: AppError
    @State private var loggedID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(error.code).fontWeight(.bold)
            Text(error.message)
            Text(error.hint)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.red)
        .textSelection(.enabled)   // долгое нажатие — скопировать текст ошибки
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { record() }
        .onChange(of: error.id) { _, _ in record() }
    }

    private func record() {
        guard loggedID != error.id else { return }
        loggedID = error.id
        if let store = try? ProjectStore(groupIdentifier: AppGroup.identifier) {
            DiagnosticsLog(root: store.root).append(event: "app_error", projectID: nil,
                detail: "\(error.code): \(error.message)")
        } else if let documents = try? ProjectDocuments() {
            DiagnosticsLog(root: documents.root).append(event: "app_error", projectID: nil,
                detail: "\(error.code): \(error.message)")
        }
    }
}

struct LibraryStatus: Identifiable {
    let size: WidgetSize
    let error: AppError?
    var id: WidgetSize { size }
}

struct LibraryRow: Identifiable {
    let id: UUID
    let name: String
    let date: Date
    let slotCount: Int?
    let fps: Int?
    let duration: Double?
    let thumbnail: UIImage?
    let statuses: [LibraryStatus]
}

struct ProjectListView: View {
    @State private var path: [AppRoute] = []
    @State private var rows: [LibraryRow] = []
    @State private var error: AppError?
    @State private var pendingDelete: UUID?
    @State private var ciStatus: String?
    private let groupID = AppGroup.identifier

    var body: some View {
        NavigationStack(path: $path) {
            List {
                    Text("\(rows.count) проектов").font(.caption).foregroundStyle(.secondary)
                    if let error { AppErrorView(error: error) }
                    ForEach(rows) { row in
                        NavigationLink(value: AppRoute.editor(row.id)) {
                            HStack(spacing: 12) {
                                Group {
                                    if let image = row.thumbnail {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo.on.rectangle").font(.title)
                                    }
                                }
                                .frame(width: 64, height: 64).clipped()
                                .background(.gray.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.name).font(.headline)
                                    if let count = row.slotCount, let fps = row.fps, let duration = row.duration {
                                        Text("\(row.date.formatted(date: .abbreviated, time: .omitted)) · \(count) кадров · \(fps) fps · \(String(format: "%.1f", duration)) с")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text(row.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(row.statuses) { status in
                                        Text(status.error.map { "\(status.size.rawValue.uppercased()): \($0.code) \($0.message)" }
                                             ?? "\(status.size.rawValue.uppercased()): OK")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(status.error == nil ? Color.green : Color.red)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Дублировать", systemImage: "plus.square.on.square") { duplicate(row.id) }
                            Button("Удалить", systemImage: "trash", role: .destructive) { pendingDelete = row.id }
                        }
                        .swipeActions {
                            Button("Удалить", role: .destructive) { pendingDelete = row.id }
                            Button("Дублировать") { duplicate(row.id) }.tint(.blue)
                        }
                    }
                    if rows.isEmpty && error == nil {
                        ContentUnavailableView("Пока нет анимаций", systemImage: "square.stack",
                                               description: Text("Нажмите + и выберите GIF, APNG или WebP."))
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.black)
            .navigationTitle("Мои анимации")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.importSource) } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }.accessibilityLabel("Импорт")
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Тестовые анимации — все GIF из Resources в бандле (в сборку для App Store не идут)
                    Menu {
                        Section("Тестовые анимации") {
                            ForEach(Self.testGIFs, id: \.self) { url in
                                Button(url.deletingPathExtension().lastPathComponent) { importTestGIF(url) }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Тестовые анимации")
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .importSource: ImportView { id in path.append(.analysis(id)) }
                case .analysis(let id): AnalysisView(id: id) { path.append(.editor(id)) }
                case .editor(let id): EditorView(id: id) { path.append(.review(id)) }
                case .review(let id): ReviewView(id: id) { path.append(.done(id)) }
                case .done(let id):
                    DoneView(id: id) { path.removeAll(); refresh() }
                }
            }
            .confirmationDialog("Удалить проект?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("Удалить: виджет покажет ошибку", role: .destructive) {
                    if let id = pendingDelete { delete(id) }
                    pendingDelete = nil
                }
            } message: {
                Text("Если проект выбран в виджете, тот покажет код ошибки и попросит выбрать другую анимацию.")
            }
            .task {
                refresh()
                if ProcessInfo.processInfo.arguments.contains("--ci-import-test") { ciImportAndPublish() }
            }
            .overlay(alignment: .bottom) {
                // метка для UI-теста в CI: импорт и публикация закончились
                if let ciStatus {
                    Text(ciStatus).font(.caption.monospaced()).padding(6)
                        .foregroundStyle(ciStatus == "ci-import-done" ? Color.green : Color.red)
                }
            }
        }
    }

    static var testGIFs: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "gif", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// CI: test.gif → проект → публикация всех размеров без экранов, затем метка "ci-import-done".
    private func ciImportAndPublish() {
        // 12 кадров по 125 мс с цветными метками номера (probe/make_frames.py) —
        // разбор видео (probe/analyze_cells.py, режим idx) видит порядок кадров
        guard let url = Bundle.main.url(forResource: "ci_frames", withExtension: "gif") else {
            ciStatus = "ci-import-failed: ci_frames.gif missing"
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let documents = try ProjectDocuments()
                let settings = try documents.importBytes(Data(contentsOf: url), name: "CI test")
                let importer = try GIFImporter(url: documents.sourceURL(settings))
                let draft = try RenderPipeline.makeDraft(importer: importer, settings: settings)
                try ProjectStore(groupIdentifier: groupID).publish(draft)
                WidgetCenter.shared.reloadAllTimelines()
                await MainActor.run { ciStatus = "ci-import-done"; refresh() }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { ciStatus = "ci-import-failed: \(value.code) \(value.message)" }
            }
        }
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            do {
                let store = try ProjectStore(groupIdentifier: groupID)
                let documents = try ProjectDocuments()
                let manifests = store.list()
                let editable = documents.list()
                let settingsByID = Dictionary(uniqueKeysWithValues: editable.map { ($0.id, $0) })
                var result = manifests.map { manifest -> LibraryRow in
                    var statuses: [LibraryStatus] = []
                    var image: UIImage?
                    for size in WidgetSize.allCases {
                        do {
                            let snapshot = try store.read(manifest.id, size: size)
                            if image == nil { image = snapshot.frames.first }
                            statuses.append(LibraryStatus(size: size, error: nil))
                        } catch {
                            statuses.append(LibraryStatus(size: size, error: AppError.convert(error)))
                        }
                    }
                    let variant = manifest.variants[.small] ?? manifest.variants.values.first
                    return LibraryRow(id: manifest.id, name: settingsByID[manifest.id]?.name ?? manifest.name,
                        date: manifest.createdAt, slotCount: variant?.slotCount, fps: variant?.fps,
                        duration: variant?.outputDuration, thumbnail: image, statuses: statuses)
                }
                let publishedIDs = Set(manifests.map(\.id))
                for settings in editable where !publishedIDs.contains(settings.id) {
                    let importer = try? GIFImporter(url: documents.sourceURL(settings))
                    let plan = importer.flatMap { try? settings.resolvedPlan(importer: $0) }
                    let image = importer.flatMap { try? $0.thumbnail(at: 0, maxPixelSize: 128) }
                        .map { UIImage(cgImage: $0) }
                    let date = (try? documents.directory(settings.id)
                        .appendingPathComponent("settings.json").resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .now
                    let status = AppError(code: "E_NOT_PUBLISHED", message: "Размер ещё не опубликован.",
                                          hint: "Откройте проект и сохраните его.")
                    result.append(LibraryRow(id: settings.id, name: settings.name,
                        date: date, slotCount: plan?.slotCount, fps: plan?.fps,
                        duration: plan?.outputDuration, thumbnail: image,
                        statuses: WidgetSize.allCases.map { LibraryStatus(size: $0, error: status) }))
                }
                result.sort { $0.date > $1.date }
                await MainActor.run { rows = result; error = nil }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { self.error = value }
            }
        }
    }

    private func duplicate(_ id: UUID) {
        Task.detached(priority: .utility) {
            do {
                let documents = try ProjectDocuments()
                let original = try documents.load(id)
                let copy = try documents.duplicate(original)
                let importer = try GIFImporter(url: documents.sourceURL(copy))
                let draft = try RenderPipeline.makeDraft(importer: importer, settings: copy)
                try ProjectStore(groupIdentifier: groupID).publish(draft)
                WidgetCenter.shared.reloadAllTimelines()
                await MainActor.run { refresh() }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { self.error = value }
            }
        }
    }

    private func delete(_ id: UUID) {
        Task.detached(priority: .utility) {
            do {
                try ProjectStore(groupIdentifier: groupID).delete(id)
                try ProjectDocuments().remove(id)
                WidgetCenter.shared.reloadAllTimelines()
                await MainActor.run { refresh() }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { self.error = value }
            }
        }
    }

    private func importTestGIF(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        Task.detached(priority: .utility) {
            do {
                let settings = try ProjectDocuments().importBytes(Data(contentsOf: url), name: name)
                await MainActor.run { path.append(.analysis(settings.id)) }
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { self.error = value }
            }
        }
    }
}

private extension WidgetVariant {
    var outputDuration: Double { Double(slotCount) / Double(fps) }
}
