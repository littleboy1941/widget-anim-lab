import SwiftUI
import UIKit

private enum EditorTool: String, CaseIterable, Identifiable {
    case plan = "План", frames = "Кадры", crop = "Кадр.", background = "Фон"
    case style = "Стиль", rotate = "Поворот", color = "Цвет"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .plan: "slider.horizontal.3"
        case .frames: "film.stack"
        case .crop: "crop.rotate"
        case .background: "square.on.square"
        case .style: "paintpalette"
        case .rotate: "rotate.right"
        case .color: "circle.lefthalf.filled"
        }
    }
}

private enum PreviewTheme: String, CaseIterable, Hashable {
    case light = "Светл.", dark = "Тёмн.", tinted = "Тон"
}

struct EditorView: View {
    let id: UUID
    let onReview: () -> Void
    @State private var settings: EditorSettings?
    @State private var importer: GIFImporter?
    @State private var nativeInfo: String?
    @State private var plans: [AnimationPlanner.Plan] = []
    @State private var previewFrames: [UIImage] = []
    @State private var sourceImage: UIImage?
    @State private var selectedSize: WidgetSize = .small
    @State private var theme: PreviewTheme = .dark
    @State private var showSource = false
    @State private var tool: EditorTool = .plan
    @State private var showPlans = false
    @State private var showDev = false
    @State private var error: AppError?
    @State private var previewWorker: Task<Void, Never>?
    @State private var playbackStart = Date()

