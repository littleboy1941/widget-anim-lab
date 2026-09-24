import Foundation
import CryptoKit
import ImageIO
import UIKit

struct ProjectSnapshot {
    let manifest: ProjectManifest
    let size: WidgetSize
    let variant: WidgetVariant
    let frames: [UIImage]
}

final class ProjectStore {
    private struct Pointer: Codable { let generation: UUID }
    struct Listing {
        let projects: [ProjectManifest]
        let diagnostics: [UUID: ProjectReadError]
    }
    private static let publicationLock = NSRecursiveLock()

    let root: URL
    let budget: AnimationBudget
    private let fm = FileManager.default

    init(groupIdentifier: String, budget: AnimationBudget = .standard) throws {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { throw ProjectReadError.groupUnavailable }
        root = group.appendingPathComponent("projects-v2", isDirectory: true)
        self.budget = budget
    }

    /// Test seam; no App Group entitlement is required by hostless XCTest.
    init(root: URL, budget: AnimationBudget = .standard) {
        self.root = root
        self.budget = budget
    }

    func publish(_ draft: ProjectDraft) throws {
        Self.publicationLock.lock()
        defer { Self.publicationLock.unlock() }
        do { try publishImpl(draft) }
        catch {
            DiagnosticsLog(root: root, maxBytes: budget.maxLogBytes).append(
                event: "publication_error", projectID: draft.id,
                detail: String(describing: error))
            throw error
        }
    }

