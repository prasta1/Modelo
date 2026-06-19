import SwiftUI

/// Sidebar (handoff §3). `.listStyle(.sidebar)` can't hit this look, so it's a
/// plain VStack in a ScrollView over `Theme.sidebarBG`.
struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: 2) {
                    navRow("Models",  icon: "square.grid.2x2",                section: .models)
                    navRow("Status",  icon: "chart.bar",                      section: .status)
                    navRow("Reports", icon: "chart.line.uptrend.xyaxis",      section: .reports)
                }

                serversSection
                conversationsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBG)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ModeloMark(size: 19).frame(width: 22, height: 22)
            Text("MODELO")
                .font(.system(size: 14, weight: .semibold))
                .tracking(2.8)
                .foregroundStyle(Theme.textBright)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 24)
    }

    // MARK: Primary nav

    private func navRow(_ title: String, icon: String, section: AppSection) -> some View {
        let active = store.section == section
        return HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 15, height: 15)
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(active ? Theme.textHi : Theme.textMute)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Theme.fillHi : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .onTapGesture { store.section = section }
    }

    // MARK: Servers

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "SERVERS", tracking: 1.4)
                Spacer()
                Text("\(store.liveServerCount) LIVE")
                    .font(.mono(10)).foregroundStyle(Theme.green)
            }
            .padding(.horizontal, 8)
            .padding(.top, 24).padding(.bottom, 8)

            ForEach(store.servers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: Server) -> some View {
        let active = server.id == store.activeServerID
        return HStack(spacing: 9) {
            Circle().fill(Theme.green).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                    .lineLimit(1)
                Text(server.host)
                    .font(.mono(9.5)).foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if active {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Theme.amberFillLo)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .stroke(Theme.amberBorder))
            }
        }
        .overlay(alignment: .leading) {
            if active {
                Capsule().fill(Theme.amber)
                    .frame(width: 2)
                    .padding(.vertical, 9)
            }
        }
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { store.activeServerID = server.id }
    }

    // MARK: Conversations

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "CONVERSATIONS", tracking: 1.4)
                .padding(.horizontal, 8)
                .padding(.top, 24).padding(.bottom, 10)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text("Search messages").font(.system(size: 12.5))
            }
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Color.white.opacity(0.05)))
            .padding(.bottom, 18)

            Eyebrow(text: "TODAY", tracking: 1.4)
                .padding(.horizontal, 8).padding(.bottom, 8)

            ForEach(Array(store.conversations.enumerated()), id: \.element.id) { idx, convo in
                let active = store.section == .models && idx == 0
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(convo.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(active ? Theme.textHi : Theme.textSoft)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(convo.time)
                        .font(.mono(9.5)).foregroundStyle(Theme.textFaint)
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(active ? Theme.fill : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
        }
    }
}
