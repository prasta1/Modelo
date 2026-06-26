import SwiftUI

/// Shown in the detail area when a project directory is selected in the sidebar.
/// Displays top-level directory contents and a button to start a new chat with
/// the directory path injected as system prompt context.
struct ProjectLandingView: View {
    let project: Project
    var onNewChat: (Project) -> Void = { _ in }

    @State private var entries: [DirectoryEntry] = []
    @State private var loadError: String?

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.panel)
        .task { loadEntries() }
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
            loadError = "Cannot read directory"
        }
    }
}

private struct DirectoryEntry {
    let name: String
    let isDirectory: Bool
}
