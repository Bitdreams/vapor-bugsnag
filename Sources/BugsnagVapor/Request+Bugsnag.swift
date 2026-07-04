import BugsnagNotifier
import Vapor

extension Request {
    public var bugsnag: Bugsnag {
        Bugsnag(request: self)
    }

    public struct Bugsnag {
        let request: Request

        /// Leaves a breadcrumb on this request's trail. Breadcrumbs are
        /// per-request (stored in `request.storage`, never shared between
        /// requests) and are attached to every event reported for this
        /// request — both unhandled middleware reports and deliberate
        /// ``notify(_:severity:metadata:)`` calls.
        ///
        /// The trail is capped at `BugsnagConfiguration.maxBreadcrumbs`
        /// (default 50); the oldest breadcrumb is dropped first. Breadcrumb
        /// metadata is redacted with the same rules as event metadata.
        public func leaveBreadcrumb(
            _ name: String,
            type: BreadcrumbType = .manual,
            metadata: [String: JSONValue]? = nil
        ) {
            var trail = request.storage[BreadcrumbsKey.self] ?? []
            trail.append(Breadcrumb(name: name, type: type, metaData: metadata))
            let limit = max(0, request.application.bugsnag.service?.configuration.maxBreadcrumbs ?? 50)
            if trail.count > limit {
                trail.removeFirst(trail.count - limit)
            }
            request.storage[BreadcrumbsKey.self] = trail
        }

        /// The breadcrumbs left on this request so far, oldest first.
        public var breadcrumbs: [Breadcrumb] {
            request.storage[BreadcrumbsKey.self] ?? []
        }

        /// Deliberately reports a handled error with full request context.
        ///
        /// Never throws and (unless `synchronous` is set) never waits on the
        /// network — the event is snapshotted here and delivered in the
        /// background. A no-op when Bugsnag is not configured.
        public func notify(
            _ error: any Error,
            severity: Severity? = nil,
            metadata: [String: [String: JSONValue]]? = nil
        ) async {
            guard let service = request.application.bugsnag.service else { return }
            let event = BugsnagEventBuilder.makeEvent(
                for: error,
                on: request,
                service: service,
                escapedToMiddleware: false,
                severityOverride: severity,
                extraMetadata: metadata
            )
            await service.client.send(event)
        }
    }
}

/// Storage key for the per-request breadcrumb trail.
struct BreadcrumbsKey: StorageKey {
    typealias Value = [Breadcrumb]
}
