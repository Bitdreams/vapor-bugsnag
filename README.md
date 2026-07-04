# vapor-bugsnag

A Bugsnag error-reporting notifier for [Vapor](https://vapor.codes) server apps on Linux.

Bugsnag has no Linux SDK and the old community Vapor package is archived, so this is a small, clean-room, pure-HTTP-API integration: an `AsyncMiddleware` catches errors in the request pipeline and POSTs structured events to Bugsnag's Error Reporting API (`https://notify.bugsnag.com`), landing backend errors in the same Bugsnag org as your iOS/mobile crash data.

Two products:

- **`BugsnagNotifier`** — the Vapor-free core: configuration, `Codable`/`Sendable` payload types, a `BugsnagClient` actor, and a `BugsnagTransport` protocol for injected HTTP delivery.
- **`BugsnagVapor`** — the Vapor 4 adapter: `BugsnagMiddleware`, `app.bugsnag` / `req.bugsnag` extensions, request snapshotting, and an `AsyncHTTPClient`-backed transport.

Compiles clean in Swift 6 language mode (full data-race safety, a superset of `-strict-concurrency=complete`).

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Bitdreams/vapor-bugsnag.git", from: "1.0.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "BugsnagVapor", package: "vapor-bugsnag"),
    ]),
]
```

## Usage

```swift
// configure.swift
import BugsnagVapor

app.bugsnag.configure(.init(
    apiKey: Environment.get("BUGSNAG_KEY")!,      // never hardcode or log this
    releaseStage: app.environment.name,
    enabledReleaseStages: ["production", "staging"],
    appVersion: myBackendVersion,
    redactedKeys: ["x-api-key"]                   // authorization/cookie/password are always redacted
))
app.middleware.use(BugsnagMiddleware())           // BEFORE (outside) ErrorMiddleware

// deliberate/handled report anywhere with a Request
await req.bugsnag.notify(SomeError.badThing, severity: .warning,
                         metadata: ["billing": ["plan": "pro"]])
```

Unhandled errors escaping a route handler are reported automatically and rethrown, so Vapor's `ErrorMiddleware` still renders the HTTP response.

### Behavior

- **Reporting never blocks or fails the request.** Delivery is fire-and-forget with a timeout (`sendTimeout`, default 5 s); failures never propagate. A `synchronous` flag exists for tests only. In-flight deliveries are drained automatically on application shutdown; `await app.bugsnag.client?.flush()` drains them on demand.
- **Delivery failures are logged, not thrown.** Transport errors, timeouts, and non-200 responses invoke `onDeliveryError` with a diagnostic message (never containing the API key). The Vapor adapter defaults it to a warning on `app.logger`, so a misconfigured key is visible in logs.
- **Severity mapping** (overridable via `onBeforeNotify`): errors escaping to the middleware are `unhandled` / `error` (`severityReason: unhandledMiddleware`); a 4xx `Abort` is reported as a handled `warning` (`handledError`) — veto those in `onBeforeNotify` if they're noise; `req.bugsnag.notify` is handled, defaulting to `warning` (`handledException`, or `userSpecifiedSeverity` when you pass a severity).
- **Redaction**: header and metadata keys matching `redactedKeys` (case-insensitive, any nesting depth) are replaced with `[REDACTED]` before encoding. `authorization`, `cookie`, and `password` are always redacted and cannot be configured away.
- **Release-stage gating**: with `enabledReleaseStages` set, events from other stages are dropped before any POST.
- **User attribution**: pass a `userResolver` closure to `configure` to extract the authenticated user (e.g. your JWT payload from `req.auth`) into the event's `user` block. It runs inside request isolation.

### Breadcrumbs

Leave breadcrumbs anywhere you have a `Request`; they're attached (oldest first) to every event reported for that request — unhandled middleware reports and deliberate `notify` calls alike:

```swift
req.bugsnag.leaveBreadcrumb("Card validated", type: .process)
req.bugsnag.leaveBreadcrumb("Charge attempted", metadata: ["provider": "stripe"])
```

- **Per-request, not process-global**: the trail lives in `request.storage`, so concurrent requests never share or leak breadcrumbs. It costs nothing when no event is reported.
- `type` is one of Bugsnag's eight categories (`navigation`, `request`, `process`, `log`, `user`, `state`, `error`, `manual`); the default is `.manual`. Timestamps are recorded automatically and encoded as ISO-8601.
- The trail is capped at `BugsnagConfiguration.maxBreadcrumbs` (default 50); the oldest breadcrumb is dropped first.
- Breadcrumb metadata goes through the same redaction as everything else (case-insensitive, any nesting depth).
- `BugsnagMiddleware` automatically leaves one `request`-type breadcrumb (`"GET /path"`) when a request enters the pipeline, so every event carries at least the incoming request. Disable with `BugsnagMiddleware(automaticRequestBreadcrumb: false)`.

### Stack traces: thin by default, opt-in throw-site capture

Swift on Linux does not attach a throw-site stack trace to a caught `Error` — by the time the middleware sees it, the frames are unwound. By default, events therefore ship with an empty `stacktrace` and lean on `errorClass`, `message`, `context` (the matched route pattern, e.g. `GET /v1/habits/:id`), request/user metadata, and a `groupingHash` of `errorClass|route` so events group per-endpoint instead of collapsing into one bucket. For an API backend this is enough to diagnose incidents: which endpoint, which user, which error, what status.

Where you want more, capture the stack **at the throw site** by opting in per throw:

```swift
throw DatabaseWriteError().bugsnagTraced()

