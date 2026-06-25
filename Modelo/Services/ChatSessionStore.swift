import Foundation
import SwiftData

/// Owns the live `ChatSession` and its in-flight send/regenerate `Task` for each
/// conversation, keyed by `PersistentIdentifier`.
///
/// Held by `ContentView` as `@State` and injected into the environment. `ChatView`
/// is rebuilt with `.id(conversation.persistentModelID)` whenever the user switches
/// conversations, which would otherwise tear down a per-view `@State` session and
/// cancel its turn. Anchoring the session here lets a turn keep streaming after the
/// user leaves the chat — so several chats can stream at once. All access is on the
/// main actor, so concurrent turns interleave cooperatively (each awaits between
/// tokens) and append only to their own conversation.
@Observable @MainActor
final class ChatSessionStore {
    private var sessions: [PersistentIdentifier: ChatSession] = [:]
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]

    /// The session for a conversation, if one has been created.
    func session(for id: PersistentIdentifier) -> ChatSession? { sessions[id] }

    /// Stores the session for a conversation. Called once per conversation when the
    /// chat view first appears.
    func setSession(_ session: ChatSession, for id: PersistentIdentifier) {
        sessions[id] = session
    }

    /// Records the in-flight turn for a conversation, replacing any prior one.
    func setTask(_ task: Task<Void, Never>?, for id: PersistentIdentifier) {
        tasks[id] = task
    }

    /// Cancels the in-flight turn for a conversation, if any. Used by the chat's
    /// stop button; navigating away deliberately does *not* cancel.
    func cancelTask(for id: PersistentIdentifier) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    /// Drops a conversation's session and cancels its turn — call when the
    /// conversation is deleted so nothing keeps writing to a vanished model.
    func discard(_ id: PersistentIdentifier) {
        tasks[id]?.cancel()
        tasks[id] = nil
        sessions[id]?.cancelPendingWork()
        sessions[id] = nil
    }
}
