import CoreGraphics
import Foundation
import XCTest

final class ImportTests: XCTestCase {
    private struct Point: Decodable {
        let x: Double
        let y: Double
        let rgba: [Int]
    }

    private struct Fixture: Decodable {
        let frameCount: Int
        let durations: [Double]
        let points: [[Point]]
    }

    private func loadFixtures() throws -> [String: Fixture] {
        let bundle = Bundle(for: ImportTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "expected", withExtension: "json"),
                                "expected.json is missing from the test bundle")
        return try JSONDecoder().decode([String: Fixture].self, from: Data(contentsOf: url))
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let file = name as NSString
        return try XCTUnwrap(
            Bundle(for: ImportTests.self).url(forResource: file.deletingPathExtension,
                                               withExtension: file.pathExtension),
            "Missing fixture \(name)"
        )
    }

    private func imagePixel(_ image: CGImage, x: Double, y: Double) throws -> [Int] {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                               bitsPerComponent: 8, bytesPerRow: width * 4,
                                               space: colorSpace, bitmapInfo: info))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let px = max(0, min(width - 1, Int((x * Double(width - 1)).rounded())))
        let py = max(0, min(height - 1, Int((y * Double(height - 1)).rounded())))
        let offset = (py * width + px) * 4
        let alpha = Int(data[offset + 3])
        if alpha == 0 { return [0, 0, 0, 0] }
        return (0..<3).map { min(255, (Int(data[offset + $0]) * 255 + alpha / 2) / alpha) } + [alpha]
    }

    private func assertColor(_ actual: [Int], _ expected: [Int],
                             context: String, tolerance: Int = 12,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 4, "\(context): invalid decoded pixel", file: file, line: line)
        XCTAssertEqual(expected.count, 4, "\(context): invalid fixture pixel", file: file, line: line)
        guard actual.count == 4 && expected.count == 4 else { return }
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), tolerance,
                "\(context), channel \(channel): got \(actual), expected \(expected). " +
                "ImageIO may have returned an uncomposited animation frame.",
                file: file, line: line)
        }
    }

    func testEveryImportedFrameIsFullyComposited() throws {
        let fixtures = try loadFixtures()
        for name in fixtures.keys.sorted() {
            let fixture = try XCTUnwrap(fixtures[name])
            let url = try fixtureURL(name)
            let importer = try GIFImporter(url: url)
            XCTAssertEqual(importer.frames.count, fixture.frameCount, name)
            XCTAssertEqual(fixture.durations.count, fixture.frameCount, name)
            XCTAssertEqual(fixture.points.count, fixture.frameCount, name)
            guard importer.frames.count == fixture.frameCount,
                  fixture.durations.count == fixture.frameCount,
                  fixture.points.count == fixture.frameCount else { continue }
            for index in 0..<fixture.frameCount {
                XCTAssertEqual(importer.frames[index].duration, fixture.durations[index],
                               accuracy: 0.011, "\(name) frame \(index) delay")
                let image = try importer.thumbnail(at: index, maxPixelSize: 20)
                XCTAssertEqual(image.width, 20,
                               "\(name) frame \(index): ImageIO may have returned only a partial frame")
                XCTAssertEqual(image.height, 20,
                               "\(name) frame \(index): ImageIO may have returned only a partial frame")
                for point in fixture.points[index] {
                    let actual = try imagePixel(image, x: point.x, y: point.y)
                    assertColor(actual, point.rgba,
                                context: "\(name) frame \(index) at (\(point.x), \(point.y))")
                }
            }
        }
    }

    func testFrameProcessorLayoutsStylesAndPalette() throws {
        let fixtures = try loadFixtures()
        for name in fixtures.keys.sorted() {
            let url = try fixtureURL(name)
            let importer = try GIFImporter(url: url)
            for index in importer.frames.indices {
                let source = try importer.thumbnail(at: index, maxPixelSize: 20)
                let center = try imagePixel(source, x: 0.5, y: 0.5)
                for layout in [FrameProcessor.Layout.fit, .crop] {
                    for style in [FrameProcessor.Style.pixelArt, .photo] {
                        var options = FrameProcessor.Options()
                        options.size = 40
                        options.layout = layout
                        options.style = style
                        options.paletteColors = 16
                        let output = try FrameProcessor.process(source, options: options)
                        XCTAssertEqual(output.width, 40, "\(name) frame \(index)")
                        XCTAssertEqual(output.height, 40, "\(name) frame \(index)")
                        let processed = try imagePixel(output, x: 0.5, y: 0.5)
                        assertColor(processed, center,
                                    context: "\(name) frame \(index), \(layout), \(style), center")
                    }
                }
            }
        }
    }

    func testPlanFromPartialGIFDurations() throws {
        let fixture = try XCTUnwrap(loadFixtures()["partial.gif"])
        let plan = try FramePlanner.makePlan(durations: fixture.durations, budget: 12)
        XCTAssertTrue(FramePlanner.fpsLimit.contains(plan.fps))
        XCTAssertTrue((1...12).contains(plan.frameCount))
        XCTAssertEqual(plan.sourceIndices.count, plan.frameCount)
        XCTAssertEqual(plan.phaseCount % plan.frameCount, 0)
        XCTAssertLessThanOrEqual(plan.phaseCount, FramePlanner.maxPhases)
        XCTAssertEqual(plan.loopDuration, fixture.durations.reduce(0, +), accuracy: 0.1)
        XCTAssertEqual(plan.sourceIndices,
                       FramePlanner.sampleIndices(durations: fixture.durations,
                                                  count: plan.frameCount))
        XCTAssertTrue(plan.sourceIndices.allSatisfy { (0..<fixture.frameCount).contains($0) })
    }
}
