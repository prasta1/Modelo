import SwiftUI
import AppKit

/// The Claude-style artifact side panel (§2.4): renders the selected artifact group's
/// latest version with a Preview⇄Source toggle, version navigation, and copy/download.
struct ArtifactPanel: View {
    let group: ArtifactGroup
    let onClose: () -> Void

    @State private var versionIndex: Int = 0
    @State private var showingSource = false
    @State private var copied = false

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
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: group.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                    .lineLimit(1)
                Text(group.kind.label + (group.language.map { " · \($0)" } ?? ""))
                    .font(.mono(10))
                    .foregroundStyle(Theme.textFaint)
            }
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

    // MARK: Content

    @ViewBuilder private var content: some View {
        if showingSource || group.kind == .code {
            ScrollView {
                MarkdownText(content: fencedSource, fontSize: 12.5)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if group.kind.isRenderable {
            ArtifactWebView(html: ArtifactHTML.document(for: current, dark: Theme.active.scheme == .dark))
        } else {   // rendered markdown
            ScrollView {
                MarkdownText(content: current.content, fontSize: 14)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtifactParser.slug(group.title, fallback: "artifact")
            + "." + group.kind.fileExtension(language: group.language)
        if panel.runModal() == .OK, let url = panel.url {
            try? current.content.write(to: url, atomically: true, encoding: .utf8)
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
                        .foregroundStyle(Theme.textFaint)
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
    }
}
