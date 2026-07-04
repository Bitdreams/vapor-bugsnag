import Foundation

/// Configuration for a ``BugsnagClient``.
public struct BugsnagConfiguration: Sendable {
    /// Keys that are always redacted regardless of what the consumer passes.
    public static let mandatoryRedactedKeys: Set<String> = ["authorization", "cookie", "password"]

    /// The default Bugsnag ingestion endpoint.
    public static let defaultNotifyEndpoint = URL(string: "https://notify.bugsnag.com/")!

    /// The Bugsnag project notifier API key. Never log this.
    public var apiKey: String

    /// The current release stage, e.g. `production` or `staging`.
    public var releaseStage: String

    /// If set, events are dropped (before any POST) unless `releaseStage` is in this set.
    public var enabledReleaseStages: Set<String>?

    /// The consuming app's version, to correlate errors to releases.
    public var appVersion: String?

    /// The app type reported to Bugsnag.
    public var appType: String

    /// The ingestion endpoint. Override for testing/proxying only.
    public var notifyEndpoint: URL

    /// Header/metadata keys to redact before encoding (matched case-insensitively).
    /// ``mandatoryRedactedKeys`` are always included in addition to these.
    public var redactedKeys: Set<String> {
        didSet { redactedKeys = Self.normalize(redactedKeys) }
    }

    /// The server identity reported in the `device` block (e.g. an ECS task id).
    /// Defaults to the process host name when nil.
    public var hostname: String?

    /// The maximum number of breadcrumbs kept in a trail. When a trail is
    /// full, the oldest breadcrumb is dropped first. Defaults to 50.
    public var maxBreadcrumbs: Int

    /// The Bugsnag payload version header/body value. `"5"` is the current schema.
    public var payloadVersion: String

    /// How long a delivery POST may take before it is abandoned.
    public var sendTimeout: TimeInterval

    /// When true, `notify`/`send` await the POST instead of firing and forgetting.
    /// Intended for tests only.
    public var synchronous: Bool

    /// Mutate or veto an event just before delivery. Return `false` to drop it.
    public var onBeforeNotify: (@Sendable (inout BugsnagEvent) -> Bool)?

    /// Called with a diagnostic message when a delivery fails (transport
    /// error, timeout, or non-200 response). Failures never propagate to the
    /// request path, so this is the only signal a misconfiguration produces.
    /// `BugsnagVapor` defaults this to a warning on the application logger.
    /// The message never contains the API key.
    public var onDeliveryError: (@Sendable (String) -> Void)?

    public init(
        apiKey: String,
        releaseStage: String,
        enabledReleaseStages: Set<String>? = nil,
        appVersion: String? = nil,
        appType: String = "vapor",
        notifyEndpoint: URL = BugsnagConfiguration.defaultNotifyEndpoint,
        redactedKeys: Set<String> = [],
        hostname: String? = nil,
        maxBreadcrumbs: Int = 50,
        payloadVersion: String = "5",
        sendTimeout: TimeInterval = 5,
        synchronous: Bool = false,
        onBeforeNotify: (@Sendable (inout BugsnagEvent) -> Bool)? = nil,
        onDeliveryError: (@Sendable (String) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.releaseStage = releaseStage
        self.enabledReleaseStages = enabledReleaseStages
        self.appVersion = appVersion
        self.appType = appType
        self.notifyEndpoint = notifyEndpoint
        self.redactedKeys = Self.normalize(redactedKeys)
        self.hostname = hostname
        self.maxBreadcrumbs = maxBreadcrumbs
        self.payloadVersion = payloadVersion
        self.sendTimeout = sendTimeout
        self.synchronous = synchronous
        self.onBeforeNotify = onBeforeNotify
        self.onDeliveryError = onDeliveryError
    }

    private static func normalize(_ keys: Set<String>) -> Set<String> {
        Set(keys.map { $0.lowercased() }).union(mandatoryRedactedKeys)
    }
}
