import SwiftUI

/// The currently-loaded model — name, capability chips, spec strip, and optional unpin action.
struct LoadedModelRow: View {
    let model: LMStudioModel
    /// Called when the user taps the pin button. Only shown when the model is loaded, not pinned, and this is non-nil.
    var onPin: (() -> Void)? = nil
    /// Called when the user taps the unpin button. Only shown when the model is pinned and this is non-nil.
    var onUnpin: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(model.familyName)
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(Theme.Palette.panelHigh, radius: 8)
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
