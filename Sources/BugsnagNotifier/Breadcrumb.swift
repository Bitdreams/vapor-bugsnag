import Foundation

/// The category of a ``Breadcrumb``, as understood by Bugsnag.
///
/// These are the eight types accepted by the payload-v5 schema; they drive
/// the icon and filtering in the Bugsnag dashboard timeline.
public enum BreadcrumbType: String, Codable, Equatable, Sendable {
    case navigation
    case request
    case process
    case log
    case user
    case state
    case error
    case manual
}

/// One entry in an event's breadcrumb trail: a timestamped note of something
/// that happened before the error.
///
/// Encodes per the payload-v5 contract: `timestamp` is an ISO-8601 string,
/// `type` is one of the eight official type strings, and `metaData` is a
/// JSON object of additional diagnostic values.
public struct Breadcrumb: Codable, Equatable, Sendable {
    /// When the breadcrumb was left. Encoded as an ISO-8601 string with
    /// fractional seconds (e.g. `2026-07-04T12:34:56.789Z`).
    public var timestamp: Date
    /// A short summary of what happened, shown in the dashboard timeline.
    public var name: String
    /// The breadcrumb category.
    public var type: BreadcrumbType
    /// Additional diagnostic values. Redacted with the same case-insensitive,
    /// recursive rules as event metadata before delivery.
    public var metaData: [String: JSONValue]?

    public init(
        timestamp: Date = Date(),
        name: String,
        type: BreadcrumbType = .manual,
        metaData: [String: JSONValue]? = nil
    ) {
        self.timestamp = timestamp
        self.name = name
        self.type = type
        self.metaData = metaData
    }

    // MARK: - Codable (timestamp as ISO-8601 string)

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case name
        case type
        case metaData
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .timestamp)
        guard let date = Self.parseTimestamp(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Breadcrumb timestamp is not ISO-8601: \(raw)"
            )
        }
        self.timestamp = date
        self.name = try container.decode(String.self, forKey: .name)
        self.type = try container.decode(BreadcrumbType.self, forKey: .type)
        self.metaData = try container.decodeIfPresent([String: JSONValue].self, forKey: .metaData)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatTimestamp(timestamp), forKey: .timestamp)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(metaData, forKey: .metaData)
    }

    static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Returns a copy with `metaData` redacted using the same rules as event
    /// metadata: top-level keys are matched case-insensitively and nested
    /// containers are redacted recursively.
    func redacting(keys redactedKeys: Set<String>) -> Breadcrumb {
        guard let metaData else { return self }
        var redacted = self
        redacted.metaData = metaData.reduce(into: [:]) { result, entry in
            result[entry.key] = redactedKeys.contains(entry.key.lowercased())
                ? .string("[REDACTED]")
                : entry.value.redacting(keys: redactedKeys)
        }
        return redacted
    }
}
