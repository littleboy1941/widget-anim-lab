import Foundation

struct OutputGeometry: Codable, Equatable {
    var width: Int
    var height: Int
    var layout: FrameProcessor.Layout
    var offsetX: Double = 0
    var offsetY: Double = 0
    var zoom: Double = 1

    static func initial(_ size: WidgetSize) -> OutputGeometry {
        switch size {
        case .small: OutputGeometry(width: 240, height: 240, layout: .fit)
        case .medium: OutputGeometry(width: 300, height: 140, layout: .fit)
        case .large: OutputGeometry(width: 280, height: 300, layout: .fit)
        }
    }
}

extension FrameProcessor.Layout: Codable, Hashable {
    private enum Value: String, Codable { case crop, fit }
    init(from decoder: Decoder) throws {
        self = try Value(from: decoder) == .crop ? .crop : .fit
    }
    func encode(to encoder: Encoder) throws {
        try (self == .crop ? Value.crop : Value.fit).encode(to: encoder)
    }
}

extension FrameProcessor.Style: Codable, Hashable {
    private enum Value: String, Codable { case automatic, photo, pixelArt }
    init(from decoder: Decoder) throws {
        switch try Value(from: decoder) {
        case .automatic: self = .automatic
        case .photo: self = .photo
        case .pixelArt: self = .pixelArt
        }
    }
    func encode(to encoder: Encoder) throws {
        let value: Value
        switch self {
        case .automatic: value = .automatic
        case .photo: value = .photo
        case .pixelArt: value = .pixelArt
        }
        try value.encode(to: encoder)
    }
}

struct PlanChoice: Codable, Equatable {
    var fps: Int
    var slotCount: Int
    var cycle: Int
    init(fps: Int, slotCount: Int, cycle: Int) {
        self.fps = fps; self.slotCount = slotCount; self.cycle = cycle
    }
    init(_ plan: AnimationPlanner.Plan) {
        fps = plan.fps; slotCount = plan.slotCount; cycle = plan.cycle
    }
    func matches(_ plan: AnimationPlanner.Plan) -> Bool {
        fps == plan.fps && slotCount == plan.slotCount && cycle == plan.cycle
    }
}

struct EditorSettings: Codable, Equatable {
    var id: UUID
    var name: String
    /// File name relative to the private project directory, never an external URL.
    var sourceFile: String
    var fragmentStart: Double
    var fragmentEnd: Double
    var loop: LoopMode = .forward
    var speed: Double = 1
    var selectedPlan: PlanChoice? = nil
    var manualSlots: [Int]? = nil
    var geometry: [WidgetSize: OutputGeometry]
    var background: CanvasColor? = nil
    var alphaThreshold: UInt8 = 8
    var style: FrameProcessor.Style = .automatic
    var paletteColors: Int? = nil
    var rotation: Int = 0
    var flipX = false
    var flipY = false
    var brightness: Double = 0
    var contrast: Double = 1

    init(id: UUID, name: String, sourceFile: String, duration: Double) {
        self.id = id
        self.name = name
        self.sourceFile = sourceFile
        fragmentStart = 0
        fragmentEnd = min(duration, 5)
        geometry = Dictionary(uniqueKeysWithValues: WidgetSize.allCases.map {
            ($0, OutputGeometry.initial($0))
        })
    }

    func selectedFrameIndices(in importer: any AnimationSource) -> [Int] {
        importer.frames.filter {
            $0.startTime < fragmentEnd && $0.startTime + $0.duration > fragmentStart
        }.map(\.index)
    }

    func selectedFrameDurations(in importer: any AnimationSource) -> [Double] {
        selectedFrameIndices(in: importer).map { index in
            let frame = importer.frames[index]
            return Self.intersectionDuration(frameStart: frame.startTime,
                frameDuration: frame.duration, fragmentStart: fragmentStart,
                fragmentEnd: fragmentEnd)
        }
    }

    static func intersectionDuration(frameStart: Double, frameDuration: Double,
                                     fragmentStart: Double, fragmentEnd: Double) -> Double {
        let start = max(frameStart, fragmentStart)
        let end = min(frameStart + frameDuration, fragmentEnd)
        return max(0, end - start)
    }

    func availablePlans(importer: any AnimationSource,
                        budget: AnimationBudget = .standard) throws -> [AnimationPlanner.Plan] {
        let pixels = WidgetSize.allCases.compactMap { size -> Int? in
            guard let item = geometry[size], FrameProcessor.validDimensions(item.width, item.height),
                  let limit = budget.maxPixels[size], item.width <= limit / item.height else { return nil }
            return item.width * item.height
        }.min() ?? 0
        if let slots = manualSlots {
            return AnimationPlanner.manualPlans(indices: slots,
                                                sourceCount: importer.frames.count,
                                                pixelsPerFrame: pixels, budget: budget)
        }
        let selected = selectedFrameIndices(in: importer)
        guard !selected.isEmpty else { return [] }
        let durations = selectedFrameDurations(in: importer)
        let local = try AnimationPlanner.allPlans(durations: durations, speed: speed,
            mode: loop, pixelsPerFrame: pixels, budget: budget)
        return local.map { plan in
            AnimationPlanner.Plan(fps: plan.fps, slotCount: plan.slotCount,
                cycle: plan.cycle, sourceIndices: plan.sourceIndices.map { selected[$0] },
                uniqueSourceIndices: plan.uniqueSourceIndices.map { selected[$0] },
                phaseToFrame: plan.phaseToFrame)
        }
    }

