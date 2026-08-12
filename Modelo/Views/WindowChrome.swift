import SwiftUI
import AppKit

/// Hands back the `NSWindow` hosting this view, once AppKit has attached it.
///
/// The app styles its windows through AppKit (transparent titlebar, themed
/// background, forced dark appearance), which SwiftUI has no equivalent for on
/// macOS 14. Reaching for `NSApp.keyWindow` to find the window works only while
/// a single window exists — with the expanded-table window open it returns
/// whichever window happens to be key, so chrome and screen-clamping land on the
/// wrong one. This walks up from a real hosted view instead, which is always the
/// window the modifier was applied in.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `view.window` is still nil during makeNSView; it's set once the view is
        // added to the hierarchy, so resolve on the next runloop pass.
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Applies Modelo's window look — transparent titlebar, themed background,
    /// dark appearance — to the window hosting this view, and reports it back so
    /// the caller can keep operating on the right window.
    ///
    /// - Parameters:
    ///   - center: Whether to center the window on screen once resolved.
    ///   - onResolve: Called with the hosting window after chrome is applied.
    func modeloWindowChrome(center: Bool = false,
                            onResolve: @escaping (NSWindow) -> Void = { _ in }) -> some View {
        background(
            WindowAccessor { window in
                window.titlebarAppearsTransparent = true
                window.backgroundColor = NSColor(Theme.windowBG)
                window.appearance = NSAppearance(named: .darkAqua)
                if center { window.center() }
                onResolve(window)
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }
}
