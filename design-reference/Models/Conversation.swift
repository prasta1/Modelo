import Foundation

/// A chat thread listed under the sidebar's "TODAY" section.
struct Conversation: Identifiable, Hashable {
    let id = UUID()
    var title: String           // "100 Words on Tacos"
    var time: String            // "21:24"
}
