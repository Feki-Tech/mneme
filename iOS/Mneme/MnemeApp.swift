import MnemeAppSupport
import MnemeCore
import MnemeSpeech
import SwiftUI

/// Mneme for iPhone and iPad: records, transcribes on the device, and keeps everything in a private archive.
///
/// Launch arguments used for screenshots and UI review: `-demo` opens a temporary archive filled with sample
/// entries (the real archive is not touched), and `-screen list|entry|note|recorder|review|settings|onboarding`
/// opens that screen.
@main
struct MnemeMobileApp: App {
    @StateObject private var model: AppModel
    private let launch: LaunchOptions

    init() {
        let launch = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        self.launch = launch
        if launch.demo, let demo = try? DemoArchive.create() {
            _model = StateObject(wrappedValue: AppModel(archiveRoot: demo.archiveRoot, modelsDirectory: demo.modelsDirectory))
        } else {
            _model = StateObject(wrappedValue: AppModel())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
                .environmentObject(model)
                .environmentObject(model.player)
                .environmentObject(model.recorder)
                .tint(Theme.accent)
        }
    }
}

struct LaunchOptions {
    var demo = false
    var screen: String?

    init(arguments: [String]) {
        demo = arguments.contains("-demo")
        if let index = arguments.firstIndex(of: "-screen"), arguments.indices.contains(index + 1) {
            screen = arguments[index + 1]
        }
    }
}

enum Theme {
    static let accent = Color("AccentColor")
    static let record = Color(red: 0.86, green: 0.22, blue: 0.24)
}
