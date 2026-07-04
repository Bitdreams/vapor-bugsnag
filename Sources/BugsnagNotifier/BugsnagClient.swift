import Foundation

/// Delivers events to Bugsnag. Owns the configuration and the injected
/// transport; all delivery state (in-flight tasks) is actor-isolated.
///
/// Delivery never throws and never blocks the caller beyond payload
/// preparation: in the default (asynchronous) mode the POST runs in a
/// fire-and-forget task with a timeout, and any failure is swallowed.
public actor BugsnagClient {
    public let configuration: BugsnagConfiguration
    private let transport: any BugsnagTransport

    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0

    public init(configuration: BugsnagConfiguration, transport: any BugsnagTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Fire-and-forget entry point: usable without `await` from any context.
    /// Ignores the `synchronous` flag by construction — use ``send(_:)`` where
    /// synchronous test delivery matters.
    ///
    /// Note: ``flush()`` only awaits deliveries that have already been
    /// enqueued; an event passed to `report` may not have reached the queue
    /// yet. Use `await send(_:)` where deterministic draining matters.
    public nonisolated func report(_ event: BugsnagEvent) {
        Task { await self.send(event) }
    }

    /// Applies release-stage gating, redaction, and `onBeforeNotify`, then
    /// delivers. Honors `configuration.synchronous`: when true the POST is
    /// awaited (tests); otherwise it runs in a tracked fire-and-forget task.
    public func send(_ event: BugsnagEvent) async {
        guard let request = makeHTTPRequest(for: event) else { return }
        if configuration.synchronous {
            await deliver(request)
        } else {
            let id = nextTaskID
            nextTaskID += 1
            inFlight[id] = Task {
                await self.deliver(request)
                self.finish(id)
            }
        }
    }

    /// Awaits all in-flight deliveries (e.g. before shutdown).
    public func flush() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func finish(_ id: Int) {
        inFlight[id] = nil
    }

    // MARK: - Payload preparation

    private func makeHTTPRequest(for event: BugsnagEvent) -> BugsnagHTTPRequest? {
        if let enabled = configuration.enabledReleaseStages,
           !enabled.contains(configuration.releaseStage) {
            return nil
        }

        var event = event
        event.redact(keys: configuration.redactedKeys)
        if let onBeforeNotify = configuration.onBeforeNotify, !onBeforeNotify(&event) {
            return nil
        }

        let payload = BugsnagPayload(
            apiKey: configuration.apiKey,
            payloadVersion: configuration.payloadVersion,
            events: [event]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return BugsnagHTTPRequest(
            url: configuration.notifyEndpoint,
            headers: [
                ("Bugsnag-Api-Key", configuration.apiKey),
                ("Bugsnag-Payload-Version", configuration.payloadVersion),
                ("Bugsnag-Sent-At", formatter.string(from: Date())),
                ("Content-Type", "application/json"),
            ],
            body: body
        )
    }

    // MARK: - Delivery

    /// POSTs the request, racing it against `sendTimeout`. Never throws:
    /// reporting must never fail or delay the app. Failures (including
    /// non-200 responses) are surfaced only through `onDeliveryError`.
    private func deliver(_ request: BugsnagHTTPRequest) async {
        let transport = self.transport
        let timeout = configuration.sendTimeout
        do {
            let response = try await withThrowingTaskGroup(of: BugsnagHTTPResponse.self) { group in
                group.addTask {
                    try await transport.send(request)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw DeliveryTimeoutError()
                }
                guard let response = try await group.next() else {
                    throw DeliveryTimeoutError()
                }
                group.cancelAll()
                return response
            }
            if response.statusCode != 200 {
                configuration.onDeliveryError?("Bugsnag delivery failed: HTTP \(response.statusCode)")
            }
        } catch is DeliveryTimeoutError {
            configuration.onDeliveryError?("Bugsnag delivery timed out after \(timeout)s")
        } catch {
            configuration.onDeliveryError?("Bugsnag delivery failed: \(error)")
        }
    }

    private struct DeliveryTimeoutError: Error {}
}
