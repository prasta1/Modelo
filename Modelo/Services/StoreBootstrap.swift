import Foundation
import SwiftData

/// Opens Modelo's SwiftData store. Shared by the Mac and iOS apps so both use the
/// same schema and the same never-delete recovery path.
enum StoreBootstrap {
    /// Every persisted model type. Both apps must open the store with this schema.
    static var schema: Schema {
        Schema([Server.self, Conversation.self, Message.self, UsageRecord.self, Persona.self, Folder.self, Preset.self])
    }

    /// `Application Support/Modelo/`, created if missing. A dedicated subfolder so
    /// SwiftData doesn't land in the shared `Application Support/default.store`.
    static var storeFolder: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Modelo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `storeFolder/Modelo.store`.
    static var storeURL: URL { storeFolder.appending(path: "Modelo.store") }

    /// Opens the SwiftData container, recovering from an unopenable store instead of
    /// crashing. (This was a `try!`: any open failure — e.g. a failed schema migration
    /// after a model change — killed the app at launch with no message at all.)
    ///
    /// Recovery moves the broken store files aside (never deletes them) and retries
    /// with a fresh store. If even the fresh store fails, the app still terminates,
    /// but the cause is now in the unified log first.
    /// - Returns: The container, plus the backup folder if recovery happened (so the
    ///   UI can tell the user where their previous data went).
    static func makeContainer(schema: Schema, storeFolder: URL, storeURL: URL) -> (ModelContainer, backupURL: URL?) {
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return (try ModelContainer(for: schema, configurations: [config]), nil)
        } catch {
            Log.data.fault("Failed to open store at \(storeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Move the whole store set aside with a timestamp so nothing is lost.
        // (Colons render as "/" in Finder; the UUID suffix keeps rapid re-launches
        // from colliding on a same-second folder name.)
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupFolder = storeFolder.appending(path: "Modelo.store.broken-\(stamp)-\(UUID().uuidString.prefix(8))",
                                                 directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = storeFolder.appending(path: "Modelo.store\(suffix)")
                if FileManager.default.fileExists(atPath: src.path) {
                    try FileManager.default.moveItem(at: src, to: backupFolder.appending(path: "Modelo.store\(suffix)"))
                }
            }
        } catch {
            // If the broken store can't be moved aside, a retry at the same URL just
            // hits the same corrupt file — there is nothing safe to run with, and
            // claiming recovery (or showing the backup alert) would be a lie.
            Log.data.fault("Could not move the broken store aside: \(error.localizedDescription, privacy: .public)")
            fatalError("Cannot back up the unopenable SwiftData store: \(error)")
        }

        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            Log.data.error("Recovered with a fresh store; previous data moved to \(backupFolder.path, privacy: .public)")
            return (container, backupFolder)
        } catch {
            Log.data.fault("Fresh store also failed to open: \(error.localizedDescription, privacy: .public)")
            fatalError("Cannot open or recreate the SwiftData store: \(error)")
        }
    }
}
