import Foundation

/// A saved reference to a local directory shown in the Projects sidebar section.
struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}
