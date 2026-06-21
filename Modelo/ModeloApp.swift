import SwiftUI
import SwiftData

@main
struct ModeloApp: App {
    let container: ModelContainer
    @State private var registry = ServerRegistry()
    @State private var reachabilityMonitor: ReachabilityMonitor
    @State private var serverMonitor = ServerMonitor()
    @State private var gpuMonitor = GPUMonitor()
    @State private var mcpManager = MCPServerManager()
    // Drives chat text size; matches the @AppStorage default used in the views.
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15

    init() {
        let schema = Schema([Server.self, Conversation.self, Message.self, UsageRecord.self, Persona.self, Folder.self])
        // Keep ModeloDos's database separate from the original Modelo app. Neither
        // app is sandboxed, so SwiftData's default store lands in a shared
        // ~/Library/Application Support/default.store — both apps would open the
        // same file. Pin this app to its own ModeloDos subfolder instead.
        let storeFolder = URL.applicationSupportDirectory.appending(path: "ModeloDos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: storeFolder, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: storeFolder.appending(path: "ModeloDos.store"))
        let container = try! ModelContainer(for: schema, configurations: [config])
        self.container = container

        let ctx = ModelContext(container)
        let registry = ServerRegistry()
        registry.seedIfNeeded(in: ctx)
        Persona.seedDefaults(in: ctx)
        // Backfill the branching tree (§1.2) for pre-existing flat conversations.
        BranchingMigration.runIfNeeded(in: ctx)
        _registry = State(initialValue: registry)

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
        WindowGroup {
            ContentView()
                .environment(registry)
                .environment(serverMonitor)
                .environment(gpuMonitor)
                .environment(mcpManager)
                .task { await startMonitoring() }
                .task { mcpManager.startAll() }
        }
        .defaultSize(width: 1100, height: 720)
        .modelContainer(container)
        .commands {
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
                Button("Increase Text Size") {
                    messageFontSize = min(FontSizeControl.range.upperBound, messageFontSize + 1)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Text Size") {
                    messageFontSize = max(FontSizeControl.range.lowerBound, messageFontSize - 1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") { messageFontSize = 15 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarChatView()
                .environment(registry)
                .environment(serverMonitor)
                .environment(mcpManager)
                .modelContainer(container)
        } label: {
            Image(nsImage: Self.bottleMenuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(container)
                .environment(mcpManager)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .navigationTitle("")
        }
        .windowResizability(.contentSize)
    }

    @MainActor private func startMonitoring() async {
        let servers = (try? ModelContext(container).fetch(FetchDescriptor<Server>())) ?? []
        reachabilityMonitor.start(servers: servers)
        serverMonitor.start(servers: servers, registry: registry)
        gpuMonitor.start(servers: servers)
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
