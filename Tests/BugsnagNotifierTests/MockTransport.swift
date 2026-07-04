import BugsnagNotifier
import Foundation

/// Records every request; behavior is configurable per test. No network.
actor MockTransport: BugsnagTransport {
    enum Behavior: Sendable {
        case succeed(status: Int)
        case fail
        case hang(seconds: Double)
    }

    private(set) var requests: [BugsnagHTTPRequest] = []
    private let behavior: Behavior

    init(behavior: Behavior = .succeed(status: 200)) {
        self.behavior = behavior
    }

    func send(_ request: BugsnagHTTPRequest) async throws -> BugsnagHTTPResponse {
        requests.append(request)
        switch behavior {
        case .succeed(let status):
            return BugsnagHTTPResponse(statusCode: status)
        case .fail:
            throw MockTransportError()
        case .hang(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return BugsnagHTTPResponse(statusCode: 200)
        }
    }

    struct MockTransportError: Error {}
}

extension MockTransport {
    /// The single delivered payload, decoded. Fails the test upstream if the
    /// count is not exactly one.
    var onlyPayload: BugsnagPayload? {
        get throws {
            guard requests.count == 1, let request = requests.first else { return nil }
            return try JSONDecoder().decode(BugsnagPayload.self, from: request.body)
        }
    }
}
