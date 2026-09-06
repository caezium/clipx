import XCTest
@testable import Clipx

/// Menu and palette actions must reach the active player on the main queue.
/// The UI suite separately types marker letters into text fields to verify that
/// plain text input remains text, without depending on checkout source files.
final class NativeMenuActionTests: XCTestCase {
    @MainActor
    func test_markingCommandsReachThePlayerOnceOnMainQueue() async {
        let names: [Notification.Name] = [.markIn, .markOut, .saveRange]
        let expectations = names.map { expectation(description: $0.rawValue) }
        var observers: [NSObjectProtocol] = []
        for (name, expected) in zip(names, expectations) {
            expected.assertForOverFulfill = true
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                XCTAssertTrue(Thread.isMainThread)
                expected.fulfill()
            })
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        MarkerActions.markIn()
        MarkerActions.markOut()
        MarkerActions.saveRange()
        await fulfillment(of: expectations, timeout: 2)
    }

    @MainActor
    func test_frameCommandsReachThePlayerOnceOnMainQueue() async {
        let names: [Notification.Name] = [.playerStepBack, .playerStepForward]
        let expectations = names.map { expectation(description: $0.rawValue) }
        var observers: [NSObjectProtocol] = []
        for (name, expected) in zip(names, expectations) {
            expected.assertForOverFulfill = true
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                XCTAssertTrue(Thread.isMainThread)
                expected.fulfill()
            })
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        PlayerActions.stepBackward()
        PlayerActions.stepForward()
        await fulfillment(of: expectations, timeout: 2)
    }
}
