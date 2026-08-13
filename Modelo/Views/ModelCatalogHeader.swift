import SwiftUI

/// Band 1: section title band, search field, refresh button.
struct ModelCatalogHeader: View {
    @Bindable var vm: ModelCatalogViewModel
    var onRefresh: (() async -> Void)? = nil
    @FocusState.Binding var searchFocused: Bool

    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            HStack(spacing: 10) {
                searchField
                    .frame(maxWidth: .infinity)
                if let onRefresh {
                    refreshButton(onRefresh)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 12)
            .padding(.bottom, 14)

            if searchFocused {
                Text("Try ctx>200k · tools · speed>85 to filter by spec")
                    .font(Theme.metric(9))
                    .foregroundStyle(Theme.textFaint.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: searchFocused)
    }

    // MARK: – Page header

    private var pageHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textHi)
                Spacer()
                let n = vm.groupedRemote.count
                if n > 0 {
                    Text("\(n) provider\(n == 1 ? "" : "s")")
                        .font(Theme.metric(9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
    }

    // MARK: – Search field

    private var searchField: some View {
        HStack(spacing: 7) {
            Text("⌕")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textFaint)

            TextField("Search models", text: $vm.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.metric(11))
                .foregroundStyle(Theme.textMid)
                .focused($searchFocused)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    // MARK: – Refresh button

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
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .disabled(isRefreshing)
    }
}
