import AppKit
import SwiftUI

/// Captures the chat column exactly as rendered on screen and wraps it in a clean,
/// share-ready card: themed backdrop, rounded corners with a soft shadow, and a
/// caption strip (wordmark + chat title · model · timestamp). The PNG goes to
/// ~/Downloads (same convention as `ConversationExporter`) and the clipboard.
///
/// The capture renders the view hierarchy via `cacheDisplay` — not a screen grab —
/// so it needs no screen-recording permission and ignores overlapping windows.
enum SessionSnapshot {

    /// Card geometry, shared with the tests so the size math stays honest.
    static let margin: CGFloat = 28
    /// Height of the strip below the shot that holds the caption line.
    static let captionBand: CGFloat = 44
    static let cornerRadius: CGFloat = 10

    /// Snapshot the pixels inside `probe`'s bounds from the window's content view.
    /// Returns nil when the probe isn't in a window yet or has no size.
    @MainActor
    static func capture(around probe: NSView) -> NSImage? {
        guard let window = probe.window, let content = window.contentView else { return nil }
        let rect = probe.convert(probe.bounds, to: content)
        guard rect.width > 1, rect.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// Caption details: "<title> · <model> · <yyyy-MM-dd HH:mm>". Pure — the caller
    /// passes the timestamp — so it's directly testable.
    static func caption(title: String, modelID: String?, stamp: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // stable digits regardless of user-region calendar
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var parts: [String] = []
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if let modelID, !modelID.isEmpty { parts.append(modelID) }
        parts.append(f.string(from: stamp))
        return parts.joined(separator: "  ·  ")
    }

    /// Compose the padded share card. `scale` is the window's backing scale so the
    /// output stays Retina-sharp. Returns a bitmap sized `shot + margins + caption`.
    @MainActor
    static func card(from shot: NSImage, caption: String, scale: CGFloat) -> NSBitmapImageRep? {
        let outSize = NSSize(width: shot.size.width + margin * 2,
                             height: shot.size.height + margin + captionBand)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((outSize.width * scale).rounded()),
                                         pixelsHigh: Int((outSize.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = outSize   // pixel buffer is scale×, but we draw in points

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ctx

        // Backdrop in the active theme's window color so the card matches the app.
        NSColor(Theme.Palette.bg).setFill()
        NSRect(origin: .zero, size: outSize).fill()

        // Soft shadow under the shot, then the shot clipped to rounded corners.
        let shotRect = NSRect(x: margin, y: captionBand, width: shot.size.width, height: shot.size.height)
        ctx.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        NSColor(Theme.Palette.panel).setFill()
        NSBezierPath(roundedRect: shotRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        ctx.restoreGraphicsState()

        ctx.saveGraphicsState()
        NSBezierPath(roundedRect: shotRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        shot.draw(in: shotRect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGraphicsState()
        NSColor(Theme.Palette.strokeStrong).setStroke()
        NSBezierPath(roundedRect: shotRect.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: cornerRadius, yRadius: cornerRadius).stroke()

        // Caption strip: wordmark on the left, details on the right.
        let wordmark = NSAttributedString(string: "MODELO", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(Theme.Palette.signal),
            .kern: 3,
        ])
        let details = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(Theme.Palette.inkFaint),
        ])
        let textY = (captionBand - wordmark.size().height) / 2
        wordmark.draw(at: NSPoint(x: margin + 2, y: textY))
        // Leave room for the wordmark; clip long titles from the left edge instead.
        let detailsX = max(margin + wordmark.size().width + 24,
                           outSize.width - margin - details.size().width)
        ctx.saveGraphicsState()
        NSRect(x: detailsX, y: 0, width: outSize.width - margin - detailsX, height: captionBand).clip()
        details.draw(at: NSPoint(x: detailsX, y: textY))
        ctx.restoreGraphicsState()

        return rep
    }

    /// Write the card to a temp PNG the caller can show in a preview panel.
    /// The caller is responsible for deleting the file when done.
    static func writeToTemp(_ rep: NSBitmapImageRep, title: String, stamp: Date = Date()) -> URL? {
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(ConversationExporter.slug(title))-\(f.string(from: stamp)).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            Log.app.error("Session snapshot temp write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Write the card to ~/Downloads/<slug>-<stamp>.png (mirrors the Markdown
    /// exporter's naming). Returns the URL, or nil on failure.
    @discardableResult
    static func writeToDownloads(_ rep: NSBitmapImageRep, title: String, stamp: Date = Date()) -> URL? {
        guard let png = rep.representation(using: .png, properties: [:]),
              let dir = try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appending(path: "\(ConversationExporter.slug(title))-\(f.string(from: stamp)).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            Log.app.error("Session snapshot write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Put the PNG on the general pasteboard so the card pastes straight into
    /// Messages/Slack/etc.
    @MainActor
    static func copyToClipboard(_ rep: NSBitmapImageRep) {
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}

/// Invisible probe installed behind the chat column so the screenshot button can
/// resolve the column's exact frame in the window at click time. Only a reference
/// is stored here; the AppKit hierarchy is walked when the button is pressed, long
/// after the view is attached, so there's no layout-timing hazard.
struct SnapshotProbeView: NSViewRepresentable {
    /// Stable box for the probe reference (`weak` — SwiftUI owns the view's lifetime).
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
