import CoreGraphics
import Foundation

/// Пиксель-арт, увеличенный в целое число раз (monono_widget_exact.gif: 192×150 × 4 = 768×600).
/// Находит наибольший k, при котором кадр состоит из одноцветных блоков k×k,
/// чтобы вернуть родной размер спрайта без потерь.
enum PixelArtScale {
    static func detect(_ image: CGImage, maxBlock: Int = 16) -> Int {
        analyze(image, maxBlock: maxBlock)?.scale ?? 1
    }

    static func detectConsistent(_ images: [CGImage], maxBlock: Int = 16) -> Int? {
        var signatures = Set<UInt64>()
        var confirmed: [Int] = []
        for image in images {
            guard let value = analyze(image, maxBlock: maxBlock),
                  signatures.insert(value.signature).inserted else { continue }
            confirmed.append(value.scale)
            if confirmed.count == 3 { break }
        }
        guard var result = confirmed.first else { return nil }
        for scale in confirmed.dropFirst() { result = gcd(result, scale) }
        return result
    }

    static func contentSignature(_ image: CGImage) -> UInt64? {
        analyze(image, maxBlock: 16)?.signature
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a, y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    private static func analyze(_ image: CGImage, maxBlock: Int) -> (scale: Int, signature: UInt64)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 2048, h <= 2048,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        let first = data[0]
        var distinct = false
        var signature: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<(w * h) {
            let pixel = data[index]
            if pixel != first { distinct = true }
            signature = (signature ^ UInt64(pixel)) &* 1_099_511_628_211
        }
        guard distinct else { return nil }
        for k in stride(from: min(maxBlock, w, h), through: 2, by: -1) where w % k == 0 && h % k == 0 {
            if uniformBlocks(data, width: w, height: h, block: k) {
                return (k, signature)
            }
        }
        return (1, signature)
    }

    private static func uniformBlocks(_ data: UnsafeMutablePointer<UInt32>, width: Int, height: Int,
                                      block: Int) -> Bool {
        for y in 0..<height {
            let row = y - y % block
            for x in 0..<width where data[y * width + x] != data[row * width + (x - x % block)] {
                return false
            }
        }
        return true
    }
}
