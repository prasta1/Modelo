import SwiftUI

/// Band 1: search field, sort pill, refresh button.
struct ModelCatalogHeader: View {
    @Bindable var vm: ModelCatalogViewModel
    var onRefresh: (() async -> Void)? = nil
    @FocusState.Binding var searchFocused: Bool

    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 10) {
            searchField
            sortPill
            if let onRefresh {
                refreshButton(onRefresh)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Text("⌕")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)

            TextField("Search models — or type ctx>200k tools speed>85", text: $vm.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textMid)
                .focused($searchFocused)

            Spacer(minLength: 0)

            Text("\(vm.totalVisible) of \(vm.totalAll)")
                .font(Theme.metric(9))
                .monospacedDigit()
                .foregroundStyle(Theme.textFaint)

            Text("⌘K")
                .font(Theme.code(9))
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private var sortPill: some View {
        Menu {
            ForEach(CatalogSort.allCases) { sort in
                Button(sort.label) { vm.sortKey = sort }
            }
        } label: {
            Text("\(vm.sortKey.label) ▾")
                .font(Theme.label(9))
                .tracking(0.5)
                .foregroundStyle(Theme.textMid)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .fixedSize()
    }

    private func refreshButton(_ action: @escaping () async -> Void) -> some View {
        Button {
            isRefreshing = true
            Task { await action(); isRefreshing = false }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(
                    isRefreshing
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: isRefreshing
                )
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .disabled(isRefreshing)
    }
}
