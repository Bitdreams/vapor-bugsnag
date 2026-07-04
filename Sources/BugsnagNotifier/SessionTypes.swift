import Foundation

/// The version of the session payload schema sent to the sessions endpoint.
/// Fixed at `"1.0"` — the only published version (bugsnag-go `sessions/publisher.go`).
public let bugsnagSessionPayloadVersion = "1.0"

/// One in-flight session. Server notifiers use the convention of **one
/// session per HTTP request**; the Vapor middleware starts one at the top of
/// the pipeline and stores it on the request.
///
/// The handled/unhandled counters track how many events were reported during
/// the session, so events can carry a `session` block and Bugsnag can compute
/// the stability score.
public struct BugsnagSession: Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    /// Handled events reported during this session so far.
    public var handledCount: Int
    /// Unhandled events reported during this session so far.
    public var unhandledCount: Int

    public init(
        id: String = UUID().uuidString,
        startedAt: Date = Date(),
        handledCount: Int = 0,
        unhandledCount: Int = 0
    ) {
        self.id = id
        self.startedAt = startedAt
        self.handledCount = handledCount
        self.unhandledCount = unhandledCount
    }

    /// The `session` block to embed in an event payload.
    public var eventSession: BugsnagEventSession {
        BugsnagEventSession(
            id: id,
            startedAt: BugsnagSessionTimestamp.iso8601(startedAt),
            events: BugsnagEventSession.Counts(handled: handledCount, unhandled: unhandledCount)
        )
    }
}

/// The `events[].session` block of an error payload: attributes the event to
/// a session for stability-score accounting.
public struct BugsnagEventSession: Codable, Equatable, Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public var handled: Int
        public var unhandled: Int

        public init(handled: Int, unhandled: Int) {
            self.handled = handled
            self.unhandled = unhandled
        }
    }

    public var id: String
    /// ISO-8601 timestamp of when the session started.
    public var startedAt: String
    public var events: Counts

    public init(id: String, startedAt: String, events: Counts) {
        self.id = id
        self.startedAt = startedAt
        self.events = events
    }
}

/// One minute-bucket in the session payload: how many sessions started in
/// the minute beginning at `startedAt`.
public struct BugsnagSessionCounts: Codable, Equatable, Sendable {
    /// ISO-8601 timestamp truncated to the minute.
    public var startedAt: String
    public var sessionsStarted: Int

    public init(startedAt: String, sessionsStarted: Int) {
        self.startedAt = startedAt
        self.sessionsStarted = sessionsStarted
    }
}

/// The top-level POST body sent to the sessions endpoint
/// (`Bugsnag-Payload-Version: 1.0`). Unlike the error payload, the API key
/// travels only in the header.
public struct BugsnagSessionPayload: Codable, Sendable {
    public var notifier: NotifierInfo
    public var app: AppInfo
    public var device: DeviceInfo
    public var sessionCounts: [BugsnagSessionCounts]

    public init(
        notifier: NotifierInfo = .current,
        app: AppInfo,
        device: DeviceInfo,
        sessionCounts: [BugsnagSessionCounts]
    ) {
        self.notifier = notifier
        self.app = app
        self.device = device
        self.sessionCounts = sessionCounts
    }
}

/// Timestamp helpers shared by session tracking.
enum BugsnagSessionTimestamp {
    /// ISO-8601 / RFC 3339 in UTC, e.g. `2026-07-04T12:34:56Z`.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The start of the minute containing `date` (session counts are
    /// aggregated per minute).
    static func minuteBucket(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
