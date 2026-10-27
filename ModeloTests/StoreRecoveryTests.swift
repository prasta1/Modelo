import XCTest
import SwiftData
@testable import Modelo

/// Exercises `StoreBootstrap.makeContainer`'s recovery path (was a `try!` that killed the
/// app at launch with no message when the store couldn't be opened).
final class StoreRecoveryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "StoreRecoveryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var schema: Schema { StoreBootstrap.schema }

    func test_makeContainer_opensHealthyStoreWithoutRecovery() {
        let storeURL = folder.appending(path: "Modelo.store")
        let (_, backupURL) = StoreBootstrap.makeContainer(schema: schema, storeFolder: folder, storeURL: storeURL)
        XCTAssertNil(backupURL, "a fresh folder must open without triggering recovery")
    }

    func test_makeContainer_recoversFromCorruptStore() throws {
        // A file that is definitely not SQLite: container creation must fail on it.
        let storeURL = folder.appending(path: "Modelo.store")
        try Data(repeating: 0xAB, count: 4096).write(to: storeURL)

        let (container, backupURL) = StoreBootstrap.makeContainer(schema: schema, storeFolder: folder, storeURL: storeURL)

        // The corrupt store must be moved aside — preserved, not deleted.
        let backup = try XCTUnwrap(backupURL, "recovery must report the backup location")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appending(path: "Modelo.store").path),
                      "corrupt store file must exist in the backup folder")

        // The replacement store must be usable end to end.
        let ctx = ModelContext(container)
        ctx.insert(Server(label: "t", host: "localhost", port: 1, sortOrder: 0))
        XCTAssertNoThrow(try ctx.save())
    }
}
