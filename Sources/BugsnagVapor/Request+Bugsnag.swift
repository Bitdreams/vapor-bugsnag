import BugsnagNotifier
import Vapor

extension Request {
    public var bugsnag: Bugsnag {
        Bugsnag(request: self)
    }

    public struct Bugsnag {
        let request: Request

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
