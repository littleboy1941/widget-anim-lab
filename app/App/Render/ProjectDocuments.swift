import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Editable sources live in Application Support, outside the widget App Group.
final class ProjectDocuments {
    let root: URL
    private let fm = FileManager.default

    init(root: URL? = nil) throws {
        if let root { self.root = root }
        else {
            self.root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
                .appendingPathComponent("editor-projects", isDirectory: true)
        }
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func directory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func sourceURL(_ settings: EditorSettings) -> URL {
        directory(settings.id).appendingPathComponent(settings.sourceFile)
    }

    func load(_ id: UUID) throws -> EditorSettings {
        try JSONDecoder().decode(EditorSettings.self,
            from: Data(contentsOf: directory(id).appendingPathComponent("settings.json")))
    }

    func save(_ settings: EditorSettings) throws {
        try fm.createDirectory(at: directory(settings.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(
            to: directory(settings.id).appendingPathComponent("settings.json"), options: .atomic)
    }

    func remove(_ id: UUID) throws {
        let url = directory(id)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    func list() -> [EditorSettings] {
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap { try? load($0) } }
    }

    func duplicate(_ settings: EditorSettings) throws -> EditorSettings {
        let newID = UUID()
        let destination = directory(newID)
        try fm.copyItem(at: directory(settings.id), to: destination)
        var copy = settings
        copy.id = newID
        copy.name += " — копия"
        try save(copy)
        return copy
    }

    func importBytes(_ data: Data, name: String) throws -> EditorSettings {
        try Task.checkCancellation()
        let type = try Self.validateType(data)
        let id = UUID()
        let sourceName = "source.\(type.preferredFilenameExtension ?? "gif")"
        let folder = directory(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let source = folder.appendingPathComponent(sourceName)
            try data.write(to: source, options: .atomic)
            try Task.checkCancellation()
            let importer = try GIFImporter(url: source)
            let settings = try initialSettings(id: id, name: name, sourceName: sourceName,
                                               importer: importer)
            try save(settings)
            return settings
        } catch {
            try? fm.removeItem(at: folder)
            DiagnosticsLog(root: root).append(event: "import_error", projectID: id,
                                              detail: String(describing: error))
            throw error
        }
    }

    func importFile(_ url: URL, name: String,
                    progress: (Double) -> Void = { _ in }) throws -> EditorSettings {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let folder = directory(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("incoming")
        do {
            guard fm.createFile(atPath: temporary.path, contents: nil) else {
                throw AppError(code: "E_READ_FAILED", message: "Не удалось создать копию.",
                               hint: "Проверьте свободное место.")
            }
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? input.close(); try? output.close() }
            let total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var written = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                written += chunk.count
                if total > 0 { progress(min(1, Double(written) / Double(total))) }
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            let type = try Self.validateType(data)
            let sourceName = "source.\(type.preferredFilenameExtension ?? "gif")"
            let source = folder.appendingPathComponent(sourceName)
            try fm.moveItem(at: temporary, to: source)
            let importer = try GIFImporter(url: source)
            let settings = try initialSettings(id: id, name: name, sourceName: sourceName,
                                               importer: importer)
            try save(settings)
            return settings
        } catch {
            try? fm.removeItem(at: folder)
            DiagnosticsLog(root: root).append(event: "import_error", projectID: id,
                                              detail: String(describing: error))
            throw error
        }
    }

    private static func validateType(_ data: Data) throws -> UTType {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache as String: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Файл не является изображением.",
                           hint: "Выберите GIF, APNG или WebP.")
        }
        guard type.conforms(to: .gif) || type.conforms(to: .png) || type.conforms(to: .webP) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Тип \(type.localizedDescription ?? type.identifier) не поддерживается.",
                           hint: "Выберите GIF, APNG или WebP, а не видео или Live Photo.")
        }
        guard CGImageSourceGetCount(source) > 1 else {
            throw AppError(code: "E_NOT_ANIMATED", message: "В файле один кадр.",
                           hint: "Выберите анимированный GIF, APNG или WebP.")
        }
        return type
    }

    private func initialSettings(id: UUID, name: String, sourceName: String,
                                 importer: GIFImporter) throws -> EditorSettings {
        var settings = EditorSettings(id: id, name: name,
                                      sourceFile: sourceName, duration: importer.totalDuration)
        let plans = try settings.availablePlans(importer: importer)
        guard let plan = AnimationPlanner.defaultPlan(
            from: plans.filter { $0.uniqueSourceIndices.count >= 2 },
            durations: settings.selectedFrameIndices(in: importer).map { importer.frames[$0].duration },
            speed: 1, mode: .forward) ?? plans.first else {
            throw AppError(code: "E_PLAN_INVALID", message: "Для исходника нет допустимого плана.",
                           hint: "Выберите более короткий фрагмент или уменьшите разрешение.")
        }
        settings.selectedPlan = PlanChoice(plan)
        return settings
    }
}
