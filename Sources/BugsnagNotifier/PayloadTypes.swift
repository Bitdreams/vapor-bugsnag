import Foundation

/// The current version of this package, reported in the payload's `notifier` block.
public let bugsnagNotifierVersion = "1.0.0"

/// Event severity, as understood by Bugsnag.
public enum Severity: String, Codable, Sendable {
    case error
    case warning
    case info
}

/// Why the event has the severity it has.
public struct SeverityReason: Codable, Equatable, Sendable {
    public var type: String

    public init(type: String) {
        self.type = type
    }

    /// The error escaped the route handler and was caught by the middleware.
    public static let unhandledMiddleware = SeverityReason(type: "unhandledMiddleware")
    /// A deliberate `notify(...)` call with the default severity.
    public static let handledException = SeverityReason(type: "handledException")
    /// A deliberate `notify(...)` call with a caller-chosen severity.
    public static let userSpecifiedSeverity = SeverityReason(type: "userSpecifiedSeverity")
    /// An expected error (e.g. a 4xx `Abort`) reported for visibility.
    public static let handledError = SeverityReason(type: "handledError")
}

/// One frame of a stack trace. Usually absent on Linux — see the README.
public struct StackFrame: Codable, Equatable, Sendable {
    public var file: String
    public var lineNumber: Int
    public var method: String

    public init(file: String, lineNumber: Int, method: String) {
        self.file = file
        self.lineNumber = lineNumber
        self.method = method
    }
}

/// A single exception within an event.
public struct BugsnagException: Codable, Equatable, Sendable {
    public var errorClass: String
    public var message: String
    public var type: String
    public var stacktrace: [StackFrame]

    public init(
        errorClass: String,
        message: String,
        type: String = "swift",
        stacktrace: [StackFrame] = []
    ) {
        self.errorClass = errorClass
        self.message = message
        self.type = type
        self.stacktrace = stacktrace
    }
}

/// The `app` block: which deployment of which version produced the event.
public struct AppInfo: Codable, Equatable, Sendable {
    public var releaseStage: String
    public var version: String?
    public var type: String?

    public init(releaseStage: String, version: String? = nil, type: String? = nil) {
        self.releaseStage = releaseStage
        self.version = version
        self.type = type
    }
}

/// The `device` block: for a server notifier, the host that produced the event.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var osName: String
    public var hostname: String?
    public var runtimeVersions: [String: String]?

    public init(osName: String, hostname: String? = nil, runtimeVersions: [String: String]? = nil) {
        self.osName = osName
        self.hostname = hostname
        self.runtimeVersions = runtimeVersions
    }

    /// Device info for the current process.
    public static func current(hostname: String? = nil) -> DeviceInfo {
        #if os(Linux)
        let osName = "linux"
        #elseif os(macOS)
        let osName = "macOS"
        #else
        let osName = "unknown"
        #endif
        return DeviceInfo(
            osName: osName,
            hostname: hostname ?? ProcessInfo.processInfo.hostName,
            runtimeVersions: ["swift": compiledSwiftVersion]
        )
    }
}

/// The Swift language version this package was compiled with (coarse).
private var compiledSwiftVersion: String {
    #if swift(>=6.3)
    return "6.3"
    #elseif swift(>=6.2)
    return "6.2"
    #elseif swift(>=6.1)
    return "6.1"
    #elseif swift(>=6.0)
    return "6.0"
    #else
    return "5.x"
    #endif
}

/// The authenticated user associated with the request, if any.
public struct BugsnagUser: Codable, Equatable, Sendable {
    public var id: String?
    public var email: String?
    public var name: String?

    public init(id: String? = nil, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

/// A `Sendable` snapshot of the HTTP request that produced the event.
public struct RequestInfo: Codable, Equatable, Sendable {
    public var url: String?
    public var httpMethod: String?
    public var clientIp: String?
    public var headers: [String: String]?

    public init(
        url: String? = nil,
        httpMethod: String? = nil,
        clientIp: String? = nil,
        headers: [String: String]? = nil
    ) {
        self.url = url
        self.httpMethod = httpMethod
        self.clientIp = clientIp
        self.headers = headers
    }
}

/// The `notifier` block identifying this package.
public struct NotifierInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var url: String

    public init(name: String, version: String, url: String) {
        self.name = name
        self.version = version
        self.url = url
    }

    public static let current = NotifierInfo(
        name: "vapor-bugsnag",
        version: bugsnagNotifierVersion,
        url: "https://github.com/Bitdreams/vapor-bugsnag"
    )
}

/// One error event. `exceptions` is the only required field; everything else
/// is optional-but-valuable context.
public struct BugsnagEvent: Codable, Equatable, Sendable {
    public var exceptions: [BugsnagException]
    public var context: String?
    public var severity: Severity
    public var unhandled: Bool
    public var severityReason: SeverityReason?
    public var app: AppInfo?
    public var device: DeviceInfo?
    public var user: BugsnagUser?
    public var request: RequestInfo?
    public var breadcrumbs: [Breadcrumb]?
    public var metaData: [String: [String: JSONValue]]?
    public var groupingHash: String?

    public init(
        exceptions: [BugsnagException],
        context: String? = nil,
        severity: Severity = .error,
        unhandled: Bool = false,
        severityReason: SeverityReason? = nil,
        app: AppInfo? = nil,
        device: DeviceInfo? = nil,
        user: BugsnagUser? = nil,
        request: RequestInfo? = nil,
        breadcrumbs: [Breadcrumb]? = nil,
        metaData: [String: [String: JSONValue]]? = nil,
        groupingHash: String? = nil
    ) {
        self.exceptions = exceptions
        self.context = context
        self.severity = severity
        self.unhandled = unhandled
        self.severityReason = severityReason
        self.app = app
        self.device = device
        self.user = user
        self.request = request
        self.breadcrumbs = breadcrumbs
        self.metaData = metaData
        self.groupingHash = groupingHash
    }

    /// Redacts sensitive keys from request headers, metadata, and breadcrumb
    /// metadata, in place.
    public mutating func redact(keys redactedKeys: Set<String>) {
        if let headers = request?.headers {
            request?.headers = headers.reduce(into: [:]) { result, entry in
                result[entry.key] = redactedKeys.contains(entry.key.lowercased())
                    ? "[REDACTED]"
                    : entry.value
            }
        }
        if let metaData {
            self.metaData = metaData.mapValues { tab in
                tab.reduce(into: [:]) { result, entry in
                    result[entry.key] = redactedKeys.contains(entry.key.lowercased())
                        ? .string("[REDACTED]")
                        : entry.value.redacting(keys: redactedKeys)
                }
            }
        }
        if let breadcrumbs {
            self.breadcrumbs = breadcrumbs.map { $0.redacting(keys: redactedKeys) }
        }
    }
}

/// The top-level POST body sent to the notify endpoint.
public struct BugsnagPayload: Codable, Sendable {
    public var apiKey: String
    public var payloadVersion: String
    public var notifier: NotifierInfo
    public var events: [BugsnagEvent]

    public init(
        apiKey: String,
        payloadVersion: String,
        notifier: NotifierInfo = .current,
        events: [BugsnagEvent]
    ) {
        self.apiKey = apiKey
        self.payloadVersion = payloadVersion
        self.notifier = notifier
        self.events = events
    }
}