    private var plan: AnimationPlanner.Plan? {
        guard let choice = settings?.selectedPlan else { return nil }
        return plans.first(where: choice.matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    preview
                    HStack {
                        Picker("Размер", selection: $selectedSize) {
                            Text("S").tag(WidgetSize.small)
                            Text("M").tag(WidgetSize.medium)
                            Text("L").tag(WidgetSize.large)
                        }.pickerStyle(.segmented)
                        Picker("Тема", selection: $theme) {
                            ForEach(PreviewTheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    Toggle("Показать исходник", isOn: $showSource).font(.caption)
                    if theme == .tinted {
                        Text("Тонировка — симуляция; итог проверяется в виджете.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    fragmentControls
                    if let error { AppErrorView(error: error) }
                    Group {
                        switch tool {
                        case .plan: planControls
                        case .frames: frameControls
                        case .crop: cropControls
                        case .background: backgroundControls
                        case .style: styleControls
                        case .rotate: rotateControls
                        case .color: colorControls
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16))
                }.padding(16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(EditorTool.allCases) { item in
                        Button {
                            tool = item
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.symbol).font(.title3)
                                Text(item.rawValue).font(.system(size: 10))
                            }
                            .foregroundStyle(tool == item ? Color.blue : Color.secondary)
                            .frame(width: 52)
                        }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .background(Color(white: 0.06))
        }
        .background(.black)
        .navigationTitle(settings?.name ?? "Редактор")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { onReview() }.disabled(plan == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("DEV") { showDev = true }
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .sheet(isPresented: $showPlans) { plansSheet }
        .sheet(isPresented: $showDev) {
            if let settings, let importer {
                DevPanelView(settings: settings, importer: importer, plan: plan)
            }
        }
        .task(id: id) { await load() }
        .onChange(of: selectedSize) { _, _ in schedulePreview() }
        .onDisappear { previewWorker?.cancel() }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            let geometry = settings?.geometry[selectedSize] ?? .initial(selectedSize)
            let aspect = CGFloat(geometry.width) / CGFloat(max(1, geometry.height))
            TimelineView(.animation(minimumInterval: 0.08)) { context in
                let count = previewFrames.count
                let fps = max(1, plan?.fps ?? 8)
                let elapsed = max(0, context.date.timeIntervalSince(playbackStart))
                let index = count == 0 ? 0 : Int(elapsed * Double(fps)) % count
                Group {
                    if showSource, let sourceImage {
                        Image(uiImage: sourceImage).resizable().scaledToFit()
                    } else if count > 0 {
                        Image(uiImage: previewFrames[index]).resizable()
                            .interpolation(settings?.style == .pixelArt ? .none : .high).scaledToFit()
                    } else {
                        ProgressView("Готовлю превью…")
                    }
                }
                .colorMultiply(theme == .tinted ? Color.cyan : Color.white)
                .saturation(theme == .tinted ? 0 : 1)
                .frame(width: min(260, 220 * aspect), height: min(260, 220 / aspect))
                .background(theme == .light ? Color.white : Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2)))
            }
            if let plan {
                Text("▶ \(plan.fps) fps · \(plan.slotCount) слотов · \(String(format: "%.1f", plan.outputDuration)) с")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 270)
        .background(Color(red: 0.07, green: 0.12, blue: 0.18), in: RoundedRectangle(cornerRadius: 22))
    }

    private var fragmentControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            let total = importer?.totalDuration ?? 1
            Text(String(format: "Фрагмент %.2f–%.2f с из %.2f с",
                        settings?.fragmentStart ?? 0, settings?.fragmentEnd ?? 0, total))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Text("Начало").font(.caption)
                Slider(value: Binding(get: { settings?.fragmentStart ?? 0 }, set: { value in
                    change { $0.fragmentStart = min(value, $0.fragmentEnd - 0.02); $0.manualSlots = nil }
                }), in: 0...max(0.02, total - 0.02))
            }
            HStack {
                Text("Конец").font(.caption)
                Slider(value: Binding(get: { settings?.fragmentEnd ?? total }, set: { value in
                    change { $0.fragmentEnd = max(value, $0.fragmentStart + 0.02); $0.manualSlots = nil }
                }), in: 0.02...max(0.02, total))
            }
            HStack {
                Button("◀ кадр") { stepFragment(-1) }
                Button("кадр ▶") { stepFragment(1) }
                Spacer()
                Button("Целиком") { change { $0.fragmentStart = 0; $0.fragmentEnd = total; $0.manualSlots = nil } }
            }.font(.caption)
        }
        .padding(12).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12))
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("План — только допустимые сочетания").font(.caption).foregroundStyle(.secondary)
            HStack {
                preset("Качество", plan: plans.max {
                    $0.fps == $1.fps ? $0.slotCount < $1.slotCount : $0.fps < $1.fps
                })
                preset("Баланс", plan: balancedPlan)
                preset("Надёжно", plan: plans.min { $0.phaseCount < $1.phaseCount })
            }
            Button("Все планы (\(plans.count))") { showPlans = true }
            Picker("Петля", selection: Binding(get: { settings?.loop ?? .forward }, set: { mode in
                change { $0.loop = mode; $0.manualSlots = nil }
            })) {
                Text("Обычная").tag(LoopMode.forward)
                Text("Обратная").tag(LoopMode.reverse)
                Text("Туда-обратно").tag(LoopMode.pingPong)
            }.pickerStyle(.segmented)
            HStack {
                Text("Скорость ×\(String(format: "%.1f", settings?.speed ?? 1))")
                Slider(value: Binding(get: { settings?.speed ?? 1 }, set: { value in
                    change { $0.speed = value; $0.manualSlots = nil }
                }), in: 0.25...3, step: 0.05)
            }
            if let plan { Text("Итоговая длительность: \(String(format: "%.2f", plan.outputDuration)) с") }
        }
    }

    private var balancedPlan: AnimationPlanner.Plan? {
        guard let importer, let settings else { return nil }
        let durations = settings.selectedFrameIndices(in: importer).map { importer.frames[$0].duration }
        return AnimationPlanner.defaultPlan(from: plans, durations: durations,
                                            speed: settings.speed, mode: settings.loop)
    }

    private func preset(_ title: String, plan: AnimationPlanner.Plan?) -> some View {
        Button {
            if let plan { select(plan) }
        } label: {
            VStack(alignment: .leading) {
                Text(title).font(.caption)
                if let plan { Text("\(plan.fps) fps · \(plan.slotCount)") }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .disabled(plan == nil)
    }

    private var plansSheet: some View {
        NavigationStack {
            List(plans.indices, id: \.self) { index in
                let item = plans[index]
                Button("\(item.fps) fps · \(item.slotCount) слотов · C \(item.cycle) · \(item.phaseCount) фаз") {
                    select(item); showPlans = false
                }
            }
            .navigationTitle("Допустимые планы")
            .toolbar { Button("Закрыть") { showPlans = false } }
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Выходные слоты: выберите кадр источника, удалите, продублируйте или переставьте.")
                .font(.caption).foregroundStyle(.secondary)
            if let indices = settings?.manualSlots ?? plan?.sourceIndices {
                ForEach(indices.indices, id: \.self) { slot in
                    let source = indices[slot]
                    HStack {
                        Text("\(slot + 1)").font(.system(size: 12, design: .monospaced))
                            .frame(width: 30)
                        if let image = previewFrames[safe: slot] {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 38, height: 38).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        Stepper("Источник \(source + 1)", value: Binding(
                            get: { (settings?.manualSlots ?? plan?.sourceIndices)?[safe: slot] ?? source },
                            set: { value in editSlots { $0[slot] = value } }
                        ), in: 0...max(0, (importer?.frames.count ?? 1) - 1))
                        Button { editSlots { values in
                            let source = values[slot]
                            values.insert(source, at: slot)
                        } }
                            label: { Image(systemName: "plus.square.on.square") }
                        Button { editSlots { if $0.count > 1 { $0.remove(at: slot) } } }
                            label: { Image(systemName: "minus.circle") }
                        Button { editSlots { if slot > 0 { $0.swapAt(slot, slot - 1) } } }
                            label: { Image(systemName: "arrow.up") }
                    }.font(.caption)
                }
            }
            Button("Вернуть автоматическую ленту") { change { $0.manualSlots = nil } }
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Пиксели исходника (все размеры)") { useNativePixels() }
                .buttonStyle(.bordered)
            Text("Для пиксель-арта: родной размер спрайта, стиль «пиксель-арт»; виджет увеличит в целое число раз.")
                .font(.caption2).foregroundStyle(.secondary)
            if let nativeInfo { Text(nativeInfo).font(.caption.monospaced()).foregroundStyle(.green) }
            Text("Размер \(selectedSize.rawValue.uppercased()) — безопасная зона показана скруглением превью")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Кадрирование", selection: Binding(
                get: { settings?.geometry[selectedSize]?.layout ?? .fit },
                set: { value in geometry { $0.layout = value } }
            )) {
                Text("Вписать").tag(FrameProcessor.Layout.fit)
                Text("Заполнить").tag(FrameProcessor.Layout.crop)
            }.pickerStyle(.segmented)
            Stepper("Ширина: \(settings?.geometry[selectedSize]?.width ?? 0) px",
                    value: Binding(get: { settings?.geometry[selectedSize]?.width ?? 240 },
                                   set: { value in geometry { $0.width = value } }),
                    in: 32...600, step: 10)
            Stepper("Высота: \(settings?.geometry[selectedSize]?.height ?? 0) px",
                    value: Binding(get: { settings?.geometry[selectedSize]?.height ?? 240 },
                                   set: { value in geometry { $0.height = value } }),
                    in: 32...600, step: 10)
            slider("Сдвиг X", value: settings?.geometry[selectedSize]?.offsetX ?? 0,
                   range: -1...1) { value in geometry { $0.offsetX = value } }
            slider("Сдвиг Y", value: settings?.geometry[selectedSize]?.offsetY ?? 0,
                   range: -1...1) { value in geometry { $0.offsetY = value } }
            slider("Масштаб", value: settings?.geometry[selectedSize]?.zoom ?? 1,
                   range: 0.25...3) { value in geometry { $0.zoom = value } }
            Button("Синхронизировать размеры") {
                guard let current = settings?.geometry[selectedSize] else { return }
                change { value in for size in WidgetSize.allCases {
                    var item = value.geometry[size] ?? .initial(size)
                    item.layout = current.layout; item.offsetX = current.offsetX
                    item.offsetY = current.offsetY; item.zoom = current.zoom
                    value.geometry[size] = item
                } }
            }
        }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Без цветного фона — системное стекло iOS, как у виджета Мононо.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Цветной фон", isOn: Binding(get: { settings?.background != nil },
                set: { enabled in change { $0.background = enabled ? CanvasColor(red: 255, green: 255, blue: 255) : nil } }))
            if let color = settings?.background {
                ColorPicker("Цвет", selection: Binding(
                    get: { Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255) },
                    set: { newColor in
                        var red: CGFloat = 1
                        var green: CGFloat = 1
                        var blue: CGFloat = 1
                        var alpha: CGFloat = 1
                        UIColor(newColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        change { $0.background = CanvasColor(
                            red: UInt8(clamping: Int((red * 255).rounded())),
                            green: UInt8(clamping: Int((green * 255).rounded())),
                            blue: UInt8(clamping: Int((blue * 255).rounded()))) }
                    }))
            }
            Stepper("Порог альфы: \(settings?.alphaThreshold ?? 8)",
                    value: Binding(get: { Int(settings?.alphaThreshold ?? 8) },
                                   set: { value in change { $0.alphaThreshold = UInt8(value) } }),
                    in: 0...128)
        }
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Стиль", selection: Binding(get: { settings?.style ?? .automatic },
                set: { value in change { $0.style = value } })) {
                Text("Авто").tag(FrameProcessor.Style.automatic)
                Text("Фото").tag(FrameProcessor.Style.photo)
                Text("Пиксель-арт").tag(FrameProcessor.Style.pixelArt)
            }.pickerStyle(.segmented)
            Toggle("Ограничить палитру", isOn: Binding(get: { settings?.paletteColors != nil },
                set: { enabled in change { $0.paletteColors = enabled ? 32 : nil } }))
            if settings?.paletteColors != nil {
                Stepper("Цветов: \(settings?.paletteColors ?? 32)",
                    value: Binding(get: { settings?.paletteColors ?? 32 },
                                   set: { value in change { $0.paletteColors = value } }),
                    in: 16...64, step: 4)
            }
        }
    }

    private var rotateControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Поворот", selection: Binding(get: { settings?.rotation ?? 0 },
                set: { value in change { $0.rotation = value } })) {
                ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Отразить по X", isOn: Binding(get: { settings?.flipX ?? false },
                set: { value in change { $0.flipX = value } }))
            Toggle("Отразить по Y", isOn: Binding(get: { settings?.flipY ?? false },
                set: { value in change { $0.flipY = value } }))
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Яркость", value: settings?.brightness ?? 0, range: -1...1) {
                value in change { $0.brightness = value }
            }
            slider("Контраст", value: settings?.contrast ?? 1, range: 0...3) {
                value in change { $0.contrast = value }
            }
        }
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>,
                        update: @escaping (Double) -> Void) -> some View {
        HStack {
            Text("\(label) \(String(format: "%.2f", value))").font(.caption).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { value }, set: update), in: range)
        }
    }

    /// Родной размер пиксель-арта: холст / k, где k — размер одноцветных блоков первого кадра.
    private func useNativePixels() {
        guard let importer else { return }
        let side = max(importer.canvasWidth, importer.canvasHeight)
        guard side > 0, let first = try? importer.thumbnail(at: 0, maxPixelSize: min(side, 2048)) else {
            error = AppError(code: "E_READ_FAILED", message: "Не прочитан первый кадр для определения пикселей.",
                             hint: "Попробуйте другой исходник.")
            return
        }
        let k = PixelArtScale.detect(first)
        let width = max(1, first.width / k), height = max(1, first.height / k)
        change { settings in
            settings.style = .pixelArt
            for size in WidgetSize.allCases {
                var g = settings.geometry[size] ?? OutputGeometry.initial(size)
                g.width = width; g.height = height; g.layout = .fit
                g.offsetX = 0; g.offsetY = 0; g.zoom = 1
                settings.geometry[size] = g
            }
        }
        nativeInfo = "Блок \(k)×\(k) → \(width)×\(height) px"
    }

    private func geometry(_ edit: (inout OutputGeometry) -> Void) {
        change { settings in
            var value = settings.geometry[selectedSize] ?? .initial(selectedSize)
            edit(&value)
            settings.geometry[selectedSize] = value
        }
    }

    private func editSlots(_ edit: (inout [Int]) -> Void) {
        change { settings in
            var values = settings.manualSlots ?? plan?.sourceIndices ?? []
            edit(&values)
            settings.manualSlots = values
        }
    }

    private func select(_ item: AnimationPlanner.Plan) {
        change { $0.selectedPlan = PlanChoice(item) }
    }

    private func change(_ edit: (inout EditorSettings) -> Void) {
        guard var value = settings else { return }
        let previous = value
        edit(&value)
        if value.fragmentStart != previous.fragmentStart || value.fragmentEnd != previous.fragmentEnd ||
            value.loop != previous.loop || value.speed != previous.speed ||
            value.manualSlots != previous.manualSlots {
            value.selectedPlan = nil
        }
        if let importer {
            plans = (try? value.availablePlans(importer: importer)) ?? []
            if !plans.contains(where: { value.selectedPlan?.matches($0) ?? false }) {
                let durations = value.selectedFrameIndices(in: importer).map { importer.frames[$0].duration }
                value.selectedPlan = (AnimationPlanner.defaultPlan(from: plans,
                    durations: durations, speed: value.speed, mode: value.loop) ?? plans.first)
                    .map(PlanChoice.init)
            }
            error = plans.isEmpty ? AppError(code: "E_PLAN_INVALID", message: "Для этой ленты нет допустимых fps и цикла.",
                                             hint: "Уменьшите число слотов или верните автоматическую ленту.") : nil
        }
        settings = value
        do { try ProjectDocuments().save(value) }
        catch { self.error = AppError.convert(error) }
        schedulePreview()
    }

    private func stepFragment(_ direction: Int) {
        guard let settings, let importer else { return }
        let starts: [Double] = importer.frames.map { $0.startTime }
        let current: Double = settings.fragmentStart
        // разбито на шаги: одним выражением компилятор не успевал вывести типы
        let next: Double
        if direction < 0 {
            next = starts.last(where: { $0 < current - 0.001 }) ?? 0
        } else {
            next = starts.first(where: { $0 > current + 0.001 }) ?? current
        }
        change { $0.fragmentStart = max(0, min(next, $0.fragmentEnd - 0.02)); $0.manualSlots = nil }
    }

    private func load() async {
        do {
            let (value, imported, first) = try await Task.detached(priority: .utility) { () -> (EditorSettings, GIFImporter, UIImage) in
                let documents = try ProjectDocuments()
                let value = try documents.load(id)
                let imported = try GIFImporter(url: documents.sourceURL(value))
                return (value, imported, UIImage(cgImage: try imported.thumbnail(at: 0, maxPixelSize: 600)))
            }.value
            settings = value; importer = imported; sourceImage = first
            plans = (try? value.availablePlans(importer: imported)) ?? []
            if plan == nil { error = AppError(code: "E_PLAN_INVALID", message: "План проекта недопустим.",
                                                hint: "Выберите план во вкладке «План».") }
            schedulePreview()
        } catch { self.error = AppError.convert(error) }
    }

    private func schedulePreview() {
        previewWorker?.cancel()
        previewFrames = []
        guard let settings, let plan else { return }
        let size = selectedSize
        previewWorker = Task.detached(priority: .utility) {
            do {
                let documents = try ProjectDocuments()
                let importer = try GIFImporter(url: documents.sourceURL(settings))
                var cache: [Int: UIImage] = [:]
                var frames: [UIImage] = []
                for index in plan.sourceIndices {
                    try Task.checkCancellation()
                    if cache[index] == nil {
                        let data = try RenderPipeline.previewFrame(importer: importer,
                            settings: settings, size: size, sourceIndex: index)
                        cache[index] = UIImage(data: data)
                    }
                    if let image = cache[index] { frames.append(image) }
                }
                try Task.checkCancellation()
                await MainActor.run { previewFrames = frames; playbackStart = .now }
            } catch is CancellationError {
            } catch {
                let value = AppError.convert(error)
                await MainActor.run { self.error = value }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
