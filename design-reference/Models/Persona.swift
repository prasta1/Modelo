import Foundation

/// An optional system persona shown as a selectable card in the Model Browser.
struct Persona: Identifiable, Hashable {
    let id = UUID()
    var name: String            // "Coding"
    var traits: String          // "Precise · Pragmatic · Senior"
}
