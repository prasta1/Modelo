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
    @Environment(ChatSessionStore.self) private var sessionStore
    @Environment(ProjectStore.self) private var projectStore
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Binding var route: SidebarRoute?
    @Binding var endpointFilter: UUID?
    var renamingIDs: Set<PersistentIdentifier> = []
    var onNewChat: () -> Void = { }
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
    @AppStorage("messageFontSize") private var messageFontSize: Double = 15
    @AppStorage("showPersonasInSidebar") private var showPersonasInSidebar = true
    private var textScale: CGFloat { messageFontSize / 15 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                newChatButton
                    .padding(.bottom, 8)

                VStack(spacing: 2) {
                    navRow("Models",   icon: "square.grid.2x2",           to: .launcher)
                    if showPersonasInSidebar {
                        navRow("Personas", icon: "person.2",              to: .personas)
                    }
                    navRow("Status",   icon: "chart.bar",                 to: .status)
                    navRow("Reports",  icon: "chart.line.uptrend.xyaxis", to: .reports)
                    navRow("Settings", icon: "gearshape",                 to: .settings)
                }

                projectsSection
                conversationsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 22)
            .hideScrollIndicators()
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
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

    // MARK: - New chat

    private var newChatButton: some View {
        Button(action: onNewChat) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .medium))
                Text("New Chat")
                    .font(.system(size: 13 * textScale, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.amber)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Theme.amber.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                .stroke(Theme.amber.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("New chat (⌘N)")
    }

    // MARK: - Primary nav

    private func navRow(_ title: String, icon: String, to dest: SidebarRoute) -> some View {
        let active = route == dest
        return HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13 * textScale))
                .frame(width: 15, height: 15)
            Text(title).font(.system(size: 13 * textScale, weight: .medium))
        }
        .foregroundStyle(active ? Theme.textHi : Theme.textMute)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Theme.fillHi : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
        .onTapGesture { route = dest }
        .help("Go to \(title)")
    }

    // MARK: - Projects

    @ViewBuilder
    private var projectsSection: some View {
        let expanded = sectionExpanded("§projects")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { toggleSection("§projects") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textMute)
                            .frame(width: 8)
                        Eyebrow("Projects")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse Projects" : "Expand Projects")
                Spacer()
                Button { projectStore.addProject() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMute)
                }
                .buttonStyle(.plain)
                .help("Add project directory")
            }
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .padding(.bottom, 10)

            if expanded {
                if projectStore.projects.isEmpty {
                    emptyLabel("No projects yet")
                } else {
                    ForEach(projectStore.projects) { project in
                        projectRow(project)
                            .contextMenu {
                                Button(role: .destructive) {
                                    if case .project(let id) = route, id == project.id { route = nil }
                                    projectStore.remove(project)
                                } label: {
                                    Label("Remove Project", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let active = route == .project(project.id)
        return HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .frame(width: 14)
                .foregroundStyle(active ? Theme.amber : Theme.textDim)
            Text(project.name)
                .font(.system(size: 12.5 * textScale))
                .foregroundStyle(active ? Theme.textHi : Theme.textSoft)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(active ? Theme.fill : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { route = .project(project.id) }
    }

    // MARK: - Conversations

    @ViewBuilder
    private var conversationsSection: some View {
        let expanded = sectionExpanded("§conversations")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { toggleSection("§conversations") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textMute)
                            .frame(width: 8)
                        Eyebrow("Conversations")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse Conversations" : "Expand Conversations")
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

            if expanded {
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
        .help(sectionExpanded(id) ? "Collapse section" : "Expand section")
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Shared row rendering used by the pinned, folder, and date sections.
    @ViewBuilder
    private func conversationList(_ convos: [Conversation]) -> some View {
        ForEach(convos, id: \.persistentModelID) { convo in
            ConversationRowView(
                convo: convo,
                active: route == .conversation(convo.persistentModelID),
                isRenaming: renamingIDs.contains(convo.persistentModelID),
                textScale: textScale,
                onTap: { route = .conversation(convo.persistentModelID) }
            )
            .contextMenu { rowMenu(convo) }
        }
    }

    /// A single conversation row. Extracted to a struct so each row can hold
    /// its own @State for streaming/completion indicators.
    private struct ConversationRowView: View {
        @Environment(ChatSessionStore.self) private var sessionStore

        let convo: Conversation
        let active: Bool
        let isRenaming: Bool
        let textScale: CGFloat
        let onTap: () -> Void

        @State private var hasUnviewedCompletion = false
        @State private var pulseOpacity: Double = 1.0

        private static let limeGreen = Color(red: 0.6, green: 1.0, blue: 0.0)

        /// True when this conversation's session is actively streaming.
        private var isStreaming: Bool {
            sessionStore.session(for: convo.persistentModelID)?.isStreaming ?? false
        }

        /// Show the dot only for background chats that are streaming or have an
        /// unread completion. Active (selected) chats already show state in the
        /// chat view itself.
        private var showDot: Bool { !active && (isStreaming || hasUnviewedCompletion) }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Fixed-width container keeps the title position stable in all states.
                ZStack {
                    if showDot {
                        Circle()
                            .fill(Self.limeGreen)
                            .frame(width: 5, height: 5)
                            .opacity(isStreaming ? pulseOpacity : 1.0)
                    }
                }
                .frame(width: 9)

                Text(convo.displayTitle)
                    .font(.system(size: 12.5 * textScale))
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
            .onTapGesture { onTap() }
            .help("Open conversation")
            // Start pulse immediately if the row appears while already streaming.
            .onAppear {
                guard isStreaming && !active else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulseOpacity = 0.2
                }
            }
            // React to streaming transitions:
            // true→false in background → mark unviewed completion, stop pulse.
            // false→true in background → start pulse.
            .onChange(of: isStreaming) { wasStreaming, nowStreaming in
                if wasStreaming && !nowStreaming && !active {
                    hasUnviewedCompletion = true
                }
                withAnimation(nowStreaming && !active
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default) {
                    pulseOpacity = (nowStreaming && !active) ? 0.2 : 1.0
                }
            }
            // Opening the chat clears the unviewed-completion badge.
            .onChange(of: active) { _, nowActive in
                if nowActive { hasUnviewedCompletion = false }
            }
        }

        // MARK: - Timestamp

        private static let shortDateFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "MMM d"; return f
        }()

        private static let longDateFormatter: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
        }()

        private func timestampLabel(for date: Date) -> String {
            let cal = Calendar.current
            if cal.isDateInToday(date) { return Theme.timeFormatter.string(from: date) }
            let year = cal.component(.year, from: date)
            let thisYear = cal.component(.year, from: Date())
            return year == thisYear
                ? Self.shortDateFormatter.string(from: date)
                : Self.longDateFormatter.string(from: date)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            TextField("Search messages", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5 * textScale))
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
            context.saveOrLog()
        } label: {
            Label(convo.isPinned ? "Unpin" : "Pin",
                  systemImage: convo.isPinned ? "pin.slash" : "pin")
        }

        Menu {
            ForEach(folders, id: \.persistentModelID) { folder in
                Button {
                    convo.folder = folder
                    context.saveOrLog()
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
                    context.saveOrLog()
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
        context.saveOrLog()
    }

    private func renameFolder() {
        guard let folder = renameTarget else { return }
        let name = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            folder.name = name
            context.saveOrLog()
        }
        renameTarget = nil
    }

    /// Deletes the folder only. The `.nullify` delete rule un-files its
    /// conversations (they fall back to date buckets) rather than deleting them.
    private func deleteFolder(_ folder: Folder) {
        context.delete(folder)
        context.saveOrLog()
    }

    private func delete(_ convo: Conversation) {
        if case .conversation(let id) = route, id == convo.persistentModelID {
            route = nil
        }
        // Cancel and drop any streaming session so it can't keep writing to the
        // now-deleted conversation (it no longer gets torn down by leaving the chat).
        sessionStore.discard(convo.persistentModelID)
        context.delete(convo)
        context.saveOrLog()
    }

}
