import SwiftUI
import WidgetKit

/// Each image is a separate layer, including the repeated pictures in deep480s.
struct DeepExperimentView: View {
    let entry: ProbeEntry
    let mode: String

    private var count: Int { mode == "deep480s" ? 480 : 240 }
    private var side: CGFloat { mode == "deep240" ? 128 : 64 }
    private var cycle: Int { mode == "deep480s" ? 60 : 30 }

    var body: some View {
        let ref = entry.date - 60
        let frames = ImageFramesAnimation.experimentFrames(count, prefix: mode)
        VStack(spacing: 2) {
            SplitImageFramesAnimation(ref: ref, size: side, frames: frames,
                                      fps: 8, cycle: cycle, stackSize: 40)
            HStack(spacing: 6) {
                Text(ref, style: .timer)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
                Text("\(frames.count)f")
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

struct DeepSelectorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeepSelector", provider: ProbeProvider()) {
            DeepExperimentView(entry: $0, mode: Variant.mode)
        }
        .configurationDisplayName("Probe 0")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}

struct Deep240SmallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Deep240Small", provider: ProbeProvider()) {
            DeepExperimentView(entry: $0, mode: "deep240s")
        }
        .configurationDisplayName("Deep 240 small")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}

struct Deep480SmallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Deep480Small", provider: ProbeProvider()) {
            DeepExperimentView(entry: $0, mode: "deep480s")
        }
        .configurationDisplayName("Deep 480 small")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}

struct Deep240LargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Deep240Large", provider: ProbeProvider()) {
            DeepExperimentView(entry: $0, mode: "deep240")
        }
        .configurationDisplayName("Deep 240 large")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
