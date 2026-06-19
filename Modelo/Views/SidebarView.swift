import SwiftUI
import SwiftData

/// Left column: brand wordmark, primary nav (Models / Status / Reports), server
/// reachability, and the conversation list. Conversations are organized as a
/// Pinned section, then user folders, then automatic date buckets (Today /
/// Yesterday / …) for everything unfiled.
///
/// Native Refined layout (handoff §3): a `ScrollView` over `Theme.sidebarBG`
/// rather than a `List`, since the system sidebar style can't reach this look.
/// Selection is driven manually by writing `route` / `endpointFilter` on tap.
struct SidebarView: View {
    @Environment(ServerRegistry.self) private var registry
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.sortOrder) private var servers: [Server]
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Binding var route: SidebarRoute?
    @Binding var endpointFilter: UUID?
    var renamingIDs: Set<PersistentIdentifier> = []
    var onRenameWithAI: (Conversation) -> Void = { _ in }
    @State private var searchText = ""
    /// Debounced mirror of `searchText` that the filter reads. Updated ~250ms
    /// after typing stops via the `.task(id: searchText)` in `body`.
    @State private var debouncedSearch = ""

    // Folder create / rename are driven by alerts with a text field.
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    /// When set, a freshly created folder also files this conversation (the
    /// "New Folder…" path inside a row's Move-to-Folder menu).
    @State private var pendingFolderConversation: Conversation?
    @State private var showRenameFolderAlert = false
    @State private var renameFolderName = ""
    @State private var renameTarget: Folder?

    /// Collapsed section IDs, newline-joined for `@AppStorage`. Absent ⇒ expanded.
    @AppStorage("collapsedSidebarSections") private var collapsedRaw = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                VStack(spacing: 2) {
                    navRow("Models",  icon: "square.grid.2x2",           to: .launcher)
                    navRow("Status",  icon: "chart.bar",                 to: .status)
                    navRow("Reports", icon: "chart.line.uptrend.xyaxis", to: .reports)
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
        .task(id: searchText) {
            // Debounce: searchText stays bound to the field so typing is live,
            // but re-running filteredConversations on every keystroke faults in
            // every message of every conversation — a visible hang once history
            // grows. Wait ~250ms of quiet, then commit the query. A fresh
            // keystroke cancels this task (the sleep throws), so we skip the
            // assignment rather than filtering on a half-typed query.
            guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
            debouncedSearch = searchText
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { pendingFolderConversation = nil }
        }
        .alert("Rename Folder", isPresented: $showRenameFolderAlert) {
            TextField("Folder name", text: $renameFolderName)
            Button("Save") { renameFolder() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        Button { route = .launcher } label: {
            HStack(spacing: 10) {
                ModeloMark(size: 19).frame(width: 22, height: 22)
                Text("MODELO")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(2.8)
                    .foregroundStyle(Theme.textBright)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .help("Go to launcher")
        .padding(.horizontal, 6)
        .padding(.bottom, 24)
    }

    // MARK: - Primary nav

    private func navRow(_ title: String, icon: String, to dest: SidebarRoute) -> some View {
        let active = route == dest
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
        .onTapGesture { route = dest }
    }

    // MARK: - Servers

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Servers")
                Spacer()
                Text("\(onlineCount) LIVE")
                    .font(.mono(10))
                    .foregroundStyle(Theme.green)
            }
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .padding(.bottom, 8)

            ForEach(servers) { server in
                serverRow(server)
            }
        }
    }

    /// Server row with the Native Refined treatment, but reading live state: the
    /// dot is a real reachability `StatusLED`, the title is `server.label`, and the
    /// active state mirrors the endpoint filter rather than a mock selection.
    private func serverRow(_ server: Server) -> some View {
        let active = endpointFilter == server.id
        let status = registry.status(for: server)
        return HStack(spacing: 9) {
            StatusLED(status: status, size: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textBright)
                    .lineLimit(1)
                Text(server.host)
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.textDim)
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
        .onTapGesture {
            endpointFilter = server.id
            route = nil
        }
    }

    private var onlineCount: Int {
        servers.filter { registry.isOnline($0) }.count
    }

    // MARK: - Conversations

    @ViewBuilder
    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Conversations")
                Spacer()
                Button {
                    pendingFolderConversation = nil
                    newFolderName = ""
                    showNewFolderAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMute)
                }
                .buttonStyle(.plain)
                .help("New folder")
            }
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .padding(.bottom, 10)

            searchField
                .padding(.bottom, 14)

            if conversations.isEmpty {
                emptyLabel("No conversations yet")
            } else if filteredConversations.isEmpty {
                emptyLabel("No matches")
            } else {
                conversationSections
            }
        }
    }

    @ViewBuilder
    private var conversationSections: some View {
        // Pinned
        if !pinnedConversations.isEmpty {
            sectionHeader(id: "pinned", title: "Pinned", icon: "pin", count: pinnedConversations.count)
            if sectionExpanded("pinned") {
                conversationList(pinnedConversations)
            }
        }

        // User folders
        ForEach(visibleFolders, id: \.persistentModelID) { folder in
            let convos = conversations(in: folder)
            let sectionID = "folder:" + folder.id.uuidString
            sectionHeader(id: sectionID, title: folder.name, icon: "folder", count: convos.count)
                .contextMenu { folderMenu(folder) }
            if sectionExpanded(sectionID) {
                if convos.isEmpty {
                    emptyLabel("Empty")
                } else {
                    conversationList(convos)
                }
            }
        }

        // Automatic date buckets (Today / Yesterday / …)
        ForEach(unfiledDateBuckets) { bucket in
            sectionHeader(id: bucket.id, title: bucket.title, count: bucket.conversations.count)
            if sectionExpanded(bucket.id) {
                conversationList(bucket.conversations)
            }
        }
    }

    /// A tappable, collapsible section header: chevron, optional icon, eyebrow
    /// title, and a trailing count. Toggling persists via `collapsedRaw`.
    private func sectionHeader(id: String, title: String, icon: String? = nil, count: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { toggleSection(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sectionExpanded(id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textMute)
                    .frame(width: 8)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textMute)
                }
                Eyebrow(title)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.mono(9))
                    .foregroundStyle(Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Shared row rendering used by the pinned, folder, and date sections.
    @ViewBuilder
    private func conversationList(_ convos: [Conversation]) -> some View {
        ForEach(convos, id: \.persistentModelID) { convo in
            conversationRow(convo)
                .contextMenu { rowMenu(convo) }
        }
    }

    private func conversationRow(_ convo: Conversation) -> some View {
        let active = route == .conversation(convo.persistentModelID)
        let isRenaming = renamingIDs.contains(convo.persistentModelID)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(convo.displayTitle)
                .font(.system(size: 12.5))
                .foregroundStyle(active ? Theme.textHi : Theme.textSoft)
                .lineLimit(1)
            if isRenaming {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
            Spacer(minLength: 0)
            Text(timestampLabel(for: convo.createdAt))
                .font(.mono(9.5))
                .foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(active ? Theme.fill : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { route = .conversation(convo.persistentModelID) }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            TextField("Search messages", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textHi)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
            .stroke(Color.white.opacity(0.05)))
    }

    private func emptyLabel(_ text: String) -> some View {
        Text(text)
            .font(.mono(11))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    // MARK: - Row + folder context menus

    @ViewBuilder
    private func rowMenu(_ convo: Conversation) -> some View {
        Button {
            convo.isPinned.toggle()
            try? context.save()
        } label: {
            Label(convo.isPinned ? "Unpin" : "Pin",
                  systemImage: convo.isPinned ? "pin.slash" : "pin")
        }

        Menu {
            ForEach(folders, id: \.persistentModelID) { folder in
                Button {
                    convo.folder = folder
                    try? context.save()
                } label: {
                    if convo.folder?.persistentModelID == folder.persistentModelID {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !folders.isEmpty { Divider() }
            Button {
                pendingFolderConversation = convo
                newFolderName = ""
                showNewFolderAlert = true
            } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
            if convo.folder != nil {
                Divider()
                Button {
                    convo.folder = nil
                    try? context.save()
                } label: { Label("Remove from Folder", systemImage: "folder.badge.minus") }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }

        Divider()
        Button {
            onRenameWithAI(convo)
        } label: { Label("Rename with AI", systemImage: "sparkles") }
        .disabled(renamingIDs.contains(convo.persistentModelID))

        Divider()
        Button("Delete", role: .destructive) { delete(convo) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button {
            renameTarget = folder
            renameFolderName = folder.name
            showRenameFolderAlert = true
        } label: { Label("Rename", systemImage: "pencil") }
        Button(role: .destructive) {
            deleteFolder(folder)
        } label: { Label("Delete Folder", systemImage: "trash") }
    }

    // MARK: - Search + partitioning

    /// Conversations after the search filter. Empty query ⇒ everything (cheap);
    /// otherwise match the title or any message body (case-insensitive). Titles
    /// are LLM-generated, so message content is the reliable signal.
    private var filteredConversations: [Conversation] {
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { convo in
            convo.displayTitle.localizedCaseInsensitiveContains(query)
                || convo.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    private var searchActive: Bool {
        !debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pinnedConversations: [Conversation] {
        filteredConversations.filter(\.isPinned)
    }

    private var unpinnedConversations: [Conversation] {
        filteredConversations.filter { !$0.isPinned }
    }

    private func conversations(in folder: Folder) -> [Conversation] {
        unpinnedConversations.filter { $0.folder?.persistentModelID == folder.persistentModelID }
    }

    /// Folders shown in the list: all of them normally, but during an active
    /// search only those with matching conversations (so empty folders don't add
    /// noise to results).
    private var visibleFolders: [Folder] {
        guard searchActive else { return folders }
        return folders.filter { !conversations(in: $0).isEmpty }
    }

    private var unfiledDateBuckets: [ConversationBucket] {
        let unfiled = unpinnedConversations.filter { $0.folder == nil }
        return ConversationGrouping.dateBuckets(unfiled, now: Date())
    }

    // MARK: - Collapsed-section persistence

    private func sectionExpanded(_ id: String) -> Bool {
        !collapsedRaw.split(separator: "\n").contains(Substring(id))
    }

    private func toggleSection(_ id: String) {
        var ids = Set(collapsedRaw.split(separator: "\n").map(String.init))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        collapsedRaw = ids.sorted().joined(separator: "\n")
    }

    // MARK: - Folder actions

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: name.isEmpty ? "New Folder" : name, sortOrder: folders.count)
        context.insert(folder)
        if let convo = pendingFolderConversation {
            convo.folder = folder
        }
        pendingFolderConversation = nil
        try? context.save()
    }

    private func renameFolder() {
        guard let folder = renameTarget else { return }
        let name = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            folder.name = name
            try? context.save()
        }
        renameTarget = nil
    }

    /// Deletes the folder only. The `.nullify` delete rule un-files its
    /// conversations (they fall back to date buckets) rather than deleting them.
    private func deleteFolder(_ folder: Folder) {
        context.delete(folder)
        try? context.save()
    }

    private func delete(_ convo: Conversation) {
        if case .conversation(let id) = route, id == convo.persistentModelID {
            route = nil
        }
        context.delete(convo)
        try? context.save()
    }

    // MARK: - Timestamps

    /// HH:mm for today, "MMM d" within this year, "MMM d, yyyy" beyond. Independent
    /// of grouping so rows read the same in any section.
    private func timestampLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return Theme.timeFormatter.string(from: date)
        }
        let year = cal.component(.year, from: date)
        let thisYear = cal.component(.year, from: Date())
        return year == thisYear
            ? Self.shortDateFormatter.string(from: date)
            : Self.longDateFormatter.string(from: date)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}
