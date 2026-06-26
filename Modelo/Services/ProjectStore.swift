import Foundation
import AppKit

/// Owns the list of user-added project directories.
/// Persisted as JSON in UserDefaults — no SwiftData schema change required.
@Observable
@MainActor
final class ProjectStore {
    private(set) var projects: [Project] = []
    private static let defaultsKey = "savedProjects"

    init() { load() }

    /// Presents an NSOpenPanel to pick a directory and appends it to the list.
    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a directory to add as a project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !projects.contains(where: { $0.path == url.path }) else { return }
        projects.append(Project(id: UUID(), name: url.lastPathComponent, path: url.path))
        save()
    }

    /// Removes the given project from the list.
    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
