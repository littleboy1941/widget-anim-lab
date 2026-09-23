// Приложение для проверки в симуляторе: показывает вариант, заданный аргументом запуска
// («fonts» — цветные шрифты, иначе картинки под масками), и пишет в stdout,
// какие шрифты зарегистрировались.
import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeScreen() }
    }
}

struct ProbeScreen: View {
    private let useFonts = ProcessInfo.processInfo.arguments.contains("fonts")
    private let ref = Date() - 60
    private let frames = ImageFramesAnimation.bundledFrames()

    var body: some View {
        ZStack {
            Color.white
            if useFonts {
                FontFramesAnimation(ref: ref, size: 300)
            } else {
                ImageFramesAnimation(ref: ref, size: 300, frames: frames)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let missing = ProbeConfig.fontNames.filter { UIFont(name: $0, size: 10) == nil }
            print("variant=\(useFonts ? "fonts" : "images") frames=\(frames.count) missingFonts=\(missing)")
            fflush(stdout)
        }
    }
}
