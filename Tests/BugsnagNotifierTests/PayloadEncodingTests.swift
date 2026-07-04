import BugsnagNotifier
import Foundation
import XCTest

final class PayloadEncodingTests: XCTestCase {
    private func makeEvent() -> BugsnagEvent {
        BugsnagEvent(
            exceptions: [
                BugsnagException(errorClass: "AppError", message: "Habit not found")
            ],
            context: "GET /v1/habits/:id",
            severity: .error,
            unhandled: true,
            severityReason: .unhandledMiddleware,
            app: AppInfo(releaseStage: "production", version: "3.2.1", type: "vapor"),
            device: DeviceInfo(osName: "linux", hostname: "task-1", runtimeVersions: ["swift": "6.0"]),
            user: BugsnagUser(id: "u-123", email: "user@example.com"),
            request: RequestInfo(
                url: "https://api.example.com/v1/habits/123",
                httpMethod: "GET",
                clientIp: "203.0.113.9",
                headers: ["Accept": "application/json"]
            ),
            metaData: ["app": ["abortStatus": 404]],
            groupingHash: "AppError|GET /v1/habits/:id"
        )
    }

    private func deliver(_ event: BugsnagEvent) async throws -> BugsnagHTTPRequest {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "test-api-key",
                releaseStage: "production",
                synchronous: true
            ),
            transport: transport
        )
        await client.send(event)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        return try XCTUnwrap(requests.first)
    }

    func testRequestTargetsNotifyEndpointWithRequiredHeaders() async throws {
        let request = try await deliver(makeEvent())

        XCTAssertEqual(request.url.absoluteString, "https://notify.bugsnag.com/")
        XCTAssertEqual(request.method, "POST")

        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["Bugsnag-Api-Key"], "test-api-key")
        XCTAssertEqual(headers["Bugsnag-Payload-Version"], "5")
        XCTAssertEqual(headers["Content-Type"], "application/json")

        let sentAt = try XCTUnwrap(headers["Bugsnag-Sent-At"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertNotNil(formatter.date(from: sentAt), "Bugsnag-Sent-At must be ISO-8601: \(sentAt)")
    }

    func testBodyMatchesPayloadVersion5Schema() async throws {
        let request = try await deliver(makeEvent())
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )

        XCTAssertEqual(json["apiKey"] as? String, "test-api-key")
        XCTAssertEqual(json["payloadVersion"] as? String, "5")

        let notifier = try XCTUnwrap(json["notifier"] as? [String: Any])
        XCTAssertEqual(notifier["name"] as? String, "vapor-bugsnag")
        XCTAssertEqual(notifier["version"] as? String, bugsnagNotifierVersion)
        XCTAssertNotNil(notifier["url"])

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let event = events[0]

        let exceptions = try XCTUnwrap(event["exceptions"] as? [[String: Any]])
        XCTAssertEqual(exceptions.count, 1)
        XCTAssertEqual(exceptions[0]["errorClass"] as? String, "AppError")
        XCTAssertEqual(exceptions[0]["message"] as? String, "Habit not found")
        XCTAssertEqual(exceptions[0]["type"] as? String, "swift")
        XCTAssertEqual((exceptions[0]["stacktrace"] as? [Any])?.count, 0)

        XCTAssertEqual(event["context"] as? String, "GET /v1/habits/:id")
        XCTAssertEqual(event["severity"] as? String, "error")
        XCTAssertEqual(event["unhandled"] as? Bool, true)
        XCTAssertEqual(
            (event["severityReason"] as? [String: Any])?["type"] as? String,
            "unhandledMiddleware"
        )
        XCTAssertEqual(event["groupingHash"] as? String, "AppError|GET /v1/habits/:id")

        let app = try XCTUnwrap(event["app"] as? [String: Any])
        XCTAssertEqual(app["releaseStage"] as? String, "production")
        XCTAssertEqual(app["version"] as? String, "3.2.1")
        XCTAssertEqual(app["type"] as? String, "vapor")

        let device = try XCTUnwrap(event["device"] as? [String: Any])
        XCTAssertEqual(device["osName"] as? String, "linux")
        XCTAssertEqual(device["hostname"] as? String, "task-1")

        let user = try XCTUnwrap(event["user"] as? [String: Any])
        XCTAssertEqual(user["id"] as? String, "u-123")
        XCTAssertEqual(user["email"] as? String, "user@example.com")

        let requestBlock = try XCTUnwrap(event["request"] as? [String: Any])
        XCTAssertEqual(requestBlock["url"] as? String, "https://api.example.com/v1/habits/123")
        XCTAssertEqual(requestBlock["httpMethod"] as? String, "GET")
        XCTAssertEqual(requestBlock["clientIp"] as? String, "203.0.113.9")

        let metaData = try XCTUnwrap(event["metaData"] as? [String: Any])
        XCTAssertEqual(
            (metaData["app"] as? [String: Any])?["abortStatus"] as? Int,
            404
        )
    }

    func testConfigurablePayloadVersionIsUsedInHeaderAndBody() async throws {
        let transport = MockTransport()
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                payloadVersion: "4",
                synchronous: true
            ),
            transport: transport
        )
        await client.send(makeEvent())

        let firstRequest = await transport.requests.first
        let request = try XCTUnwrap(firstRequest)
        let headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) })
        XCTAssertEqual(headers["Bugsnag-Payload-Version"], "4")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["payloadVersion"] as? String, "4")
    }
}