    func resolvedPlan(importer: any AnimationSource,
                      budget: AnimationBudget = .standard) throws -> AnimationPlanner.Plan {
        let plans = try availablePlans(importer: importer, budget: budget)
        guard let choice = selectedPlan,
              let plan = plans.first(where: choice.matches) else {
            throw AppError(code: "E_PLAN_INVALID", message: "Выбранный план больше не подходит.",
                           hint: "Откройте вкладку «План» и выберите допустимый вариант.")
        }
        return plan
    }

    func frameOptions(for size: WidgetSize) throws -> FrameProcessor.Options {
        guard let geometry = geometry[size] else {
            throw AppError(code: "E_SIZE_MISSING", message: "Нет настроек размера \(size.rawValue).",
                           hint: "Задайте разрешение в «Кадрировании».")
        }
        var options = FrameProcessor.Options()
        options.width = geometry.width
        options.height = geometry.height
        options.layout = geometry.layout
        options.offsetX = geometry.offsetX
        options.offsetY = geometry.offsetY
        options.zoom = geometry.zoom
        options.rotation = rotation
        options.flipX = flipX
        options.flipY = flipY
        options.brightness = brightness
        options.contrast = contrast
        options.background = background
        options.transparentAlphaThreshold = alphaThreshold
        options.style = style
        options.paletteColors = paletteColors
        return options
    }
}

struct AppError: Error, Identifiable, Equatable {
    var code: String
    var message: String
    var hint: String
    var id: String { code + message }

    static func convert(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }
        if let read = error as? ProjectReadError {
            let message: String
            switch read {
            case .groupUnavailable: message = "Контейнер App Group недоступен. \(AppGroup.diagnostics)"
            case .projectDeleted: message = "Проект удалён. Выберите другую анимацию."
            case .manifestInvalid(let reason): message = "Манифест повреждён: \(reason)"
            case .frameFileMissing(let name): message = "Отсутствует кадр \(name)."
            case .frameInvalid(let reason): message = "Кадр повреждён: \(reason)"
            case .budgetExceeded(let actual, let limit):
                message = String(format: "Память %.1f МБ превышает бюджет %.1f МБ.", actual, limit)
            }
            return AppError(code: "E_\(read.code)", message: message,
                            hint: "Проверьте исходник и попробуйте сохранить ещё раз.")
        }
        if let imported = error as? GIFImporter.ImportError {
            switch imported {
            case .emptyAnimation:
                return AppError(code: "E_NOT_ANIMATED", message: "В файле меньше двух кадров.",
                                hint: "Выберите анимированный GIF, APNG или WebP.")
            case .unsupportedFormat:
                return AppError(code: "E_UNSUPPORTED_TYPE", message: "Формат не поддерживается.",
                                hint: "Выберите GIF, APNG или WebP.")
            case .decodeFailed(let index):
                return AppError(code: "E_READ_FAILED", message: "Не прочитан кадр \(index).",
                                hint: "Попробуйте другой исходник.")
            case .sourcePixels:
                return AppError(code: "E_SOURCE_PIXELS", message: "Холст исходника превышает 80 Мпикс.",
                                hint: "Выберите анимацию меньшего размера.")
            case .sourceTooLarge:
                return AppError(code: "E_SOURCE_TOO_LARGE", message: "Файл исходника превышает 150 МБ.",
                                hint: "Выберите файл меньшего размера.")
            default: break
            }
        }
        if let video = error as? VideoSourceError {
            switch video {
            case .sourceTooLong:
                return AppError(code: "E_SOURCE_TOO_LONG", message: "Видео длиннее 60 секунд.",
                                hint: "Выберите фрагмент до 60 секунд в «Фото» или «Файлах» и импортируйте его снова.")
            case .noVideoTrack, .invalidDuration:
                return AppError(code: "E_NOT_ANIMATED", message: "В файле нет пригодного видеоряда.",
                                hint: "Выберите MP4, MOV, M4V или Live Photo с видео.")
            case .decodeFailed(let index):
                return AppError(code: "E_READ_FAILED", message: "Не прочитан видеокадр \(index).",
                                hint: "Попробуйте другой исходник.")
            case .mainThreadInitialization:
                return AppError(code: "E_READ_FAILED", message: "Видео открыто в главном потоке.",
                                hint: "Повторите импорт.")
            case .invalidSize:
                return AppError(code: "E_READ_FAILED", message: "Недопустимый размер видеокадра.",
                                hint: "Выберите другое видео.")
            }
        }
        if error is FrameProcessor.ProcessingError {
            return AppError(code: "E_RENDER_FRAME", message: "Не удалось обработать кадр.",
                            hint: "Проверьте разрешение и параметры кадрирования.")
        }
        if error is AnimationPlanner.PlanningError {
            return AppError(code: "E_PLAN_INVALID", message: "Нет допустимого плана для текущих настроек.",
                            hint: "Сократите фрагмент или снизьте разрешение.")
        }
        return AppError(code: "E_READ_FAILED", message: error.localizedDescription,
                        hint: "Проверьте файл и повторите действие.")
    }
}
