import BugsnagNotifier
import Foundation
import XCTest

final class SessionTrackerTests: XCTestCase {
    /// 2026-01-01T00:00:00Z — a fixed, minute-aligned reference date.
    private static let baseDate = Date(timeIntervalSince1970: 1_767_225_600)

    private func makeConfiguration(
        releaseStage: String = "production",
        enabledReleaseStages: Set<String>? = nil,
        sessionFlushInterval: TimeInterval = 30,
        sendTimeout: TimeInterval = 5,
        synchronous: Bool = true,
        onDeliveryError: (@Sendable (String) -> Void)? = nil
    ) -> BugsnagConfiguration {
        BugsnagConfiguration(
            apiKey: "test-api-key",
            releaseStage: releaseStage,
            enabledReleaseStages: enabledReleaseStages,
            appVersion: "3.2.1",
            hostname: "task-1",
            sendTimeout: sendTimeout,
            sessionFlushInterval: sessionFlushInterval,
            synchronous: synchronous,
            onDeliveryError: onDeliveryError
        )
    }

    private func decodePayload(_ request: BugsnagHTTPRequest) throws -> BugsnagSessionPayload {
        try JSONDecoder().decode(BugsnagSessionPayload.self, from: request.body)
    }

    // MARK: - Minute-bucket batching

