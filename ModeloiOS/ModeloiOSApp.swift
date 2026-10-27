import SwiftData
import SwiftUI

/// Entry point for the iOS companion app.
@main
struct ModeloiOSApp: App {
    let container: ModelContainer
    let storeRecoveryBackupURL: URL?
    @State private var showStoreRecoveryAlert = false
    @State private var registry: ServerRegistry
    @State private var reachabilityMonitor: ReachabilityMonitor

    init() {
        // No seeding: the Mac's localhost server would point at the phone itself.
        let (container, storeBackup) = StoreBootstrap.makeContainer(
            schema: StoreBootstrap.schema,
            storeFolder: StoreBootstrap.storeFolder,
            storeURL: StoreBootstrap.storeURL)
        self.container = container
        storeRecoveryBackupURL = storeBackup
        _showStoreRecoveryAlert = State(initialValue: storeBackup != nil)

        let registry = ServerRegistry()
        _registry = State(initialValue: registry)
        // Same production probe as the Mac: one short-timeout HTTP check per server.
        let client = LMStudioClient.shared
        _reachabilityMonitor = State(initialValue: ReachabilityMonitor(registry: registry) { endpoint in
            await client.probeReachable(endpoint: endpoint)
        })
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(registry)
                .environment(reachabilityMonitor)
                .alert("Chat database was reset", isPresented: $showStoreRecoveryAlert) {
                    Button("OK") { }
                } message: {
                    Text("The previous database couldn't be opened, so a fresh one was created. Your old data was preserved at:\n\(storeRecoveryBackupURL?.path ?? "")")
                }
        }
        .modelContainer(container)
    }
}
