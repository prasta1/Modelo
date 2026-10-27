import SwiftData
import SwiftUI

/// Settings ▸ Endpoints: every server with live status, plus add, edit, reorder,
/// pause, and delete.
struct EndpointsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @State private var form: FormRequest?
    @State private var pendingDelete: Server?

    /// One presentation of the add/edit form.
    private struct FormRequest: Identifiable {
        let id = UUID()
        let draft: EndpointDraft
        let existing: Server?
    }

    var body: some View {
        Group {
            if servers.isEmpty {
                ContentUnavailableView {
                    Label("Add an endpoint", systemImage: "server.rack")
                } description: {
                    Text("Connect to LM Studio, Ollama, or a cloud API.")
                } actions: {
                    addMenu { Text("Add Endpoint") }
                }
            } else {
                List {
                    Section("Endpoints") {
                        ForEach(servers) { server in
                            EndpointRow(server: server) {
                                form = FormRequest(draft: EndpointDraft(server: server, keychain: KeychainStore()),
                                                   existing: server)
                            }
                        }
                        .onMove { from, to in
                            ServerListActions.reorder(servers, fromOffsets: from, toOffset: to)
                            context.saveOrLog()
                        }
                        .onDelete { offsets in
                            pendingDelete = offsets.first.map { servers[$0] }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .primaryAction) {
                        addMenu { Label("Add Endpoint", systemImage: "plus") }
                    }
                }
            }
        }
        .sheet(item: $form) { request in
            EndpointFormView(draft: request.draft, existing: request.existing)
        }
        .confirmationDialog("Delete \"\(pendingDelete?.label ?? "")\"?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { server in
            // `presenting:` hands the server to the action, so it can't be nil'd by the
            // dismissal binding before the delete runs.
            Button("Delete", role: .destructive) {
                ServerListActions.delete(server, in: context, keychain: KeychainStore())
            }
        } message: { _ in
            Text("Its API key is removed too.")
        }
    }

    /// The add menu: local runtimes, the dedicated cloud endpoints, provider presets,
    /// and a custom base URL — the same choices as the Mac.
    private func addMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Section("Local") {
                ForEach(ServerKind.localCases, id: \.self) { kind in
                    Button(kind.displayName) { add(EndpointDraft(kind: kind)) }
                }
            }
            Section("Cloud") {
                Button(ServerKind.openRouter.displayName) { add(EndpointDraft(kind: .openRouter)) }
                Button(ServerKind.nous.displayName) { add(EndpointDraft(kind: .nous)) }
                ForEach(CloudPreset.all) { preset in
                    Button(preset.name) { add(EndpointDraft(preset: preset)) }
                }
                Button("Custom…") { add(EndpointDraft(kind: .cloudAPI)) }
            }
        } label: {
            label()
        }
    }

    private func add(_ draft: EndpointDraft) {
        form = FormRequest(draft: draft, existing: nil)
    }
}

/// One endpoint: name, runtime, address, live status, and the Active switch.
private struct EndpointRow: View {
    let server: Server
    let onEdit: () -> Void
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.modelContext) private var context

    var body: some View {
        HStack(spacing: 12) {
            // The tappable area is the text only (borderless), so the switch beside it
            // toggles on its own instead of also opening the edit sheet.
            Button(action: onEdit) {
                info.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            // ON = active, matching the Mac's pill toggle (`isPaused` is the inverse).
            Toggle("Active", isOn: Binding(get: { !server.isPaused },
                                           set: { server.isPaused = !$0; context.saveOrLog() }))
                .labelsHidden()
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.label).font(.headline)
            Text(server.kind.isLocal ? "\(server.kind.displayName) · \(server.host):\(server.port)"
                                     : "\(server.kind.displayName) · \(server.baseURL)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            statusLine
        }
    }

    @ViewBuilder private var statusLine: some View {
        if server.isPaused {
            Text("PAUSED").font(.caption2.monospaced()).foregroundStyle(.secondary)
        } else {
            let status = registry.status(for: server)
            HStack(spacing: 6) {
                Circle().fill(color(for: status)).frame(width: 7, height: 7)
                Text(status.displayLabel).font(.caption2.monospaced())
                if let ms = registry.latency(for: server) {
                    Text(String(format: "%.0f ms", ms)).font(.caption2.monospaced())
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func color(for status: ServerStatus) -> Color {
        switch status {
        case .online:   .green
        case .offline:  .red
        case .needsKey: .orange
        case .unknown:  .gray
        }
    }
}