    func testFlushAggregatesSessionsIntoMinuteBuckets() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: transport)

        // Two sessions in the first minute, one in the next.
        await tracker.startSession(at: Self.baseDate.addingTimeInterval(10))
        await tracker.startSession(at: Self.baseDate.addingTimeInterval(50))
        await tracker.startSession(at: Self.baseDate.addingTimeInterval(70))
        await tracker.flush()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "one flush must produce exactly one POST")
        let payload = try decodePayload(requests[0])
        XCTAssertEqual(payload.sessionCounts, [
            BugsnagSessionCounts(startedAt: "2026-01-01T00:00:00Z", sessionsStarted: 2),
            BugsnagSessionCounts(startedAt: "2026-01-01T00:01:00Z", sessionsStarted: 1),
        ])
    }

    func testFlushDrainsCounts() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: transport)

        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()
        await tracker.flush()  // nothing left: must not POST again

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFlushWithNoSessionsDoesNotPost() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: transport)
        await tracker.flush()
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Request shape (bugsnag-go sessions/publisher.go contract)

    func testSessionRequestTargetsSessionsEndpointWithRequiredHeaders() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: transport)
        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://sessions.bugsnag.com/")
        XCTAssertEqual(request.method, "POST")

        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["Bugsnag-Api-Key"], "test-api-key")
        XCTAssertEqual(headers["Bugsnag-Payload-Version"], "1.0")
        XCTAssertEqual(headers["Content-Type"], "application/json")

        let sentAt = try XCTUnwrap(headers["Bugsnag-Sent-At"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertNotNil(formatter.date(from: sentAt), "Bugsnag-Sent-At must be ISO-8601: \(sentAt)")
    }

    func testSessionBodyMatchesPayloadVersion1Schema() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: transport)
        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )

        // Unlike the error payload, the API key travels only in the header.
        XCTAssertNil(json["apiKey"])

        let notifier = try XCTUnwrap(json["notifier"] as? [String: Any])
        XCTAssertEqual(notifier["name"] as? String, "vapor-bugsnag")
        XCTAssertEqual(notifier["version"] as? String, bugsnagNotifierVersion)
        XCTAssertNotNil(notifier["url"])

        let app = try XCTUnwrap(json["app"] as? [String: Any])
        XCTAssertEqual(app["releaseStage"] as? String, "production")
        XCTAssertEqual(app["version"] as? String, "3.2.1")
        XCTAssertEqual(app["type"] as? String, "vapor")

        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertNotNil(device["osName"])
        XCTAssertEqual(device["hostname"] as? String, "task-1")

        let sessionCounts = try XCTUnwrap(json["sessionCounts"] as? [[String: Any]])
        XCTAssertEqual(sessionCounts.count, 1)
        XCTAssertEqual(sessionCounts[0]["startedAt"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(sessionCounts[0]["sessionsStarted"] as? Int, 1)
    }

    // MARK: - Release-stage gating

    func testExcludedReleaseStageNeverPosts() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(
            configuration: makeConfiguration(
                releaseStage: "development",
                enabledReleaseStages: ["production", "staging"]
            ),
            transport: transport
        )
        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "excluded stage must not attempt a POST")
    }

    func testIncludedReleaseStagePosts() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(
            configuration: makeConfiguration(
                releaseStage: "staging",
                enabledReleaseStages: ["production", "staging"]
            ),
            transport: transport
        )
        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - Periodic + shutdown flush

    func testPeriodicFlushDeliversWithoutExplicitFlush() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(
            configuration: makeConfiguration(sessionFlushInterval: 0.05, synchronous: false),
            transport: transport
        )
        await tracker.startSession(at: Self.baseDate)

        for _ in 0..<200 {
            if await transport.requests.count >= 1 {
                await tracker.shutdown()
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the periodic flush loop never delivered")
    }

    func testShutdownFlushesPendingCounts() async throws {
        let transport = MockTransport()
        let tracker = SessionTracker(
            configuration: makeConfiguration(synchronous: false),  // long interval: loop won't fire
            transport: transport
        )
        await tracker.startSession(at: Self.baseDate)
        await tracker.shutdown()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "shutdown must drain pending counts")
        let payload = try decodePayload(requests[0])
        XCTAssertEqual(payload.sessionCounts, [
            BugsnagSessionCounts(startedAt: "2026-01-01T00:00:00Z", sessionsStarted: 1)
        ])
    }

    func testStartedSessionCarriesFreshIdentity() async throws {
        let tracker = SessionTracker(configuration: makeConfiguration(), transport: MockTransport())
        let first = await tracker.startSession(at: Self.baseDate)
        let second = await tracker.startSession(at: Self.baseDate)

        XCTAssertNotEqual(first.id, second.id, "each session must get its own id")
        XCTAssertNotNil(UUID(uuidString: first.id), "session id must be a UUID")
        XCTAssertEqual(first.startedAt, Self.baseDate)
        XCTAssertEqual(first.handledCount, 0)
        XCTAssertEqual(first.unhandledCount, 0)
        XCTAssertEqual(
            first.eventSession,
            BugsnagEventSession(
                id: first.id,
                startedAt: "2026-01-01T00:00:00Z",
                events: .init(handled: 0, unhandled: 0)
            )
        )
    }

    // MARK: - Delivery-error diagnostics (same semantics as event delivery)

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

    private func flushOnce(
        behavior: MockTransport.Behavior,
        sendTimeout: TimeInterval = 5,
        box: MessageBox
    ) async {
        let tracker = SessionTracker(
            configuration: makeConfiguration(
                sendTimeout: sendTimeout,
                onDeliveryError: { box.append($0) }
            ),
            transport: MockTransport(behavior: behavior)
        )
        await tracker.startSession(at: Self.baseDate)
        await tracker.flush()
    }

    func testAccepted202IsNotAnError() async throws {
        let box = MessageBox()
        await flushOnce(behavior: .succeed(status: 202), box: box)
        XCTAssertTrue(box.messages.isEmpty, "the sessions endpoint acknowledges with 202")
    }

    func testOnDeliveryErrorReportsNon2xxResponse() async throws {
        let box = MessageBox()
        await flushOnce(behavior: .succeed(status: 401), box: box)
        XCTAssertEqual(box.messages, ["Bugsnag session delivery failed: HTTP 401"])
    }

    func testOnDeliveryErrorReportsTransportFailure() async throws {
        let box = MessageBox()
        await flushOnce(behavior: .fail, box: box)
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertTrue(box.messages[0].contains("session delivery failed"))
    }

    func testOnDeliveryErrorReportsTimeout() async throws {
        let box = MessageBox()
        await flushOnce(behavior: .hang(seconds: 30), sendTimeout: 0.2, box: box)
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertTrue(box.messages[0].contains("timed out"))
    }
}
