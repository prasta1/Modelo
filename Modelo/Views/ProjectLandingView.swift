import SwiftUI

/// Shown in the detail area when a project directory is selected in the sidebar.
/// Displays top-level directory contents and a button to start a new chat with
/// the directory path injected as system prompt context.
struct ProjectLandingView: View {
    let project: Project
    var onNewChat: (Project) -> Void = { _ in }

    @State private var entries: [DirectoryEntry] = []
    @State private var loadError: String?
    @State private var memories: [Memory] = []
    @State private var showMemoryManager = false
    @AppStorage(MemoryStore.enabledKey) private var memoryEnabled = false

    var body: some View {
        // The landing content sits in a ScrollView so its natural height stops
        // acting as a *minimum* the window has to satisfy — without it, a project
        // with a long file listing grew the window past the bottom of the screen.
        // `minHeight: proxy.size.height` keeps the content vertically centered
        // while it still fits, matching how the empty states elsewhere read.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                landing
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Theme.Palette.panel)
        .task { loadEntries(); loadMemories() }
        .sheet(isPresented: $showMemoryManager, onDismiss: loadMemories) {
            VStack(spacing: 0) {
                HStack {
                    Text("Memories — \(project.name)")
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                    Spacer()
                    Button("Done") { showMemoryManager = false }
                        .font(Theme.metric(11))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().overlay(Theme.line)
                MemoryManagerView(scope: .project(path: project.path))
            }
            .frame(width: 700, height: 480)
            .background(Theme.windowBG)
        }
    }

    /// Folder header, directory listing, and memory card, centered as a group.
    private var landing: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                // Icon + header
                VStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.amber)
                    Text(project.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                    Text(project.path)
                        .font(.mono(11))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                // Directory listing or error
                if let err = loadError {
                    Text(err)
                        .font(.mono(11))
                        .foregroundStyle(Theme.Palette.alert)
                } else if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow("Contents", color: Theme.textDim)
                            .padding(.bottom, 10)
                        ForEach(entries.prefix(14), id: \.name) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(entry.isDirectory
                                                     ? Theme.amber.opacity(0.6)
                                                     : Theme.textDim)
                                    .frame(width: 14)
                                Text(entry.name)
                                    .font(.mono(12))
                                    .foregroundStyle(Theme.textSoft)
                            }
                            .padding(.vertical, 4)
                        }
                        if entries.count > 14 {
                            Text("… and \(entries.count - 14) more")
                                .font(.mono(11))
                                .foregroundStyle(Theme.textFaint)
                                .padding(.top, 4)
                        }
                    }
                    .padding(16)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .frame(maxWidth: 340)
                }

                // Project memory summary. Hidden when the feature is off and this
                // project has nothing stored (nothing to review or clean up).
                if memoryEnabled || !memories.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Eyebrow("Memory", color: Theme.textDim)
                            Spacer(minLength: 8)
                            Button("Manage…") { showMemoryManager = true }
                                .buttonStyle(.plain)
                                .font(Theme.metric(11))
                                .foregroundStyle(Theme.amber)
                        }
                        .padding(.bottom, 10)
                        if memories.isEmpty {
                            Text(memoryEnabled
                                 ? "Nothing saved yet — the model saves project facts here with save_memory."
                                 : "Memory is off (Settings ▸ Memory); saved memories are kept but not shown to models.")
                                .font(Theme.metric(10))
                                .foregroundStyle(Theme.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(memories.prefix(4)) { memory in
                                HStack(spacing: 8) {
                                    Image(systemName: "brain")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textDim)
                                        .frame(width: 14)
                                    Text(memory.name)
                                        .font(.mono(12))
                                        .foregroundStyle(Theme.textSoft)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 4)
                            }
                            if memories.count > 4 {
                                Text("… and \(memories.count - 4) more")
                                    .font(.mono(11))
                                    .foregroundStyle(Theme.textFaint)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(16)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .frame(maxWidth: 340)
                }

                // New Chat button
                Button { onNewChat(project) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                        Text("New Chat in \(project.name)")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.amberFillLo,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .stroke(Theme.amberBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(48)
            Spacer()
        }
    }

    private func loadMemories() {
        memories = MemoryStore.list(.project(path: project.path))
    }

    private func loadEntries() {
        let url = project.url
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            entries = urls
                .sorted {
                    let aDir = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let bDir = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if aDir != bDir { return aDir }
                    return $0.lastPathComponent
                        .localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                .map {
                    let isDir = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return DirectoryEntry(name: $0.lastPathComponent, isDirectory: isDir)
                }
        } catch {
            Log.app.error("Project directory read failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Cannot read directory"
        }
    }
}

private struct DirectoryEntry {
    let name: String
    let isDirectory: Bool
}
