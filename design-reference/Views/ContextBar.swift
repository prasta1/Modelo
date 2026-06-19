import SwiftUI

/// Chat context bar (handoff §5.1): model chip (opens the picker), mono meta,
/// and a context-window usage meter on the right.
struct ContextBar: View {
    @Environment(AppStore.self) private var store
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 14) {
            modelChip
            if let model = store.selectedModel {
                Text("\(model.meta) · \(model.contextLabel) ctx")
                    .font(.mono(11)).foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            usageMeter
        }
        .padding(.horizontal, 26)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }
    }

    private var modelChip: some View {
        Button { showingPicker.toggle() } label: {
            HStack(spacing: 9) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                Text(store.selectedModel?.name ?? "—")
                    .font(.mono(12.5)).foregroundStyle(Theme.textHi)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMute)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            ModelPickerView(isPresented: $showingPicker)
                .environment(store)
        }
    }

    private var usageMeter: some View {
        HStack(spacing: 12) {
            Text("\(tokenString(store.tokensUsed)) / \(tokenString(store.contextWindow))")
                .font(.mono(11)).foregroundStyle(Theme.textMute)
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 130, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.amber)
                        .frame(width: 130 * store.contextFraction, height: 5)
                }
        }
    }

    private func tokenString(_ n: Int) -> String {
        let k = Double(n) / 1000
        return k >= 100 ? "\(Int(k.rounded()))K"
                        : String(format: "%.1fK", k)
    }
}
