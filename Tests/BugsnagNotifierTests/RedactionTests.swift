import BugsnagNotifier
import Foundation
import XCTest

final class RedactionTests: XCTestCase {
    private func makeClient(
        redactedKeys: Set<String> = [],
        transport: MockTransport
    ) -> BugsnagClient {
        BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: "k",
                releaseStage: "production",
                redactedKeys: redactedKeys,
                synchronous: true
            ),
            transport: transport
        )
    }

    func testDefaultSensitiveHeadersAreRedactedCaseInsensitively() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        await client.send(
            BugsnagEvent(
                exceptions: [BugsnagException(errorClass: "E", message: "m")],
                request: RequestInfo(headers: [
                    "AUTHORIZATION": "Bearer secret-token",
                    "Cookie": "session=abc",
                    "Accept": "application/json",
                ])
            )
        )

        let maybePayload = try await transport.onlyPayload
        let payload = try XCTUnwrap(maybePayload)
        let headers = try XCTUnwrap(payload.events[0].request?.headers)
        XCTAssertEqual(headers["AUTHORIZATION"], "[REDACTED]")
        XCTAssertEqual(headers["Cookie"], "[REDACTED]")
        XCTAssertEqual(headers["Accept"], "application/json")

        let body = await transport.requests[0].body
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(raw.contains("secret-token"), "raw payload must not contain the token")
        XCTAssertFalse(raw.contains("session=abc"))
    }

    func testMetadataIsRedactedRecursively() async throws {
        let transport = MockTransport()
        let client = makeClient(redactedKeys: ["x-api-key"], transport: transport)
        await client.send(
            BugsnagEvent(
                exceptions: [BugsnagException(errorClass: "E", message: "m")],
                metaData: [
                    "account": [
                        "password": "hunter2",
                        "plan": "pro",
                        "nested": ["X-Api-Key": "abc123", "safe": true],
                    ]
                ]
            )
        )

        let maybePayload = try await transport.onlyPayload
        let payload = try XCTUnwrap(maybePayload)
        let account = try XCTUnwrap(payload.events[0].metaData?["account"])
        XCTAssertEqual(account["password"], .string("[REDACTED]"))
        XCTAssertEqual(account["plan"], .string("pro"))
        XCTAssertEqual(
            account["nested"],
            .object(["X-Api-Key": .string("[REDACTED]"), "safe": .bool(true)])
        )

        let body = await transport.requests[0].body
        let raw = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(raw.contains("hunter2"))
        XCTAssertFalse(raw.contains("abc123"))
    }

    func testMandatoryKeysCannotBeRemovedByCustomConfiguration() async throws {
        let transport = MockTransport()
        // A consumer passing a custom set must not lose the mandatory keys.
        let client = makeClient(redactedKeys: ["x-custom"], transport: transport)
        await client.send(
            BugsnagEvent(
                exceptions: [BugsnagException(errorClass: "E", message: "m")],
                request: RequestInfo(headers: [
                    "Authorization": "Bearer t",
                    "X-Custom": "v",
                ])
            )
        )

        let maybePayload = try await transport.onlyPayload
        let payload = try XCTUnwrap(maybePayload)
        let headers = try XCTUnwrap(payload.events[0].request?.headers)
        XCTAssertEqual(headers["Authorization"], "[REDACTED]")
        XCTAssertEqual(headers["X-Custom"], "[REDACTED]")
    }
}
