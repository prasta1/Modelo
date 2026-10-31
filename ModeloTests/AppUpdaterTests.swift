import Sparkle
import XCTest
@testable import Modelo

final class AppUpdaterTests: XCTestCase {
    func testDoesNotStartUnderXCTest() {
        XCTAssertFalse(AppUpdater.shouldStart(environment: ["XCTestConfigurationFilePath": "/tests"]))
        XCTAssertFalse(AppUpdater.shouldStart(environment: ["XCTestConfigurationFilePath": ""]))
    }

    func testStartsNormally() {
        XCTAssertTrue(AppUpdater.shouldStart(environment: [:]))
    }

    @MainActor
    func testFeedOverride() throws {
        let suite = "AppUpdaterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = UpdaterFeedOverride(defaults: defaults)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil
        )
        XCTAssertNil(delegate.feedURLString(for: controller.updater))
        defaults.set("http://localhost:8000/appcast.xml", forKey: "ModeloDebugFeedURL")
        #if DEBUG
        XCTAssertEqual(delegate.feedURLString(for: controller.updater), "http://localhost:8000/appcast.xml")
        #else
        XCTAssertNil(delegate.feedURLString(for: controller.updater))
        #endif
    }

    func testReleasePolicy() {
        let info = Bundle.main.infoDictionary!
        XCTAssertNil(info["SUEnableAutomaticChecks"])
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUFeedURL"] as? String,
                       "https://github.com/prasta1/Modelo/releases/latest/download/appcast.xml")
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }
}