    private func publishImpl(_ draft: ProjectDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.variants.isEmpty else {
            throw ProjectReadError.manifestInvalid("project name or variants are empty")
        }
        let projectDir = directory(for: draft.id)
        if fm.fileExists(atPath: projectDir.appendingPathComponent("deleted.json").path) {
            throw ProjectReadError.projectDeleted
        }
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let generation = UUID()
        let stage = projectDir.appendingPathComponent(generation.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: stage) } }

        var variants: [WidgetSize: WidgetVariant] = [:]
        for (size, input) in draft.variants {
            var records: [FrameRecord] = []
            for (index, data) in input.pngData.enumerated() {
                let name = String(format: "frame_%03d.png", index)
                let relative = "\(size.rawValue)/\(name)"
                let hash = Self.digest(data)
                records.append(FrameRecord(file: relative, byteCount: data.count, sha256: hash))
            }
            let variant = WidgetVariant(width: input.width, height: input.height,
                                        fps: input.fps, cycle: input.cycle, slotCount: input.slotCount,
                                        phaseToFrame: input.phaseToFrame,
                                        overlapSeconds: input.overlapSeconds,
                                        background: input.background,
                                        pixelArt: input.pixelArt, frames: records)
            try validate(variant, size: size)
            let sizeDir = stage.appendingPathComponent(size.rawValue, isDirectory: true)
            try fm.createDirectory(at: sizeDir, withIntermediateDirectories: false)
            for (index, data) in input.pngData.enumerated() {
                try validatePNG(data, width: input.width, height: input.height,
                                name: records[index].file)
                try data.write(to: stage.appendingPathComponent(records[index].file), options: .atomic)
            }
            variants[size] = variant
        }
        let originalDate = (try? readManifest(draft.id).createdAt) ?? draft.createdAt
        let manifest = ProjectManifest(version: 2, id: draft.id, name: draft.name,
                                       createdAt: originalDate, generation: generation,
                                       variants: variants)
        try encoded(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        // The pointer is the commit record. A failed publication leaves it untouched.
        try Task.checkCancellation()
        try encoded(Pointer(generation: generation)).write(
            to: projectDir.appendingPathComponent("current.json"), options: .atomic)
        committed = true
        do { try cleanupGenerations(in: projectDir, keeping: generation) }
        catch {
            DiagnosticsLog(root: root, maxBytes: budget.maxLogBytes).append(
                event: "generation_cleanup_error", projectID: draft.id,
                detail: String(describing: error))
        }
        DiagnosticsLog(root: root, maxBytes: budget.maxLogBytes).append(
            event: "published", projectID: draft.id, detail: generation.uuidString)
    }

    func delete(_ id: UUID) throws {
        Self.publicationLock.lock()
        defer { Self.publicationLock.unlock() }
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        DiagnosticsLog(root: root, maxBytes: budget.maxLogBytes).append(
            event: "deleted", projectID: id, detail: "")
    }

    func listing() throws -> Listing {
        if !fm.fileExists(atPath: root.path) { return Listing(projects: [], diagnostics: [:]) }
        let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var projects: [ProjectManifest] = []
        var diagnostics: [UUID: ProjectReadError] = [:]
        for url in urls {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            do { projects.append(try readManifest(id)) }
            catch let failure as ProjectReadError { diagnostics[id] = failure }
            catch { diagnostics[id] = .manifestInvalid(error.localizedDescription) }
        }
        return Listing(projects: projects.sorted { $0.createdAt > $1.createdAt },
                       diagnostics: diagnostics)
    }

    private func cleanupGenerations(in projectDir: URL, keeping generation: UUID) throws {
        let current = try JSONDecoder().decode(Pointer.self,
            from: Data(contentsOf: projectDir.appendingPathComponent("current.json"))).generation
        guard current == generation else { return }
        let folders = try fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
        for folder in folders {
            guard let old = UUID(uuidString: folder.lastPathComponent), old != current else { continue }
            try fm.removeItem(at: folder)
        }
    }

    func read(_ id: UUID, size: WidgetSize) throws -> ProjectSnapshot {
        let manifest = try readManifest(id)
        guard let variant = manifest.variants[size] else {
            throw ProjectReadError.manifestInvalid("\(size.rawValue) variant missing")
        }
        try validate(variant, size: size)
        let generationDir = directory(for: id).appendingPathComponent(
            manifest.generation.uuidString.lowercased(), isDirectory: true)
        var images: [UIImage] = []
        for record in variant.frames {
            let url = generationDir.appendingPathComponent(record.file)
            guard fm.fileExists(atPath: url.path) else {
                if !fm.fileExists(atPath: directory(for: id).path) {
                    throw ProjectReadError.projectDeleted
                }
                throw ProjectReadError.frameFileMissing(record.file)
            }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                if !fm.fileExists(atPath: directory(for: id).path) {
                    throw ProjectReadError.projectDeleted
                }
                throw ProjectReadError.frameInvalid("unreadable \(record.file)")
            }
            guard data.count == record.byteCount, Self.digest(data) == record.sha256 else {
                throw ProjectReadError.frameInvalid("size or hash mismatch: \(record.file)")
            }
            try validatePNG(data, width: variant.width, height: variant.height, name: record.file)
            guard let image = UIImage(data: data) else {
                throw ProjectReadError.frameInvalid("decode failed: \(record.file)")
            }
            images.append(image)
        }
        return ProjectSnapshot(manifest: manifest, size: size, variant: variant, frames: images)
    }

    private func readManifest(_ id: UUID) throws -> ProjectManifest {
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.appendingPathComponent("deleted.json").path) {
            throw ProjectReadError.projectDeleted
        }
        let pointer: Pointer
        do {
            pointer = try JSONDecoder().decode(Pointer.self,
                from: Data(contentsOf: dir.appendingPathComponent("current.json")))
        } catch {
            if !fm.fileExists(atPath: dir.path) { throw ProjectReadError.projectDeleted }
            throw ProjectReadError.manifestInvalid("current pointer is missing or corrupt")
        }
        let url = dir.appendingPathComponent(pointer.generation.uuidString.lowercased())
            .appendingPathComponent("manifest.json")
        let manifest: ProjectManifest
        do { manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: url)) }
        catch { throw ProjectReadError.manifestInvalid("manifest file is missing or corrupt") }
        guard manifest.version == 2, manifest.id == id,
              manifest.generation == pointer.generation,
              !manifest.name.isEmpty, !manifest.variants.isEmpty else {
            throw ProjectReadError.manifestInvalid("version, identity, or variants")
        }
        return manifest
    }

    private func validate(_ variant: WidgetVariant, size: WidgetSize) throws {
        guard FrameProcessor.validDimensions(variant.width, variant.height),
              let maxPixels = budget.maxPixels[size],
              variant.width <= maxPixels, variant.height <= maxPixels,
              variant.width <= maxPixels / variant.height else {
            throw ProjectReadError.manifestInvalid("invalid \(size.rawValue) pixel dimensions")
        }
        guard (budget.minFPS...budget.maxFPS).contains(variant.fps),
              AnimationBudget.supportedCycles.contains(variant.cycle),
              60 % variant.cycle == 0,
              variant.phaseCount <= budget.maxPhases,
              variant.slotCount > 0, variant.phaseCount % variant.slotCount == 0,
              !variant.frames.isEmpty, variant.frames.count <= variant.slotCount,
              variant.phaseToFrame.count == variant.phaseCount,
              variant.phaseToFrame.allSatisfy({ variant.frames.indices.contains($0) }),
              variant.overlapSeconds.isFinite,
              variant.overlapSeconds == budget.overlap(forFPS: variant.fps) else {
            throw ProjectReadError.manifestInvalid("invalid fps, cycle, phase table, or overlap")
        }
        for (index, frame) in variant.frames.enumerated() {
            guard frame.file == String(format: "\(size.rawValue)/frame_%03d.png", index),
                  frame.byteCount > 0, frame.byteCount <= budget.maxPNGBytes,
                  frame.sha256.count == 64,
                  frame.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw ProjectReadError.manifestInvalid("invalid frame record \(index)")
            }
        }
        let pixels = variant.width * variant.height
        let decoded = Double(pixels) * 4 * Double(variant.frames.count)
        if decoded > Double(budget.maxDecodedBytes) {
            throw ProjectReadError.budgetExceeded(actualMB: decoded / 1_048_576,
                                                  limitMB: Double(budget.maxDecodedBytes) / 1_048_576)
        }
    }

    private func validatePNG(_ data: Data, width: Int, height: Int, name: String) throws {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? NSDictionary,
              (properties.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue == width,
              (properties.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue == height else {
            throw ProjectReadError.frameInvalid("PNG dimensions or format: \(name)")
        }
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
