import BugsnagNotifier
import BugsnagVapor
import XCTVapor

final class BreadcrumbTrailTests: XCTestCase {
    typealias MockTransport = BugsnagMiddlewareTests.MockTransport

    struct SomethingBrokeError: Error {}

    private func withApp(
        configuration: BugsnagConfiguration? = nil,
        transport: any BugsnagTransport,
        middleware: BugsnagMiddleware = BugsnagMiddleware(),
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            let config = configuration ?? BugsnagConfiguration(
                apiKey: "test-key",
                releaseStage: "testing",
                synchronous: true
            )
            app.bugsnag.configure(config, transport: transport)
            app.middleware.use(middleware)
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func allEvents(from transport: MockTransport) async throws -> [BugsnagEvent] {
        let requests = await transport.requests
        return try requests.flatMap {
            try JSONDecoder().decode(BugsnagPayload.self, from: $0.body).events
        }
    }

    // MARK: - Attachment to events

    func testBreadcrumbsAttachToUnhandledEventsInOrder() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("charge") { req -> HTTPStatus in
                req.bugsnag.leaveBreadcrumb("Card validated", type: .process)
                req.bugsnag.leaveBreadcrumb(
                    "Charge attempted",
                    metadata: ["provider": "stripe"]
                )
                throw SomethingBrokeError()
            }
            try await app.testable().test(.GET, "/charge") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            let breadcrumbs = try XCTUnwrap(event.breadcrumbs)
            XCTAssertEqual(breadcrumbs.count, 3)

            // The middleware's automatic request breadcrumb comes first.
            XCTAssertEqual(breadcrumbs[0].type, .request)
            XCTAssertEqual(breadcrumbs[0].name, "GET /charge")

            XCTAssertEqual(breadcrumbs[1].name, "Card validated")
            XCTAssertEqual(breadcrumbs[1].type, .process)
            XCTAssertEqual(breadcrumbs[2].name, "Charge attempted")
            XCTAssertEqual(breadcrumbs[2].type, .manual)
            XCTAssertEqual(breadcrumbs[2].metaData?["provider"], .string("stripe"))
            XCTAssertLessThanOrEqual(breadcrumbs[0].timestamp, breadcrumbs[2].timestamp)
        }
    }

    func testBreadcrumbsAttachToDeliberateNotifyEvents() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            app.get("sync") { req -> HTTPStatus in
                req.bugsnag.leaveBreadcrumb("Sync started", type: .process)
                await req.bugsnag.notify(SomethingBrokeError(), severity: .info)
                return .ok
            }
            try await app.testable().test(.GET, "/sync") { response async in
                XCTAssertEqual(response.status, .ok)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            let breadcrumbs = try XCTUnwrap(event.breadcrumbs)
            XCTAssertEqual(
                breadcrumbs.map(\.name),
                ["GET /sync", "Sync started"]
            )
        }
    }

    func testAutomaticRequestBreadcrumbCanBeDisabled() async throws {
        let transport = MockTransport()
        try await withApp(
            transport: transport,
            middleware: BugsnagMiddleware(automaticRequestBreadcrumb: false)
        ) { app in
            app.get("boom") { _ -> HTTPStatus in
                throw SomethingBrokeError()
            }
            try await app.testable().test(.GET, "/boom") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            XCTAssertNil(event.breadcrumbs, "no breadcrumbs were left, so the field must be omitted")
        }
    }

    // MARK: - Cap eviction

    func testTrailIsCappedDroppingOldestFirst() async throws {
        let transport = MockTransport()
        let config = BugsnagConfiguration(
            apiKey: "test-key",
            releaseStage: "testing",
            maxBreadcrumbs: 3,
            synchronous: true
        )
        try await withApp(configuration: config, transport: transport) { app in
            app.get("busy") { req -> HTTPStatus in
                for index in 1...5 {
                    req.bugsnag.leaveBreadcrumb("step-\(index)")
                }
                throw SomethingBrokeError()
            }
            try await app.testable().test(.GET, "/busy") { response async in
                XCTAssertEqual(response.status, .internalServerError)
            }

            let maybeEvent = try await transport.onlyEvent
            let event = try XCTUnwrap(maybeEvent)
            // The automatic request breadcrumb and steps 1-2 were evicted.
            XCTAssertEqual(
                event.breadcrumbs?.map(\.name),
                ["step-3", "step-4", "step-5"]
            )
        }
    }

    // MARK: - Per-request isolation

    func testConcurrentRequestsKeepSeparateTrails() async throws {
        let transport = MockTransport()
        try await withApp(transport: transport) { app in
            for route in ["alpha", "beta"] {
                app.get(PathComponent(stringLiteral: route)) { req -> HTTPStatus in
                    req.bugsnag.leaveBreadcrumb("crumb-\(route)")
                    // Overlap the two requests so shared state would show up.
                    try await Task.sleep(for: .milliseconds(50))
                    req.bugsnag.leaveBreadcrumb("late-crumb-\(route)")
                    throw SomethingBrokeError()
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for route in ["alpha", "beta"] {
                    group.addTask {
                        try await app.testable().test(.GET, "/\(route)") { response async in
                            XCTAssertEqual(response.status, .internalServerError)
                        }
                    }
                }
                try await group.waitForAll()
            }

            let events = try await allEvents(from: transport)
            XCTAssertEqual(events.count, 2)
            for route in ["alpha", "beta"] {
                let event = try XCTUnwrap(
                    events.first { $0.context == "GET /\(route)" },
                    "missing event for /\(route)"
                )
                XCTAssertEqual(
                    event.breadcrumbs?.map(\.name),
                    ["GET /\(route)", "crumb-\(route)", "late-crumb-\(route)"],
                    "trail for /\(route) must contain only its own breadcrumbs"
                )
            }
        }
    }
}
