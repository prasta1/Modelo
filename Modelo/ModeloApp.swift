import SwiftUI
import SwiftData

@main
struct ModeloApp: App {
    let container: ModelContainer
    // Set when the store couldn't be opened and was moved aside (see makeContainer);
    // drives a one-time launch alert telling the user where their data went.
    let storeRecoveryBackupURL: URL?
    @State private var showStoreRecoveryAlert = false
    @State private var registry = ServerRegistry()
    @State private var reachabilityMonitor: ReachabilityMonitor
    @State private var serverMonitor = ServerMonitor()
    @State private var gpuMonitor = GPUMonitor()
    @State private var prometheusMonitor = PrometheusMonitor()
    @State private var mcpManager = MCPServerManager()
    @State private var favoritesStore = FavoritesStore()
    @State private var rotationStore = RotationStore()
    @State private var projectStore = ProjectStore()
    // Owned here, not in ContentView, so the notification-center delegate it holds
    // outlives any window: the app keeps running menu-bar-only after the main window
    // closes, and a notification tap must still route to the chat. Set up in init().
    @State private var notifier = ChatNotifier()
    // Drives chat text size; matches the @AppStorage default used in the views.
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    // Selected color theme (§3.5). Reading this in a scene body makes that scene
    // rebuild when the theme changes; `palette` applies it to `Theme.active`.
    @AppStorage("themeID") private var themeID = ThemeID.dark.rawValue
    // Show the menu-bar icon (General settings toggle).
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    // Routes ⌘, / sidebar / "Manage models" to the in-app settings pane. Owned
    // here so the ⌘, command works even when no window is focused.
    @State private var settingsNavigator = SettingsNavigator()

    /// `WindowGroup` id for the main window, so ⌘, can reopen it by id in
    /// menu-bar-only mode (and find it via its NSWindow identifier prefix).
    static let mainWindowID = "main"

    /// Applies the stored theme to `Theme.active` and returns it. Called in each scene
    /// body (before its `.id(themeID)` subtree builds) so colors repaint on change.
    private var palette: ThemePalette { Theme.applyStored(themeID) }

