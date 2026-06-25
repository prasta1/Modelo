import Foundation
import SwiftData
import UserNotifications
import AppKit

/// Posts a macOS user notification when a chat's reply finishes while the user
/// isn't watching it — the app is in the background, or a different chat (or
/// non-chat view) is on screen. Held by `ContentView` and injected; ContentView
/// keeps `foreground` in sync with the open conversation.
@Observable @MainActor
final class ChatNotifier {
    /// The conversation currently on screen, or nil for non-chat views. A reply
    /// that finishes here while the app is focused isn't worth interrupting.
    var foreground: PersistentIdentifier?

    /// Ask the OS for permission once, up front, so the first real notification
    /// isn't lost behind the permission prompt. No-op effect if already decided.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A reply just finished in `conversation`. Surface it unless the user is
    /// already looking at that chat with the app focused.
    func replyFinished(conversation id: PersistentIdentifier, title: String, snippet: String) {
        if NSApplication.shared.isActive, foreground == id { return }

        let body = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }   // an error or empty turn isn't a "reply"

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Reply ready" : title
        content.body = String(body.prefix(180))
        content.sound = .default
        // Immediate, one-shot (nil trigger); a fresh id so replies don't coalesce.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
