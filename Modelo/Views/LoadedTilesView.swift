import SwiftUI

/// One row of tiles for the models a server holds in memory, above the catalog
/// table. Each tile names the model and its endpoint; hovering offers eject.
/// Renders nothing when no model is loaded.
struct LoadedTilesView: View {
    let vm: ModelCatalogViewModel

    var body: some View {
        if !vm.loadedModels.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Loaded", color: Theme.textFaint, size: 9)
                    .padding(.horizontal, Theme.gutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(vm.loadedModels) { item in
                            LoadedTile(item: item,
                                       isSelected: vm.selectedID == item.id,
                                       onSelect: { vm.selectedID = item.id },
                                       onEject: item.server.kind.canEject
                                           ? vm.onEject.map { eject in { await eject(item) } }
                                           : nil)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 10)
        }
    }
}

private struct LoadedTile: View {
    let item: DiscoveredModel
    let isSelected: Bool
    let onSelect: () -> Void
    /// nil where the endpoint can't unload models; the tile then has no eject.
    let onEject: (() async -> Void)?

    @State private var hovering = false
    @State private var ejecting = false

    private var name: String { item.model.shortName }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 5, height: 5)
                        .shadow(color: Theme.glows ? Theme.green.opacity(0.9) : .clear, radius: 4)
                    Text(name)
                        .font(Theme.metric(13))
                        .foregroundStyle(isSelected ? Theme.amberName : Theme.textMid)
                        .lineLimit(1)
                }
                Text(item.server.label)
                    .font(Theme.metric(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .padding(.leading, 11)
            }
            Spacer(minLength: 0)
            if let onEject, hovering || ejecting {
                Button {
                    ejecting = true
                    Task {
                        await onEject()
                        ejecting = false
                    }
                } label: {
                    if ejecting {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMute)
                    }
                }
                .buttonStyle(.plain)
                .disabled(ejecting)
                .help("Unload model")
                .accessibilityLabel("Unload \(name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 200, height: 60)
        .background(
            isSelected ? Theme.amberFill : Theme.fill,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? Theme.amberBorder : Theme.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) loaded on \(item.server.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Unload") {
            guard let onEject, !ejecting else { return }
            ejecting = true
            Task { await onEject(); ejecting = false }
        }
    }
}
