import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum RenderPipeline {
    private static let thumbnailCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 24 * 1_048_576
        return cache
    }()

    static func sizeError(_ size: WidgetSize, settings: EditorSettings,
                          plan: AnimationPlanner.Plan,
                          budget: AnimationBudget = .standard) -> AppError? {
        guard let geometry = settings.geometry[size], geometry.width > 0, geometry.height > 0,
              let limit = budget.maxPixels[size],
              geometry.width <= limit / geometry.height else {
            return AppError(code: "E_BUDGET_PIXELS", message: "\(size.rawValue): разрешение превышает бюджет.",
                            hint: "Уменьшите ширину или высоту в «Кадрировании».")
        }
        let decoded = Double(geometry.width) * Double(geometry.height) * 4 * Double(plan.uniqueSourceIndices.count)
        if decoded > Double(budget.maxDecodedBytes) {
            return AppError(code: "E_BUDGET_MEMORY",
                message: String(format: "%@: %.1f МБ > %.1f МБ", size.rawValue,
                                decoded / 1_048_576, Double(budget.maxDecodedBytes) / 1_048_576),
                hint: "Уменьшите разрешение или выберите план «Надёжно».")
        }
        return nil
    }

    static func makeDraft(importer: GIFImporter, settings: EditorSettings,
                          sizes: Set<WidgetSize> = Set(WidgetSize.allCases),
                          budget: AnimationBudget = .standard,
                          progress: (Double) -> Void = { _ in }) throws -> ProjectDraft {
        let plan = try settings.resolvedPlan(importer: importer, budget: budget)
        guard !sizes.isEmpty else {
            throw AppError(code: "E_SIZE_MISSING", message: "Не выбран ни один размер.",
                           hint: "Включите хотя бы один размер в проверке.")
        }
        for size in sizes {
            if let error = sizeError(size, settings: settings, plan: plan, budget: budget) {
                throw error
            }
        }
        var variants: [WidgetSize: VariantDraft] = [:]
        let ordered = WidgetSize.allCases.filter { sizes.contains($0) }
        let total = ordered.count * plan.uniqueSourceIndices.count
        var completed = 0
        for size in ordered {
            let options = try settings.frameOptions(for: size)
            var png: [Data] = []
            for index in plan.uniqueSourceIndices {
                try Task.checkCancellation()
                let source = try importer.frame(at: index)
                let frame = try FrameProcessor.process(source, options: options)
                let data = try pngData(frame)
                guard data.count <= budget.maxPNGBytes else {
                    throw AppError(code: "E_BUDGET_PNG", message: "\(size.rawValue): PNG кадра \(index) слишком велик.",
                                   hint: "Уменьшите разрешение или палитру.")
                }
                png.append(data)
                completed += 1
                progress(Double(completed) / Double(max(1, total)))
            }
            guard let geometry = settings.geometry[size] else { continue }
            variants[size] = VariantDraft(width: geometry.width, height: geometry.height,
                fps: plan.fps, cycle: plan.cycle, slotCount: plan.slotCount,
                phaseToFrame: plan.phaseToFrame, overlapSeconds: budget.overlapSeconds,
                background: settings.background, pixelArt: settings.style == .pixelArt,
                pngData: png)
        }
        return ProjectDraft(id: settings.id, name: settings.name, createdAt: .now,
                            variants: variants)
    }

    static func previewFrame(importer: GIFImporter, settings: EditorSettings,
                             size: WidgetSize, sourceIndex: Int) throws -> Data {
        let encoded = try JSONEncoder().encode(settings)
        let digest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let key = "\(digest):\(size.rawValue):\(sourceIndex)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached as Data }
        try Task.checkCancellation()
        let options = try settings.frameOptions(for: size, preview: true)
        let source = try importer.thumbnail(at: sourceIndex, maxPixelSize: 600)
        let processed = try FrameProcessor.process(source, options: options)
        let data = try pngData(processed)
        thumbnailCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            bytes as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError(code: "E_RENDER_PNG", message: "Не создан PNG-кодер.",
                           hint: "Попробуйте уменьшить разрешение.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppError(code: "E_RENDER_PNG", message: "Не удалось записать PNG.",
                           hint: "Попробуйте уменьшить разрешение.")
        }
        return bytes as Data
    }
}
