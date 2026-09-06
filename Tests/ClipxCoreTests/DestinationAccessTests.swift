import XCTest
@testable import Clipx

final class DestinationAccessTests: XCTestCase {
    func testPickedDestinationSurvivesResolutionAndClear() throws {
        let suite = "clipx-destination-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try MediaRegressionTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try DestinationAccess.remember(folder, for: .exportFolder, defaults: defaults)
        let lease = try XCTUnwrap(DestinationAccess.resolve(.exportFolder, defaults: defaults))
        XCTAssertEqual(lease.url.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        let output = lease.url.appendingPathComponent("probe.txt")
        try Data("writable".utf8).write(to: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNotNil(defaults.data(forKey: DestinationAccess.Location.exportFolder.bookmarkKey))
        DestinationAccess.clear(.exportFolder, defaults: defaults)
        XCTAssertNil(try DestinationAccess.resolve(.exportFolder, defaults: defaults))
    }
}
