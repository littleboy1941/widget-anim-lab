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
        let rawDuration: Double
    }

    enum ImportError: Error {
        case unreadableFile
        case unsupportedFormat
        case emptyAnimation
        case invalidSize
        case decodeFailed(Int)
        case sourcePixels
        case sourceTooLarge
    }

    static let maxSourcePixels = 80_000_000
    static let maxSourceBytes = 150 * 1_000_000

    static func validateSource(width: Int, height: Int, bytes: Int) throws {
        guard bytes >= 0, bytes <= maxSourceBytes else { throw ImportError.sourceTooLarge }
        guard width > 0, height > 0, width <= maxSourcePixels / height else {
            throw ImportError.sourcePixels
        }
    }

    let frames: [FrameInfo]
    let totalDuration: Double
    let format: UTType
    let canvasWidth: Int
    let canvasHeight: Int
    let fileBytes: Int
    let correctedDelayCount: Int
    let hasTransparency: Bool
    private let source: CGImageSource

    init(url: URL, maximumSourceFrames: Int = 10_000) throws {
        let sourceBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceBytes <= Self.maxSourceBytes else { throw ImportError.sourceTooLarge }
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
        guard count > 1 && count <= maximumSourceFrames else {
            throw ImportError.emptyAnimation
        }
        self.source = source
        self.format = format
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? NSDictionary
        let canvas = CGImageSourceCopyProperties(source, nil) as? NSDictionary
        canvasWidth = (canvas?.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue ??
            (properties?.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue ?? 0
        canvasHeight = (canvas?.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue ??
            (properties?.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue ?? 0
        fileBytes = sourceBytes
        try Self.validateSource(width: canvasWidth, height: canvasHeight, bytes: fileBytes)
        for index in 0..<count {
            let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? NSDictionary
            let width = (frameProperties?.object(forKey: kCGImagePropertyPixelWidth) as? NSNumber)?.intValue ?? canvasWidth
            let height = (frameProperties?.object(forKey: kCGImagePropertyPixelHeight) as? NSNumber)?.intValue ?? canvasHeight
            try Self.validateSource(width: width, height: height, bytes: fileBytes)
        }
        let first = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache as String: false] as CFDictionary)
        hasTransparency = first.map { [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly]
            .contains($0.alphaInfo) } ?? false

        var infos: [FrameInfo] = []
        infos.reserveCapacity(count)
        var elapsed = 0.0
        var corrected = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? NSDictionary
            let raw = Self.delay(properties: properties, format: format)
            let delay = raw.isFinite && raw >= 0.02 ? raw : 0.1
            if delay != raw { corrected += 1 }
            infos.append(FrameInfo(index: index, startTime: elapsed, duration: delay,
                                   rawDuration: raw))
            elapsed += delay
        }
        guard elapsed.isFinite else { throw ImportError.emptyAnimation }
        frames = infos
        totalDuration = elapsed
        correctedDelayCount = corrected
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

    func frame(at index: Int) throws -> CGImage {
        guard frames.indices.contains(index),
              let image = CGImageSourceCreateImageAtIndex(source, index,
                  [kCGImageSourceShouldCache as String: false] as CFDictionary) else {
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
        return value
    }
}
