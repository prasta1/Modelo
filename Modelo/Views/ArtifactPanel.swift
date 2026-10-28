import SwiftUI
import AppKit

/// The Claude-style artifact side panel (§2.4): renders the selected artifact group's
/// latest version with a Preview⇄Source toggle, version navigation, and copy/download.
struct ArtifactPanel: View {
    let groups: [ArtifactGroup]
    let selectedID: String
    let onSelect: (String) -> Void
    let onClose: () -> Void

    @State private var versionIndex: Int = 0
    @State private var showingSource = false
    @State private var copied = false

    // View ▸ text-size commands (⌘+/⌘−) drive this value; 15 pt is "Actual Size".
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15

    /// Zoom factor relative to the default text size, so artifact text tracks the
    /// View ▸ text-size commands while keeping its compact base sizes at ⌘0.
    private var textScale: CGFloat { messageFontSize / 15 }

    private var group: ArtifactGroup { groups.first { $0.id == selectedID } ?? groups[0] }
    private var current: Artifact { group.versions[min(versionIndex, group.versions.count - 1)] }
    private var hasToggle: Bool { group.kind.isRenderable || group.kind == .markdown }
    private var previewLabel: String { group.kind.isRenderable ? "Preview" : "Rendered" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Theme.line)
            footer
        }
        .background(Theme.windowBG)
        .onAppear { versionIndex = group.versions.count - 1 }
        // Follow the newest version when the model revises the artifact while it's open.
        .onChange(of: group.versions.count) { versionIndex = group.versions.count - 1 }
        // Reset to the latest version + preview when switching artifacts via the picker.
        .onChange(of: selectedID) { versionIndex = group.versions.count - 1; showingSource = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: group.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.amber)
            if groups.count > 1 { picker } else { titleBlock }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMute)
            }
            .buttonStyle(.plain)
            .help("Close artifact")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(group.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .lineLimit(1)
            Text(group.kind.label + (group.language.map { " · \($0)" } ?? ""))
                .font(.mono(10))
                .foregroundStyle(Theme.textDim)
        }
    }

    /// Dropdown to switch between the conversation's artifacts (§2.4).
    private var picker: some View {
        Menu {
            ForEach(groups) { g in
                Button { onSelect(g.id) } label: {
                    Label(g.title, systemImage: g.kind.icon)
                }
            }
        } label: {
            HStack(spacing: 6) {
                titleBlock
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMute)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch artifact")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if showingSource || group.kind == .code {
            ScrollView {
                MarkdownText(content: fencedSource, fontSize: 12.5 * textScale)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)
        } else if group.kind.isRenderable {
            ArtifactWebView(html: ArtifactHTML.document(for: current, dark: Theme.active.scheme == .dark))
        } else {   // rendered markdown
            ScrollView {
                MarkdownText(content: current.content, fontSize: 14 * textScale)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hideScrollIndicators()
            }
            .scrollIndicators(.hidden)
        }
    }

    private var fencedSource: String {
        let lang: String
        switch group.kind {
        case .code:     lang = current.language ?? ""
        case .html:     lang = "html"
        case .svg:      lang = "xml"
        case .mermaid:  lang = "mermaid"
        case .markdown: lang = "markdown"
        }
        return "```\(lang)\n\(current.content)\n```"
    }

    // MARK: Footer (toggle · versions · actions)

    private var footer: some View {
        HStack(spacing: 10) {
            if hasToggle {
                Picker("", selection: $showingSource) {
                    Text(previewLabel).tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            if group.versions.count > 1 {
                HStack(spacing: 6) {
                    stepper("chevron.left", enabled: versionIndex > 0) { versionIndex -= 1 }
                    Text("v\(versionIndex + 1)/\(group.versions.count)")
                        .font(.mono(10)).foregroundStyle(Theme.textDim)
                    stepper("chevron.right", enabled: versionIndex < group.versions.count - 1) { versionIndex += 1 }
                }
            }
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMute)
            }
            .buttonStyle(.plain).help("Copy source")
            Button(action: download) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMute)
            }
            .buttonStyle(.plain).help("Save to file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func stepper(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Theme.textLo : Theme.textFaint.opacity(0.4))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.content, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func download() {
        exportArtifact(current)
    }
}

