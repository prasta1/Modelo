import SwiftData
import SwiftUI

/// The app's root: a split view whose sidebar will hold conversations (slice 2), with
/// Settings behind a toolbar gear. Also owns reachability polling for every server.
struct RootView: View {
    @Environment(ReachabilityMonitor.self) private var reachability
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
                .navigationTitle("Modelo")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        } detail: {
            Color.clear
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                EndpointsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        // Restart probing whenever a server is added, removed, paused, or re-pointed,
        // so the probe set never goes stale (paused servers stop being polled).
        .task(id: probeKey) {
            reachability.start(servers: servers.filter { !$0.isPaused })
        }
    }

    private var probeKey: [String] {
        servers.map { "\($0.id)|\($0.isPaused)|\($0.host)|\($0.port)|\($0.kindRaw)" }
    }
}
