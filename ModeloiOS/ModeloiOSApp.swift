import SwiftData
import SwiftUI

/// Entry point for the iOS companion app.
@main
struct ModeloiOSApp: App {
    let container: ModelContainer
    let storeRecoveryBackupURL: URL?
    @State private var showStoreRecoveryAlert = false

    init() {
        // No seeding: the Mac's localhost server would point at the phone itself.
        let (container, storeBackup) = StoreBootstrap.makeContainer(
            schema: StoreBootstrap.schema,
            storeFolder: StoreBootstrap.storeFolder,
            storeURL: StoreBootstrap.storeURL)
        self.container = container
        storeRecoveryBackupURL = storeBackup
        _showStoreRecoveryAlert = State(initialValue: storeBackup != nil)
    }

    var body: some Scene {
        WindowGroup {
            Text("Modelo")
                .alert("Chat database was reset", isPresented: $showStoreRecoveryAlert) {
                    Button("OK") { }
                } message: {
                    Text("The previous database couldn't be opened, so a fresh one was created. Your old data was preserved at:\n\(storeRecoveryBackupURL?.path ?? "")")
                }
        }
        .modelContainer(container)
    }
}
