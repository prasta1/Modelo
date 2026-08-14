import SwiftUI

/// 326pt fixed right panel: model detail + compare mode.
struct ModelInspectorView: View {
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let onLaunch: (DiscoveredModel) -> Void

    @State private var comparing = false

    var body: some View {
        VStack(spacing: 0) {
            if let model = vm.selectedModel {
                if comparing, let prev = vm.previousModel {
                    ComparePanel(model1: model, model2: prev, vm: vm, onClose: { comparing = false })
                } else {
                    DetailPanel(
                        model: model,
                        vm: vm,
                        rotation: rotation,
                        compareCandidate: vm.previousModel,
                        onOpenCompare: { comparing = true },
                        onLaunch: onLaunch
                    )
                }
            } else {
                InspectorPlaceholder()
            }
        }
        .background(Theme.sidebarBG)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.line).frame(width: 1)
        }
        .onChange(of: vm.selectedID) { comparing = false }
    }
}

// MARK: - Detail Panel

private struct DetailPanel: View {
    let model: DiscoveredModel
    let vm: ModelCatalogViewModel
    let rotation: RotationStore
    let compareCandidate: DiscoveredModel?
    let onOpenCompare: () -> Void
    let onLaunch: (DiscoveredModel) -> Void

    private var m: LMStudioModel { model.model }

    private var placementLine: String {
        if m.isLoaded                { return "LOADED · \(vm.localHostname.uppercased())" }
        if model.server.kind.isLocal { return "NOT LOADED" }
        return "REMOTE · \(model.server.label.uppercased())"
    }

    private var placementColor: Color {
        if m.isLoaded                { return Theme.amber }
        if model.server.kind.isLocal { return Theme.textFaint }
        return Theme.green
    }

