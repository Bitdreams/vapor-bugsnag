import BugsnagNotifier
import Vapor

extension Application {
    public var bugsnag: Bugsnag {
        Bugsnag(application: self)
    }

    public struct Bugsnag {
        let application: Application

        struct Key: StorageKey {
            typealias Value = Service
        }

        struct Service: Sendable {
            let client: BugsnagClient
            let sessionTracker: SessionTracker?
            let configuration: BugsnagConfiguration
            let userResolver: (@Sendable (Request) -> BugsnagUser?)?
        }

        /// Sets up Bugsnag reporting for this application. Call once from
        /// `configure.swift`, then register ``BugsnagMiddleware``.
        ///
        /// - Parameters:
        ///   - configuration: see ``BugsnagConfiguration``.
        ///   - transport: override HTTP delivery (tests). Defaults to the
        ///     application's shared `HTTPClient`.
        ///   - userResolver: extracts the authenticated user from a request
        ///     (e.g. from a JWT payload in `req.auth`) for the event's `user`
        ///     block. Runs inside request isolation, before delivery.
        public func configure(
            _ configuration: BugsnagConfiguration,
            transport: (any BugsnagTransport)? = nil,
            userResolver: (@Sendable (Request) -> BugsnagUser?)? = nil
        ) {
            var configuration = configuration
            if configuration.onDeliveryError == nil {
                let logger = application.logger
                configuration.onDeliveryError = { message in
                    logger.warning("\(message)")
                }
            }
            let transport = transport ?? AsyncHTTPClientTransport(
                client: application.http.client.shared,
                timeout: configuration.sendTimeout
            )
            let service = Service(
                client: BugsnagClient(configuration: configuration, transport: transport),
                sessionTracker: configuration.autoCaptureSessions
                    ? SessionTracker(configuration: configuration, transport: transport)
                    : nil,
                configuration: configuration,
                userResolver: userResolver
            )
            application.storage[Key.self] = service
            application.lifecycle.use(
                FlushOnShutdown(client: service.client, sessionTracker: service.sessionTracker)
            )
        }

        /// The configured client, if ``configure(_:transport:userResolver:)`` has run.
        public var client: BugsnagClient? {
            service?.client
        }

        /// The session tracker, if configured with `autoCaptureSessions` on.
        /// Use `await app.bugsnag.sessions?.flush()` to deliver pending
        /// session counts on demand.
        public var sessions: SessionTracker? {
            service?.sessionTracker
        }

        var service: Service? {
            application.storage[Key.self]
        }
    }
}

/// Drains in-flight deliveries and pending session counts before the
/// application shuts down.
private struct FlushOnShutdown: LifecycleHandler {
    let client: BugsnagClient
    let sessionTracker: SessionTracker?

    func shutdownAsync(_ application: Application) async {
        await client.flush()
        await sessionTracker?.shutdown()
    }
}
