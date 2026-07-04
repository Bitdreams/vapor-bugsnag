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

    struct DiskUnavailableError: Error, LocalizedError {
        var errorDescription: String? { "disk unavailable" }
    }

    struct SyncFailedError: BugsnagChainedError, LocalizedError {
        let underlyingError: (any Error)?
        var errorDescription: String? { "sync failed" }
    }

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

    // MARK: - Cause chains

    func testChainedErrorReportsCauseChainInOrder() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("sync") { _ -> HTTPStatus in
                throw SyncFailedError(underlyingError: DiskUnavailableError())
            }
            try await app.testable().test(.GET, "/sync") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.exceptions.count, 2)
            XCTAssertTrue(event.exceptions[0].errorClass.contains("SyncFailedError"))
            XCTAssertEqual(event.exceptions[0].message, "sync failed")
            XCTAssertTrue(event.exceptions[1].errorClass.contains("DiskUnavailableError"))
            XCTAssertEqual(event.exceptions[1].message, "disk unavailable")
            XCTAssertEqual(event.exceptions.map(\.stacktrace), [[], []])

            // Classification and grouping stay keyed off the primary error.
            XCTAssertEqual(event.severity, .error)
            XCTAssertTrue(event.unhandled)
            XCTAssertEqual(event.severityReason, .unhandledMiddleware)
            XCTAssertEqual(event.groupingHash, "\(event.exceptions[0].errorClass)|GET /sync")
        }
    }

    func testChainedErrorWrappingAbortKeepsPrimarySeverityMapping() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("wrapped-abort") { _ -> HTTPStatus in
                // A 4xx Abort as a CAUSE must not downgrade the event: the
                // AbortError check considers the primary (outermost) error only.
                throw SyncFailedError(underlyingError: Abort(.notFound, reason: "Habit not found"))
            }
            try await app.testable().test(.GET, "/wrapped-abort") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .error)
            XCTAssertTrue(event.unhandled)
            XCTAssertEqual(event.severityReason, .unhandledMiddleware)
            XCTAssertNil(event.metaData?["app"]?["abortStatus"])
            XCTAssertEqual(event.exceptions.count, 2)
            XCTAssertEqual(event.exceptions[1].message, "Habit not found")
        }
    }

    func testPlainErrorStillProducesExactlyOneException() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("plain") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }
            try await app.testable().test(.GET, "/plain") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.exceptions.count, 1)
            XCTAssertTrue(event.exceptions[0].errorClass.contains("DatabaseExplodedError"))
        }
    }

    // MARK: - Throw-site stack traces (opt-in)

    func testTracedErrorPopulatesStacktraceWithInnerErrorClass() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("traced") { _ -> HTTPStatus in
                throw DatabaseExplodedError().bugsnagTraced()
            }
            try await app.testable().test(.GET, "/traced") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            let exception = event.exceptions[0]

            // Frames were captured at the throw site inside the route closure.
            XCTAssertFalse(exception.stacktrace.isEmpty)
            XCTAssertTrue(exception.stacktrace[0].file.contains("BugsnagMiddlewareTests"))
            XCTAssertGreaterThan(exception.stacktrace[0].lineNumber, 0)

            // Class/message/grouping reflect the WRAPPED error, not the wrapper.
            XCTAssertTrue(exception.errorClass.contains("DatabaseExplodedError"))
            XCTAssertFalse(exception.errorClass.contains("BugsnagTracedError"))
            XCTAssertEqual(event.groupingHash, "\(exception.errorClass)|GET /traced")

            XCTAssertEqual(event.severity, .error)
            XCTAssertTrue(event.unhandled)
            XCTAssertEqual(event.severityReason, .unhandledMiddleware)
        }
    }

    func testTracedAbortKeepsHTTPStatusAndSeverityMapping() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("traced-missing") { _ -> HTTPStatus in
                throw Abort(.notFound, reason: "Habit not found").bugsnagTraced()
            }
            // The AbortError forwarding must keep the 404 (not a generic 500).
            try await app.testable().test(.GET, "/traced-missing") { response async in
                XCTAssertEqual(response.status, .notFound)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.severity, .warning)
            XCTAssertFalse(event.unhandled)
            XCTAssertEqual(event.severityReason, .handledError)
            XCTAssertEqual(event.exceptions[0].message, "Habit not found")
            XCTAssertEqual(event.metaData?["app"]?["abortStatus"], .int(404))
            XCTAssertFalse(event.exceptions[0].stacktrace.isEmpty)
        }
    }

    struct SelfTracingError: Error, BugsnagStackTraceProviding {
        var bugsnagStacktrace: [StackFrame] {
            [StackFrame(file: "custom.swift", lineNumber: 7, method: "custom()")]
        }
    }

    func testCustomStackTraceProvidingErrorSuppliesItsOwnFrames() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("custom-traced") { _ -> HTTPStatus in
                throw SelfTracingError()
            }
            try await app.testable().test(.GET, "/custom-traced") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(
                event.exceptions[0].stacktrace,
                [StackFrame(file: "custom.swift", lineNumber: 7, method: "custom()")]
            )
            // A direct conformer is its own errorClass.
            XCTAssertTrue(event.exceptions[0].errorClass.contains("SelfTracingError"))
        }
    }

    func testTracedChainedErrorCombinesFramesAndCauseChain() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("traced-chain") { _ -> HTTPStatus in
                throw SyncFailedError(underlyingError: DiskUnavailableError()).bugsnagTraced()
            }
            try await app.testable().test(.GET, "/traced-chain") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            // The chain is walked from the unwrapped error; only the primary
            // exception carries the throw-site frames.
            XCTAssertEqual(event.exceptions.count, 2)
            XCTAssertTrue(event.exceptions[0].errorClass.contains("SyncFailedError"))
            XCTAssertFalse(event.exceptions[0].stacktrace.isEmpty)
            XCTAssertTrue(event.exceptions[1].errorClass.contains("DiskUnavailableError"))
            XCTAssertEqual(event.exceptions[1].stacktrace, [])
            XCTAssertEqual(event.groupingHash, "\(event.exceptions[0].errorClass)|GET /traced-chain")
        }
    }

    // Regression: untraced errors still ship stacktrace: [] — this is also
    // asserted in testUnhandledErrorIsReportedAndRethrown above.
    func testUntracedErrorStillSendsEmptyStacktrace() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("plain") { _ -> HTTPStatus in
                throw DatabaseExplodedError()
            }
            try await app.testable().test(.GET, "/plain") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertEqual(event.exceptions[0].stacktrace, [])
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
