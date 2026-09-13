import XCTest
@testable import Music_Haptics

final class PipelineStatusTests: XCTestCase {
    func testActiveStatusClampsProgressAndIsActive() {
        let low = PipelineStatus.active(.analyzing, progress: -2, message: "Listening")
        let high = PipelineStatus.active(.designingChart, progress: 3, message: "Designing")

        XCTAssertEqual(low.progress, 0)
        XCTAssertEqual(high.progress, 1)
        XCTAssertTrue(low.isActive)
        XCTAssertTrue(high.isActive)
    }

    func testTerminalStatusesAreNotActive() {
        XCTAssertFalse(PipelineStatus.idle.isActive)
        XCTAssertFalse(PipelineStatus(stage: .ready, progress: 1,
                                      message: "Ready", errorMessage: nil).isActive)
        XCTAssertFalse(PipelineStatus(stage: .cancelled, progress: 0,
                                      message: "Cancelled", errorMessage: nil).isActive)
    }

    func testFailurePreservesUserFacingError() {
        let status = PipelineStatus.failed("The audio decoder could not open this file.")

        XCTAssertEqual(status.stage, .failed)
        XCTAssertEqual(status.progress, 1)
        XCTAssertEqual(status.errorMessage, "The audio decoder could not open this file.")
        XCTAssertFalse(status.isActive)
    }
}
