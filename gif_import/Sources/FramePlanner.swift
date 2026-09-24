import Foundation

/// Чистая логика: этот файл можно включать и в тестовый target без iOS SDK.
enum FramePlanner {
    struct Plan: Equatable {
        let fps: Int
        let frameCount: Int
        let timerCycle: Int
        let sourceIndices: [Int]
        let pingPong: Bool

        var loopDuration: Double { Double(frameCount) / Double(fps) }
        var phaseCount: Int { timerCycle * fps }
    }

    enum PlanningError: Error {
        case invalidInput
        case noFeasiblePlan
    }

    static let cycleDivisors = [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60]
    /// Общие пределы для планировщика и FrameStore: план, выходящий за них,
    /// FrameStore отвергнет. Потолок фаз уточняется проверкой длины анимации.
    static let fpsLimit = 1...12
    static let maxPhases = 48

    /// Времена относятся к одному проходу исходника. В режиме ping-pong
    /// один проход занимает приблизительно половину итоговой петли.
    static func makePlan(
        durations: [Double],
        budget: Int,
        preferredFPS: Int = 8,
        allowedFPS: ClosedRange<Int> = 4...12,
        maxPhaseCount: Int = maxPhases,
        pingPong: Bool = false
    ) throws -> Plan {
        guard !durations.isEmpty, (1...24).contains(budget), preferredFPS > 0,
              fpsLimit.contains(allowedFPS.lowerBound),
              fpsLimit.contains(allowedFPS.upperBound),
              (1...maxPhases).contains(maxPhaseCount),
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw PlanningError.invalidInput
        }
        let total = durations.reduce(0, +)
        guard total.isFinite && total > 0 else { throw PlanningError.invalidInput }

        var best: (score: Double, plan: Plan)?
        for fps in allowedFPS {
            for count in 1...budget {
                if pingPong && (count < 4 || count % 2 != 0) { continue }
                guard let cycle = cycleDivisors.first(where: {
                    ($0 * fps) <= maxPhaseCount && ($0 * fps) % count == 0
                }) else { continue }

                let forwardSlots = pingPong ? (count + 2) / 2 : count
                let traversal = pingPong
                    ? Double(forwardSlots - 1) / Double(fps)
                    : Double(forwardSlots) / Double(fps)
                // Длительность важнее близости к желаемой частоте.
                let mismatch = abs(log(traversal / total))
                let fpsPenalty = 0.12 * abs(log(Double(fps) / Double(preferredFPS)))
                let phasePenalty = 0.0005 * Double(cycle * fps)
                let score = mismatch + fpsPenalty + phasePenalty
                let indices = sampleIndices(durations: durations, count: forwardSlots)
                let sequence: [Int]
                if pingPong {
                    // Концы не удваиваются: 0,1,2,3,2,1.
                    sequence = indices + Array(indices.dropFirst().dropLast().reversed())
                } else {
                    sequence = indices
                }
                let plan = Plan(fps: fps, frameCount: sequence.count,
                                timerCycle: cycle, sourceIndices: sequence,
                                pingPong: pingPong)
                if let current = best {
                    if score < current.score - 1e-9 ||
                        (abs(score - current.score) <= 1e-9 && plan.fps > current.plan.fps) {
                        best = (score, plan)
                    }
                } else {
                    best = (score, plan)
                }
            }
        }
        guard let best else { throw PlanningError.noFeasiblePlan }
        return best.plan
    }

    /// Выборка в центрах равных временных интервалов, с учётом задержек.
    static func sampleIndices(durations: [Double], count: Int) -> [Int] {
        guard !durations.isEmpty, count > 0 else { return [] }
        let total = durations.reduce(0, +)
        var result: [Int] = []
        result.reserveCapacity(count)
        var index = 0
        var end = durations[0]
        for slot in 0..<count {
            // деление до умножения: при огромном total произведение уходит в infinity
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
