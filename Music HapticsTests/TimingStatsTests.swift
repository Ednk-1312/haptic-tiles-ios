import XCTest
@testable import Music_Haptics

final class TimingStatsTests: XCTestCase {

    func testMeanMaxAndCount() {
        var stats = RollingStats()
        stats.add(10)
        stats.add(20)
        stats.add(30)
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.mean, 20, accuracy: 0.0001)
        XCTAssertEqual(stats.max, 30)
    }

    func testIncrementalMeanMatchesBatchMean() {
        let values: [Double] = [16.7, 33.3, 8.4, 21.1, 12.9, 18.2, 9.7]
        var stats = RollingStats()
        for v in values { stats.add(v) }
        let batchMean = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(stats.mean, batchMean, accuracy: 0.0001)
        XCTAssertEqual(stats.max, values.max() ?? 0)
    }

    func testReset() {
        var stats = RollingStats()
        stats.add(5)
        stats.reset()
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.mean, 0)
        XCTAssertEqual(stats.max, 0)
    }

    func testEmptyStatsAreZero() {
        let stats = RollingStats()
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.mean, 0)
        XCTAssertEqual(stats.max, 0)
    }

    func testNegativeValuesTrackedLikeAnyOther() {
        // Judgment deltas are signed; the engine feeds |delta| in, but the
        // helper itself must not assume positivity.
        var stats = RollingStats()
        stats.add(-12)
        stats.add(4)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.mean, -4, accuracy: 0.0001)
        XCTAssertEqual(stats.max, 4)
    }
}