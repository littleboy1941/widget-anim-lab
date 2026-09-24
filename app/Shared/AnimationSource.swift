import CoreGraphics
import UniformTypeIdentifiers

struct AnimationFrameInfo {
    let index: Int
    let startTime: Double
    let duration: Double
    let rawDuration: Double
}

protocol AnimationSource: AnyObject {
    var frames: [AnimationFrameInfo] { get }
    var canvasWidth: Int { get }
    var canvasHeight: Int { get }
    var totalDuration: Double { get }
    var format: UTType { get }
    var fileBytes: Int { get }

    func thumbnail(at index: Int, maxPixelSize: Int) throws -> CGImage
    func frame(at index: Int) throws -> CGImage
}

enum VideoSourceError: Error {
    case noVideoTrack
    case invalidDuration
    case sourceTooLong
    case invalidSize
    case decodeFailed(Int)
    case mainThreadInitialization
}
