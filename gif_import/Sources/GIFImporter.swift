import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Держит источник и метаданные, а пиксели декодирует только по запросу.
final class GIFImporter {
    struct FrameInfo {
        let index: Int
        let startTime: Double
        let duration: Double
    }

    enum ImportError: Error {
        case unreadableFile
        case unsupportedFormat
        case emptyAnimation
        case invalidSize
        case decodeFailed(Int)
    }

    let frames: [FrameInfo]
    let totalDuration: Double
    let format: UTType
    private let source: CGImageSource

    init(url: URL, maximumSourceFrames: Int = 10_000) throws {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache as String: false] as CFDictionary
        ) else { throw ImportError.unreadableFile }
        guard let typeID = CGImageSourceGetType(source),
              let format = UTType(typeID as String),
              format.conforms(to: .gif) || format.conforms(to: .png) ||
              format.conforms(to: .webP) else {
            throw ImportError.unsupportedFormat
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 && count <= maximumSourceFrames else {
            throw ImportError.emptyAnimation
        }
        self.source = source
        self.format = format

        var infos: [FrameInfo] = []
        infos.reserveCapacity(count)
        var elapsed = 0.0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? NSDictionary
            let delay = Self.delay(properties: properties, format: format)
            infos.append(FrameInfo(index: index, startTime: elapsed, duration: delay))
            elapsed += delay
        }
        guard elapsed.isFinite else { throw ImportError.emptyAnimation }
        frames = infos
        totalDuration = elapsed
    }

    /// Одновременно держать только один thumbnail; вызывающий код сразу
    /// обрабатывает и записывает PNG, затем освобождает изображение.
    func thumbnail(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard frames.indices.contains(index) else { throw ImportError.decodeFailed(index) }
        guard (1...2048).contains(maxPixelSize) else { throw ImportError.invalidSize }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceShouldCache as String: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ImportError.decodeFailed(index)
        }
        return image
    }

    private static func delay(properties: NSDictionary?, format: UTType) -> Double {
        let dictionaryKey: CFString
        let rawKey: CFString
        let clampedKey: CFString
        if format.conforms(to: .gif) {
            dictionaryKey = kCGImagePropertyGIFDictionary
            rawKey = kCGImagePropertyGIFUnclampedDelayTime
            clampedKey = kCGImagePropertyGIFDelayTime
        } else if format.conforms(to: .webP) {
            dictionaryKey = kCGImagePropertyWebPDictionary
            rawKey = kCGImagePropertyWebPUnclampedDelayTime
            clampedKey = kCGImagePropertyWebPDelayTime
        } else {
            dictionaryKey = kCGImagePropertyPNGDictionary
            rawKey = kCGImagePropertyAPNGUnclampedDelayTime
            clampedKey = kCGImagePropertyAPNGDelayTime
        }
        let nested = properties?.object(forKey: dictionaryKey) as? NSDictionary
        let raw = (nested?.object(forKey: rawKey) as? NSNumber)?.doubleValue
            ?? (properties?.object(forKey: rawKey) as? NSNumber)?.doubleValue
        let clamped = (nested?.object(forKey: clampedKey) as? NSNumber)?.doubleValue
            ?? (properties?.object(forKey: clampedKey) as? NSNumber)?.doubleValue
        let value = raw ?? clamped ?? 0.1
        // Распространённое браузерное правило: 0–10 мс показывать 100 мс.
        return value.isFinite && value >= 0.02 ? value : 0.1
    }
}
