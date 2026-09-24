import Foundation

enum LoopMode { case forward, reverse, pingPong }

enum AnimationPlanner {
    struct Plan: Equatable {
        let fps: Int
        let slotCount: Int
        let cycle: Int
        let sourceIndices: [Int]
        let uniqueSourceIndices: [Int]
        let phaseToFrame: [Int]

        var phaseCount: Int { fps * cycle }
        var outputDuration: Double { Double(slotCount) / Double(fps) }
        var timerCount: Int { 2 * phaseCount }
    }

    enum PlanningError: Error { case invalidInput, noFeasiblePlan }

    /// Enumerates every geometrically and memory-feasible (fps, N, C) combination.
    static func allPlans(durations: [Double], speed: Double, mode: LoopMode,
                         pixelsPerFrame: Int, budget: AnimationBudget = .standard) throws -> [Plan] {
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              speed.isFinite, speed > 0, pixelsPerFrame > 0,
              pixelsPerFrame <= Int.max / 4,
              pixelsPerFrame <= (budget.maxPixels.values.max() ?? 0) else {
            throw PlanningError.invalidInput
        }
        let total = durations.reduce(0, +)
        guard total.isFinite, total > 0 else { throw PlanningError.invalidInput }
        let maxFrames = budget.maxDecodedBytes / (pixelsPerFrame * 4)
        var plans: [Plan] = []
        for fps in budget.minFPS...budget.maxFPS {
            for cycle in AnimationBudget.supportedCycles where 60 % cycle == 0 {
                let phases = fps * cycle
                guard phases <= budget.maxPhases else { continue }
                for slots in 1...phases where phases % slots == 0 {
                    if mode == .pingPong && (slots < 4 || slots % 2 != 0) { continue }
                    let forwardCount = mode == .pingPong ? (slots + 2) / 2 : slots
                    let sampled = sample(durations: durations, count: forwardCount)
                    let sequence: [Int]
                    switch mode {
                    case .forward: sequence = sampled
                    case .reverse: sequence = Array(sampled.reversed())
                    case .pingPong:
                        sequence = sampled + Array(sampled.dropFirst().dropLast().reversed())
                    }
                    var unique: [Int] = []
                    var lookup: [Int: Int] = [:]
                    let slotToFrame = sequence.map { source -> Int in
                        if let value = lookup[source] { return value }
                        let value = unique.count
                        unique.append(source)
                        lookup[source] = value
                        return value
                    }
                    guard unique.count <= maxFrames else { continue }
                    let repeats = phases / slots
                    let table = slotToFrame.flatMap { Array(repeating: $0, count: repeats) }
                    plans.append(Plan(fps: fps, slotCount: slots, cycle: cycle,
                                      sourceIndices: sequence, uniqueSourceIndices: unique,
                                      phaseToFrame: table))
                }
            }
        }
        if plans.isEmpty { throw PlanningError.noFeasiblePlan }
        return plans
    }

    static func defaultPlan(from plans: [Plan], durations: [Double], speed: Double,
                            mode: LoopMode, preferredFPS: Int = 8) -> Plan? {
        let input = durations.reduce(0, +) / speed
        let target = mode == .pingPong ? input * 2 : input
        return plans.min { a, b in
            func score(_ plan: Plan) -> Double {
                abs(log(plan.outputDuration / target)) +
                0.12 * abs(log(Double(plan.fps) / Double(preferredFPS))) +
                0.0005 * Double(plan.phaseCount)
            }
            return score(a) < score(b)
        }
    }

    /// Sample the center of each equal time interval, respecting source delays.
    private static func sample(durations: [Double], count: Int) -> [Int] {
        let total = durations.reduce(0, +)
        var result: [Int] = []
        var index = 0
        var end = durations[0]
        for slot in 0..<count {
            let time = (Double(slot) + 0.5) / Double(count) * total
            while index + 1 < durations.count && time >= end {
                index += 1
                end += durations[index]
            }
            result.append(index)
        }
        return result
    }
}
