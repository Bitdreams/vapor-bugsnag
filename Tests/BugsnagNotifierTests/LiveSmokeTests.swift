import BugsnagNotifier
import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in integration smoke test against the live Bugsnag ingestion endpoint.
///
/// Skipped unless `BUGSNAG_KEY` is set:
/// ```
/// BUGSNAG_KEY=<project key> swift test --filter LiveSmokeTests
/// ```
/// Resolves the payload-version 4-vs-5 question from the spec; the result is
/// documented in the README.
final class LiveSmokeTests: XCTestCase {
    /// URLSession-backed transport, used only by this opt-in test.
    private struct URLSessionTransport: BugsnagTransport {
        func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            for header in request.headers {
                urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
            }
            urlRequest.httpBody = request.body
            let (_, response) = try await URLSession.shared.data(for: urlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return BugsnagHTTPResponse(statusCode: statusCode)
        }
    }

    /// Wraps a transport and records response status codes for assertion.
    private actor StatusRecordingTransport: BugsnagTransport {
        private let wrapped: any BugsnagTransport
        private(set) var statusCodes: [Int] = []

        init(wrapping wrapped: any BugsnagTransport) {
            self.wrapped = wrapped
        }

        func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
            let response = try await wrapped.send(request)
            statusCodes.append(response.statusCode)
            return response
        }
    }

    private func liveAPIKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["BUGSNAG_KEY"], !key.isEmpty else {
            throw XCTSkip("Set BUGSNAG_KEY to run the live smoke test")
        }
        return key
    }

    private func postDummyEvent(apiKey: String, payloadVersion: String) async throws -> Int {
        let transport = StatusRecordingTransport(wrapping: URLSessionTransport())
        let client = BugsnagClient(
            configuration: BugsnagConfiguration(
                apiKey: apiKey,
                releaseStage: "development",
                appVersion: bugsnagNotifierVersion,
                payloadVersion: payloadVersion,
                synchronous: true
            ),
            transport: transport
        )
        await client.send(
            BugsnagEvent(
                exceptions: [
                    BugsnagException(
                        errorClass: "VaporBugsnagSmokeTest",
                        message: "vapor-bugsnag live smoke test (payloadVersion \(payloadVersion)) — safe to ignore"
                    )
                ],
                context: "SMOKE /vapor-bugsnag",
                severity: .info,
                severityReason: .handledException,
                device: DeviceInfo.current(),
                groupingHash: "VaporBugsnagSmokeTest|payloadVersion-\(payloadVersion)"
            )
        )
        let statusCodes = await transport.statusCodes
        XCTAssertEqual(statusCodes.count, 1, "expected exactly one live POST")
        return statusCodes.first ?? 0
    }

    func testLiveEndpointAcceptsPayloadVersion5() async throws {
        let status = try await postDummyEvent(apiKey: liveAPIKey(), payloadVersion: "5")
        XCTAssertEqual(status, 200, "notify.bugsnag.com rejected payloadVersion 5")
    }

    func testLiveEndpointResponseToPayloadVersion4() async throws {
        // Informational: bugsnag-go historically sends "4". Not asserted as 200;
        // the console output documents what the endpoint returned.
        let status = try await postDummyEvent(apiKey: liveAPIKey(), payloadVersion: "4")
        print("[LiveSmokeTests] payloadVersion 4 → HTTP \(status)")
        XCTAssertNotEqual(status, 0, "no HTTP response received")
    }
}
