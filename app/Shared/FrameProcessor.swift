import Foundation
import CoreGraphics

enum FrameProcessor {
    enum Layout { case crop, fit }
    enum Style { case automatic, photo, pixelArt }

    struct Options {
        var size: Int = 300
        var layout: Layout = .fit
        var style: Style = .automatic
        var paletteColors: Int? = nil
        var transparentAlphaThreshold: UInt8 = 8
    }

    enum ProcessingError: Error {
        case invalidOptions
        case contextFailed
    }

    static func process(_ image: CGImage, options: Options) throws -> CGImage {
        guard (1...400).contains(options.size),
              options.paletteColors.map({ (16...64).contains($0) }) ?? true else {
            throw ProcessingError.invalidOptions
        }
        let pixelArt = options.style == .pixelArt ||
            (options.style == .automatic && looksLikePixelArt(image))
        guard let context = makeContext(width: options.size, height: options.size) else {
            throw ProcessingError.contextFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: options.size, height: options.size))
        context.interpolationQuality = pixelArt ? .none : .high

        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let target = CGFloat(options.size)
        let ratio = options.layout == .fit
            ? min(target / sourceWidth, target / sourceHeight)
            : max(target / sourceWidth, target / sourceHeight)
        let scale: CGFloat
        if pixelArt && ratio >= 1 {
            scale = options.layout == .fit ? floor(ratio) : ceil(ratio)
        } else {
            scale = ratio
        }
        let width = sourceWidth * max(scale, 1 / max(sourceWidth, sourceHeight))
        let height = sourceHeight * max(scale, 1 / max(sourceWidth, sourceHeight))
        let rect = CGRect(x: (target - width) / 2, y: (target - height) / 2,
                          width: width, height: height)
        context.draw(image, in: rect)

        guard let raw = context.data else { throw ProcessingError.contextFailed }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        let pixelCount = options.size * options.size
        for i in 0..<pixelCount where bytes[i * 4 + 3] < options.transparentAlphaThreshold {
            let offset = i * 4
            bytes[offset] = 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
            bytes[offset + 3] = 0
        }
        if let colors = options.paletteColors {
            quantize(bytes: bytes, pixelCount: pixelCount, colors: colors)
        }
        guard let result = context.makeImage() else { throw ProcessingError.contextFailed }
        return result
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
    }

    /// Консервативная эвристика: мало цветов и много одинаковых соседей.
    private static func looksLikePixelArt(_ image: CGImage) -> Bool {
        let width = min(image.width, 96)
        let height = min(image.height, 96)
        guard let context = makeContext(width: width, height: height) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return false }
        let bytes = raw.assumingMemoryBound(to: UInt8.self)
        var colors = Set<UInt32>()
        var equalPairs = 0
        var allPairs = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i + 3] < 16 { continue }
                let key = (UInt32(bytes[i] >> 3) << 15) |
                    (UInt32(bytes[i + 1] >> 3) << 10) |
                    (UInt32(bytes[i + 2] >> 3) << 5)
                colors.insert(key)
                if colors.count > 64 { return false }
                if x > 0 && bytes[i - 1] >= 16 {
                    allPairs += 1
                    if bytes[i] == bytes[i - 4] &&
                        bytes[i + 1] == bytes[i - 3] &&
                        bytes[i + 2] == bytes[i - 2] { equalPairs += 1 }
                }
                if y > 0 && bytes[i - width * 4 + 3] >= 16 {
                    allPairs += 1
                    if bytes[i] == bytes[i - width * 4] &&
                        bytes[i + 1] == bytes[i - width * 4 + 1] &&
                        bytes[i + 2] == bytes[i - width * 4 + 2] { equalPairs += 1 }
                }
            }
        }
        return colors.count >= 2 && allPairs > 100 &&
            Double(equalPairs) / Double(allPairs) > 0.55
    }

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    /// Детерминированный k-means по разреженной выборке, без дизеринга.
    private static func quantize(bytes: UnsafeMutablePointer<UInt8>,
                                 pixelCount: Int, colors: Int) {
        let stride = max(1, pixelCount / 4096)
        var samples: [RGB] = []
        for i in Swift.stride(from: 0, to: pixelCount, by: stride) {
            let p = i * 4
            guard bytes[p + 3] >= 16 else { continue }
            samples.append(RGB(r: Double(bytes[p]), g: Double(bytes[p + 1]),
                               b: Double(bytes[p + 2])))
        }
        guard !samples.isEmpty else { return }
        var centers: [RGB] = [samples[0]]
        while centers.count < min(colors, samples.count) {
            let next = samples.max { nearestDistance($0, centers) < nearestDistance($1, centers) }!
            if nearestDistance(next, centers) < 1 { break }
            centers.append(next)
        }
        for _ in 0..<6 {
            var sums = Array(repeating: RGB(r: 0, g: 0, b: 0), count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)
            for sample in samples {
                let k = nearestIndex(sample, centers)
                sums[k].r += sample.r
                sums[k].g += sample.g
                sums[k].b += sample.b
                counts[k] += 1
            }
            for k in centers.indices where counts[k] > 0 {
                centers[k] = RGB(r: sums[k].r / Double(counts[k]),
                                 g: sums[k].g / Double(counts[k]),
                                 b: sums[k].b / Double(counts[k]))
            }
        }
        for i in 0..<pixelCount {
            let p = i * 4
            guard bytes[p + 3] >= 16 else { continue }
            let sample = RGB(r: Double(bytes[p]), g: Double(bytes[p + 1]),
                             b: Double(bytes[p + 2]))
            let color = centers[nearestIndex(sample, centers)]
            // Контекст хранит premultiplied RGBA: каналы не выше альфы.
            let alpha = Int(bytes[p + 3])
            bytes[p] = UInt8(clamping: min(alpha, Int(color.r.rounded())))
            bytes[p + 1] = UInt8(clamping: min(alpha, Int(color.g.rounded())))
            bytes[p + 2] = UInt8(clamping: min(alpha, Int(color.b.rounded())))
        }
    }

    private static func nearestDistance(_ sample: RGB, _ centers: [RGB]) -> Double {
        var best = Double.infinity
        for center in centers { best = min(best, distance(sample, center)) }
        return best
    }

    private static func nearestIndex(_ sample: RGB, _ centers: [RGB]) -> Int {
        var best = Double.infinity
        var result = 0
        for index in centers.indices {
            let value = distance(sample, centers[index])
            if value < best {
                best = value
                result = index
            }
        }
        return result
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }
}
