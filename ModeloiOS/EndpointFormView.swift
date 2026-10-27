import SwiftData
import SwiftUI

/// Add/edit form for one endpoint. Edits a draft; nothing is written until Save.
struct EndpointFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ReachabilityMonitor.self) private var reachability

    @State private var draft: EndpointDraft
    let existing: Server?

    @State private var testState: TestState = .idle

    private enum TestState: Equatable { case idle, running, reachable, unreachable }

    init(draft: EndpointDraft, existing: Server?) {
        _draft = State(initialValue: draft)
        self.existing = existing
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.kind.isLocal { localFields } else { cloudFields }
                testSection
            }
            .navigationTitle(existing == nil ? "New Endpoint" : existing?.label ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!draft.isValid)
                }
            }
            // Any edit invalidates a previous test result.
            .onChange(of: draft) { testState = .idle }
        }
    }

    @ViewBuilder private var localFields: some View {
        Section {
            Picker("Runtime", selection: Binding(get: { draft.kind },
                                                 set: { draft.switchRuntime(to: $0) })) {
                ForEach(ServerKind.localCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            TextField("Label", text: $draft.label)
        }
        Section {
            TextField("Host", text: $draft.host, prompt: Text("spark.tailnet.ts.net"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", value: $draft.port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            TextField("Subtitle", text: $draft.connectionID, prompt: Text("Optional"))
        } header: {
            Text("Address")
        } footer: {
            Text("Hostname or IP. Prefix with https:// for servers that only speak TLS.")
        }
    }

    @ViewBuilder private var cloudFields: some View {
        Section {
            TextField("Label", text: $draft.label)
            if !draft.kind.hasFixedURL {
                TextField("Base URL", text: $draft.host, prompt: Text("https://api.example.com/v1"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SecureField("API Key", text: $draft.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            Text("The key is stored in the keychain on this device.")
        }
    }

    private var testSection: some View {
        Section {
            Button(action: runTest) {
                HStack {
                    Text("Test connection")
                    Spacer()
                    switch testState {
                    case .idle:        EmptyView()
                    case .running:     ProgressView()
                    case .reachable:   Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unreachable: Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
            .disabled(!draft.isValid || testState == .running)
        }
    }

    private func runTest() {
        testState = .running
        let endpoint = draft.endpoint
        Task {
            let ok = await LMStudioClient.shared.probeReachable(endpoint: endpoint)
            testState = ok ? .reachable : .unreachable
        }
    }

    private func save() {
        let server = draft.save(into: context, keychain: KeychainStore(), existing: existing)
        // Probe now so a just-added key flips "NO KEY" to live without waiting a poll cycle.
        Task { await reachability.checkOnce(server) }
        dismiss()
    }
}
