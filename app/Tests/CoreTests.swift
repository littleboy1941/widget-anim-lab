import Foundation
import UIKit
import XCTest

final class CoreTests: XCTestCase {
    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2),
                                      format: format).pngData { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func draft(id: UUID = UUID(), bytes: Data? = nil) -> ProjectDraft {
        let data = bytes ?? png()
        let variant = VariantDraft(width: 2, height: 2, fps: 4, cycle: 2,
                                   slotCount: 2, phaseToFrame: [0, 0, 0, 0, 0, 0, 0, 0],
                                   overlapSeconds: 0.02, background: nil,
                                   pixelArt: true, pngData: [data])
        return ProjectDraft(id: id, name: "Fixture", createdAt: .now,
                            variants: [.small: variant])
    }

    private func tempStore(budget: AnimationBudget = .standard) -> ProjectStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-lab-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProjectStore(root: root, budget: budget)
    }

    func testPlannerEnumeratesOnlyValidPlansAndDeduplicates() throws {
        let plans = try AnimationPlanner.allPlans(durations: [0.8, 0.1, 0.1],
                                                   speed: 1, mode: .forward,
                                                   pixelsPerFrame: 4)
        XCTAssertFalse(plans.isEmpty)
        for plan in plans {
            XCTAssertTrue((4...12).contains(plan.fps))
            XCTAssertEqual(60 % plan.cycle, 0)
            XCTAssertLessThanOrEqual(plan.phaseCount, 40)
            XCTAssertEqual(plan.phaseCount % plan.slotCount, 0)
            XCTAssertEqual(plan.phaseToFrame.count, plan.phaseCount)
            // петля по кругу: фаза i показывает слот i mod N, кадр меняется каждую 1/fps с
            for phase in 0..<plan.phaseCount {
                let slot = phase % plan.slotCount
                XCTAssertEqual(plan.phaseToFrame[phase],
                               plan.uniqueSourceIndices.firstIndex(of: plan.sourceIndices[slot]),
                               "fps \(plan.fps) C \(plan.cycle) N \(plan.slotCount) phase \(phase)")
            }
        }
        XCTAssertTrue(plans.contains { $0.uniqueSourceIndices.count < $0.slotCount })
    }

    func testFragmentUsesIntersectionDurations() {
        let first = EditorSettings.intersectionDuration(frameStart: 0, frameDuration: 0.1,
            fragmentStart: 0.09, fragmentEnd: 0.15)
        let second = EditorSettings.intersectionDuration(frameStart: 0.1, frameDuration: 0.1,
            fragmentStart: 0.09, fragmentEnd: 0.15)
        XCTAssertEqual(first, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(second, 0.05, accuracy: 0.000_001)
    }

    func testReliablePresetKeepsAnimation() throws {
        let plans = try AnimationPlanner.allPlans(durations: [0.1, 0.1, 0.1],
            speed: 1, mode: .forward, pixelsPerFrame: 4)
        let selected = try XCTUnwrap(AnimationPlanner.reliablePlan(from: plans,
            sourceFrameCount: 3))
        XCTAssertGreaterThanOrEqual(selected.uniqueSourceIndices.count, 2)
        XCTAssertEqual(AnimationPlanner.reliablePlan(from: plans.filter {
            $0.uniqueSourceIndices.count == 1
        }, sourceFrameCount: 3), nil)
    }

    func testSourceLimitsAndOutputDimensions() throws {
        XCTAssertNoThrow(try GIFImporter.validateSource(width: 10_000, height: 8_000,
            bytes: 150_000_000))
        XCTAssertThrowsError(try GIFImporter.validateSource(width: 10_000, height: 8_001,
            bytes: 1)) {
            XCTAssertEqual(AppError.convert($0).code, "E_SOURCE_PIXELS")
        }
        XCTAssertThrowsError(try GIFImporter.validateSource(width: 1, height: 1,
            bytes: 150_000_001)) {
            XCTAssertEqual(AppError.convert($0).code, "E_SOURCE_TOO_LARGE")
        }
        XCTAssertFalse(FrameProcessor.validDimensions(3_000, 20))
        XCTAssertTrue(FrameProcessor.validDimensions(2_048, 20))
        var settings = EditorSettings(id: UUID(), name: "Размер", sourceFile: "source.gif",
            duration: 1)
        settings.geometry[.small] = OutputGeometry(width: 3_000, height: 20, layout: .fit)
        let plan = AnimationPlanner.Plan(fps: 4, slotCount: 2, cycle: 2,
            sourceIndices: [0, 1], uniqueSourceIndices: [0, 1],
            phaseToFrame: [0, 1, 0, 1, 0, 1, 0, 1])
        XCTAssertEqual(RenderPipeline.sizeError(.small, settings: settings, plan: plan)?.code,
                       "E_BUDGET_PIXELS")
    }

    func testPingPongDoesNotRepeatEndpoints() throws {
        let plans = try AnimationPlanner.allPlans(durations: [1, 1, 1, 1],
                                                   speed: 1, mode: .pingPong,
                                                   pixelsPerFrame: 4)
        let plan = try XCTUnwrap(plans.first { $0.slotCount == 6 })
        XCTAssertEqual(plan.sourceIndices, [0, 1, 2, 3, 2, 1])
    }

    func testManifestRoundTrip() throws {
        let store = tempStore()
        let input = draft()
        try store.publish(input)
        let manifest = try store.read(input.id, size: .small).manifest
        let decoded = try JSONDecoder().decode(ProjectManifest.self,
                                                from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(manifest.version, 2)
    }

    func testPublicationRollbackAndDeletion() throws {
        let store = tempStore()
        let input = draft()
        try store.publish(input)
        XCTAssertEqual(try store.listing().projects.map(\.id), [input.id])
        XCTAssertThrowsError(try store.publish(draft(id: input.id, bytes: Data("bad".utf8))))
        XCTAssertEqual(try store.read(input.id, size: .small).manifest.name, "Fixture")
        try store.delete(input.id)
        XCTAssertTrue(try store.listing().projects.isEmpty)
        XCTAssertThrowsError(try store.read(input.id, size: .small)) {
            XCTAssertEqual($0 as? ProjectReadError, .projectDeleted)
        }
    }

    func testGenerationCleanupKeepsOnlyCurrent() throws {
        let store = tempStore()
        let id = UUID()
        try store.publish(draft(id: id))
        let first = try XCTUnwrap(store.listing().projects.first).generation
        try store.publish(draft(id: id))
        let second = try XCTUnwrap(store.listing().projects.first).generation
        let directory = store.root.appendingPathComponent(id.uuidString.lowercased())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(first.uuidString.lowercased()).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory
            .appendingPathComponent(second.uuidString.lowercased()).path))
        try store.delete(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPixelScaleSkipsSolidFirstFrame() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let solid = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4),
            format: format).image { context in
                context.cgContext.setFillColor(UIColor.red.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            }
        let patterned = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4),
            format: format).image { context in
                context.cgContext.setFillColor(UIColor.red.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                context.cgContext.setFillColor(UIColor.blue.cgColor)
                context.cgContext.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
            }
        let images = [try XCTUnwrap(solid.cgImage), try XCTUnwrap(patterned.cgImage)]
        XCTAssertEqual(PixelArtScale.detectConsistent(images), 4)
    }

    func testTypedReadErrors() throws {
        let missing = tempStore()
        XCTAssertThrowsError(try missing.read(UUID(), size: .small)) {
            XCTAssertEqual($0 as? ProjectReadError, .projectDeleted)
        }
        let store = tempStore()
        let input = draft()
        try store.publish(input)
        XCTAssertThrowsError(try store.read(input.id, size: .medium)) {
            guard let error = $0 as? ProjectReadError,
                  case .manifestInvalid = error else { return XCTFail() }
        }
        let base = store.root.appendingPathComponent(input.id.uuidString.lowercased())
        let manifest = try store.read(input.id, size: .small).manifest
        let frame = base.appendingPathComponent(manifest.generation.uuidString.lowercased())
            .appendingPathComponent("small/frame_000.png")
        try Data("changed".utf8).write(to: frame)
        XCTAssertThrowsError(try store.read(input.id, size: .small)) {
            guard let error = $0 as? ProjectReadError,
                  case .frameInvalid = error else { return XCTFail() }
        }
        try FileManager.default.removeItem(at: frame)
        XCTAssertThrowsError(try store.read(input.id, size: .small)) {
            guard let error = $0 as? ProjectReadError,
                  case .frameFileMissing = error else { return XCTFail() }
        }
        var tiny = AnimationBudget.standard
        tiny.maxDecodedBytes = 1
        let constrained = ProjectStore(root: store.root, budget: tiny)
        XCTAssertThrowsError(try constrained.read(input.id, size: .small)) {
            guard let error = $0 as? ProjectReadError,
                  case .budgetExceeded = error else { return XCTFail() }
        }
    }

    private func twoColorImage() throws -> CGImage {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info))
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(UIColor.blue.cgColor)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let start = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes + start, count: 4))
    }

    func testRectangularRenderingFitFillRotateFlipAndBackground() throws {
        let source = try twoColorImage()
        var options = FrameProcessor.Options()
        options.width = 4; options.height = 4; options.style = .pixelArt
        options.layout = .fit
        let fit = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(fit.width, 4); XCTAssertEqual(fit.height, 4)
        XCTAssertEqual(try pixel(fit, x: 0, y: 0)[3], 0)
        XCTAssertEqual(try pixel(fit, x: 0, y: 2)[3], 255)

        options.layout = .crop
        let fill = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(try pixel(fill, x: 0, y: 0)[3], 255)
        options.flipX = true
        let flipped = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(try pixel(fill, x: 0, y: 2), try pixel(flipped, x: 3, y: 2))
        XCTAssertEqual(try pixel(fill, x: 3, y: 2), try pixel(flipped, x: 0, y: 2))

        options.flipX = false; options.rotation = 90
        options.width = 2; options.height = 4
        let rotated = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(rotated.width, 2); XCTAssertEqual(rotated.height, 4)
        XCTAssertNotEqual(try pixel(rotated, x: 1, y: 0), try pixel(rotated, x: 1, y: 3))
        options.flipY = true
        let reflected = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(try pixel(rotated, x: 1, y: 0), try pixel(reflected, x: 1, y: 3))

        options.rotation = 0; options.flipY = false; options.layout = .fit
        options.width = 4; options.height = 4
        options.background = CanvasColor(red: 12, green: 34, blue: 56)
        let backed = try FrameProcessor.process(source, options: options)
        XCTAssertEqual(try pixel(backed, x: 0, y: 0), [12, 34, 56, 255])
    }

    func testEditorSettingsRoundTrip() throws {
        var value = EditorSettings(id: UUID(), name: "Тест", sourceFile: "source.gif", duration: 8)
        value.fragmentStart = 1.25; value.fragmentEnd = 6.5
        value.loop = .pingPong; value.speed = 1.5
        value.selectedPlan = PlanChoice(fps: 8, slotCount: 4, cycle: 2)
        value.manualSlots = [3, 2, 1, 2]
        value.geometry[.medium]?.width = 280
        value.background = CanvasColor(red: 1, green: 2, blue: 3)
        value.rotation = 270; value.flipX = true; value.paletteColors = 32
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testManualSlotEditsRecalculateFeasiblePlans() throws {
        let four = AnimationPlanner.manualPlans(indices: [0, 1, 2, 3],
            sourceCount: 20, pixelsPerFrame: 100)
        XCTAssertFalse(four.isEmpty)
        XCTAssertTrue(four.allSatisfy { $0.slotCount == 4 && $0.phaseCount % 4 == 0 })
        let thirteen = AnimationPlanner.manualPlans(indices: Array(0..<13),
            sourceCount: 20, pixelsPerFrame: 100)
        XCTAssertTrue(thirteen.isEmpty)
        let gif = try XCTUnwrap(Bundle(for: CoreTests.self).url(forResource: "test", withExtension: "gif"))
        let importer = try GIFImporter(url: gif)
        var settings = EditorSettings(id: UUID(), name: "Лента", sourceFile: "test.gif",
                                      duration: importer.totalDuration)
        let original = try XCTUnwrap(settings.availablePlans(importer: importer).first)
        settings.selectedPlan = PlanChoice(original)
        settings.manualSlots = Array(repeating: 0, count: 13)
        XCTAssertTrue(try settings.availablePlans(importer: importer).isEmpty)
        XCTAssertThrowsError(try settings.resolvedPlan(importer: importer)) {
            XCTAssertEqual(($0 as? AppError)?.code, "E_PLAN_INVALID")
        }
    }

    func testBundledGIFThroughRenderPipelineAndStore() throws {
        let gif = try XCTUnwrap(Bundle(for: CoreTests.self).url(forResource: "test", withExtension: "gif"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let documents = try ProjectDocuments(root: root.appendingPathComponent("documents"))
        let settings = try documents.importBytes(Data(contentsOf: gif), name: "Test GIF")
        let importer = try GIFImporter(url: documents.sourceURL(settings))
        let plans = try settings.availablePlans(importer: importer)
        XCTAssertTrue(plans.contains { settings.selectedPlan?.matches($0) ?? false })
        let draft = try RenderPipeline.makeDraft(importer: importer, settings: settings)
        XCTAssertEqual(draft.id, settings.id)
        XCTAssertEqual(draft.variants.count, 3)
        let store = ProjectStore(root: root.appendingPathComponent("published"))
        try store.publish(draft)
        for size in WidgetSize.allCases {
            XCTAssertFalse(try store.read(settings.id, size: size).frames.isEmpty)
        }
    }
}
