import Foundation

/// Counts sessions started per minute bucket and periodically POSTs the
/// aggregated counts to the Bugsnag sessions endpoint, powering the
/// stability score.
///
/// Mirrors the reference server notifiers (bugsnag-go's `sessions.tracker` /
/// bugsnag-ruby's session tracker): sessions are never delivered
/// individually — only `{ startedAt: <minute>, sessionsStarted: N }`
/// aggregates, flushed every ``BugsnagConfiguration/sessionFlushInterval``
/// seconds and on demand via ``flush()``.
///
/// Like ``BugsnagClient``, delivery never throws and never blocks the
/// caller: the POST runs in a tracked fire-and-forget task with a timeout
/// (awaited only when `configuration.synchronous` is set, for tests), and
/// failures surface solely through `configuration.onDeliveryError`.
public actor SessionTracker {
    public let configuration: BugsnagConfiguration
    private let transport: any BugsnagTransport

    /// Sessions started, keyed by minute bucket.
    private var counts: [Date: Int] = [:]
    private var flushLoop: Task<Void, Never>?
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    private var isShutDown = false

    public init(configuration: BugsnagConfiguration, transport: any BugsnagTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Records the start of a new session (one per HTTP request, per the
    /// server-notifier convention) and returns it so callers can attach it
    /// to events reported during the session. Starts the periodic flush loop
    /// on first use.
    ///
    /// This only increments an in-memory counter — it never performs I/O, so
    /// it is safe to await on the request path.
    @discardableResult
    public func startSession(at date: Date = Date()) -> BugsnagSession {
        counts[BugsnagSessionTimestamp.minuteBucket(for: date), default: 0] += 1
        ensureFlushLoop()
        return BugsnagSession(startedAt: date)
    }

    /// Delivers all accumulated counts now and awaits any in-flight
    /// deliveries (e.g. before shutdown).
    public func flush() async {
        await flushPending()
        while let task = inFlight.values.first {
            await task.value
        }
    }

    /// Stops the periodic flush loop and performs a final drain.
    public func shutdown() async {
        isShutDown = true
        flushLoop?.cancel()
        flushLoop = nil
        await flush()
    }

    // MARK: - Flush machinery

    private func ensureFlushLoop() {
        guard flushLoop == nil, !isShutDown else { return }
        let interval = configuration.sessionFlushInterval
        guard interval > 0, interval.isFinite else { return }
        flushLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.flushPending()
            }
        }
    }

    /// Drains the counters into one payload and hands it to delivery.
    /// Honors `configuration.synchronous` exactly like event delivery.
    private func flushPending() async {
        guard let request = makeSessionRequest() else { return }
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

    private func finish(_ id: Int) {
        inFlight[id] = nil
    }

    // MARK: - Payload preparation

    /// Drains accumulated counts. Returns nil (dropping the counts) when
    /// there is nothing to send or the release stage is gated out.
    private func makeSessionRequest() -> BugsnagHTTPRequest? {
        let pending = counts
        counts = [:]
        guard !pending.isEmpty else { return nil }
        if let enabled = configuration.enabledReleaseStages,
           !enabled.contains(configuration.releaseStage) {
            return nil
        }

        let payload = BugsnagSessionPayload(
            notifier: .current,
            app: AppInfo(
                releaseStage: configuration.releaseStage,
                version: configuration.appVersion,
                type: configuration.appType
            ),
            device: DeviceInfo.current(hostname: configuration.hostname),
            sessionCounts: pending
                .sorted { $0.key < $1.key }
                .map { bucket, started in
                    BugsnagSessionCounts(
                        startedAt: BugsnagSessionTimestamp.iso8601(bucket),
                        sessionsStarted: started
                    )
                }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { return nil }

        return BugsnagHTTPRequest(
            url: configuration.sessionsEndpoint,
            headers: [
                ("Bugsnag-Api-Key", configuration.apiKey),
                ("Bugsnag-Payload-Version", bugsnagSessionPayloadVersion),
                ("Bugsnag-Sent-At", BugsnagSessionTimestamp.iso8601(Date())),
                ("Content-Type", "application/json"),
            ],
            body: body
        )
    }

    // MARK: - Delivery

    /// POSTs the request, racing it against `sendTimeout` — same semantics
    /// as event delivery. The sessions endpoint acknowledges with HTTP 202,
    /// so any 2xx counts as success.
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
            if !(200..<300).contains(response.statusCode) {
                configuration.onDeliveryError?("Bugsnag session delivery failed: HTTP \(response.statusCode)")
            }
        } catch is DeliveryTimeoutError {
            configuration.onDeliveryError?("Bugsnag session delivery timed out after \(timeout)s")
        } catch {
            configuration.onDeliveryError?("Bugsnag session delivery failed: \(error)")
        }
    }

    private struct DeliveryTimeoutError: Error {}
}
