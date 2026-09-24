import SwiftUI
import WidgetKit

/// Same centered 128 pt layout as LengthExperimentView. On the selected
/// simulator the animation crop is x=142, y=240, w=384, h=384 pixels.
/// simctl recordVideo is variable-rate, at most about 60 samples/s; 30 fps
/// is near its measurement limit, and a missed frame may be unobservable.
struct RateExperimentView: View {
    let entry: ProbeEntry
    let mode: String

    private var fps: Int {
        switch mode {
        case "fps8", "fontA8svg": return 8
        case "fps12": return 12
        case "fps16": return 16
        case "fps24", "fps24o0", "fontA24": return 24
        default: return 30
        }
    }

    private var isFont: Bool { mode.hasPrefix("fontA") }
    private var fontPrefix: String {
        switch mode {
        case "fontA24": return "WAFrame24_"
        case "fontA30": return "WAFrame30_"
        default: return "WAFrame8SVG_"
        }
    }

    var body: some View {
        let ref = entry.date - 60
        let frames = isFont ? [] : ImageFramesAnimation.experimentFrames(fps, prefix: "fps\(fps)")
        VStack(spacing: 2) {
            if isFont {
                BryceFontFramesAnimation(ref: ref, size: 128, fps: fps,
                                         prefix: fontPrefix)
            } else {
                ImageFramesAnimation(ref: ref, size: 128, frames: frames,
                                     overlap: mode.hasSuffix("o0") ? 0 : 0.01,
                                     cycle: 2, fps: fps)
            }
            HStack(spacing: 6) {
                Text(ref, style: .timer)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .leading)
                Text(mode)
                    .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.white, for: .widget)
    }
}

// The first widget is selected by the CI matrix. The IPA is built in fps8
// mode, giving the phone ten distinct widgets: this one plus nine below.
struct RateSelectorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RateSelector", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: Variant.mode)
        }
        .configurationDisplayName("Probe 0")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct Rate12Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate12", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps12")
        }
        .configurationDisplayName("FPS 12 images")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct Rate16Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate16", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps16")
        }
        .configurationDisplayName("FPS 16 images")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct Rate24Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate24", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps24")
        }
        .configurationDisplayName("FPS 24 images")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct Rate30Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate30", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps30")
        }
        .configurationDisplayName("FPS 30 images")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct Rate24ZeroWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate24Zero", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps24o0")
        }
        .configurationDisplayName("FPS 24 overlap 0")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct Rate30ZeroWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Rate30Zero", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fps30o0")
        }
        .configurationDisplayName("FPS 30 overlap 0")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct RateFont24Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RateFont24", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fontA24")
        }
        .configurationDisplayName("Font A 24 sbix")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct RateFont30Widget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RateFont30", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fontA30")
        }
        .configurationDisplayName("Font A 30 sbix")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
struct RateFont8SVGWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RateFont8SVG", provider: ProbeProvider()) {
            RateExperimentView(entry: $0, mode: "fontA8svg")
        }
        .configurationDisplayName("Font A 8 SVG")
        .supportedFamilies([.systemSmall]).contentMarginsDisabled()
    }
}
