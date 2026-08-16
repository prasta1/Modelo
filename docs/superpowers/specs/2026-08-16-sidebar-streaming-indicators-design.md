# Sidebar Streaming Indicators — Design Spec

**Date:** 2026-08-16  
**Status:** Approved

## Overview

Add a small lime-green dot to conversation rows in the sidebar to indicate when a background chat is actively streaming or has finished and is waiting to be read.

## Behavior

### When indicators show

Both indicators are **background-only** — they only appear on conversations that are NOT the currently selected route. The active chat already provides visual feedback in the chat view itself.

### Streaming state

- A 5pt lime-green circle with a repeating opacity pulse (1.0 → 0.2, easeInOut, ~0.7s, autoreverses)
- Shown while `ChatSession.isStreaming == true` for this conversation and the conversation is not active

### Completed state

- Same 5pt lime-green circle, solid (no animation)
- Appears when `isStreaming` transitions `true → false` while the conversation is in the background
- Persists until the user navigates to that conversation (clears on `active → true`)
- Does **not** survive app restarts (transient UI state only)

### Idle state

- No dot, but the leading container is still fixed-width (9pt) so the title text position is stable across all states

## Implementation

### Extract `conversationRow` into `ConversationRowView`

The existing `conversationRow(_ convo: Conversation)` function in `SidebarView` is converted to a private `ConversationRowView: View` struct. This is required so each row can hold its own `@State`:

- `@State private var hasUnviewedCompletion: Bool = false`
- `@State private var pulseOpacity: Double = 1.0`

### Data wiring

`ConversationRowView` receives:

| Parameter | Type | Source |
|---|---|---|
| `convo` | `Conversation` | ForEach iteration |
| `active` | `Bool` | `route == .conversation(convo.persistentModelID)` |
| `isRenaming` | `Bool` | `renamingIDs.contains(convo.persistentModelID)` |
| `textScale` | `CGFloat` | Passed from parent |
| `sessionStore` | `ChatSessionStore` | Via `@Environment` on the struct |
| `route` | `Binding<SidebarRoute?>` | Passed from parent |

`isStreaming` is derived inside the struct:

```swift
private var isStreaming: Bool {
    sessionStore.session(for: convo.persistentModelID)?.isStreaming ?? false
}
```

Since `ChatSession` and `ChatSessionStore` are both `@Observable`, reading `isStreaming` in the view body automatically establishes a live dependency — no manual subscriptions needed.

### State transitions

```swift
// Detect streaming completion while in background
.onChange(of: isStreaming) { wasStreaming, nowStreaming in
    if wasStreaming && !nowStreaming && !active {
        hasUnviewedCompletion = true
    }
}

// Clear unviewed completion when user opens the chat
.onChange(of: active) { _, nowActive in
    if nowActive { hasUnviewedCompletion = false }
}
```

### Pulse animation

```swift
.onAppear {
    if isStreaming {
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.2
        }
    }
}
.onChange(of: isStreaming) { _, nowStreaming in
    withAnimation(nowStreaming
        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
        : .default) {
        pulseOpacity = nowStreaming ? 0.2 : 1.0
    }
}
```

### Color

Lime green defined as a local constant (or added to `Theme`):

```swift
private let limeGreen = Color(red: 0.6, green: 1.0, blue: 0.0)
```

### Row layout

```swift
HStack(alignment: .firstTextBaseline, spacing: 10) {
    // Fixed-width leading container — stable width regardless of dot state
    ZStack {
        if !active && (isStreaming || hasUnviewedCompletion) {
            Circle()
                .fill(limeGreen)
                .frame(width: 5, height: 5)
                .opacity(isStreaming ? pulseOpacity : 1.0)
        }
    }
    .frame(width: 9, height: 9)

    Text(convo.displayTitle)
        ...
    if isRenaming { ProgressView()... }
    Spacer(minLength: 0)
    Text(timestampLabel(for: convo.createdAt))
        ...
}
```

## Files changed

| File | Change |
|---|---|
| `Modelo/Modelo/Views/SidebarView.swift` | Extract `conversationRow` into `ConversationRowView` struct; add dot logic |

No other files need to change. `ChatSession.isStreaming` and `ChatSessionStore.session(for:)` already exist and are correctly `@Observable`.

## Out of scope

- Indicator in the active (selected) conversation row — the chat view already covers this
- Persistence across app restarts — transient state is sufficient
- Error state indicator (streaming failed) — a separate concern
