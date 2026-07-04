import BugsnagNotifier
import Vapor

/// Catches errors escaping the route handler, reports them to Bugsnag, and
/// rethrows so Vapor's `ErrorMiddleware` still renders the HTTP response.
///
/// Register it **before** (outside) `ErrorMiddleware`:
/// ```swift
/// app.bugsnag.configure(...)
/// app.middleware.use(BugsnagMiddleware())
/// ```
///
/// The event is built from the request *inside* the `catch`, within request
/// isolation; only the resulting `Sendable` event reaches the delivery task.
public struct BugsnagMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            if let service = request.application.bugsnag.service {
                let event = BugsnagEventBuilder.makeEvent(
                    for: error,
                    on: request,
                    service: service,
                    escapedToMiddleware: true
                )
                await service.client.send(event)
            }
            throw error
        }
    }
}
