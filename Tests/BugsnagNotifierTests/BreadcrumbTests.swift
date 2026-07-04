import BugsnagNotifier
import Foundation
import XCTest

final class BreadcrumbTests: XCTestCase {
    // MARK: - Encoding shape

    func testBreadcrumbEncodesTimestampAsISO8601String() throws {
        let breadcrumb = Breadcrumb(
            timestamp: Date(timeIntervalSince1970: 1_720_000_000.5),
            name: "Cache warmed",
            type: .process,
            metaData: ["entries": 42]
        )
        let data = try JSONEncoder().encode(breadcrumb)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["timestamp"] as? String, "2024-07-03T09:46:40.500Z")
        XCTAssertEqual(json["name"] as? String, "Cache warmed")
        XCTAssertEqual(json["type"] as? String, "process")
        XCTAssertEqual((json["metaData"] as? [String: Any])?["entries"] as? Int, 42)
    }

    func testMetadataIsOmittedWhenNil() throws {
        let breadcrumb = Breadcrumb(name: "n", type: .log)
        let data = try JSONEncoder().encode(breadcrumb)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["metaData"])
        XCTAssertEqual(Set(json.keys), ["timestamp", "name", "type"])
    }

    func testTypeStringsMatchTheOfficialEightCategories() {
        XCTAssertEqual(BreadcrumbType.navigation.rawValue, "navigation")
        XCTAssertEqual(BreadcrumbType.request.rawValue, "request")
        XCTAssertEqual(BreadcrumbType.process.rawValue, "process")
        XCTAssertEqual(BreadcrumbType.log.rawValue, "log")
        XCTAssertEqual(BreadcrumbType.user.rawValue, "user")
        XCTAssertEqual(BreadcrumbType.state.rawValue, "state")
        XCTAssertEqual(BreadcrumbType.error.rawValue, "error")
        XCTAssertEqual(BreadcrumbType.manual.rawValue, "manual")
    }

    func testDecodingRoundTripsAndAcceptsWholeSecondTimestamps() throws {
        let original = Breadcrumb(
            timestamp: Date(timeIntervalSince1970: 1_720_000_000.25),
            name: "Query ran",
            type: .request,
            metaData: ["table": "habits"]
        )
        let decoded = try JSONDecoder().decode(
            Breadcrumb.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)

        // Other notifiers emit timestamps without fractional seconds.
        let plain = Data(#"{"timestamp":"2024-07-03T09:46:40Z","name":"n","type":"manual"}"#.utf8)
        let breadcrumb = try JSONDecoder().decode(Breadcrumb.self, from: plain)
        XCTAssertEqual(breadcrumb.timestamp, Date(timeIntervalSince1970: 1_720_000_000))
    }

    func testEventEncodesBreadcrumbsArrayInDeliveredPayload() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                synchronous: true
            ),
            transport: transport
        )
        await client.send(
            BugsnagEvent(
                exceptions: [BugsnagException(errorClass: "E", message: "m")],
                breadcrumbs: [
                    Breadcrumb(
                        timestamp: Date(timeIntervalSince1970: 1_720_000_000),
                        name: "GET /v1/habits",
                        type: .request
                    ),
                    Breadcrumb(
                        timestamp: Date(timeIntervalSince1970: 1_720_000_001),
                        name: "Payment attempted",
                        type: .process,
                        metaData: ["provider": "stripe"]
                    ),
                ]
            )
        )

        let requests = await transport.requests
        let body = try XCTUnwrap(requests.first?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let breadcrumbs = try XCTUnwrap(events[0]["breadcrumbs"] as? [[String: Any]])

        XCTAssertEqual(breadcrumbs.count, 2)
        XCTAssertEqual(breadcrumbs[0]["timestamp"] as? String, "2024-07-03T09:46:40.000Z")
        XCTAssertEqual(breadcrumbs[0]["name"] as? String, "GET /v1/habits")
        XCTAssertEqual(breadcrumbs[0]["type"] as? String, "request")
        XCTAssertEqual(breadcrumbs[1]["name"] as? String, "Payment attempted")
        XCTAssertEqual(
            (breadcrumbs[1]["metaData"] as? [String: Any])?["provider"] as? String,
            "stripe"
        )
    }

    // MARK: - Redaction

    func testBreadcrumbMetadataIsRedactedCaseInsensitivelyAndRecursively() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                redactedKeys: ["x-api-key"],
                synchronous: true
            ),
            transport: transport
        )
        await client.send(
            BugsnagEvent(
                exceptions: [BugsnagException(errorClass: "E", message: "m")],
                breadcrumbs: [
                    Breadcrumb(
                        name: "Upstream call",
                        type: .request,
                        metaData: [
                            "PASSWORD": "hunter2",
                            "endpoint": "/v2/charge",
                            "nested": ["X-Api-Key": "abc123", "safe": true],
                        ]
                    )
                ]
            )
        )

        let maybePayload = try await transport.onlyPayload
        let payload = try XCTUnwrap(maybePayload)
        let breadcrumb = try XCTUnwrap(payload.events[0].breadcrumbs?.first)
        let metaData = try XCTUnwrap(breadcrumb.metaData)
        XCTAssertEqual(metaData["PASSWORD"], .string("[REDACTED]"))
        XCTAssertEqual(metaData["endpoint"], .string("/v2/charge"))
        XCTAssertEqual(
            metaData["nested"],
            .object(["X-Api-Key": .string("[REDACTED]"), "safe": .bool(true)])
        )

        let body = await transport.requests[0].body
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("abc123"))
    }
}
