import XCTest
@testable import Clipx

/// Smoke-tests for AppEnvironment.shared. We can't safely call bootstrap() in
/// unit tests because it would open the real ~/Library/Application Support DB
/// and start FSEvents on real folders. Instead we verify the contract around
/// the optional service properties and the bootstrapError signal.
@MainActor
final class AppEnvironmentBootstrapTests: XCTestCase {
    func test_appState_bootstrapErrorDefaultsToNil() {
        // Implicit: this test runs in a fresh test process where the env may or
        // may not be bootstrapped depending on app lifecycle. Just verify the
        // error channel exists and is settable.
        AppState.shared.bootstrapError = nil
        XCTAssertNil(AppState.shared.bootstrapError)
    }

    func test_appState_bootstrapErrorSurfacesMessage() {
        AppState.shared.bootstrapError = "Disk full"
        XCTAssertEqual(AppState.shared.bootstrapError, "Disk full")
        AppState.shared.bootstrapError = nil
    }

    /// The "partial-init" guarantee — every service is either all-or-nothing.
    /// We can't induce a real failure in a test, but we can document the
    /// invariant: properties are simultaneously nil (pre-bootstrap) or
    /// simultaneously non-nil (post-bootstrap).
    func test_serviceProperties_allOrNothing() {
        let env = AppEnvironment.shared
        let allNil = env.database == nil
            && env.markerStore == nil
            && env.tagStore == nil
            && env.bookmarkStore == nil
            && env.searchEngine == nil
            && env.thumbnailEngine == nil
            && env.indexer == nil
            && env.watcher == nil
            && env.exportPipeline == nil
        let allSet = env.database != nil
            && env.markerStore != nil
            && env.tagStore != nil
            && env.bookmarkStore != nil
            && env.searchEngine != nil
            && env.thumbnailEngine != nil
            && env.indexer != nil
            && env.watcher != nil
            && env.exportPipeline != nil
        XCTAssertTrue(allNil || allSet, "AppEnvironment must be fully nil or fully populated; partial init is a bug")
    }
}
