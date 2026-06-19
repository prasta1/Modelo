import SwiftUI

/// Root shell: `NavigationSplitView` with the Modelo sidebar and a detail pane
/// that switches on `AppSection`. Window chrome (traffic lights, toolbar) is
/// real macOS chrome, not drawn (handoff §4).
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(296)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .toolbar { toolbarItems }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.windowBG)
    }

    @ViewBuilder private var detail: some View {
        switch store.section {
        case .models:   ChatView()          // "models" tab shows Chat (handoff §2)
        case .status:   StatusView()
        case .reports:  ReportingView()
        case .settings: SettingsView()
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { } label: { Image(systemName: "square.and.arrow.up") }
            Button { } label: { Image(systemName: "chart.bar") }
            // Record dot doubles as the Settings entry; amber when active (handoff §4).
            Button {
                store.section = (store.section == .settings ? .models : .settings)
            } label: {
                Image(systemName: "record.circle")
                    .foregroundStyle(store.section == .settings ? Theme.amber : Theme.textMute)
            }
        }
    }
}
