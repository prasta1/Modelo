import SwiftUI
import AppKit

/// Multiline chat composer backed by `NSTextView`, so we control the Return key the
/// way SwiftUI's `TextField` can't on macOS: **Enter submits, Shift+Enter inserts a
/// newline.** Grows with its content from one line up to `maxLines`, then scrolls.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    var placeholder: String = ""
    var fontSize: CGFloat = 15
    var maxLines: Int = 8
    var onSubmit: () -> Void
    /// Up/Down arrow hooks for an attached popup (e.g. the slash menu). Return true to
    /// consume the key (the cursor doesn't move); nil/false lets the text view handle it.
    var onMoveUp: (() -> Bool)? = nil
    var onMoveDown: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PlaceholderTextView {
        let tv = PlaceholderTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(Theme.textHi)
        tv.string = text
        tv.placeholder = placeholder
        tv.onFocusChange = { focused in
            DispatchQueue.main.async { if isFocused != focused { isFocused = focused } }
        }
        return tv
    }

    func updateNSView(_ tv: PlaceholderTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text { tv.string = text }
        if tv.font?.pointSize != fontSize { tv.font = .systemFont(ofSize: fontSize) }
        tv.placeholder = placeholder
        // Apply external focus requests (e.g. "edit & resend" focuses the composer).
        if isFocused, tv.window?.firstResponder != tv {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        DispatchQueue.main.async { context.coordinator.recalcHeight(tv) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalcHeight(tv)
        }

        /// Intercept Return: Shift+Return falls through to the default (inserts a
        /// newline); plain Return submits and is consumed.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shift { return false }
                parent.onSubmit()
                return true
            }
            // Let an attached popup (slash menu) claim Up/Down before the cursor moves.
            if commandSelector == #selector(NSResponder.moveUp(_:)), parent.onMoveUp?() == true {
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)), parent.onMoveDown?() == true {
                return true
            }
            return false
        }

        /// Size the view to its content, clamped to 1…maxLines tall.
        func recalcHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let line = ceil(tv.font?.boundingRectForFont.height ?? tv.font?.pointSize ?? 16)
            let used = lm.usedRect(for: tc).height
            let clamped = min(max(used, line), line * CGFloat(parent.maxLines))
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }
    }
}

/// NSTextView that draws a placeholder when empty and reports focus changes.
final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15),
            .foregroundColor: NSColor(Theme.textFaint)
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width,
                                     y: textContainerInset.height), withAttributes: attrs)
    }
}
