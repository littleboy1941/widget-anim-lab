import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit
import Photos

private struct PhotoSourceFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try copied(received.file, fallbackExtension: "gif")
        }
        FileRepresentation(importedContentType: .movie) { received in
            try copied(received.file, fallbackExtension: "mov")
        }
    }

    private static func copied(_ source: URL, fallbackExtension: String) throws -> PhotoSourceFile {
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= GIFImporter.maxSourceBytes else {
            throw GIFImporter.ImportError.sourceTooLarge
        }
        let ext = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: target)
        return PhotoSourceFile(url: target)
    }
}

private enum LivePhotoVideo {
    static func copy(from item: PhotosPickerItem) async throws -> URL {
        guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else {
            throw AppError(code: "E_READ_FAILED", message: "Не удалось открыть Live Photo.",
                           hint: "Попробуйте экспортировать Live Photo в «Файлы».")
        }
        let resources = PHAssetResource.assetResources(for: livePhoto)
        guard let paired = resources.first(where: { $0.type == .fullSizePairedVideo }) ??
                resources.first(where: { $0.type == .pairedVideo }) else {
            throw AppError(code: "E_NOT_ANIMATED", message: "У Live Photo нет парного видео.",
                           hint: "Выберите Live Photo с движением или отдельное видео.")
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-photo-\(UUID().uuidString).mov")
        do {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: paired, toFile: target,
                    options: options) { failure in
                    if let failure { continuation.resume(throwing: failure) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
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
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos, .livePhotos]),
                             preferredItemEncoding: .current) {
                    Label("Из «Фото»", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.borderedProminent)
                Text("Копирую оригинал во временный файл. Лимит — 150 МБ; видео — до 60 с.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { showFiles = true } label: {
                    Label("Из «Файлов»", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                .buttonStyle(.bordered)
                Text("GIF, APNG, WebP, MP4, MOV или M4V").font(.caption).foregroundStyle(.secondary)
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
        .fileImporter(isPresented: $showFiles, allowedContentTypes:
            [.gif, .png, .webP, .movie, .mpeg4Movie, .quickTimeMovie]) { result in
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
                let isLive = item.supportedContentTypes.contains { $0.conforms(to: .livePhoto) }
                let sourceURL: URL
                if isLive {
                    sourceURL = try await LivePhotoVideo.copy(from: item)
                } else {
                    guard let source = try await item.loadTransferable(type: PhotoSourceFile.self) else {
                        throw AppError(code: "E_READ_FAILED", message: "«Фото» не вернуло исходные данные.",
                                       hint: "Попробуйте экспортировать исходник в «Файлы».")
                    }
                    sourceURL = source.url
                }
                defer { try? FileManager.default.removeItem(at: sourceURL) }
                try Task.checkCancellation()
                let settings = try ProjectDocuments().importFile(sourceURL, name: "Анимация из Фото")
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
    let importer: any AnimationSource
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
                    if let video = info.importer as? VideoSource {
                        row("FPS источника", String(format: "%.2f", video.nominalFrameRate))
                        row("Звук", video.hasAudio ? "есть — игнорируется" : "нет")
                    } else if let gif = info.importer as? GIFImporter {
                        let delays = gif.frames.map(\.rawDuration)
                        row("Задержки", String(format: "%.0f–%.0f мс", (delays.min() ?? 0) * 1000, (delays.max() ?? 0) * 1000))
                        row("Прозрачность", gif.hasTransparency ? "есть" : "не обнаружена")
                        if gif.correctedDelayCount > 0 {
                            warning("\(gif.correctedDelayCount) нулевых/коротких задержек (<20 мс) заменены на 100 мс.")
                        }
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
                let importer = try documents.source(for: settings)
                let first = try importer.thumbnail(at: 0, maxPixelSize: 500)
                return AnalysisInfo(importer: importer, image: UIImage(cgImage: first))
            }.value
            info = value
        } catch { self.error = AppError.convert(error) }
    }
}