    private var subLine: String {
        [m.publisher, m.quantization, m.arch]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Placement
                    HStack(spacing: 5) {
                        Circle().fill(placementColor)
                            .frame(width: 5, height: 5)
                            .shadow(color: m.isLoaded ? placementColor.opacity(0.9) : .clear, radius: 4)
                        Text(placementLine)
                            .font(Theme.label(8))
                            .tracking(0.8)
                            .foregroundStyle(placementColor)
                    }
                    .padding(.bottom, 7)

                    // Name
                    Text(m.shortName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textHi)
                        .lineLimit(3)
                        .padding(.bottom, 2)

                    // Sub line
                    if !subLine.isEmpty {
                        Text(subLine)
                            .font(Theme.metric(9))
                            .foregroundStyle(Theme.textFaint)
                            .lineLimit(1)
                    }

                    // Capability chips
                    HStack(spacing: 4) {
                        if m.isFree           { Chip(text: "free",   tint: Theme.green) }
                        if m.supportsToolUse  { Chip(text: "tools",  tint: Theme.amber) }
                        if m.supportsVision   { Chip(text: "vision", tint: Theme.blue) }
                        if m.supportsThinking { Chip(text: "reason", tint: Theme.purple) }
                        if m.isLoaded         { Chip(text: "local",  tint: Theme.amber) }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                    specRows.padding(.bottom, 14)
                    historyBlock.padding(.bottom, 12)

                    if let prev = compareCandidate {
                        compareAffordance(prev: prev)
                            .padding(.bottom, 12)
                    }
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)

            inspectorFooter
        }
    }

    // MARK: Spec rows (SPEED / CONTEXT / SIZE / COST — BENCH omitted)

    @ViewBuilder private var specRows: some View {
        VStack(spacing: 0) {
            // SPEED
            let spd = vm.speedMedians[m.id] ?? 0
            let spdFrac = vm.maxSpeedMedian > 0 ? spd / vm.maxSpeedMedian : 0
            let spdRank = vm.speedRank(for: model.id)
            SpecRow(
                label: "Speed",
                value: spd > 0 ? "\(Int(spd)) tok/s" : "—",
                rank: spdRank.map { "\(ordinal($0.rank)) of \($0.total)" },
                barFrac: spdFrac,
                barAccent: true
            )

            // CONTEXT
            let ctxFrac: Double = {
                guard let c = m.maxContextLength, vm.maxContextLength > 0 else { return 0 }
                return Double(c) / Double(vm.maxContextLength)
            }()
            SpecRow(
                label: "Context",
                value: contextLabel,
                rank: vm.contextRankLabel(for: model.id),
                barFrac: ctxFrac,
                barAccent: false
            )

            // SIZE
            let sizeStr = m.displaySizeFormatted ?? m.parameterSize ?? "—"
            let sizeFrac: Double = {
                guard let bytes = m.fileSizeBytes else { return 0 }
                let maxBytes = vm.allModels.compactMap { $0.model.fileSizeBytes }.max() ?? 1
                return maxBytes > 0 ? Double(bytes) / Double(maxBytes) : 0
            }()
            SpecRow(label: "Size", value: sizeStr, rank: nil, barFrac: sizeFrac, barAccent: false)

            // COST
            let costStr = (m.isLoaded || model.server.kind.isLocal)
                ? "free — runs locally"
                : (m.isFree ? "free" : "paid · \(model.server.label)")
            SpecRow(label: "Cost", value: costStr, rank: nil, barFrac: 0, barAccent: false)
        }
    }

    private var contextLabel: String {
        guard let c = m.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }

    // MARK: History block

    @ViewBuilder private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.bottom, 10)

            let count = vm.usageCount(for: model.id) ?? 0
            Text("\(count)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textHi)
                .monospacedDigit()

            Text("chats · last used \(vm.lastUsedLabel(for: model.id) ?? "never")")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint)
                .padding(.bottom, 8)

            let bars = vm.histogram(for: model.id)
            let maxBar = bars.max() ?? 1
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bars.indices, id: \.self) { i in
                    let frac = maxBar > 0 ? Double(bars[i]) / Double(maxBar) : 0
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.amber.opacity(0.22 + frac * 0.78))
                        .frame(maxWidth: .infinity, minHeight: 2, maxHeight: max(2, 26 * frac))
                }
            }
            .frame(height: 28)

            Text("12 weeks")
                .font(Theme.metric(8))
                .foregroundStyle(Theme.textFaint.opacity(0.45))
        }
    }

    // MARK: Compare affordance

    @ViewBuilder private func compareAffordance(prev: DiscoveredModel) -> some View {
        Button(action: onOpenCompare) {
            HStack {
                Text("Compare with \(prev.model.shortName)")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                Spacer()
                Text("Open")
                    .font(Theme.label(9))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.amberBorder, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .padding(11)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    // MARK: Footer

    private var inspectorFooter: some View {
        HStack(spacing: 7) {
            Button { onLaunch(model) } label: {
                HStack(spacing: 6) {
                    Text("New chat")
                    Text("⏎").font(Theme.mono(11))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: 0x0F0F13))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                if rotation.isPinned(m.id) { rotation.unpin(m.id) } else { rotation.pin(m.id) }
            } label: {
                Text(rotation.isPinned(m.id) ? "Unpin" : "Pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMid)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Theme.sidebarBG)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default:
            switch n % 10 {
            case 1: return "\(n)st"
            case 2: return "\(n)nd"
            case 3: return "\(n)rd"
            default: return "\(n)th"
            }
        }
    }
}

// MARK: - Spec Row

private struct SpecRow: View {
    let label: String
    let value: String
    let rank: String?
    let barFrac: Double
    let barAccent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label.uppercased())
                    .font(Theme.label(7.5))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textFaint.opacity(0.45))
                    .frame(width: 56, alignment: .leading)
                Text(value)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textLo)
                    .monospacedDigit()
                    .lineLimit(1)
                if let rank {
                    Spacer()
                    Text(rank)
                        .font(Theme.metric(8))
                        .foregroundStyle(Theme.textFaint.opacity(0.45))
                }
            }
            if barFrac > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill).frame(height: 3)
                        Capsule()
                            .fill(barAccent ? Theme.amber : Color.white.opacity(0.20))
                            .frame(width: geo.size.width * barFrac, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1)
        }
    }
}

