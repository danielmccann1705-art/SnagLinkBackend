@testable import App
import XCTVapor

/// Lane A P2: one photo processed at a time; a bounded wait ends in a retryable 503, never a 422.
final class ImageProcessingGateTests: XCTestCase {
    func testOneHolderAtATimeHandOffInOrderAndABoundedRetryableWait() async throws {
        let gate = ImageProcessingGate(wait: 300_000_000)
        try await gate.acquire()
        // A second request waits, then gets the gate the moment the first releases it.
        let order = OrderBox()
        let second = Task { try await gate.acquire(); await order.add("second acquired"); await gate.release() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await order.add("first releases"); await gate.release()
        try await second.value
        let seen = await order.items
        XCTAssertEqual(seen, ["first releases", "second acquired"])
        // A wait that reaches the bound is 503 media_unavailable.
        try await gate.acquire()
        let started = Date()
        do { try await gate.acquire(); XCTFail("a second holder must not get the gate") }
        catch let error as Abort {
            XCTAssertEqual(error.status, .serviceUnavailable); XCTAssertEqual(error.identifier, "media_unavailable")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        }
        await gate.release()
        // Free again: an acquire succeeds at once.
        try await gate.acquire(); await gate.release()
    }
}
private actor OrderBox { var items: [String] = []; func add(_ value: String) { items.append(value) } }
