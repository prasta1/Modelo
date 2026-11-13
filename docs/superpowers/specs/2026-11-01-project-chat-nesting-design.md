# Project Chat Nesting — Design Spec

**Date:** 2026-11-01
**Status:** Approved

## Overview

Fix: starting a new chat from inside a Project (via "New Chat in `<project>`" on
`ProjectLandingView`) sets `Conversation.projectPath` for filesystem/memory tool
scoping, but the chat then renders in the normal flat Pinned/date-bucket/Folder
list — visually disconnected from the project it was created under. Project rows
in the sidebar are static leaves with no children.

This spec makes each Project row in the sidebar collapsible, listing its own
chats as nested children (mirroring how Folders already group chats), and
removes those chats from the main Conversations list entirely so each chat has
exactly one home.

## Data model

No schema change. `Conversation.projectPath: String?` is already the link to a
project; `Project.path` is immutable once added (`ProjectStore.addProject`
dedupes by path and there's no rename/edit path). So "chats belonging to
project X" is simply:

```swift
conversations.filter { $0.projectPath == project.path }
```

Matching is by **path**, not a stored project id — existing conversations
already have the right `projectPath` set, so no migration is needed.

## Behavior

### Nesting

- `projectRow(_:)` gains a chevron (same visual language as `sectionHeader`'s
  chevron) that toggles expand/collapse, persisted through the existing
  `collapsedRaw` AppStorage mechanism, keyed `"project:" + project.id.uuidString`
  (parallel to folders' `"folder:" + folder.id.uuidString"`).
- The chevron is its own tap target, a sibling to the rest of the row content
  inside the outer `HStack` — not a `Button` nested inside the row's
  `.onTapGesture` — following the same sibling-elements pattern already used in
  `projectsSection`'s header (toggle button + "add project" button as siblings).
  This avoids gesture-conflict bugs between the two tap regions.
- Tapping anywhere else on the row is unchanged: navigates to `.project(id)` →
  `ProjectLandingView`.
- When expanded, render that project's chats directly beneath the row using
  the existing `conversationList(_:)` / `ConversationRowView`, so rename,
  delete, "Rename with AI", pin, and "Move to Folder" all come for free with
  no new context-menu code.
- An expanded project with zero chats shows `emptyLabel("No chats yet")` —
  same pattern as an empty folder's `emptyLabel("Empty")`.

### Removal from the main Conversations list

`filteredConversations` (the base query everything else derives from) gains one
more exclusion: any conversation whose `projectPath` matches a **current**
project's path is dropped before the pinned/unpinned split.

```swift
private func isInCurrentProject(_ convo: Conversation) -> Bool {
    guard let path = convo.projectPath else { return false }
    return projectStore.projects.contains { $0.path == path }
}

private var filteredConversations: [Conversation] {
    let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = query.isEmpty ? conversations : conversations.filter { convo in
        convo.displayTitle.localizedCaseInsensitiveContains(query)
            || convo.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
    }
    return base.filter { !isInCurrentProject($0) }
}
```

Because `pinnedConversations`, `unpinnedConversations`, `conversations(in:
folder)`, and `unfiledDateBuckets` all derive from `filteredConversations`,
this one change is sufficient to pull project chats out of Pinned, date
buckets, and Folders simultaneously — no changes needed in those functions.

### Project-nested chat list

A separate accessor feeds the nested list under each project row, independent
of the search/exclusion filter above (project nesting is not currently
search-filtered — see Out of scope):

```swift
private func conversations(in project: Project) -> [Conversation] {
    conversations
        .filter { $0.projectPath == project.path }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
}
```

Pinned chats sort first within the project's own list (consistent with "pinning
is a within-project affordance now"); no new pin glyph is added to the row —
`ConversationRowView` doesn't currently render pin state for any row, and
adding one is out of scope here.

### Edge cases

- **Pinned project chats**: per the exclusion filter above, a pinned project
  chat never appears in the top-level Pinned section — only nested under its
  project, sorted first there.
- **Orphaned chats** (project removed via `ProjectStore.remove`, but old chats
  still carry the now-stale `projectPath`): `isInCurrentProject` only matches
  *current* `projectStore.projects`, so once a project disappears its old chats
  automatically fall back into the normal Pinned/date-bucket/Folder flow — no
  cleanup code needed, this falls out of the filter for free.
- **Project + Folder both set** on the same chat: `projectPath` wins for sidebar
  placement. `conversations(in: folder:)` only ever sees chats already excluded
  from `isInCurrentProject`, so a chat with both fields set renders nested under
  its project and never under the folder, with no explicit priority check
  needed — it's a consequence of the filter ordering above. `folder` stays set
  (inert) in case `projectPath` is ever cleared later.

## Implementation

### Files changed

| File | Change |
|---|---|
| `Modelo/Modelo/Views/SidebarView.swift` | Add chevron + expand/collapse to `projectRow`; nest `conversationList` under each expanded project row; add `isInCurrentProject(_:)` and `conversations(in: Project)`; add one `.filter` line to `filteredConversations` |

No changes to `Project.swift`, `ProjectStore.swift`, `Conversation.swift`,
`ContentView.swift`, or `ProjectLandingView.swift`.

### Sketch: `projectRow`

```swift
private func projectSectionID(_ project: Project) -> String { "project:" + project.id.uuidString }

private func projectRow(_ project: Project) -> some View {
    let active = route == .project(project.id)
    return HStack(spacing: 10) {
        Button {
            withAnimation(.snappy(duration: 0.2)) { toggleSection(projectSectionID(project)) }
        } label: {
            Image(systemName: sectionExpanded(projectSectionID(project)) ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textMute)
                .frame(width: 8)
        }
        .buttonStyle(.plain)

        HStack(spacing: 10) {
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
        .contentShape(Rectangle())
        .onTapGesture { route = .project(project.id) }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(active ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7))
}
```

### Sketch: `projectsSection` ForEach

```swift
ForEach(projectStore.projects) { project in
    VStack(alignment: .leading, spacing: 0) {
        projectRow(project)
            .contextMenu { /* existing "Remove Project" */ }
        if sectionExpanded(projectSectionID(project)) {
            let convos = conversations(in: project)
            if convos.isEmpty {
                emptyLabel("No chats yet")
            } else {
                conversationList(convos)
            }
        }
    }
}
```

## Out of scope

- Searching inside project-nested chats — the sidebar search field stays
  scoped to the main Conversations list; project chats are not search-matched.
  A chat that would've matched a search term but lives in a project simply
  won't surface. Revisit if this proves confusing in practice.
- Any UI to move a chat out of a project (clear `projectPath`).
- A pin glyph on rows (pin state already has no visual indicator on any row
  today; this spec doesn't add one).
- Renaming or editing a `Project`'s path after creation — `ProjectStore` has no
  such path today.
- Changes to `ProjectLandingView`'s existing "New Chat in Project" flow.
