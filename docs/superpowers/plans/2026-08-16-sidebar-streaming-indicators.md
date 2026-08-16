# Sidebar Streaming Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pulsing lime-green dot to background conversation rows while streaming, transitioning to a solid dot after completion until the chat is opened.

**Architecture:** Extract `conversationRow` from a function into a private `ConversationRowView` struct so each row can hold its own `@State`. The struct reads `ChatSession.isStreaming` via the `@Observable` `ChatSessionStore` — no new services or state hoisting needed. The dot lives in a fixed-width leading `ZStack` so the title never shifts.

**Tech Stack:** SwiftUI, `@Observable` (Swift 5.9+), existing `ChatSession`/`ChatSessionStore`

**Spec:** `docs/superpowers/specs/2026-08-16-sidebar-streaming-indicators-design.md`

---

## File Map

| File | Change |
|---|---|
| `Modelo/Modelo/Views/SidebarView.swift` | Extract `conversationRow` function → `ConversationRowView` struct; update `conversationList` call-site; delete old function; add dot state + UI |

---

### Task 1: Extract `conversationRow` into `ConversationRowView` struct

**Files:**
- Modify: `Modelo/Modelo/Views/SidebarView.swift` (lines 354–388, the `conversationList` and `conversationRow` functions)

This is a pure refactor — no behavioral change. The new struct receives the same data the function computed locally, and produces the identical view.

- [ ] **Step 1: Add `ConversationRowView` struct just above the `// MARK: - Search + partitioning` comment**

Insert the following block after the closing brace of `conversationRow` (currently at line 388) and before the `private var searchField` block:

```swift
/// A single conversation row. Extracted to a struct so each row can hold
/// its own @State for streaming/completion indicators.
private struct ConversationRowView: View {
    @Environment(ChatSessionStore.self) private var sessionStore

    let convo: Conversation
    let active: Bool
    let isRenaming: Bool
    let textScale: CGFloat
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
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
```

- [ ] **Step 2: Replace `conversationList` to use `ConversationRowView`**

Replace the existing `conversationList` function (lines 355–361):

```swift
// BEFORE
@ViewBuilder
private func conversationList(_ convos: [Conversation]) -> some View {
    ForEach(convos, id: \.persistentModelID) { convo in
        conversationRow(convo)
            .contextMenu { rowMenu(convo) }
    }
}
```

with:

```swift
// AFTER
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
```

- [ ] **Step 3: Delete the old `conversationRow` function**

Remove lines 363–388 (the entire `private func conversationRow(_ convo: Conversation) -> some View` function body and signature).

- [ ] **Step 4: Build and verify — no behavior change**

Use Xcode's build system or `XcodeRefreshCodeIssuesInFile` on `SidebarView.swift`. The sidebar should look and behave identically to before. Rows still tap, rename spinners still show, timestamps still appear.

- [ ] **Step 5: Commit**

```bash
git add Modelo/Modelo/Views/SidebarView.swift
git commit -m "refactor: extract conversationRow into ConversationRowView struct"
```

---

### Task 2: Add streaming/completion dot to `ConversationRowView`

**Files:**
- Modify: `Modelo/Modelo/Views/SidebarView.swift` — the `ConversationRowView` struct added in Task 1

- [ ] **Step 1: Add state properties and helpers to `ConversationRowView`**

Inside `ConversationRowView`, after the `let onTap: () -> Void` line and before `var body`, add:

```swift
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
```

- [ ] **Step 2: Replace the `HStack` in `ConversationRowView.body` with the complete version including the leading dot container**

Replace the entire `HStack { ... }` block (and all its modifiers through `.help(...)`) in `ConversationRowView.body` with:

```swift
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
```

- [ ] **Step 3: Add animation and state-transition modifiers**

Append these modifiers to the `HStack` in `ConversationRowView.body`, after `.help("Open conversation")`:

```swift
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
```

- [ ] **Step 4: Build and verify**

Use `XcodeRefreshCodeIssuesInFile` on `SidebarView.swift` to check for compiler errors. Then build the project with `BuildProject`. Confirm:
- No build errors or warnings from the new code
- The sidebar renders as before for idle conversations
- (Manually test by sending a message and switching chats to see the dot)

- [ ] **Step 5: Commit**

```bash
git add Modelo/Modelo/Views/SidebarView.swift
git commit -m "feat: add streaming/completion dot to background sidebar conversation rows"
```
