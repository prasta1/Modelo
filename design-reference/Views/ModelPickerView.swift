import SwiftUI

/// Model picker popover (handoff §8). Grouped by server, with per-model load
/// state. Anchored to the context-bar / composer model chip.
struct ModelPickerView: View {
    @Environment(AppStore.self) private var store
    @Binding var isPresented: Bool
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.modelGroups, id: \.server.id) { group in
                        groupHeader(group.server)
                        ForEach(filtered(group.models)) { model in
                            LoadedModelRow(model: model) { select(model) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            }

            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 418)
        .frame(maxHeight: 520)
        .background(Theme.popoverBG)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            TextField("Search models…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textHi)
            Text("\(store.models.count)")
                .font(.mono(10)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.line))
        .padding(13)
    }

    private func groupHeader(_ server: Server) -> some View {
        HStack(spacing: 10) {
            Text(label(for: server))
                .font(.mono(9.5)).tracking(1.2).foregroundStyle(Theme.textDim)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            Text(server.pickerMeta)
                .font(.mono(9.5)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8).padding(.top, 11).padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(Theme.textMute)
            Text("Manage models").font(.system(size: 12)).foregroundStyle(Theme.textLo)
            Spacer()
            Text("⌘L to switch").font(.mono(10)).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.012))
    }

    // MARK: Helpers

    private func label(for server: Server) -> String {
        server.kind == .cloud ? "\(server.name.uppercased()) · CLOUD"
                              : server.name.uppercased()
    }

    private func filtered(_ models: [ModelInfo]) -> [ModelInfo] {
        search.isEmpty ? models
                       : models.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func select(_ model: ModelInfo) {
        store.selectModel(model)
        isPresented = false
    }
}
