import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Editable sources live in Application Support, outside the widget App Group.
final class ProjectDocuments {
    struct Listing {
        let projects: [EditorSettings]
        let diagnostics: [UUID: AppError]
    }
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

    func source(for settings: EditorSettings) throws -> any AnimationSource {
        let url = sourceURL(settings)
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || Self.isVideoExtension(url.pathExtension) {
            return try VideoSource(url: url)
        }
        return try GIFImporter(url: url)
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

    func list() throws -> Listing {
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var projects: [EditorSettings] = []
        var diagnostics: [UUID: AppError] = [:]
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            do { projects.append(try load(id)) }
            catch { diagnostics[id] = AppError(code: "E_SETTINGS_INVALID",
                message: "Настройки проекта \(id) не читаются: \(error.localizedDescription)",
                hint: "Восстановите проект из резервной копии или удалите его.") }
        }
        return Listing(projects: projects, diagnostics: diagnostics)
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
        guard data.count <= GIFImporter.maxSourceBytes else { throw GIFImporter.ImportError.sourceTooLarge }
        let type = try Self.validateType(data, name: name)
        let id = UUID()
        let sourceName = Self.sourceName(type: type, originalName: name)
        let folder = directory(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let source = folder.appendingPathComponent(sourceName)
            try data.write(to: source, options: .atomic)
            try Task.checkCancellation()
            let importer = try self.source(at: source, type: type)
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
            let total = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard total <= GIFImporter.maxSourceBytes else { throw GIFImporter.ImportError.sourceTooLarge }
            var written = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                guard written <= GIFImporter.maxSourceBytes - chunk.count else {
                    throw GIFImporter.ImportError.sourceTooLarge
                }
                try output.write(contentsOf: chunk)
                written += chunk.count
                if total > 0 { progress(min(1, Double(written) / Double(total))) }
            }
            let type = try Self.validateType(temporary, name: url.lastPathComponent)
            let sourceName = Self.sourceName(type: type, originalName: url.lastPathComponent)
            let source = folder.appendingPathComponent(sourceName)
            try fm.moveItem(at: temporary, to: source)
            let importer = try self.source(at: source, type: type)
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

    private func source(at url: URL, type: UTType) throws -> any AnimationSource {
        if type.conforms(to: .movie) || Self.isVideoExtension(url.pathExtension) {
            return try VideoSource(url: url)
        }
        return try GIFImporter(url: url)
    }

    private static func validateType(_ data: Data, name: String) throws -> UTType {
        let ext = URL(fileURLWithPath: name).pathExtension
        if Self.isVideoExtension(ext) { return UTType(filenameExtension: ext) ?? .mpeg4Movie }
        if let video = Self.sniffVideoType(data) { return video }
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache as String: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Файл не является изображением.",
                           hint: "Выберите GIF, APNG, WebP, MP4, MOV или M4V.")
        }
        guard CGImageSourceGetCount(source) > 1 else {
            throw AppError(code: "E_NOT_ANIMATED", message: "В файле один кадр.",
                           hint: "Выберите анимированный GIF, APNG или WebP.")
        }
        guard type.conforms(to: .gif) || type.conforms(to: .png) || type.conforms(to: .webP) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Тип \(type.localizedDescription ?? type.identifier) не поддерживается.",
                           hint: "Выберите GIF, APNG, WebP, MP4, MOV или M4V.")
        }
        return type
    }

    private static func validateType(_ url: URL, name: String) throws -> UTType {
        let ext = URL(fileURLWithPath: name).pathExtension
        if Self.isVideoExtension(ext) { return UTType(filenameExtension: ext) ?? .mpeg4Movie }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if let header = try handle.read(upToCount: 12),
           let video = Self.sniffVideoType(header) { return video }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache as String: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Файл не является изображением.",
                           hint: "Выберите GIF, APNG, WebP, MP4, MOV или M4V.")
        }
        guard CGImageSourceGetCount(source) > 1 else {
            throw AppError(code: "E_NOT_ANIMATED", message: "В файле один кадр.",
                           hint: "Выберите анимированный файл.")
        }
        guard type.conforms(to: .gif) || type.conforms(to: .png) || type.conforms(to: .webP) else {
            throw AppError(code: "E_UNSUPPORTED_TYPE", message: "Формат не поддерживается.",
                           hint: "Выберите GIF, APNG, WebP, MP4, MOV или M4V.")
        }
        return type
    }

    private func initialSettings(id: UUID, name: String, sourceName: String,
                                 importer: any AnimationSource) throws -> EditorSettings {
        var settings = EditorSettings(id: id, name: name,
                                      sourceFile: sourceName, duration: importer.totalDuration)
        let plans = try settings.availablePlans(importer: importer)
        guard let plan = AnimationPlanner.defaultPlan(
            from: plans.filter { $0.uniqueSourceIndices.count >= 2 },
            durations: settings.selectedFrameDurations(in: importer),
            speed: 1, mode: .forward) ?? plans.first else {
            throw AppError(code: "E_PLAN_INVALID", message: "Для исходника нет допустимого плана.",
                           hint: "Выберите более короткий фрагмент или уменьшите разрешение.")
        }
        settings.selectedPlan = PlanChoice(plan)
        return settings
    }

    private static func isVideoExtension(_ ext: String) -> Bool {
        ["mp4", "mov", "m4v"].contains(ext.lowercased())
    }

    private static func sniffVideoType(_ data: Data) -> UTType? {
        guard data.count >= 12,
              let atom = String(data: data.subdata(in: 4..<8), encoding: .ascii) else { return nil }
        if atom == "ftyp" {
            let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii)
            return brand == "qt  " ? .quickTimeMovie : .mpeg4Movie
        }
        return ["moov", "mdat", "wide"].contains(atom) ? .quickTimeMovie : nil
    }

    private static func sourceName(type: UTType, originalName: String) -> String {
        let ext = URL(fileURLWithPath: originalName).pathExtension
        if isVideoExtension(ext) { return "source.\(ext.lowercased())" }
        return "source.\(type.preferredFilenameExtension ?? "gif")"
    }
}
