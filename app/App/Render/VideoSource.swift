import Foundation
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// Video metadata is loaded once; pixel data is requested only for selected grid points.
final class VideoSource: AnimationSource {
    typealias SourceError = VideoSourceError

    static let maximumDuration = 60.0

    let frames: [AnimationFrameInfo]
    let canvasWidth: Int
    let canvasHeight: Int
    let totalDuration: Double
    let format: UTType
    let fileBytes: Int
    let nominalFrameRate: Double
    let hasAudio: Bool

    private let asset: AVURLAsset

    init(url: URL) throws {
        // AVAsset.load is async on iOS 18. All current callers open sources from
        // detached tasks; never block the UI while waiting for asset metadata.
        guard !Thread.isMainThread else { throw SourceError.mainThreadInitialization }
        try Task.checkCancellation()
        let metadata = try Self.loadMetadataSynchronously(url: url)
        try Task.checkCancellation()
        let duration = metadata.duration
        guard duration.isFinite, duration > 0 else { throw SourceError.invalidDuration }
        guard duration <= Self.maximumDuration else { throw SourceError.sourceTooLong }
        let bounds = CGRect(origin: .zero, size: metadata.naturalSize)
            .applying(metadata.preferredTransform)
        guard bounds.width.isFinite, bounds.height.isFinite,
              abs(bounds.width) < CGFloat(Int.max),
              abs(bounds.height) < CGFloat(Int.max) else { throw SourceError.invalidSize }
        let width = Int(ceil(abs(bounds.width)))
        let height = Int(ceil(abs(bounds.height)))
        guard width > 0, height > 0 else { throw SourceError.invalidSize }

        let rate = metadata.nominalFrameRate.isFinite && metadata.nominalFrameRate > 0
            ? metadata.nominalFrameRate : 30
        let gridRate = min(rate, 30)
        let count = Int(ceil(duration * gridRate))
        guard count >= 2 else { throw SourceError.invalidDuration }
        let step = 1 / gridRate
        var infos: [AnimationFrameInfo] = []
        infos.reserveCapacity(count)
        for index in 0..<count {
            let start = Double(index) * step
            let frameDuration = min(step, duration - start)
            infos.append(AnimationFrameInfo(index: index, startTime: start,
                                            duration: frameDuration, rawDuration: frameDuration))
        }
        asset = AVURLAsset(url: url)
        frames = infos
        canvasWidth = width
        canvasHeight = height
        totalDuration = duration
        nominalFrameRate = rate
        hasAudio = metadata.hasAudio
        format = UTType(filenameExtension: url.pathExtension) ?? .movie
        fileBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    func thumbnail(at index: Int, maxPixelSize: Int) throws -> CGImage {
        guard frames.indices.contains(index) else { throw SourceError.decodeFailed(index) }
        guard (1...2048).contains(maxPixelSize) else { throw SourceError.invalidSize }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: CGFloat(maxPixelSize), height: CGFloat(maxPixelSize))
        let time = CMTime(seconds: frames[index].startTime, preferredTimescale: 60_000)
        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw SourceError.decodeFailed(index)
        }
    }

    func frame(at index: Int) throws -> CGImage {
        try thumbnail(at: index, maxPixelSize: 2048)
    }

    private struct Metadata {
        let duration: Double
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let nominalFrameRate: Double
        let hasAudio: Bool
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Metadata, Error>?
        let ready = DispatchSemaphore(value: 0)

        func finish(_ result: Result<Metadata, Error>) {
            lock.lock()
            value = result
            lock.unlock()
            ready.signal()
        }

        func take() -> Result<Metadata, Error> {
            lock.lock()
            defer { lock.unlock() }
            return value!
        }
    }

    private static func loadMetadataSynchronously(url: URL) throws -> Metadata {
        let box = ResultBox()
        Task.detached(priority: .utility) {
            do {
                let asset = AVURLAsset(url: url)
                let time = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks)
                var videoTrack: AVAssetTrack?
                var audio = false
                for track in tracks {
                    let mediaType = track.mediaType
                    if mediaType == .video && videoTrack == nil { videoTrack = track }
                    if mediaType == .audio { audio = true }
                }
                guard let videoTrack else { throw SourceError.noVideoTrack }
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let rate = try await videoTrack.load(.nominalFrameRate)
                box.finish(.success(Metadata(duration: CMTimeGetSeconds(time),
                    naturalSize: size, preferredTransform: transform,
                    nominalFrameRate: Double(rate), hasAudio: audio)))
            } catch {
                box.finish(.failure(error))
            }
        }
        box.ready.wait()
        return try box.take().get()
    }
}
