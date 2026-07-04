import Foundation

/// An HTTP request ready for delivery to the Bugsnag ingestion endpoint.
public struct BugsnagHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    /// Ordered header fields (name, value).
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(url: URL, method: String = "POST", headers: [(name: String, value: String)], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// The response from a delivery attempt.
public struct BugsnagHTTPResponse: Sendable {
    public var statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

/// Abstraction over HTTP delivery, so the core stays free of any HTTP client
/// dependency. `BugsnagVapor` provides an `AsyncHTTPClient`-backed
/// implementation; tests inject mocks.
public protocol BugsnagTransport: Sendable {
    func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse
}
