import BugsnagNotifier
import BugsnagVapor
import XCTVapor

final class SessionTrackingTests: XCTestCase {
    /// Records every request; no network. Splits recorded traffic by
    /// endpoint so tests can assert on event and session POSTs separately.
    actor MockTransport: BugsnagTransport {
        private(set) var requests: [BugsnagHTTPRequest] = []

        func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
            requests.append(request)
            // Like the real endpoints: notify acknowledges 200, sessions 202.
            return BugsnagHTTPResponse(statusCode: request.url.host == "sessions.bugsnag.com" ? 202 : 200)
        }

        var eventRequests: [BugsnagHTTPRequest] {
            requests.filter { $0.url.host == "notify.bugsnag.com" }
        }

        var sessionRequests: [BugsnagHTTPRequest] {
            requests.filter { $0.url.host == "sessions.bugsnag.com" }
        }

        var events: [BugsnagEvent] {
            get throws {
                try eventRequests.flatMap {
                    try JSONDecoder().decode(BugsnagPayload.self, from: $0.body).events
                }
            }
        }

        var sessionPayloads: [BugsnagSessionPayload] {
            get throws {
                try sessionRequests.map {
                    try JSONDecoder().decode(BugsnagSessionPayload.self, from: $0.body)
                }
            }
        }
    }

    struct DatabaseExplodedError: Error {}

    private func makeConfiguration(autoCaptureSessions: Bool = true) -> BugsnagConfiguration {
        BugsnagConfiguration(
            apiKey: "test-key",
            releaseStage: "testing",
            appVersion: "1.2.3",
            autoCaptureSessions: autoCaptureSessions,
            hostname: "test-host",
            synchronous: true
        )
    }

    private func withApp(
        configuration: BugsnagConfiguration? = nil,
        transport: MockTransport,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.bugsnag.configure(configuration ?? makeConfiguration(), transport: transport)
            app.middleware.use(BugsnagMiddleware())
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - event.session attribution

    func testUnhandledErrorEventCarriesSessionBlock() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("boom") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }
            try await app.testable().test(.GET, "/boom") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let events = try await transport.events
            XCTAssertEqual(events.count, 1)
            let session = try XCTUnwrap(events[0].session)
            XCTAssertNotNil(UUID(uuidString: session.id), "session id must be a UUID")
            XCTAssertEqual(session.events, .init(handled: 0, unhandled: 1))

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            XCTAssertNotNil(
                formatter.date(from: session.startedAt),
                "session startedAt must be ISO-8601: \(session.startedAt)"
            )
        }
    }

    func testHandledNotifyIncrementsHandledCountWithinTheSameSession() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("checkout") { req -> HTTPStatus in
                await req.bugsnag.notify(DatabaseExplodedError())
                await req.bugsnag.notify(DatabaseExplodedError())
                return .ok
            }
            try await app.testable().test(.GET, "/checkout") { response async in
                XCTAssertEqual(response.status, .ok)
            }

            let events = try await transport.events
            XCTAssertEqual(events.count, 2)
            let first = try XCTUnwrap(events[0].session)
            let second = try XCTUnwrap(events[1].session)
            XCTAssertEqual(first.id, second.id, "both events belong to the request's one session")
            XCTAssertEqual(first.events, .init(handled: 1, unhandled: 0))
            XCTAssertEqual(second.events, .init(handled: 2, unhandled: 0))
        }
    }

    // MARK: - Per-request session counting

    func testEachRequestStartsOneSession() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("ok") { _ -> HTTPStatus in .ok }

            try await app.testable().test(.GET, "/ok") { response async in
                XCTAssertEqual(response.status, .ok)
            }
            try await app.testable().test(.GET, "/ok") { response async in
                XCTAssertEqual(response.status, .ok)
            }

            let tracker = try XCTUnwrap(app.bugsnag.sessions)
            await tracker.flush()

            let payloads = try await transport.sessionPayloads
            XCTAssertEqual(payloads.count, 1)
            let started = payloads[0].sessionCounts.reduce(0) { $0 + $1.sessionsStarted }
            XCTAssertEqual(started, 2, "two requests must count as two sessions")
        }
    }

    // MARK: - autoCaptureSessions off

    func testAutoCaptureSessionsFalseDisablesTrackingEntirely() async throws {
        let transport = MockTransport()
        try await withApp(
            configuration: makeConfiguration(autoCaptureSessions: false),
            transport: transport
        ) { app in
            app.get("boom") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }
            try await app.testable().test(.GET, "/boom") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            XCTAssertNil(app.bugsnag.sessions, "no tracker when autoCaptureSessions is off")

            let events = try await transport.events
            XCTAssertEqual(events.count, 1, "error reporting itself must still work")
            XCTAssertNil(events[0].session, "events must not carry a session block")
        }

        // Shutdown already ran inside withApp; still no session traffic.
        let sessionRequests = await transport.sessionRequests
        XCTAssertTrue(sessionRequests.isEmpty)
    }

    // MARK: - Shutdown flush

    func testShutdownFlushesPendingSessions() async throws {
        let transport = MockTransport()
        let app = try await Application.make(.testing)
        app.bugsnag.configure(makeConfiguration(), transport: transport)
        app.middleware.use(BugsnagMiddleware())
        app.get("ok") { _ -> HTTPStatus in .ok }

        try await app.testable().test(.GET, "/ok") { response async in
            XCTAssertEqual(response.status, .ok)
        }

        // No explicit flush: the lifecycle handler must drain on shutdown.
        try await app.asyncShutdown()

        let payloads = try await transport.sessionPayloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].sessionCounts.reduce(0) { $0 + $1.sessionsStarted }, 1)
    }
}
