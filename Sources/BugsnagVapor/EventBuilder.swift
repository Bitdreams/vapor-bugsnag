import BugsnagNotifier
import Vapor

/// Builds a `Sendable` ``BugsnagEvent`` from a request and an error.
///
/// This runs synchronously inside request isolation — everything the delivery
/// task needs is copied into the event here, so no `Request` (non-`Sendable`)
/// ever crosses into a `Task`.
enum BugsnagEventBuilder {
    static func makeEvent(
        for error: any Error,
        on request: Request,
        service: Application.Bugsnag.Service,
        escapedToMiddleware: Bool,
        severityOverride: Severity? = nil,
        extraMetadata: [String: [String: JSONValue]]? = nil
    ) -> BugsnagEvent {
        let configuration = service.configuration
        let abort = error as? any AbortError
        let errorClass = String(reflecting: type(of: error))
        let message = abort?.reason
            ?? (error as? any LocalizedError)?.errorDescription
            ?? String(describing: error)

        let severity: Severity
        let unhandled: Bool
        let severityReason: SeverityReason
        if escapedToMiddleware {
            if let abort, (400..<500).contains(abort.status.code) {
                // Expected client errors (401/404/422...) are reported as
                // handled warnings; veto them in onBeforeNotify to drop.
                severity = .warning
                unhandled = false
                severityReason = .handledError
            } else {
                severity = .error
                unhandled = true
                severityReason = .unhandledMiddleware
            }
        } else {
            severity = severityOverride ?? .warning
            unhandled = false
            severityReason = severityOverride == nil ? .handledException : .userSpecifiedSeverity
        }

        let context = request.route.map { "\($0.method.rawValue) /\($0.path.string)" }
            ?? "\(request.method.rawValue) \(request.url.path)"

        var metaData = extraMetadata ?? [:]
        metaData["request", default: [:]]["requestId"] = .string(request.id)
        if let abort {
            metaData["app", default: [:]]["abortStatus"] = .int(Int(abort.status.code))
        }

        return BugsnagEvent(
            exceptions: [
                BugsnagException(
                    errorClass: errorClass,
                    message: message,
                    stacktrace: []  // thin by design on Linux; groupingHash compensates
                )
            ],
            context: context,
            severity: severity,
            unhandled: unhandled,
            severityReason: severityReason,
            app: AppInfo(
                releaseStage: configuration.releaseStage,
                version: configuration.appVersion,
                type: configuration.appType
            ),
            device: DeviceInfo.current(hostname: configuration.hostname),
            user: service.userResolver?(request),
            request: makeRequestInfo(from: request),
            metaData: metaData,
            groupingHash: "\(errorClass)|\(context)"
        )
    }

    private static func makeRequestInfo(from request: Request) -> RequestInfo {
        let scheme = request.headers.first(name: .xForwardedProto) ?? "http"
        let url = request.headers.first(name: .host)
            .map { "\(scheme)://\($0)\(request.url.string)" }
            ?? request.url.string

        let clientIp = request.headers.first(name: .xForwardedFor)
            .map { String($0.split(separator: ",")[0]).trimmingCharacters(in: .whitespaces) }
            ?? request.remoteAddress?.ipAddress

        var headers: [String: String] = [:]
        for (name, value) in request.headers {
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        return RequestInfo(
            url: url,
            httpMethod: request.method.rawValue,
            clientIp: clientIp,
            headers: headers
        )
    }
}