/// Writes an artifact to disk via a save panel. HTML artifacts get the same themed
/// document the preview and “Open in Browser” produce — a bare model fragment with no
/// `<head>` would otherwise save as unstyled, blank-looking HTML. Other kinds save raw
/// source so the file type matches its extension (.svg → SVG, .mmd → Mermaid, etc.).
/// Shared by the panel’s footer download button and the inline card’s right-click menu.
private func exportArtifact(_ artifact: Artifact) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = ArtifactParser.slug(artifact.title, fallback: "artifact")
        + "." + artifact.kind.fileExtension(language: artifact.language)
    if panel.runModal() == .OK, let url = panel.url {
        let content: String
        if artifact.kind == .html {
            content = ArtifactHTML.document(for: artifact, dark: Theme.active.scheme == .dark, forExport: true)
        } else {
            content = artifact.content
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Renders a renderable artifact (HTML/SVG/Mermaid) to the same document shown in the
/// panel’s live preview, then opens it in the user’s default browser — useful for
/// artifacts that need real window chrome, print, or devtools the embedded preview can’t give.
private func openArtifactInBrowser(_ artifact: Artifact) {
    let html = ArtifactHTML.document(for: artifact, dark: Theme.active.scheme == .dark, forExport: true)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(ArtifactParser.slug(artifact.title, fallback: "artifact"))
        .appendingPathExtension("html")
    guard (try? html.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
    NSWorkspace.shared.open(url)
}

/// Captures a renderable artifact's preview as a PNG and saves it via a save panel.
/// `ArtifactPNGRenderer` keeps itself alive until the completion handler fires, so the
/// instance here doesn't need to be held onto.
@MainActor
private func exportArtifactAsPNG(_ artifact: Artifact) {
    _ = ArtifactPNGRenderer(artifact: artifact, dark: Theme.active.scheme == .dark) { image in
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtifactParser.slug(artifact.title, fallback: "artifact") + ".png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

/// Compact inline card shown in the chat where an artifact was emitted. Tapping opens
/// it in the panel — the full content never floods the message stream.
struct ArtifactCard: View {
    let artifact: Artifact
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: artifact.kind.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.amber)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textHi)
                        .lineLimit(1)
                    Text(artifact.kind.label + (artifact.language.map { " · \($0)" } ?? ""))
                        .font(.mono(10))
                        .foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMute)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(isOpen || hovering ? Theme.amberFillLo : Theme.fill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                .stroke(isOpen ? Theme.amberBorder : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open “\(artifact.title)” in the artifact panel")
        .contextMenu {
            if artifact.kind.isRenderable {
                Button("Open in Browser") { openArtifactInBrowser(artifact) }
                Button("Export as PNG…") { exportArtifactAsPNG(artifact) }
            }
            Button("Export File…") { exportArtifact(artifact) }
        }
    }
}

/// Width rules for the artifact side panel (§2.4), shared by its display and its
/// resize drag so the two can't disagree.
enum ArtifactPanelSizing {
    static let minWidth = 320.0
    /// The chat column never shrinks below this; it's the panel's only upper limit.
    /// Sized for the chat header (model picker, Tools chip, buttons) to fit on one row —
    /// at 360 it wrapped and stretched tall.
    static let minChatWidth = 560.0

    /// The width the panel is shown at for a stored (possibly out-of-range) width.
    static func clamp(_ width: Double, detailWidth: Double) -> Double {
        let upper = max(360, detailWidth - minChatWidth)
        return min(max(width, minWidth), max(minWidth, upper))
    }

    /// The new width after dragging the handle by `translation` (rightward = narrower).
    /// Starts from the visible width, not the stored one: a stored width above the cap
    /// otherwise swallowed the drag until it fell back under it.
    static func dragged(storedWidth: Double, translation: Double, detailWidth: Double) -> Double {
        clamp(clamp(storedWidth, detailWidth: detailWidth) - translation, detailWidth: detailWidth)
    }
}
