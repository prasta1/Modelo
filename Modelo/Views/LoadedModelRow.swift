import SwiftUI

/// The currently-loaded model — name, capability chips, spec strip, and optional unpin/chat actions.
struct LoadedModelRow: View {
    let model: LMStudioModel
    /// Called when the user taps the pin button. Only shown when the model is loaded, not pinned, and this is non-nil.
    var onPin: (() -> Void)? = nil
    /// Called when the user taps the unpin button. Only shown when the model is pinned and this is non-nil.
    var onUnpin: (() -> Void)? = nil
    /// Called when the user clicks the row to start a new chat with this model.
    var onChat: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(model.familyName)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(hovering && onChat != nil ? Theme.amber : Theme.Palette.ink)
                    if model.keepInRam == true {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Theme.Palette.signal)
                            .help("Pinned — model will not be auto-evicted")
                    }
                    CapabilityChips(model: model)
                }
                SpecStrip(model: model)
            }
            Spacer(minLength: 0)
            if hovering {
                HStack(spacing: 8) {
                    if let onChat {
                        Button(action: onChat) {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 9, weight: .medium))
                                Text("New Chat")
                                    .font(Theme.label(9))
                                    .tracking(0.5)
                            }
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.amberFillLo, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.amberBorder))
                        }
                        .buttonStyle(.plain)
                        .help("Start a new chat with \(model.familyName)")
                        .transition(.opacity)
                    }
                    if model.keepInRam == true, let onUnpin {
                        Button(action: onUnpin) {
                            Image(systemName: "pin.slash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkDim)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin model (allow eviction)")
                        .transition(.opacity)
                    } else if model.keepInRam != true, let onPin {
                        Button(action: onPin) {
                            Image(systemName: "pin")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.Palette.inkDim)
                        }
                        .buttonStyle(.plain)
                        .help("Pin model (prevent auto-eviction)")
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.Palette.panelHigh, radius: 8)
        .contentShape(Rectangle())
        .onTapGesture { onChat?() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// Shown when no model is loaded or the server hasn't been polled yet.
struct NoModelRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.inkFaint)
            Text("No model loaded")
                .font(Theme.metric(11))
                .foregroundStyle(Theme.Palette.inkFaint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.Palette.panelHigh, radius: 8)
    }
}
