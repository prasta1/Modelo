import SwiftUI

/// Model Browser grid — the "01 Native Refined" frame from the exploration.
/// Not routed by default (the Models tab shows Chat per handoff §2); present
/// it from the picker's "Manage models" or wherever model management belongs.
struct ModelBrowserView: View {
    @Environment(AppStore.self) private var store
    /// FREE chip only appears under cloud scope (handoff / chat 2 note).
    var showFree = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 11), count: 3)

    private var loadedCount: Int { store.catalog.filter(\.isLoaded).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "PERSONA — OPTIONAL", color: Theme.textFaint, size: 10.5, tracking: 1.6)
                    .padding(.bottom, 12)

                HStack(spacing: 11) {
                    ForEach(store.personas) { personaCard($0) }
                }
                .padding(.bottom, 24)

                Divider().overlay(Theme.line).padding(.bottom, 20)

                serverHeader.padding(.bottom, 16)
                badges.padding(.bottom, 20)

                LazyVGrid(columns: columns, spacing: 11) {
                    ForEach(store.catalog) { modelCard($0) }
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 26)
        }
        .background(Theme.windowBG)
    }

    // MARK: Personas

    private func personaCard(_ p: Persona) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(p.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textBright)
            Text(p.traits).font(.mono(9.5)).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(Color.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: Server header + badges

    private var serverHeader: some View {
        HStack(spacing: 11) {
            Circle().fill(Theme.green).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color(hex: 0x5BBF8A, alpha: 0.14), lineWidth: 3))
            Text(store.servers.first { $0.id == store.activeServerID }?.name ?? "")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textHi)
            Spacer()
            Text("\(loadedCount) loaded · 13").font(.mono(11)).foregroundStyle(Theme.textDim)
        }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if showFree { capsuleBadge("FREE", filled: true) }
            capsuleBadge("VISION")
            capsuleBadge("TOOLS")
            capsuleBadge("REASON")
        }
    }

    private func capsuleBadge(_ text: String, filled: Bool = false) -> some View {
        Text(text)
            .font(.mono(10)).tracking(1).foregroundStyle(filled ? Theme.amber : Theme.textMute)
            .padding(.horizontal, 12).frame(height: 24)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.amberFill)
                } else {
                    RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08))
                }
            }
    }

    // MARK: Model cards

    private func modelCard(_ m: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.name)
                .font(.mono(13.5, .medium)).foregroundStyle(Theme.textHi)
                .lineLimit(1).padding(.trailing, 14)
            Text(m.specs)
                .font(.mono(10.5)).foregroundStyle(Theme.textDim)
                .padding(.top, 9)
            HStack(spacing: 6) {
                ForEach(m.capabilities, id: \.self) { cap in
                    Text(cap)
                        .font(.mono(9)).tracking(0.9).foregroundStyle(Theme.purple)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(Color(hex: 0x9682DC, alpha: 0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(minHeight: 18, alignment: .leading)
            .padding(.top, 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 17).padding(.vertical, 15)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .overlay(alignment: .topTrailing) {
            if m.isLoaded {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Theme.greenGlow, lineWidth: 3))
                    .padding(16)
            }
        }
    }
}