// or, when re-throwing someone else's error:
} catch {
    throw BugsnagTracedError(wrapping: error)
}
```

`bugsnagTraced()` wraps the error in a `BugsnagTracedError` that records `Thread.callStackSymbols` at that moment, plus the exact `#fileID`/`#line`/`#function` of the call site as the guaranteed top frame. The middleware (and `req.bugsnag.notify`) then populates the event's `stacktrace` from it. Reporting uses the **wrapped** error for `errorClass`, `message`, severity mapping, and `groupingHash`, so tracing an error never changes how its events group in Bugsnag. Tracing is idempotent — re-wrapping keeps the original throw-site frames — and `BugsnagVapor` forwards `AbortError` through the wrapper, so `throw Abort(.notFound).bugsnagTraced()` still renders a 404.

Set expectations accordingly:

- The top frame (file, line, function) is always exact. The frames below it are **mangled** Swift symbols (`$s...` — demangle with `swift demangle`) with no line numbers, and release builds may lose frames to inlining. On Linux, frames from the app image may show only a return address unless the binary exports symbols; frames are capped at 50.
- Any error type can supply its own frames instead by conforming to `BugsnagStackTraceProviding` (a `bugsnagStacktrace: [StackFrame]` property).
- Optional image-level improvement (not configured by this package): build the deployment image with frame pointers enabled — `-Xcc -fno-omit-frame-pointer` (plus `-Xswiftc -Xllvm -Xswiftc -frame-pointer=all` where supported) — and link with `--export-dynamic` so `backtrace_symbols` resolves names instead of bare addresses. Both are deployment-image decisions, documented here as a follow-up only.

### "Caused by" error chains

Wrapper errors can surface their root cause as separate "caused by" entries in the Bugsnag UI — one `exceptions[]` entry per link, primary error first (the same convention as `bugsnag-go`'s `Unwrap` support). Conform wrapper errors to `BugsnagChainedError`:

```swift
import BugsnagNotifier

struct SyncFailedError: BugsnagChainedError, LocalizedError {
    let underlyingError: (any Error)?
    var errorDescription: String? { "syncing habits failed" }
}

// in a route handler
do {
    try await store.save(habit)
} catch {
    throw SyncFailedError(underlyingError: error)  // reported as SyncFailedError, caused by `error`
}
```

Chains are followed through `BugsnagChainedError.underlyingError` and, best-effort, through `NSError`'s `NSUnderlyingErrorKey` (the Cocoa convention — useful on Darwin, typically absent on Linux). Traversal is capped at 8 links (`BugsnagErrorChain.unwrap(_:maxDepth:)` is public if you need it directly) and guards against cycles. Severity, `unhandled`, and `groupingHash` remain keyed off the primary (outermost) error, so wrapping an `Abort` does not change how the event is classified or grouped.

## Payload version

Events are sent with `Bugsnag-Payload-Version: 5` (also as `payloadVersion` in the body), the current schema version. The reference `bugsnag-go` notifier historically sends `4` and the endpoint accepts both. The version is configurable via `BugsnagConfiguration.payloadVersion`.

To confirm against the live endpoint, run the opt-in smoke test with a real project key (it posts one `info`-severity dummy event for each version and reports the HTTP status):

```
BUGSNAG_KEY=<project key> swift test --filter LiveSmokeTests
```

> Live confirmation pending: the smoke test has not yet been run against a real project key. Default remains `5` per Bugsnag's current documentation. Update this note with the observed result after running it.

## Development

```
swift build
swift test
swift build -Xswiftc -strict-concurrency=complete   # must be clean
```

Unit tests use an injected mock transport and never hit the network. See [CLAUDE.md](CLAUDE.md) for conventions and [docs/IMPLEMENTATION-SPEC.md](docs/IMPLEMENTATION-SPEC.md) for the full build brief.

## License

MIT.
