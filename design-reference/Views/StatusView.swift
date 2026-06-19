import SwiftUI

/// Server Status dashboard (handoff §6): a 3-up grid of live server cards over a
/// streaming console.
struct StatusView: View {
    @Environment(AppStore.self) private var store

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.statusServers) { ServerRow(server: $0) }
            }

            ConsoleInspector()
                .padding(.top, 18)
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Server status").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textHi)
            Text("updated 2s ago").font(.mono(11)).foregroundStyle(Theme.textDim)
            Spacer()

            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.system(size: 12)).foregroundStyle(Theme.textLo)
                .padding(.horizontal, 13).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(Color.white.opacity(0.08)))

            Text("+ Add server")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
                .padding(.horizontal, 13).frame(height: 30)
                .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
    }
}
