import XCTest

// Добавить FramePlanner.swift и этот файл в отдельный тестовый target.
final class FramePlannerTests: XCTestCase {
    func testTwelveFramesAtEightFPS() throws {
        let plan = try FramePlanner.makePlan(
            durations: Array(repeating: 0.125, count: 12), budget: 12
        )
        XCTAssertEqual(plan.fps, 8)
        XCTAssertEqual(plan.frameCount, 12)
        XCTAssertEqual(plan.timerCycle, 3)
        XCTAssertEqual(plan.sourceIndices, Array(0..<12))
        XCTAssertEqual(plan.phaseCount % plan.frameCount, 0)
    }

    func testVariableDelaysSampleByTime() {
        XCTAssertEqual(
            FramePlanner.sampleIndices(durations: [0.1, 0.7, 0.2], count: 5),
            [1, 1, 1, 1, 2]
        )
    }

    func testPingPongDoesNotRepeatEndpoints() throws {
        let plan = try FramePlanner.makePlan(
            durations: Array(repeating: 0.125, count: 12),
            budget: 24, pingPong: true
        )
        XCTAssertEqual(plan.fps, 8)
        XCTAssertEqual(plan.frameCount, 24)
        XCTAssertEqual(Array(plan.sourceIndices[13...]),
                       Array(plan.sourceIndices[1..<12].reversed()))
        XCTAssertEqual(plan.phaseCount % plan.frameCount, 0)
    }

    func testImpossiblePhaseBudget() {
        XCTAssertThrowsError(try FramePlanner.makePlan(
            durations: [1], budget: 12, maxPhaseCount: 2
        ))
    }

    func testInvalidDuration() {
        XCTAssertThrowsError(try FramePlanner.makePlan(durations: [0], budget: 12))
    }
}
