import XCTest
@testable import Music_Haptics

/// The one-time playfield-fit migration (build 4): a stale/narrow persisted
/// fit from older builds must reset to the full screen, so the four-lane
/// field spans the whole display. After the migration runs once, later
/// stored values are left untouched (gameplay no longer reads them anyway).
@MainActor
final class PlayfieldFitMigrationTests: XCTestCase {

    private let keys = ["settings.playfieldFitX", "settings.playfieldFitY",
                        "settings.playfieldFitW", "settings.playfieldFitH",
                        "settings.playfieldFitResetBuild"]

    override func tearDown() {
        // Restore whatever the previous state was, so tests never leak state.
        let d = UserDefaults.standard
        for key in keys {
            d.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testStaleNarrowFitResetsToFullScreen() {
        let d = UserDefaults.standard
        // Simulate an old build's persisted narrow centered playfield
        // (the "one lane in the middle" state) with no reset marker yet.
        d.set(0.30, forKey: "settings.playfieldFitX")
        d.set(0.15, forKey: "settings.playfieldFitY")
        d.set(0.40, forKey: "settings.playfieldFitW")
        d.set(0.70, forKey: "settings.playfieldFitH")
        d.removeObject(forKey: "settings.playfieldFitResetBuild")

        let settings = SettingsStore()
        let fit = settings.playfieldFit
        XCTAssertEqual(fit.x, 0, accuracy: 1e-9)
        XCTAssertEqual(fit.y, 0, accuracy: 1e-9)
        XCTAssertEqual(fit.width, 1, accuracy: 1e-9)
        XCTAssertEqual(fit.height, 1, accuracy: 1e-9)
        // Marker persisted so the migration never runs again.
        XCTAssertEqual(d.integer(forKey: "settings.playfieldFitResetBuild"), 4)
    }

    func testUserFitAfterMigrationIsPreserved() {
        let d = UserDefaults.standard
        // Marker already at the current build: the migration must not run
        // again and must leave stored values untouched.
        d.set(4, forKey: "settings.playfieldFitResetBuild")
        d.set(0.10, forKey: "settings.playfieldFitX")
        d.set(0.20, forKey: "settings.playfieldFitY")
        d.set(0.80, forKey: "settings.playfieldFitW")
        d.set(0.60, forKey: "settings.playfieldFitH")

        let settings = SettingsStore()
        let fit = settings.playfieldFit
        XCTAssertEqual(fit.x, 0.10, accuracy: 1e-9)
        XCTAssertEqual(fit.width, 0.80, accuracy: 1e-9)
    }

    func testDefaultFullScreenIsUntouched() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "settings.playfieldFitX")
        d.removeObject(forKey: "settings.playfieldFitY")
        d.removeObject(forKey: "settings.playfieldFitW")
        d.removeObject(forKey: "settings.playfieldFitH")
        d.removeObject(forKey: "settings.playfieldFitResetBuild")

        let settings = SettingsStore()
        let fit = settings.playfieldFit
        XCTAssertEqual(fit, PlayfieldFit.full)
    }
}