    init() {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self, Persona.self, Folder.self, Preset.self])
        // Pin to a dedicated subfolder so SwiftData doesn't land in the shared
        // ~/Library/Application Support/default.store.
        let storeFolder = URL.applicationSupportDirectory.appending(path: "Modelo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)

        // One-time migration: move the old ModeloDos store to the new Modelo location
        // (and its SQLite -wal/-shm sidecars) so existing data carries over.
        let newStore = storeFolder.appending(path: "Modelo.store")
        let oldFolder = URL.applicationSupportDirectory.appending(path: "ModeloDos", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: oldFolder.appending(path: "ModeloDos.store").path),
           !FileManager.default.fileExists(atPath: newStore.path) {
            for suffix in ["", "-wal", "-shm"] {
                let src = oldFolder.appending(path: "ModeloDos.store\(suffix)")
                let dst = storeFolder.appending(path: "Modelo.store\(suffix)")
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.moveItem(at: src, to: dst)
                }
            }
        }

        let (container, storeBackup) = Self.makeContainer(schema: schema, storeFolder: storeFolder, storeURL: newStore)
        self.container = container
        storeRecoveryBackupURL = storeBackup
        _showStoreRecoveryAlert = State(initialValue: storeBackup != nil)

        // Subscribe to MetricKit so crashes/hangs from previous sessions get logged
        // and archived on this launch (they'd otherwise vanish without a trace).
        CrashReporter.shared.start()

        let ctx = ModelContext(container)
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: ctx)
        Persona.seedDefaults(in: ctx)
        // Backfill the branching tree (§1.2) for pre-existing flat conversations.
        BranchingMigration.runIfNeeded(in: ctx)
        // Prune old usage records per the retention setting (§3.4; 0 = keep forever).
        UsageRetention.prune(in: ctx, retentionDays: UserDefaults.standard.integer(forKey: UsageRetention.key))
        // Apply the saved theme before the first frame (§3.5).
        Theme.applyStored(UserDefaults.standard.string(forKey: "themeID") ?? ThemeID.dark.rawValue)
        _registry = State(initialValue: registry)

        // Register the notification-center delegate now, before launch finishes, so a
        // tap that cold-launches the app reaches the delegate. The same instance is
        // injected into the WindowGroup below.
        let notifier = ChatNotifier()
        notifier.registerDelegate()
        _notifier = State(initialValue: notifier)

        // Reachability probe: single-shot short-timeout check (NOT fetchModels —
        // see Task 6 note on the double-fallback timeout). The probe receives a
        // Sendable `Endpoint` snapshot (built on the main actor in `checkOnce`),
        // so nothing touches a SwiftData @Model off-main.
        let client = LMStudioClient.shared
        _reachabilityMonitor = State(initialValue: ReachabilityMonitor(registry: registry) { endpoint in
            await client.probeReachable(endpoint: endpoint)
        })
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environment(registry)
                .environment(serverMonitor)
                .environment(gpuMonitor)
                .environment(prometheusMonitor)
                .environment(mcpManager)
                .environment(favoritesStore)
                .environment(rotationStore)
                .environment(projectStore)
                .environment(reachabilityMonitor)
                .environment(notifier)
                .environment(settingsNavigator)
                .task { await startMonitoring() }
                .task { mcpManager.startAll() }
                .preferredColorScheme(palette.scheme)
                .id(themeID)   // rebuild the tree so static Theme.* reads repaint (§3.5)
                .onAppear {
                    DispatchQueue.main.async {
                        if let window = NSApp.keyWindow {
                            window.center()
                            window.titlebarAppearsTransparent = true
                            window.backgroundColor = NSColor(Theme.windowBG)
                            window.appearance = NSAppearance(named: .darkAqua)
                        }
                    }
                }
                .alert("Chat database was reset", isPresented: $showStoreRecoveryAlert) {
                    Button("OK") { }
                } message: {
                    Text("The previous database couldn't be opened, so a fresh one was created. Your old data was preserved at:\n\(storeRecoveryBackupURL?.path ?? "")")
                }
        }
        .defaultSize(width: 1200, height: 740)
        .defaultPosition(.center)
        .modelContainer(container)
        .commands {
            // App menu ▸ Settings… (⌘,) — routes in-app; there is no Settings scene.
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(navigator: settingsNavigator)
            }
            // File ▸ New Chat — replaces the default "New Window" item.
            CommandGroup(replacing: .newItem) {
                NewChatCommand()
            }
            // Go ▸ navigate to the app's main sections.
            CommandMenu("Go") {
                GoCommands()
            }
            // View ▸ console toggle + text size.
            CommandGroup(after: .toolbar) {
                ConsoleMenuButton()
                Divider()
                // Content text size, clamped to 12...26 pt. Applies to all reading
                // surfaces (chat, composer, artifact panel, menu-bar quick chat);
                // app chrome keeps fixed sizes.
                Button("Increase Text Size") {
                    messageFontSize = min(26, messageFontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Text Size") {
                    messageFontSize = max(12, messageFontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") { messageFontSize = 15 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarChatView()
                .environment(registry)
                .environment(serverMonitor)
                .environment(mcpManager)
                .environment(favoritesStore)
                .environment(rotationStore)
                .modelContainer(container)
                .preferredColorScheme(palette.scheme)
                .id(themeID)
        } label: {
            Image(nsImage: Self.bottleMenuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// Opens the SwiftData container, recovering from an unopenable store instead of
    /// crashing. (This was a `try!`: any open failure — e.g. a failed schema migration
    /// after a model change — killed the app at launch with no message at all.)
    ///
    /// Recovery moves the broken store files aside (never deletes them) and retries
    /// with a fresh store. If even the fresh store fails, the app still terminates,
    /// but the cause is now in the unified log first.
    /// - Returns: The container, plus the backup folder if recovery happened (so the
    ///   UI can tell the user where their previous data went).
    /// - Note: Internal (not private) so `StoreRecoveryTests` can exercise the
    ///   recovery path against a temp folder.
    static func makeContainer(schema: Schema, storeFolder: URL, storeURL: URL) -> (ModelContainer, backupURL: URL?) {
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return (try ModelContainer(for: schema, configurations: [config]), nil)
        } catch {
            Log.data.fault("Failed to open store at \(storeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Move the whole store set aside with a timestamp so nothing is lost.
        // (Colons render as "/" in Finder; the UUID suffix keeps rapid re-launches
        // from colliding on a same-second folder name.)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupFolder = storeFolder.appending(path: "Modelo.store.broken-\(stamp)-\(UUID().uuidString.prefix(8))",
                                                 directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = storeFolder.appending(path: "Modelo.store\(suffix)")
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.moveItem(at: src, to: backupFolder.appending(path: "Modelo.store\(suffix)"))
                }
            }
        } catch {
            // If the broken store can't be moved aside, a retry at the same URL just
            // hits the same corrupt file — there is nothing safe to run with, and
            // claiming recovery (or showing the backup alert) would be a lie.
            Log.data.fault("Could not move the broken store aside: \(error.localizedDescription, privacy: .public)")
            fatalError("Cannot back up the unopenable SwiftData store: \(error)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            Log.data.error("Recovered with a fresh store; previous data moved to \(backupFolder.path, privacy: .public)")
            return (container, backupFolder)
        } catch {
            Log.data.fault("Fresh store also failed to open: \(error.localizedDescription, privacy: .public)")
            fatalError("Cannot open or recreate the SwiftData store: \(error)")
        }
    }

    @MainActor private func startMonitoring() async {
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Server>())) ?? []
        let servers = all.filter { !$0.isPaused }
        reachabilityMonitor.start(servers: servers)
        serverMonitor.start(servers: servers, registry: registry)
        gpuMonitor.start(servers: servers)
        prometheusMonitor.start(servers: servers)
    }

    // Template image lets macOS tint it automatically for light/dark menu bar.
    static let bottleMenuBarIcon: NSImage = {
        let size = NSSize(width: 11, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let cgRect = CGRect(origin: .zero, size: rect.size)
            ctx.addPath(BottleShape().path(in: cgRect).cgPath)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Single-stroke outline silhouette of a Negra Modelo-style beer bottle.
private struct BottleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Start at top-left of the mouth/lip
        p.move(to: CGPoint(x: w * 0.36, y: 0))
        // Lip top edge
        p.addLine(to: CGPoint(x: w * 0.64, y: 0))
        // Lip right side down
        p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.05))
        // Step out to neck
        p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.05))
        // Neck right side, slight taper outward toward shoulder
        p.addLine(to: CGPoint(x: w * 0.73, y: h * 0.30))
        // Right shoulder: bezier curves outward to the body
        p.addCurve(
            to: CGPoint(x: w * 0.93, y: h * 0.48),
            control1: CGPoint(x: w * 0.74, y: h * 0.35),
            control2: CGPoint(x: w * 0.93, y: h * 0.40)
        )
        // Body right side
        p.addLine(to: CGPoint(x: w * 0.93, y: h * 0.88))
        // Rounded bottom (punt)
        p.addCurve(
            to: CGPoint(x: w * 0.07, y: h * 0.88),
            control1: CGPoint(x: w * 0.93, y: h * 0.97),
            control2: CGPoint(x: w * 0.07, y: h * 0.97)
        )
        // Body left side
        p.addLine(to: CGPoint(x: w * 0.07, y: h * 0.48))
        // Left shoulder: bezier curves inward up to neck
        p.addCurve(
            to: CGPoint(x: w * 0.27, y: h * 0.30),
            control1: CGPoint(x: w * 0.07, y: h * 0.40),
            control2: CGPoint(x: w * 0.26, y: h * 0.35)
        )
        // Neck left side
        p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.05))
        // Step in to lip
        p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.05))
        // Lip left side back to start
        p.addLine(to: CGPoint(x: w * 0.36, y: 0))
        p.closeSubpath()

        return p
    }
}

/// View ▸ Show/Hide Console — toggles the same `@AppStorage` flag the detail
/// inspector reads, so the menu item stays in sync with the toolbar button.
private struct ConsoleMenuButton: View {
    @AppStorage("consoleInspectorOpen") private var open = false

    var body: some View {
        Button(open ? "Hide Console" : "Show Console") { open.toggle() }
            .keyboardShortcut("i", modifiers: .command)
    }
}
