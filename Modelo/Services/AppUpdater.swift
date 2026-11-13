import Sparkle
import SwiftUI

enum AppUpdater {
    static func shouldStart(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }
}

final class UpdaterFeedOverride: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Local test feeds must never redirect a Release build.
        #if DEBUG
        return defaults.string(forKey: "ModeloDebugFeedURL")
        #else
        return nil
        #endif
    }
}

struct CheckForUpdatesCommand: View {
    let updater: SPUUpdater
    @State private var canCheckForUpdates = false

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!canCheckForUpdates)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) {
                canCheckForUpdates = $0
            }
    }
}
