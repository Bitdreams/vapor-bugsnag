import AsyncHTTPClient
import BugsnagNotifier
import Foundation
import NIOCore

/// Production transport backed by `AsyncHTTPClient` (the client Vapor already
/// ships). Use an application-level client, not `req.client`: delivery may
/// outlive the request.
public struct AsyncHTTPClientTransport: BugsnagTransport {
    let client: HTTPClient
    let timeout: TimeInterval

    public init(client: HTTPClient, timeout: TimeInterval = 5) {
        self.client = client
        self.timeout = timeout
    }

    public func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
        var httpRequest = HTTPClientRequest(url: request.url.absoluteString)
        httpRequest.method = .POST
        for header in request.headers {
            httpRequest.headers.add(name: header.name, value: header.value)
        }
        httpRequest.body = .bytes(ByteBuffer(data: request.body))
        let response = try await client.execute(
            httpRequest,
            timeout: .milliseconds(Int64(timeout * 1000))
        )
        return BugsnagHTTPResponse(statusCode: Int(response.status.code))
    }
}
