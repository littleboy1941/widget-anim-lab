import Foundation

enum WidgetSize: String, Codable, CaseIterable, Hashable {
    case small, medium, large
}

/// Conservative product limits. Recheck all pixel and memory limits with device measurements.
struct AnimationBudget: Codable, Equatable {
    /// 160 фаз = 20 с при 8 fps; проверено в стенде со стопками по 40 кадров (2026-09-24).
    var maxPhases = 160
    var maxPixels: [WidgetSize: Int] = [.small: 90_000, .medium: 120_000, .large: 160_000]
    // TODO: Measure peak widget RSS/jetsam on a real iPhone before revising this budget.
    var maxDecodedBytes = 16 * 1_048_576
    var maxPNGBytes = 4 * 1_048_576
    var minFPS = 4
    /// До 30 fps: в стенде 16 fps — 100 % по порядку, 24–30 fps — 98 % (симулятор, 2026-09-25).
    var maxFPS = 30
    var overlapSeconds = 0.02

    /// Перекрытие окон по частоте (замеры 2026-09-25): при высоком fps окно короче
    /// (33–62 мс), и 0,02 с даёт заметное двоение.
    func overlap(forFPS fps: Int) -> Double {
        if fps <= 12 { return overlapSeconds }
        if fps <= 24 { return 0.01 }
        return 0
    }
    var maxLogBytes = 256 * 1024

    static let standard = AnimationBudget()
    static let supportedCycles = [2, 3, 4, 5, 6, 10, 12, 15, 20, 30]
}

struct FrameRecord: Codable, Equatable {
    let file: String
    let byteCount: Int
    let sha256: String
}

struct CanvasColor: Codable, Equatable {
    /// Nil means a transparent widget background. Otherwise use opaque sRGB bytes.
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct WidgetVariant: Codable, Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let cycle: Int
    /// N output slots; N divides phaseCount. frames contains only unique PNGs.
    let slotCount: Int
    let phaseToFrame: [Int]
    let overlapSeconds: Double
    let background: CanvasColor?
    let pixelArt: Bool
    let frames: [FrameRecord]

    var phaseCount: Int { cycle * fps }
    var frameCount: Int { frames.count }
    var decodedBytes: Int { width * height * 4 * frames.count }
}

struct ProjectManifest: Codable, Equatable {
    let version: Int
    let id: UUID
    let name: String
    let createdAt: Date
    let generation: UUID
    let variants: [WidgetSize: WidgetVariant]
}

struct VariantDraft {
    let width: Int
    let height: Int
    let fps: Int
    let cycle: Int
    let slotCount: Int
    let phaseToFrame: [Int]
    let overlapSeconds: Double
    let background: CanvasColor?
    let pixelArt: Bool
    let pngData: [Data]
}

struct ProjectDraft {
    let id: UUID
    let name: String
    let createdAt: Date
    let variants: [WidgetSize: VariantDraft]
}

enum ProjectReadError: Error, Equatable {
    case groupUnavailable
    case projectDeleted
    case manifestInvalid(String)
    case frameFileMissing(String)
    case frameInvalid(String)
    case budgetExceeded(actualMB: Double, limitMB: Double)

    var code: String {
        switch self {
        case .groupUnavailable: "GROUP_UNAVAILABLE"
        case .projectDeleted: "PROJECT_DELETED"
        case .manifestInvalid: "MANIFEST_INVALID"
        case .frameFileMissing: "FRAME_MISSING"
        case .frameInvalid: "FRAME_INVALID"
        case .budgetExceeded: "BUDGET_EXCEEDED"
        }
    }

    var message: String {
        switch self {
        case .groupUnavailable: "App Group unavailable. \(AppGroup.diagnostics)"
        case .projectDeleted: "Project deleted. Choose another animation."
        case .manifestInvalid(let reason): "Manifest invalid: \(reason)"
        case .frameFileMissing(let name): "Frame file missing: \(name)"
        case .frameInvalid(let reason): "Frame invalid: \(reason)"
        case .budgetExceeded(let actual, let limit):
            String(format: "Budget exceeded: %.1f MB > %.1f MB", actual, limit)
        }
    }
}
