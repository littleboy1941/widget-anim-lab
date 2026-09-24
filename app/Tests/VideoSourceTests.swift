import XCTest
import AVFoundation
import CoreGraphics

final class VideoSourceTests: XCTestCase {
    func testGridAndThumbnails() async throws {
        let url = try makeVideo(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await Task.detached { try VideoSource(url: url) }.value

        XCTAssertEqual(source.frames.count, 10)
        XCTAssertEqual(source.totalDuration, 1, accuracy: 0.02)
        XCTAssertEqual(source.nominalFrameRate, 10, accuracy: 0.5)
        XCTAssertEqual(source.canvasWidth, 64)
        XCTAssertEqual(source.canvasHeight, 32)
        for (index, frame) in source.frames.enumerated() {
            XCTAssertEqual(frame.index, index)
            XCTAssertEqual(frame.startTime, Double(index) / 10, accuracy: 0.001)
            XCTAssertEqual(frame.duration, 0.1, accuracy: 0.02)
        }

        let first = try source.thumbnail(at: 0, maxPixelSize: 16)
        let last = try source.thumbnail(at: 8, maxPixelSize: 16)
        XCTAssertLessThanOrEqual(max(first.width, first.height), 16)
        XCTAssertLessThanOrEqual(max(last.width, last.height), 16)
        let firstColor = centerRGB(first)
        let lastColor = centerRGB(last)
        XCTAssertGreaterThan(firstColor.red, firstColor.blue + 100)
        XCTAssertGreaterThan(lastColor.blue, lastColor.red + 100)
    }

    func testPreferredTransformRotatesCanvasAndThumbnail() async throws {
        let url = try makeVideo(rotated: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await Task.detached { try VideoSource(url: url) }.value

        XCTAssertEqual(source.canvasWidth, 32)
        XCTAssertEqual(source.canvasHeight, 64)
        let image = try source.thumbnail(at: 0, maxPixelSize: 20)
        XCTAssertLessThan(image.width, image.height)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 20)
    }

    private func makeVideo(rotated: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-source-test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 32,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: 10]
        ])
        input.expectsMediaDataInRealTime = false
        if rotated {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 32
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<10 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw writer.error ?? TestError.writerFailed }
                Thread.sleep(forTimeInterval: 0.001)
            }
            let red: UInt8 = index < 5 ? 240 : 10
            let blue: UInt8 = index < 5 ? 10 : 240
            let buffer = try pixelBuffer(red: red, blue: blue)
            let time = CMTime(value: CMTimeValue(index), timescale: 10)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? TestError.writerFailed
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 10) == .success else { throw TestError.writerFailed }
        guard writer.status == .completed else { throw writer.error ?? TestError.writerFailed }
        return url
    }

    private func pixelBuffer(red: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 32,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else { throw TestError.bufferFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw TestError.bufferFailed }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<32 {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<64 {
                let pixel = row.advanced(by: x * 4)
                pixel[0] = blue
                pixel[1] = 10
                pixel[2] = red
                pixel[3] = 255
            }
        }
        return buffer
    }

    private func centerRGB(_ image: CGImage) -> (red: Int, blue: Int) {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: space, bitmapInfo: info)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[0]), Int(bytes[2]))
    }

    private enum TestError: Error { case writerFailed, bufferFailed }
}