// MARK: - Compare Panel

private struct ComparePanel: View {
    let model1: DiscoveredModel
    let model2: DiscoveredModel
    let vm: ModelCatalogViewModel
    let onClose: () -> Void

    private var m1: LMStudioModel { model1.model }
    private var m2: LMStudioModel { model2.model }
    private var speed1: Double { vm.speedMedians[m1.id] ?? 0 }
    private var speed2: Double { vm.speedMedians[m2.id] ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m1.shortName).font(Theme.metric(10)).foregroundStyle(Theme.textHi).lineLimit(1)
                    Text(m2.shortName).font(Theme.metric(10)).foregroundStyle(Theme.textMid).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Text("✕ close")
                        .font(Theme.label(9))
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    compareRow("Speed",
                               v1: speed1 > 0 ? "\(Int(speed1)) t/s" : "—",
                               v2: speed2 > 0 ? "\(Int(speed2)) t/s" : "—",
                               winner: speed1 > speed2 ? 0 : (speed2 > speed1 ? 1 : nil))

                    compareRow("Context",
                               v1: ctxLabel(m1), v2: ctxLabel(m2),
                               winner: (m1.maxContextLength ?? 0) > (m2.maxContextLength ?? 0) ? 0 :
                                       (m2.maxContextLength ?? 0) > (m1.maxContextLength ?? 0) ? 1 : nil)

                    compareRow("Size",
                               v1: m1.displaySizeFormatted ?? "—",
                               v2: m2.displaySizeFormatted ?? "—",
                               winner: nil)

                    let cost1IsFree = model1.server.kind.isLocal || m1.isFree
                    let cost2IsFree = model2.server.kind.isLocal || m2.isFree
                    compareRow("Cost",
                               v1: cost1IsFree ? "free" : "paid",
                               v2: cost2IsFree ? "free" : "paid",
                               winner: cost1IsFree && !cost2IsFree ? 0 : !cost1IsFree && cost2IsFree ? 1 : nil)

                    verdictView.padding(.top, 14)
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private func compareRow(_ label: String, v1: String, v2: String, winner: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.label(7.5))
                .tracking(0.5)
                .foregroundStyle(Theme.textFaint.opacity(0.45))
            HStack {
                Text(v1)
                    .font(Theme.mono(10))
                    .foregroundStyle(winner == 0 ? Theme.amber : Theme.textLo)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(v2)
                    .font(Theme.mono(10))
                    .foregroundStyle(winner == 1 ? Theme.amber : Theme.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1) }
    }

    @ViewBuilder private var verdictView: some View {
        let parts = verdictParts
        if !parts.isEmpty {
            Text(parts.joined(separator: " "))
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textMid)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verdictParts: [String] {
        var parts: [String] = []
        if speed1 > 0 && speed2 > 0 {
            let diff = abs(Int(speed1) - Int(speed2))
            if diff > 0 {
                let faster = speed1 > speed2 ? m1.familyName : m2.familyName
                parts.append("\(faster) is \(diff) tok/s faster.")
            }
        }
        if let c1 = m1.maxContextLength, let c2 = m2.maxContextLength, c1 != c2 {
            let bigger = c1 > c2 ? m1.familyName : m2.familyName
            parts.append("\(bigger) has a larger context window.")
        }
        if m1.isFree != m2.isFree {
            let free = m1.isFree ? m1.familyName : m2.familyName
            parts.append("\(free) is free to use.")
        }
        return parts
    }

    private func ctxLabel(_ m: LMStudioModel) -> String {
        guard let c = m.maxContextLength else { return "—" }
        if c >= 1_000_000 { return "\(c / 1_000_000)M" }
        if c >= 1_000     { return "\(c / 1_000)K" }
        return "\(c)"
    }
}

// MARK: - Placeholder

private struct InspectorPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Select a model")
                .font(Theme.metric(13))
                .foregroundStyle(Theme.textFaint)
            Text("Use ↑↓ or click a row")
                .font(Theme.metric(10))
                .foregroundStyle(Theme.textFaint.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
