# Project Chat Nesting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nest a project's chats under its collapsible row in the sidebar instead of leaving them in the flat Pinned/date-bucket/Folder list.

**Architecture:** Extract the pure project/conversation matching logic (which chats belong to which project, and which chats should be excluded from the flat list) into a new testable `ProjectGrouping` enum, mirroring the existing `ConversationGrouping` pattern. Wire that logic into `SidebarView`: one new filter in `filteredConversations`, and a chevron + nested `conversationList` on each project row.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Testing (`@Test`/`#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-01-project-chat-nesting-design.md`

---

## File Structure

| File | Change |
|---|---|
| `Modelo/Modelo/Services/ProjectGrouping.swift` | Create — pure, testable project/conversation matching logic |
| `Modelo/ModeloTests/ProjectGroupingTests.swift` | Create — unit tests for the above |
| `Modelo/Modelo/Views/SidebarView.swift` | Modify — wire the exclusion filter into `filteredConversations`; add chevron + nesting to `projectRow`/`projectsSection` |

No changes to `Project.swift`, `ProjectStore.swift`, `Conversation.swift`, `ContentView.swift`, or `ProjectLandingView.swift` — confirmed in the spec.

**Note on the spec:** the spec sketched `isInCurrentProject` and `conversations(in: Project)` as private methods directly on `SidebarView`. This plan instead extracts them into `ProjectGrouping`, a standalone enum — the exact pattern the codebase already uses for `ConversationGrouping` ("Pure date-bucketing of conversations for the sidebar. Kept out of the view so the bucketing reads clearly and can be unit-tested."). Same behavior, just testable. The spec's `conversations(in: folder:)` priority reasoning (project-exclusion happens upstream in `filteredConversations`, so a chat with both `folder` and `projectPath` set never reaches folder filtering) is unaffected by this change.

---

### Task 1: Create a feature branch

**Files:** none

- [ ] **Step 1: Create and switch to the feature branch**

```bash
git checkout -b feature/project-chat-nesting
```

Expected: `Switched to a new branch 'feature/project-chat-nesting'`. (Any pre-existing uncommitted change to `Modelo/Services/MCPClient.swift` carries over harmlessly — this plan never touches that file.)

---

### Task 2: `ProjectGrouping` — pure matching logic

**Files:**
- Create: `Modelo/Modelo/Services/ProjectGrouping.swift`
- Test: `Modelo/ModeloTests/ProjectGroupingTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Modelo/ModeloTests/ProjectGroupingTests.swift`:

```swift
import Testing
import Foundation
@testable import Modelo

struct ProjectGroupingTests {
    private func convo(projectPath: String? = nil, pinned: Bool = false,
                        daysAgo: Int = 0, now: Date = Date()) -> Conversation {
        let c = Conversation(modelID: "m", serverID: nil)
        c.projectPath = projectPath
        c.isPinned = pinned
        c.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return c
    }

    private func project(path: String, name: String = "P") -> Project {
        Project(id: UUID(), name: name, path: path)
    }

    @Test func isInCurrentProject_trueWhenPathMatchesAProject() {
        let p = project(path: "/repo")
        let c = convo(projectPath: "/repo")
        #expect(ProjectGrouping.isInCurrentProject(c, projects: [p]))
    }

    @Test func isInCurrentProject_falseWhenNoProjectPath() {
        let c = convo(projectPath: nil)
        #expect(!ProjectGrouping.isInCurrentProject(c, projects: [project(path: "/repo")]))
    }

    @Test func isInCurrentProject_falseWhenPathMatchesNoProject() {
        // Orphaned: the project that created this chat has since been removed.
        let c = convo(projectPath: "/deleted-repo")
        #expect(!ProjectGrouping.isInCurrentProject(c, projects: [project(path: "/repo")]))
    }

    @Test func excludingCurrentProjects_dropsOnlyMatchedChats() {
        let p = project(path: "/repo")
        let inProject = convo(projectPath: "/repo")
        let orphaned = convo(projectPath: "/deleted-repo")
        let plain = convo(projectPath: nil)
        let result = ProjectGrouping.excludingCurrentProjects([inProject, orphaned, plain], projects: [p])
        #expect(result.count == 2)
        #expect(!result.contains { $0 === inProject })
        #expect(result.contains { $0 === orphaned })
        #expect(result.contains { $0 === plain })
    }

    @Test func conversationsInProject_filtersByPath() {
        let p = project(path: "/repo")
        let mine = convo(projectPath: "/repo")
        let other = convo(projectPath: "/other")
        let result = ProjectGrouping.conversations(in: p, from: [mine, other])
        #expect(result.count == 1)
        #expect(result.first === mine)
    }

    @Test func conversationsInProject_sortsPinnedFirstThenNewest() {
        let p = project(path: "/repo")
        let now = Date()
        let older = convo(projectPath: "/repo", pinned: false, daysAgo: 2, now: now)
        let newer = convo(projectPath: "/repo", pinned: false, daysAgo: 0, now: now)
        let pinnedOld = convo(projectPath: "/repo", pinned: true, daysAgo: 5, now: now)
        let result = ProjectGrouping.conversations(in: p, from: [older, newer, pinnedOld])
        #expect(result[0] === pinnedOld)
        #expect(result[1] === newer)
        #expect(result[2] === older)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project so the new test file is picked up**

```bash
cd /Users/prasta/Projects/apps/active/modelo && xcodegen generate
```

Expected: `Generated project at Modelo.xcodeproj`. (`sources: - ModeloTests` in `project.yml` globs the whole directory, so no `project.yml` edit is needed.)

- [ ] **Step 3: Run the new tests to verify they fail**

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:ModeloTests/ProjectGroupingTests test
```

Expected: **FAIL** — `cannot find 'ProjectGrouping' in scope` (the type doesn't exist yet).

- [ ] **Step 4: Write the implementation**

Create `Modelo/Modelo/Services/ProjectGrouping.swift`:

```swift
import Foundation

/// Pure helpers for associating conversations with their `Project` (if any). Kept
/// out of the view so the matching reads clearly and can be unit-tested, mirroring
/// `ConversationGrouping`.
enum ProjectGrouping {
    /// True when `convo.projectPath` matches a path in `projects` — i.e. it belongs
    /// to a project that's still present in the sidebar's Projects list. A chat
    /// whose project was later removed (path no longer in `projects`) reads false
    /// here, which is what lets it fall back into the flat conversation list.
    static func isInCurrentProject(_ convo: Conversation, projects: [Project]) -> Bool {
        guard let path = convo.projectPath else { return false }
        return projects.contains { $0.path == path }
    }

    /// `conversations` with every project-scoped one removed — the set that still
    /// belongs in the flat Pinned/date-bucket/Folder list.
    static func excludingCurrentProjects(_ conversations: [Conversation], projects: [Project]) -> [Conversation] {
        conversations.filter { !isInCurrentProject($0, projects: projects) }
    }

    /// `conversations` scoped to `project`, pinned ones first, then newest first.
    static func conversations(in project: Project, from all: [Conversation]) -> [Conversation] {
        all
            .filter { $0.projectPath == project.path }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.createdAt > rhs.createdAt
            }
    }
}
```

- [ ] **Step 5: Run the tests again to verify they pass**

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:ModeloTests/ProjectGroupingTests test
```

Expected: `** TEST SUCCEEDED **`, all 6 tests in `ProjectGroupingTests` passing.

- [ ] **Step 6: Commit**

```bash
git add Modelo/Modelo/Services/ProjectGrouping.swift Modelo/ModeloTests/ProjectGroupingTests.swift
git commit -m "feat(sidebar): add ProjectGrouping for matching chats to their project"
```

---

### Task 3: Exclude project chats from the flat Conversations list

**Files:**
- Modify: `Modelo/Modelo/Views/SidebarView.swift` (the `filteredConversations` computed property, currently around line 574)

- [ ] **Step 1: Replace `filteredConversations` to exclude current-project chats**

In `Modelo/Modelo/Views/SidebarView.swift`, find:

```swift
    private var filteredConversations: [Conversation] {
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { convo in
            convo.displayTitle.localizedCaseInsensitiveContains(query)
                || convo.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }
```

Replace with:

```swift
    private var filteredConversations: [Conversation] {
        let query = debouncedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty ? conversations : conversations.filter { convo in
            convo.displayTitle.localizedCaseInsensitiveContains(query)
                || convo.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
        return ProjectGrouping.excludingCurrentProjects(base, projects: projectStore.projects)
    }
```

(`projectStore` is already injected at the top of `SidebarView` via `@Environment(ProjectStore.self) private var projectStore` — no new wiring needed.)

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Modelo/Modelo/Views/SidebarView.swift
git commit -m "fix(sidebar): exclude project-scoped chats from the flat Conversations list"
```

---

### Task 4: Nest each project's chats under its sidebar row

**Files:**
- Modify: `Modelo/Modelo/Views/SidebarView.swift` (`projectRow`, currently lines 215-234, and the `projectsSection` `ForEach`, currently lines 199-210)

This task is UI layout with no SwiftData-relationship-free pure logic to extract (same reasoning `ConversationGrouping.swift`'s doc comment already gives for why folder/pinned grouping stays untested in the view), so verification here is build + manual check in the running app rather than a new unit test.

- [ ] **Step 1: Add a stable section-id helper and the expand/collapse chevron to `projectRow`**

In `Modelo/Modelo/Views/SidebarView.swift`, find:

```swift
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
```

Replace with:

```swift
    private func projectSectionID(_ project: Project) -> String { "project:" + project.id.uuidString }

    private func projectRow(_ project: Project) -> some View {
        let active = route == .project(project.id)
        let expanded = sectionExpanded(projectSectionID(project))
        return HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { toggleSection(projectSectionID(project)) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textMute)
                    .frame(width: 8)
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse project" : "Expand project")

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
        .background(active ? Theme.fill : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
    }
```

The chevron `Button` and the name/icon `HStack` are siblings inside the outer `HStack`, each with their own tap handling (`Button` action vs. `.onTapGesture`) — the same sibling-tap-targets pattern `projectsSection`'s header already uses for its toggle button and "add project" button, so the two gestures can't conflict.

- [ ] **Step 2: Nest the project's chats under the row in `projectsSection`**

In the same file, find:

```swift
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
```

Replace with:

```swift
                if projectStore.projects.isEmpty {
                    emptyLabel("No projects yet")
                } else {
                    ForEach(projectStore.projects) { project in
                        VStack(alignment: .leading, spacing: 0) {
                            projectRow(project)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        if case .project(let id) = route, id == project.id { route = nil }
                                        projectStore.remove(project)
                                    } label: {
                                        Label("Remove Project", systemImage: "trash")
                                    }
                                }
                            if sectionExpanded(projectSectionID(project)) {
                                let convos = ProjectGrouping.conversations(in: project, from: conversations)
                                if convos.isEmpty {
                                    emptyLabel("No chats yet")
                                } else {
                                    conversationList(convos)
                                }
                            }
                        }
                    }
                }
```

- [ ] **Step 3: Regenerate and build**

```bash
cd /Users/prasta/Projects/apps/active/modelo && xcodegen generate
xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual verification in the running app**

Launch the built app (`open build/Build/Products/Debug/Modelo.app`, or run from Xcode) and check:

1. Sidebar → Projects → add a project directory (the `+` button) if none exists.
2. Click the chevron on the project row: it collapses/expands; an empty project shows "No chats yet".
3. Click the project row's name/icon (not the chevron): navigates to the `ProjectLandingView` landing page, unchanged from before.
4. From the landing page, click "New Chat in `<project>`" — the new chat must appear **nested under the project row**, not in the main Conversations list below.
5. Pin that chat (right-click → Pin): it must stay nested under the project (sorted to the top of that project's list) and must **not** appear in the top-level "Pinned" section.
6. Remove the project (right-click the project row → "Remove Project"): the chat that was nested under it must now reappear in the normal Pinned/date-bucket/Folder list (the orphan fallback).
7. Collapse/expand state should survive closing and reopening the app (persisted via `collapsedRaw`).

- [ ] **Step 5: Commit**

```bash
git add Modelo/Modelo/Views/SidebarView.swift
git commit -m "feat(sidebar): nest project chats under their project row"
```

---

### Task 5: Final full-suite verification

**Files:** none

- [ ] **Step 1: Run the full test suite one more time**

```bash
xcodebuild -project Modelo.xcodeproj -scheme Modelo \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Push the feature branch**

```bash
git push -u origin feature/project-chat-nesting
```

(Per global convention, auto-push is allowed on `feature/*` branches.)
