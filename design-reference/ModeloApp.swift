import SwiftUI

@main
struct ModeloApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)          // traffic lights stay native (handoff §4)
        .windowResizability(.contentMinSize)

        // Menu-bar mini chat (handoff §7). `.window` gives a real popover with
        // the system-provided notch + vibrancy.
        MenuBarExtra {
            MenuBarChatView()
                .environment(store)
        } label: {
            // Replace with a template (monochrome) asset: Image("ModeloMenuBarIcon").
            Image(systemName: "circle.hexagongrid")
        }
        .menuBarExtraStyle(.window)
    }
}
