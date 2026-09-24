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
        }
        XCTAssertTrue(plans.contains { $0.uniqueSourceIndices.count < $0.slotCount })
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
        XCTAssertEqual(store.list().map(\.id), [input.id])
        XCTAssertThrowsError(try store.publish(draft(id: input.id, bytes: Data("bad".utf8))))
        XCTAssertEqual(try store.read(input.id, size: .small).manifest.name, "Fixture")
        try store.delete(input.id)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertThrowsError(try store.read(input.id, size: .small)) {
            XCTAssertEqual($0 as? ProjectReadError, .projectDeleted)
        }
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
}
