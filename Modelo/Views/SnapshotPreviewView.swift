import SwiftUI
import AppKit

/// Wraps a file URL so it can be used with `.sheet(item:)`.
struct SnapshotItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Preview panel shown after taking a chat screenshot. Presents the rendered
/// card image with a Share button (native macOS share sheet) and a Done button
/// that dismisses without saving. Temp file is deleted on disappear.
struct SnapshotPreviewView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(contentsOf: url) {
                ScrollView(.vertical) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 700)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Preview unavailable")
                    .foregroundStyle(Theme.Palette.inkFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 500, idealWidth: 720, minHeight: 400)
        .background(Theme.windowBG)
        .onAppear {
            // Auto-copy so the user can paste immediately without extra steps.
            guard let data = try? Data(contentsOf: url) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
        .onDisappear { try? FileManager.default.removeItem(at: url) }
    }
}
