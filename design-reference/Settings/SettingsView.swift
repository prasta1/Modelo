import SwiftUI

/// Settings screen (handoff §5/§9): sub-nav, endpoint list with toggles,
/// default-model / API-key fields, and behavior switches.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textHi)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 18)
                .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

            HStack(spacing: 0) {
                subnav
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBG)
    }

    // MARK: Sub-nav

    private var subnav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.settingsSections, id: \.self) { item in
                let active = item == store.settingsSection
                Text(item)
                    .font(.system(size: 13))
                    .foregroundStyle(active ? Theme.textHi : Theme.textMute)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(active ? Theme.fillHi : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .contentShape(Rectangle())
                    .onTapGesture { store.settingsSection = item }
            }
            Spacer()
        }
        .frame(width: 188, alignment: .top)
        .padding(.horizontal, 12).padding(.vertical, 16)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.line).frame(width: 1)
        }
    }

    // MARK: Content

    private var content: some View {
        @Bindable var store = store
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Endpoints").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textHi)
                    Spacer()
                    Text("+ Add endpoint")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Theme.amberFill, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(.bottom, 14)

                ForEach($store.endpoints) { $endpoint in
                    endpointRow($endpoint)
                }

                Text("Defaults & behavior")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textHi)
                    .padding(.top, 26).padding(.bottom, 14)

                HStack(spacing: 12) {
                    field(label: "DEFAULT MODEL") {
                        Text(store.defaultModel).font(.mono(12.5)).foregroundStyle(Theme.textHi)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textMute)
                    }
                    field(label: "OPENROUTER API KEY") {
                        Text(store.apiKeyMasked).font(.mono(12.5)).tracking(0.6).foregroundStyle(Theme.textLo)
                        Spacer()
                    }
                }
                .padding(.bottom, 18)

                ForEach($store.behaviors) { $toggle in
                    HStack(spacing: 14) {
                        Text(toggle.label).font(.system(size: 13)).foregroundStyle(Theme.textMid)
                        Spacer()
                        PillToggle(isOn: $toggle.isOn)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 13)
                    .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.045)) }
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 24)
        }
    }

    private func endpointRow(_ endpoint: Binding<EndpointRow>) -> some View {
        HStack(spacing: 14) {
            Circle().fill(Theme.green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.wrappedValue.name)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textHi)
                Text(endpoint.wrappedValue.url)
                    .font(.mono(10)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(endpoint.wrappedValue.type)
                .font(.mono(9.5)).tracking(0.6).foregroundStyle(Theme.textLo)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.fillHi, in: RoundedRectangle(cornerRadius: 6))
            PillToggle(isOn: endpoint.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .padding(.bottom, 8)
    }

    private func field<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.mono(9.5)).tracking(0.6).foregroundStyle(Theme.textFaint)
            HStack { content() }
                .padding(.horizontal, 13).frame(height: 38)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field)
                    .stroke(Color.white.opacity(0.09)))
        }
        .frame(maxWidth: .infinity)
    }
}
