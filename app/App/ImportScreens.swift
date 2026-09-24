import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

private struct PhotoSourceFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let source = received.file
            let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes <= GIFImporter.maxSourceBytes else {
                throw GIFImporter.ImportError.sourceTooLarge
            }
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: target)
            return PhotoSourceFile(url: target)
        }
    }
}

struct ImportView: View {
    let onImported: (UUID) -> Void
    @State private var photo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var progress = 0.0
    @State private var working = false
    @State private var error: AppError?
    @State private var worker: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PhotosPicker(selection: $photo, matching: .images,
                             preferredItemEncoding: .current) {
                    Label("Из «Фото»", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                Text("Копирую оригинал во временный файл. Лимит исходника — 150 МБ и 80 Мпикс.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showFiles = true } label: {
                    Label("Из «Файлов»", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.bordered)
                Text("GIF, APNG или WebP").font(.caption).foregroundStyle(.secondary)
                if working {
                    ProgressView(value: progress)
                    Button("Остановить", role: .cancel) {
                        worker?.cancel()
                        working = false
                    }
                }
                if let error { AppErrorView(error: error) }
            }.padding(16)
        }
        .background(.black)
        .navigationTitle("Импорт анимации")
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.gif, .png, .webP]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let failure): report(failure)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
        .onDisappear { worker?.cancel() }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        working = true; progress = 0; error = nil
        worker = Task.detached(priority: .userInitiated) {
            do {
                guard let source = try await item.loadTransferable(type: PhotoSourceFile.self) else {
                    throw AppError(code: "E_READ_FAILED", message: "«Фото» не вернуло исходные данные.",
                                   hint: "Попробуйте экспортировать GIF в «Файлы».")
                }
                defer { try? FileManager.default.removeItem(at: source.url) }
                try Task.checkCancellation()
                let settings = try ProjectDocuments().importFile(source.url, name: "Анимация из Фото")
                try Task.checkCancellation()
                await MainActor.run { working = false; onImported(settings.id) }
            } catch {
                await MainActor.run { report(error) }
            }
        }
    }

    private func importFile(_ url: URL) {
        working = true; progress = 0; error = nil
        worker = Task.detached(priority: .userInitiated) {
            do {
                let settings = try ProjectDocuments().importFile(url,
                    name: url.deletingPathExtension().lastPathComponent) { value in
                    Task { @MainActor in progress = value }
                }
                try Task.checkCancellation()
                await MainActor.run { working = false; onImported(settings.id) }
            } catch {
                await MainActor.run { report(error) }
            }
        }
    }

    private func report(_ failure: Error) {
        working = false
        if failure is CancellationError { return }
        let value = AppError.convert(failure)
        self.error = value
        if let documents = try? ProjectDocuments() {
            DiagnosticsLog(root: documents.root).append(event: "import_error", projectID: nil,
                                                  detail: "\(value.code): \(value.message)")
        }
    }
}

private struct AnalysisInfo {
    let importer: GIFImporter
    let image: UIImage
}

struct AnalysisView: View {
    let id: UUID
    let onEdit: () -> Void
    @State private var info: AnalysisInfo?
    @State private var error: AppError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let info {
                    Image(uiImage: info.image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 250)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
                    row("Формат", info.importer.format.localizedDescription ?? info.importer.format.identifier)
                    row("Размер", ByteCountFormatter.string(fromByteCount: Int64(info.importer.fileBytes), countStyle: .file))
                    row("Холст", "\(info.importer.canvasWidth) × \(info.importer.canvasHeight)")
                    row("Кадры", "\(info.importer.frames.count)")
                    row("Длительность", String(format: "%.2f с", info.importer.totalDuration))
                    let delays = info.importer.frames.map(\.rawDuration)
                    row("Задержки", String(format: "%.0f–%.0f мс", (delays.min() ?? 0) * 1000, (delays.max() ?? 0) * 1000))
                    row("Прозрачность", info.importer.hasTransparency ? "есть" : "не обнаружена")
                    if info.importer.correctedDelayCount > 0 {
                        warning("\(info.importer.correctedDelayCount) нулевых/коротких задержек (<20 мс) заменены на 100 мс.")
                    }
                    if info.importer.totalDuration > 5 {
                        warning("Анимация длиннее типового плана 8 fps. В редакторе предложен фрагмент; можно выбрать целиком с меньшим fps.")
                    }
                    if info.importer.fileBytes > 20 * 1_048_576 {
                        warning("Большой исходник. Публикация может занять заметное время.")
                    }
                    Button("Открыть редактор", action: onEdit)
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                } else if let error {
                    AppErrorView(error: error)
                } else {
                    ProgressView("Анализирую исходник…")
                }
            }.padding(16)
        }
        .background(.black)
        .navigationTitle("Анализ исходника")
        .task(id: id) { await load() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
            .padding(10).background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
    }
    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.yellow)
            .padding(10).background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
    private func load() async {
        do {
            let value = try await Task.detached(priority: .utility) { () -> AnalysisInfo in
                let documents = try ProjectDocuments()
                let settings = try documents.load(id)
                let importer = try GIFImporter(url: documents.sourceURL(settings))
                let first = try importer.thumbnail(at: 0, maxPixelSize: 500)
                return AnalysisInfo(importer: importer, image: UIImage(cgImage: first))
            }.value
            info = value
        } catch { self.error = AppError.convert(error) }
    }
}
