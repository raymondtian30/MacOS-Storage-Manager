import XCTest
@testable import SpaceSenseCore

final class SpaceSenseTests: XCTestCase {
    func testVolumeStatsNotZero() {
        let stats = VolumeStats.currentBootVolume()
        XCTAssertGreaterThan(stats.totalBytes, 0)
    }
}
