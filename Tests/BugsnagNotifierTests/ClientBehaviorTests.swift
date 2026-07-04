import BugsnagNotifier
import Foundation
import XCTest

final class ClientBehaviorTests: XCTestCase {
    private func makeEvent() -> BugsnagEvent {
        BugsnagEvent(exceptions: [BugsnagException(errorClass: "E", message: "m")])
    }

    // MARK: - Release-stage gating

    func testExcludedReleaseStageNeverPosts() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "development",
                enabledReleaseStages: ["production", "staging"],
                synchronous: true
            ),
            transport: transport
        )
        await client.send(makeEvent())
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "excluded stage must not attempt a POST")
    }

    func testIncludedReleaseStagePosts() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "staging",
                enabledReleaseStages: ["production", "staging"],
                synchronous: true
            ),
            transport: transport
        )
        await client.send(makeEvent())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - onBeforeNotify

    func testOnBeforeNotifyCanVeto() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                synchronous: true,
                onBeforeNotify: { _ in false }
            ),
            transport: transport
        )
        await client.send(makeEvent())
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOnBeforeNotifyCanMutate() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                synchronous: true,
                onBeforeNotify: { event in
                    event.severity = .info
                    event.context = "overridden"
                    return true
                }
            ),
            transport: transport
        )
        await client.send(makeEvent())
        let maybePayload = try await transport.onlyPayload
        let payload = try XCTUnwrap(maybePayload)
        XCTAssertEqual(payload.events[0].severity, .info)
        XCTAssertEqual(payload.events[0].context, "overridden")
    }

    // MARK: - Delivery modes

    func testSynchronousDeliveryCompletesBeforeReturn() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(apiKey: "k", releaseStage: "production", synchronous: true),
            transport: transport
        )
        await client.send(makeEvent())
        // No flush, no waiting: the request must already be there.
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFireAndForgetDeliversAfterFlush() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(apiKey: "k", releaseStage: "production", synchronous: false),
            transport: transport
        )
        await client.send(makeEvent())
        await client.send(makeEvent())
        await client.flush()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testNonisolatedReportEventuallyDelivers() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(apiKey: "k", releaseStage: "production", synchronous: false),
            transport: transport
        )
        client.report(makeEvent())  // no await: usable from any context

        for _ in 0..<200 {
            await client.flush()
            if await transport.requests.count == 1 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("report(_:) never delivered")
    }

    // MARK: - Failure isolation

    func testHungTransportIsAbandonedAfterTimeout() async throws {
        let transport = MockTransport(behavior: .hang(seconds: 30))
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                sendTimeout: 0.2,
                synchronous: true
            ),
            transport: transport
        )
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await client.send(makeEvent())
        }
        XCTAssertLessThan(elapsed, .seconds(5), "delivery must be abandoned at sendTimeout")
    }

    func testFailingTransportDoesNotThrowOrCrash() async throws {
        let transport = MockTransport(behavior: .fail)
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(apiKey: "k", releaseStage: "production", synchronous: true),
            transport: transport
        )
        await client.send(makeEvent())  // send is non-throwing by design
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - Delivery-error diagnostics

    /// Thread-safe recorder for the synchronous onDeliveryError closure.
    private final class MessageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeClient(
        behavior: MockTransport.Behavior,
        sendTimeout: TimeInterval = 5,
        box: MessageBox
    ) -> BugsnagClient {
        BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                sendTimeout: sendTimeout,
                synchronous: true,
                onDeliveryError: { box.append($0) }
            ),
            transport: MockTransport(behavior: behavior)
        )
    }

    func testOnDeliveryErrorReportsTransportFailure() async throws {
        let box = MessageBox()
        await makeClient(behavior: .fail, box: box).send(makeEvent())
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertTrue(box.messages[0].contains("delivery failed"))
    }

    func testOnDeliveryErrorReportsNon200Response() async throws {
        let box = MessageBox()
        await makeClient(behavior: .succeed(status: 401), box: box).send(makeEvent())
        XCTAssertEqual(box.messages, ["Bugsnag delivery failed: HTTP 401"])
    }

    func testOnDeliveryErrorReportsTimeout() async throws {
        let box = MessageBox()
        await makeClient(behavior: .hang(seconds: 30), sendTimeout: 0.2, box: box).send(makeEvent())
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertTrue(box.messages[0].contains("timed out"))
    }

    func testSuccessfulDeliveryDoesNotInvokeOnDeliveryError() async throws {
        let box = MessageBox()
        await makeClient(behavior: .succeed(status: 200), box: box).send(makeEvent())
        XCTAssertTrue(box.messages.isEmpty)
    }
}
