import BugsnagNotifier
import Vapor

/// Forwards `AbortError` through the tracing wrapper, so
/// `throw Abort(.notFound).bugsnagTraced()` still renders a 404 (not a
/// generic 500) when Vapor's `ErrorMiddleware` handles the rethrown error.
///
/// Lives here on purpose: the wrapper is declared in the Vapor-free core, and
/// this adapter owns all Vapor coupling.
extension BugsnagTracedError: AbortError {
    public var status: HTTPResponseStatus {
        (wrapped as? any AbortError)?.status ?? .internalServerError
    }

    public var reason: String {
        // Deliberately generic for non-abort errors: `reason` is rendered to
        // the HTTP client, and internal error details must not leak there.
        (wrapped as? any AbortError)?.reason ?? status.reasonPhrase
    }

    public var headers: HTTPHeaders {
        (wrapped as? any AbortError)?.headers ?? [:]
    }
}
