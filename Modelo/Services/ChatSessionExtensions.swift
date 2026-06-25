import Foundation
import SwiftData
import Combine

/// Extensions to add enhanced features to ChatSession
extension ChatSession {
    /// Notification when streaming completes (success or failure)
    static let streamingCompleted = Notification.Name("ChatSession.streamingCompleted")
    /// Notification when streaming starts
    static let streamingStarted = Notification.Name("ChatSession.streamingStarted")
    /// Notification when tool call limit changes
    static let toolCallLimitChanged = Notification.Name("ChatSession.toolCallLimitChanged")
    
    /// Tool call limit for this session (configurable per chat)
    var maxToolRounds: Int = 5
    /// Global default for new sessions
    static var globalMaxToolRounds: Int = 5 {
        didSet {
            NotificationCenter.default.post(name: .toolCallLimitChanged, object: nil)
        }
    }
    
    /// Optional external notification handler for streaming completion
    var onStreamingCompleted: (() -> Void)? = nil
    /// Optional external notification handler for streaming start
    var onStreamingStarted: (() -> Void)? = nil
    
    /// Publisher for streaming state changes
    private var streamingStatePublisher = PassthroughSubject<Bool, Never>()
    var isStreamingPublisher: AnyPublisher<Bool, Never> {
        streamingStatePublisher.eraseToAnyPublisher()
    }
    
    /// Timer for checking global limit changes
    private var limitCheckTimer: Timer?
    
    /// Update the tool call limit for this session
    func updateToolCallLimit(_ limit: Int) {
        maxToolRounds = limit
    }
    
    /// Reset to global default
    func resetToolCallLimit() {
        maxToolRounds = Self.globalMaxToolRounds
    }
    
    /// Enhanced runTurn with notification support
    func enhancedRunTurn(in conversation: Conversation, server: Server,
                         modelSupportsTools: Bool,
                         sampling: SamplingParams,
                         contextWindow: Int,
                         firstAssistant: Message?,
                         titleOnFirstExchange: Bool) async {
        isStreaming = true
        streamingStatePublisher.send(true)
        NotificationCenter.default.post(name: .streamingStarted, object: self)
        onStreamingStarted?()
        defer {
            isStreaming = false
            streamingStatePublisher.send(false)
            NotificationCenter.default.post(name: .streamingCompleted, object: self)
            onStreamingCompleted?()
        }
        
        // Call the original runTurn method
        await runTurn(in: conversation, server: server,
                     modelSupportsTools: modelSupportsTools,
                     sampling: sampling, contextWindow: contextWindow,
                     firstAssistant: firstAssistant,
                     titleOnFirstExchange: titleOnFirstExchange)
    }
    
    deinit {
        limitCheckTimer?.invalidate()
    }
}

/// Timer for checking global limit changes
extension ChatSession {
    private func setupToolCallLimitTimer() {
        limitCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.maxToolRounds != Self.globalMaxToolRounds {
                    self.maxToolRounds = Self.globalMaxToolRounds
                }
            }
        }
    }
}