import SwiftUI

/// Section label + 4-card horizontal grid for pinned rotation models.
/// Lives above (outside) the table's ScrollView — never scrolls.
struct RotationTierView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore

    /// Resolve a rotation slot to a live DiscoveredModel (keyed by LMStudioModel.id).
    private func item(for slot: Int) -> DiscoveredModel? {
        guard let modelID = rotation.slots[slot] else { return nil }
        return vm.allModels.first { $0.model.id == modelID }
    }

    private var hasPins: Bool { rotation.slots.contains { $0 != nil } }

    var body: some View {
        if hasPins {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Eyebrow("Your Rotation", color: Theme.textFaint, size: 9)
                    Text("⌥1–4 to switch mid-chat")
                        .font(Theme.metric(9))
                        .foregroundStyle(Theme.textFaint.opacity(0.45))
                }
                .padding(.horizontal, Theme.gutter)

                HStack(spacing: 9) {
                    ForEach(0..<4, id: \.self) { slot in
                        let resolved = item(for: slot)
                        let isSelected = resolved.map { $0.id == vm.selectedID } ?? false
                        Group {
                            if let resolved {
                                FilledRotationCard(
                                    slotIndex: slot,
                                    item: resolved,
                                    isSelected: isSelected,
                                    vm: vm
                                )
                            } else {
                                EmptyRotationCard(slotIndex: slot)
                            }
                        }
                        .frame(height: 94)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
            .padding(.top, 24)
            .padding(.bottom, 10)
        } else {
            HStack(spacing: 6) {
                Eyebrow("Rotation", color: Theme.textFaint.opacity(0.6), size: 9)
                Text("·")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.25))
                Text("Pin models here with ⌥1–4")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.3))
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line.opacity(0.4)).frame(height: 1)
            }
        }
    }
}

// MARK: - Filled Card

private struct FilledRotationCard: View {
    let slotIndex: Int
    let item: DiscoveredModel
    let isSelected: Bool
    let vm: ModelCatalogViewModel

    private var model: LMStudioModel { item.model }

    private var placementLabel: String {
        if model.isLoaded           { return "Loaded" }
        if item.server.kind.isLocal { return "Cold" }
        return "Remote"
    }

    private var dotColor: Color {
        if model.isLoaded           { return Theme.amber }
        if item.server.kind.isLocal { return Theme.textFaint }
        return Theme.green
    }

    private var metricsText: String {
        var parts: [String] = []
        let spd = vm.speedLabel(for: item.id)
        if spd != "—" { parts.append("\(spd) t/s") }
        if let c = model.maxContextLength {
            if c >= 1_000_000 { parts.append("\(c / 1_000_000)M") }
            else if c >= 1_000 { parts.append("\(c / 1_000)K") }
        }
        if let sz = model.parameterSize { parts.append(sz) }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }

    private var sparkBars: [Int] { Array(vm.histogram(for: item.id).suffix(8)) }
    private var maxBar: Int { sparkBars.max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: model.isLoaded ? dotColor.opacity(0.9) : .clear, radius: 4)
                    Text(placementLabel.uppercased())
                        .font(Theme.label(8))
                        .tracking(0.6)
                        .foregroundStyle(dotColor)
                }
                Spacer()
                Text("⌥\(slotIndex + 1)")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.4))
            }

            Text(model.shortName)
                .font(Theme.metric(11))
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Theme.amber : Theme.textMid)
                .lineLimit(2)

            Text(metricsText)
                .font(Theme.mono(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)

            HStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(sparkBars.indices, id: \.self) { i in
                        let frac = maxBar > 0 ? Double(sparkBars[i]) / Double(maxBar) : 0
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(isSelected
                                  ? Theme.amber.opacity(0.30 + frac * 0.70)
                                  : Theme.fillHi.opacity(0.4 + frac * 0.6))
                            .frame(width: 5, height: max(2, 12 * frac))
                    }
                }
                Spacer()
                if let count = vm.usageCount(for: item.id) {
                    Text("\(count)×")
                        .font(Theme.metric(9))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textFaint.opacity(0.45))
                }
            }
            .frame(height: 14)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            isSelected ? Theme.amberFill : Theme.fill,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isSelected ? Theme.amberBorder : Theme.line,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { vm.selectedID = item.id }
    }
}

// MARK: - Empty Card

private struct EmptyRotationCard: View {
    let slotIndex: Int

    var body: some View {
        ZStack {
            Text("⌥\(slotIndex + 1)  ·  Pin a model")
                .font(Theme.metric(9))
                .foregroundStyle(Theme.textFaint.opacity(0.28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Theme.line.opacity(0.6),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
    }
}
