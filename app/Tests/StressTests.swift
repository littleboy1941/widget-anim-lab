import Darwin
import Foundation
import XCTest

final class StressTests: XCTestCase {
    private final class Footprint {
        private(set) var peakBytes: UInt64 = 0

        func sample() {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS { peakBytes = max(peakBytes, info.phys_footprint) }
        }

        var peakMB: Double { Double(peakBytes) / 1_048_576 }
    }

    private func fixture(_ name: String) throws -> URL {
        let parts = name.split(separator: ".", maxSplits: 1)
        let base = String(parts[0])
        let ext = parts.count == 2 ? String(parts[1]) : nil
        return try XCTUnwrap(Bundle(for: StressTests.self)
            .url(forResource: base, withExtension: ext), "Missing fixture \(name)")
    }

    private func documents() throws -> ProjectDocuments {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-stress-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ProjectDocuments(root: root)
    }

    private func run(_ name: String, expectedFrames: Int,
                     minimumDuration: Double? = nil,
                     check: ((GIFImporter) -> Void)? = nil) throws {
        let start = Date()
        let memory = Footprint()
        memory.sample()
        defer {
            memory.sample()
            print(String(format: "STRESS %@ time=%.2fs peakMB=%.1f",
                         name, Date().timeIntervalSince(start), memory.peakMB))
        }
        let docs = try documents()
        let settings = try docs.importFile(fixture(name), name: name) { _ in memory.sample() }
        memory.sample()
        let importer = try GIFImporter(url: docs.sourceURL(settings))
        XCTAssertEqual(importer.frames.count, expectedFrames, name)
        XCTAssertEqual(settings.fragmentStart, 0, accuracy: 0.000_001, name)
        XCTAssertEqual(settings.fragmentEnd, min(importer.totalDuration, 5),
                       accuracy: 0.000_001, name)
        if let minimumDuration {
            XCTAssertGreaterThanOrEqual(importer.totalDuration, minimumDuration, name)
        }
        check?(importer)
        let plan = try settings.resolvedPlan(importer: importer)
        XCTAssertTrue(settings.selectedPlan?.matches(plan) ?? false, name)
        let budget = AnimationBudget.standard
        let draft = try RenderPipeline.makeDraft(importer: importer, settings: settings) { _ in
            memory.sample()
        }
        memory.sample()
        XCTAssertEqual(draft.variants.count, WidgetSize.allCases.count, name)
        for size in WidgetSize.allCases {
            let variant = try XCTUnwrap(draft.variants[size], "\(name): \(size)")
            let decodedLimit = budget.maxDecodedBytes / (variant.width * variant.height * 4)
            XCTAssertGreaterThan(variant.pngData.count, 0, name)
            XCTAssertLessThanOrEqual(variant.pngData.count, decodedLimit, name)
            XCTAssertLessThanOrEqual(variant.pngData.count, budget.maxPhases, name)
            XCTAssertEqual(variant.pngData.count, plan.uniqueSourceIndices.count, name)
            XCTAssertLessThanOrEqual(variant.phaseToFrame.count, budget.maxPhases, name)
            XCTAssertTrue(variant.pngData.allSatisfy { !$0.isEmpty && $0.count <= budget.maxPNGBytes }, name)
        }
    }

    private func reject(_ name: String, expectedCodes: Set<String>) throws {
        let start = Date()
        let memory = Footprint()
        memory.sample()
        defer {
            memory.sample()
            print(String(format: "STRESS %@ time=%.2fs peakMB=%.1f",
                         name, Date().timeIntervalSince(start), memory.peakMB))
        }
        let docs = try documents()
        do {
            let settings = try docs.importFile(fixture(name), name: name) { _ in memory.sample() }
            memory.sample()
            let importer = try GIFImporter(url: docs.sourceURL(settings))
            _ = try RenderPipeline.makeDraft(importer: importer, settings: settings) { _ in
                memory.sample()
            }
            XCTFail("\(name) was accepted and rendered")
        } catch {
            let converted = AppError.convert(error)
            XCTAssertTrue(expectedCodes.contains(converted.code),
                          "\(name): unexpected \(converted.code): \(converted.message)")
            XCTAssertFalse(converted.message.isEmpty, name)
            print("STRESS \(name) error=\(converted.code): \(converted.message)")
        }
    }

    func test4KPartialGIF() throws {
        try run("4k_partial.gif", expectedFrames: 30) { importer in
            XCTAssertEqual(importer.canvasWidth, 3840)
            XCTAssertEqual(importer.canvasHeight, 2160)
            XCTAssertGreaterThan(importer.fileBytes, 1_000_000)
        }
    }

    func test500FrameGIFWithVariableDelays() throws {
        try run("many_delays.gif", expectedFrames: 500) { importer in
            XCTAssertGreaterThan(importer.correctedDelayCount, 0)
            XCTAssertTrue(importer.frames.contains { $0.rawDuration >= 0.5 })
        }
    }

    func testTransparentDisposalGIF() throws {
        try run("transparent_disposal.gif", expectedFrames: 12) { importer in
            XCTAssertTrue(importer.hasTransparency)
        }
    }

    func testOversizeCanvasRejectsWithSourcePixels() throws {
        try reject("oversize_canvas.gif", expectedCodes: ["E_SOURCE_PIXELS"])
    }

    func testOversizeByteCountRejectsBeforeReading() throws {
        let start = Date()
        let memory = Footprint()
        memory.sample()
        defer {
            memory.sample()
            print(String(format: "STRESS source_over_150mb time=%.2fs peakMB=%.1f",
                         Date().timeIntervalSince(start), memory.peakMB))
        }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress-large-\(UUID().uuidString).gif")
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(GIFImporter.maxSourceBytes + 1))
        try handle.close()
        let docs = try documents()
        XCTAssertThrowsError(try docs.importFile(source, name: "source_over_150mb")) {
            XCTAssertEqual(AppError.convert($0).code, "E_SOURCE_TOO_LARGE")
        }
    }

    func testTruncatedGIFRejectsWithReadableError() throws {
        // ImageIO can report a truncated stream as a one-frame image or as a
        // corrupt animated image, depending on the simulator's decoder.
        try reject("truncated.gif", expectedCodes: ["E_NOT_ANIMATED", "E_READ_FAILED"])
    }

    func test200FrameAPNG() throws {
        try run("many.apng", expectedFrames: 200)
    }

    func test200FrameWebP() throws {
        try run("many.webp", expectedFrames: 200)
    }

    func testSingleFrameGIFRejectsWithNotAnimated() throws {
        try reject("single.gif", expectedCodes: ["E_NOT_ANIMATED"])
    }

    func test120SecondGIFUsesDefaultFragment() throws {
        try run("long_120s.gif", expectedFrames: 120, minimumDuration: 120) { importer in
            XCTAssertEqual(importer.totalDuration, 120, accuracy: 0.1)
        }
    }
}
