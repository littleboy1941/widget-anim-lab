// Опыт 2026-09-25 (гибрид): анимация на приватном _clockHandRotationEffect (ClockHandRotationKit
// 1.1.0, MIT) — как у конкурентов (TapeKit) и личного виджета. Эффект работает только в сборках
// SDK ≤ 26.0 (Xcode 26.0.1): workflow private-probe.yml. Кадры — дуги огромного радиуса,
// которые система вращает сама; приём Widgetnimation (MIT).
// Две клетки: 16 fps × 16 кадров и 30 fps × 30 кадров (idx-метки make_frames.py), петля 1 с.
// Вопросы: частота и порядок кадров, живёт ли анимация во время свайпа (analyze_swipe.py).
#if PRIVATE_EXPERIMENTS
import ClockHandRotationKit
import SwiftUI
import WidgetKit

private struct ArcSliceMask: Shape {
    let startAngle: Double
    let endAngle: Double
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
        return path
    }
}

struct RotationFramesAnimation: View {
    let frames: [UIImage]
    let fps: Int
    let size: CGFloat

    var body: some View {
        let radius = size * 50
        let angle = 360.0 / Double(max(1, frames.count))
        let period = Double(frames.count) / Double(fps)
        ZStack {
            ForEach(frames.indices, id: \.self) { index in
                Image(uiImage: frames[index])
                    .resizable()
                    .frame(width: size, height: size)
                    .mask(
                        ArcSliceMask(startAngle: -angle * Double(index + 1),
                                     endAngle: -angle * Double(index), radius: radius)
                            .stroke(Color.white,
                                    style: StrokeStyle(lineWidth: size * 1.5, lineCap: .butt),
                                    antialiased: false)
                            .frame(width: size, height: size)
                            .clockHandRotationEffect(period: .custom(period))
                            .offset(y: radius)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct PrivateExperimentView: View {
    let entry: SwipeEntry

    var body: some View {
        HStack(spacing: 12) {
            RotationFramesAnimation(frames: ImageFramesAnimation.experimentFrames(16, prefix: "fps16"),
                                    fps: 16, size: 128)
            RotationFramesAnimation(frames: ImageFramesAnimation.experimentFrames(30, prefix: "fps30"),
                                    fps: 30, size: 128)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

struct PrivateProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PrivateProbe", provider: SwipeProvider()) {
            PrivateExperimentView(entry: $0)
        }
        .configurationDisplayName("Probe 0")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}
#endif
