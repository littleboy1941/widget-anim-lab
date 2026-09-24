import CoreGraphics
import Foundation

/// Пиксель-арт, увеличенный в целое число раз (monono_widget_exact.gif: 192×150 × 4 = 768×600).
/// Находит наибольший k, при котором кадр состоит из одноцветных блоков k×k,
/// чтобы вернуть родной размер спрайта без потерь.
enum PixelArtScale {
    static func detect(_ image: CGImage, maxBlock: Int = 16) -> Int {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.assumingMemoryBound(to: UInt32.self) else { return 1 }
        for k in stride(from: min(maxBlock, w, h), through: 2, by: -1) where w % k == 0 && h % k == 0 {
            if uniformBlocks(data, width: w, height: h, block: k) { return k }
        }
        return 1
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
