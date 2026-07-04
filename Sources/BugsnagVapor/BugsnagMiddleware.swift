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
///
/// By default the middleware also leaves one `request`-type breadcrumb
/// (`"GET /path"`) when the request enters the pipeline, so every event
/// carries at least the incoming request in its breadcrumb trail. Pass
/// `automaticRequestBreadcrumb: false` to disable.
public struct BugsnagMiddleware: AsyncMiddleware {
    private let automaticRequestBreadcrumb: Bool

    public init(automaticRequestBreadcrumb: Bool = true) {
        self.automaticRequestBreadcrumb = automaticRequestBreadcrumb
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if automaticRequestBreadcrumb {
            request.bugsnag.leaveBreadcrumb(
                "\(request.method.rawValue) \(request.url.path)",
                type: .request,
                metadata: ["requestId": .string(request.id)]
            )
        }
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
