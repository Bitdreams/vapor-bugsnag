import BugsnagNotifier
import BugsnagVapor
import XCTVapor

final class BugsnagMiddlewareTests: XCTestCase {
    /// Records every request; no network. (Local copy — test targets don't share sources.)
    actor MockTransport: BugsnagTransport {
        private(set) var requests: [BugsnagHTTPRequest] = []
        private let delaySeconds: Double

        init(delaySeconds: Double = 0) {
            self.delaySeconds = delaySeconds
        }

        func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
            requests.append(request)
            if delaySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            return BugsnagHTTPResponse(statusCode: 200)
        }

        var onlyEvent: BugsnagEvent? {
            get throws {
                guard requests.count == 1, let request = requests.first else { return nil }
                let payload = try JSONDecoder().decode(BugsnagPayload.self, from: request.body)
                return payload.events.first
            }
        }
    }

    struct DatabaseExplodedError: Error {}

    private func withApp(
        configuration: BugsnagConfiguration? = nil,
        transport: (any BugsnagTransport)? = nil,
        userResolver: (@Sendable (Request) -> BugsnagUser?)? = nil,
        configureBugsnag: Bool = true,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            if configureBugsnag {
                let config = configuration ?? BugsnagConfiguration(
                    apiKey: "test-key",
                    releaseStage: "testing",
                    appVersion: "1.2.3",
                    hostname: "test-host",
                    synchronous: true
                )
                app.bugsnag.configure(config, transport: transport, userResolver: userResolver)
            }
            app.middleware.use(BugsnagMiddleware())
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Unhandled errors

    func testUnhandledErrorIsReportedAndRethrown() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("habits", ":id") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }

            try await app.testable().test(
                .GET, "/habits/123",
                headers: ["Authorization": "Bearer secret", "Accept": "application/json"]
            ) { response async in
                // The error must still reach ErrorMiddleware and render a 500.
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .error)
            XCTAssertTrue(event.unhandled)
            XCTAssertEqual(event.severityReason, .unhandledMiddleware)
            XCTAssertEqual(event.context, "GET /habits/:id")
            XCTAssertTrue(event.exceptions[0].errorClass.contains("DatabaseExplodedError"))
            XCTAssertEqual(event.groupingHash, "\(event.exceptions[0].errorClass)|GET /habits/:id")
            XCTAssertEqual(event.exceptions[0].stacktrace, [])

            XCTAssertEqual(event.app?.releaseStage, "testing")
            XCTAssertEqual(event.app?.version, "1.2.3")
            XCTAssertEqual(event.app?.type, "vapor")
            XCTAssertEqual(event.device?.hostname, "test-host")

            let headers = try XCTUnwrap(event.request?.headers)
            XCTAssertEqual(headers["Authorization"], "[REDACTED]")
            XCTAssertEqual(headers["Accept"], "application/json")
            XCTAssertEqual(event.request?.httpMethod, "GET")

            XCTAssertNotNil(event.metaData?["request"]?["requestId"])
        }
    }

    func testServerErrorAbortIsUnhandledError() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("boom") { _ -> HTTPStatus in
                throw Abort(.internalServerError, reason: "kaboom")
            }
            try await app.testable().test(.GET, "/boom") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .error)
            XCTAssertTrue(event.unhandled)
            XCTAssertEqual(event.exceptions[0].message, "kaboom")
            XCTAssertEqual(event.metaData?["app"]?["abortStatus"], .int(500))
        }
    }

    func testClientErrorAbortIsHandledWarning() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("missing") { _ -> HTTPStatus in
                throw Abort(.notFound, reason: "Habit not found")
            }
            try await app.testable().test(.GET, "/missing") { response async in
                XCTAssertEqual(response.status, .notFound)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .warning)
            XCTAssertFalse(event.unhandled)
            XCTAssertEqual(event.severityReason, .handledError)
            XCTAssertEqual(event.exceptions[0].message, "Habit not found")
            XCTAssertEqual(event.metaData?["app"]?["abortStatus"], .int(404))
        }
    }

    // MARK: - Handled notify

    func testDeliberateNotifyReportsHandledEventWithMetadata() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("checkout") { req -> HTTPStatus in
                await req.bugsnag.notify(
                    DatabaseExplodedError(),
                    severity: .info,
                    metadata: ["billing": ["plan": "pro"]]
                )
                return .ok
            }
            try await app.testable().test(.GET, "/checkout") { response async in
                XCTAssertEqual(response.status, .ok)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .info)
            XCTAssertFalse(event.unhandled)
            XCTAssertEqual(event.severityReason, .userSpecifiedSeverity)
            XCTAssertEqual(event.context, "GET /checkout")
            XCTAssertEqual(event.metaData?["billing"]?["plan"], .string("pro"))
        }
    }

    func testDeliberateNotifyWithoutSeverityDefaultsToHandledWarning() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("quiet") { req -> HTTPStatus in
                await req.bugsnag.notify(DatabaseExplodedError())
                return .ok
            }
            try await app.testable().test(.GET, "/quiet") { response async in
                XCTAssertEqual(response.status, .ok)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .warning)
            XCTAssertFalse(event.unhandled)
            XCTAssertEqual(event.severityReason, .handledException)
        }
    }

    // MARK: - User extraction

    func testUserResolverPopulatesUserBlock() async throws {
        let transport = MockTransport()
        let resolver: @Sendable (Request) -> BugsnagUser? = { req in
            // Stands in for JWT extraction from req.auth in a real app.
            req.headers.first(name: "X-Test-User").map { BugsnagUser(id: $0, email: "u@example.com") }
        }
        try await withApp(transport: transport, userResolver: resolver) { app in
            app.get("me") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }
            try await app.testable().test(
                .GET, "/me",
                headers: ["X-Test-User": "user-42"]
            ) { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.user?.id, "user-42")
            XCTAssertEqual(event.user?.email, "u@example.com")
        }
    }

    // MARK: - Isolation from the request path

    func testUnconfiguredBugsnagIsANoOp() async throws {
        try await withApp(configureBugsnag: false) { app in
            app.get("boom") { _ -> HTTPStatus in
                throw Abort(.internalServerError)
            }
            try await app.testable().test(.GET, "/boom") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }
        }
    }

    func testSlowDeliveryDoesNotDelayTheResponse() async throws {
        let transport = MockTransport(delaySeconds: 10)
        let config = BugsnagConfiguration(
            apiKey: "test-key",
            releaseStage: "testing",
            sendTimeout: 0.5,
            synchronous: false  // production mode: fire-and-forget
        )
        try await withApp(configuration: config, transport: transport) { app in
            app.get("slow-notify") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }

            let clock = ContinuousClock()
            let elapsed = try await clock.measure {
                try await app.testable().test(.GET, "/slow-notify") { response async in
                    XCTAssertEqual(response.status, .internalServerError)
                }
            }
            XCTAssertLessThan(
                elapsed, .seconds(5),
                "a hung notify endpoint must not delay the response"
            )
            if let client = app.bugsnag.client {
                await client.flush()
            }
        }
    }
}
