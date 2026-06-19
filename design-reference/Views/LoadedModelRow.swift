import SwiftUI

/// One model row in the picker popover (handoff §8). `ModelState` drives the
/// leading indicator and whether a "Load" button appears.
struct LoadedModelRow: View {
    @Environment(AppStore.self) private var store
    let model: ModelInfo
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            indicator.frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                Text(model.meta)
                    .font(.mono(10)).foregroundStyle(Theme.textDim)
            }

            Spacer(minLength: 0)

            Text(model.contextLabel)
                .font(.mono(10.5)).foregroundStyle(Theme.textFaint)

            if model.state == .idle {
                Button { load() } label: {
                    Text("Load")
                        .font(.mono(10)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(model.state == .selected ? Theme.amberFillLo : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    @ViewBuilder private var indicator: some View {
        switch model.state {
        case .selected:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.amber)
        case .loaded:
            Circle().fill(Theme.green).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.greenGlow, lineWidth: 3))
        case .idle:
            Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                .frame(width: 7, height: 7)
        case .cloud:
            Image(systemName: "cloud")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMute)
        }
    }

    private var nameColor: Color {
        switch model.state {
        case .selected: return Theme.amberName
        case .idle:     return Theme.textSoft
        default:        return Theme.textHi
        }
    }

    private func load() {
        guard let i = store.models.firstIndex(where: { $0.id == model.id }) else { return }
        // Real load is async (handoff §8): show progress, then flip to .loaded.
        store.models[i].state = .loaded
    }
}
