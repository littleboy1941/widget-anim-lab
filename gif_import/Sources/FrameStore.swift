import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Общий формат данных приложения и расширения. Запись вызывает только приложение.
final class FrameStore {
    struct Entry: Codable {
        let file: String
        let byteCount: Int
        let checksum: UInt64
    }

    struct Manifest: Codable {
        let version: Int
        let fps: Int
        let frameCount: Int
        let size: Int
        let timerCycle: Int
        let frames: [Entry]
    }

    struct Snapshot {
        let manifest: Manifest
        let frameURLs: [URL]
    }

    private struct Current: Codable { let generation: String }

    enum StoreError: Error {
        case groupUnavailable
        case invalidPlan
        case encodingFailed
        case invalidSnapshot
    }

    private let root: URL
    private let fileManager = FileManager.default

    init(groupIdentifier: String) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { throw StoreError.groupUnavailable }
        root = container.appendingPathComponent("gif_import", isDirectory: true)
    }

    /// Замыкание возвращает уже обработанный квадратный кадр. В памяти
    /// одновременно находится лишь текущий CGImage и его PNG-кодировщик.
    func publish(plan: FramePlanner.Plan, size: Int,
                 frameAt: (Int) throws -> CGImage) throws {
        guard Self.validGeometry(fps: plan.fps, count: plan.frameCount,
                                 size: size, cycle: plan.timerCycle),
              plan.sourceIndices.count == plan.frameCount else {
            throw StoreError.invalidPlan
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let generation = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(generation, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? fileManager.removeItem(at: directory) } }

        var entries: [Entry] = []
        for (position, sourceIndex) in plan.sourceIndices.enumerated() {
            let image = try frameAt(sourceIndex)
            guard image.width == size && image.height == size else {
                throw StoreError.invalidPlan
            }
            let name = String(format: "frame_%03d.png", position)
            let url = directory.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { throw StoreError.encodingFailed }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw StoreError.encodingFailed }
            let (length, checksum) = try Self.fingerprint(url)
            guard length > 0 && length <= 4_000_000 else { throw StoreError.invalidSnapshot }
            entries.append(Entry(file: name, byteCount: length, checksum: checksum))
        }
        let manifest = Manifest(version: 1, fps: plan.fps,
                                frameCount: plan.frameCount, size: size,
                                timerCycle: plan.timerCycle, frames: entries)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

        // Читатель увидит либо старое поколение, либо целиком новое.
        let pointer = Current(generation: generation)
        try JSONEncoder().encode(pointer).write(
            to: root.appendingPathComponent("current.json"), options: .atomic
        )
        published = true
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Вызывать в расширении один раз при загрузке timeline. PNG не декодируются.
    func readCurrent() throws -> Snapshot {
        let pointerURL = root.appendingPathComponent("current.json")
        let current = try JSONDecoder().decode(Current.self, from: Data(contentsOf: pointerURL))
        guard UUID(uuidString: current.generation) != nil,
              current.generation == current.generation.lowercased() else {
            throw StoreError.invalidSnapshot
        }
        let directory = root.appendingPathComponent(current.generation, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        guard manifest.version == 1,
              Self.validGeometry(fps: manifest.fps, count: manifest.frameCount,
                                 size: manifest.size, cycle: manifest.timerCycle),
              manifest.frames.count == manifest.frameCount else {
            throw StoreError.invalidSnapshot
        }
        var urls: [URL] = []
        for (index, entry) in manifest.frames.enumerated() {
            guard entry.file == String(format: "frame_%03d.png", index),
                  entry.byteCount > 0 && entry.byteCount <= 4_000_000 else {
                throw StoreError.invalidSnapshot
            }
            let url = directory.appendingPathComponent(entry.file)
            let (length, checksum) = try Self.fingerprint(url)
            guard length == entry.byteCount, checksum == entry.checksum,
                  let source = CGImageSourceCreateWithURL(
                    url as CFURL,
                    [kCGImageSourceShouldCache as String: false] as CFDictionary
                  ),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? NSDictionary,
                  (properties.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue == manifest.size,
                  (properties.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue == manifest.size else {
                throw StoreError.invalidSnapshot
            }
            urls.append(url)
        }
        return Snapshot(manifest: manifest, frameURLs: urls)
    }

    private static func validGeometry(fps: Int, count: Int, size: Int, cycle: Int) -> Bool {
        let budget = size <= 300 ? 24 : 12
        return FramePlanner.fpsLimit.contains(fps) && (1...400).contains(size) &&
            (1...budget).contains(count) && FramePlanner.cycleDivisors.contains(cycle) &&
            cycle * fps <= FramePlanner.maxPhases && (cycle * fps) % count == 0
    }

    /// FNV-1a служит для обнаружения повреждения, а не для защиты от подмены.
    private static func fingerprint(_ url: URL) throws -> (Int, UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 14_695_981_039_346_656_037
        var count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += chunk.count
            for byte in chunk {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            if count > 4_000_000 { throw StoreError.invalidSnapshot }
        }
        return (count, hash)
    }
}
