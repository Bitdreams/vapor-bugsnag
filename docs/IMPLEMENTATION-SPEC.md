# Implementation Spec / Prompt: `swift-bugsnag-vapor`

> **Purpose.** This is a self-contained brief for building a new, standalone Swift package — a Bugsnag error-reporting notifier for Vapor server apps on Linux. Hand it to a fresh Claude instance (or engineer) working in a **new, empty git repository**. It assumes no prior context. It is derived from two research reports (linked at the end) — you do **not** need to read them to execute this, but they contain the evidence behind every decision here.
>
> **One-line summary of what you are building:** a small SwiftPM package that catches errors in a Vapor request pipeline and POSTs structured event JSON to Bugsnag's Error Reporting API (`https://notify.bugsnag.com`), so a Vapor backend's errors show up in Bugsnag alongside the org's existing iOS crash data.

---

## 0. Why this exists (context you can trust without re-verifying)

- Bugsnag has **no Linux-capable official SDK** (`bugsnag-cocoa` is Apple-platforms-only). The only community Vapor package (`nodes-vapor/bugsnag` / `ml-archive/bugsnag`) was **archived April 2024**, last stable **3.1.0 (Feb 2020)**, and predates Swift strict concurrency. So this is a **from-scratch, pure-HTTP-API integration** — not a wrapper around anything.
- Bugsnag's Error Reporting API is small, stable, and the same ingestion endpoint every official SDK uses. Building a clean notifier is ~0.5–1.5 days of work; the JSON POST is trivial, and the only genuinely hard part (server-side stack traces) is a **known, accepted limitation** — see §7.
- The reference design to model on is **`bugsnag/bugsnag-go` v2** (MIT, actively maintained, statically typed, fire-and-forget goroutine delivery ≈ Swift `Task`). All Bugsnag notifiers are MIT; this is a clean-room reimplementation, so there is no licensing obstacle.

## 1. Goals and non-goals

**Goals (v1):**
- A SwiftPM package with two products: a Vapor-independent `BugsnagNotifier` core and a `BugsnagVapor` integration layer.
- Catch **unhandled** errors from the Vapor pipeline via an `AsyncMiddleware` and report them.
- Allow **deliberate/handled** reports from anywhere with a request (`req.bugsnag.notify(...)`).
- Fire-and-forget async delivery that **never blocks or fails the request**.
- Rich context: app/release-stage/version, request (route, method, filtered headers, client IP), authenticated user (id/email), arbitrary metadata; sensitive-key redaction.
- Correct behavior under **Swift strict concurrency** (`Sendable`, no capturing `Request` in a `Task`).
- A test hook to make delivery synchronous so tests can assert on it.

**Non-goals (defer to v2, do not build now):**
- Session tracking / stability score (separate `sessions.bugsnag.com` endpoint + batch-flush loop).
- Breadcrumbs.
- Durable retry / persistent queue / error-event batching.
- Rich stack-trace symbolication (see §7 — v1 ships thin/empty stack traces by design).

## 2. Target environment

- Swift 5.9+, **strict concurrency enabled**. Package must compile clean with `-strict-concurrency=complete`.
- Vapor 4 (4.115+), Linux (the consumer runs on containerized Linux). Also builds on macOS for dev.
- Dependencies: Vapor (for the `BugsnagVapor` target only). The `BugsnagNotifier` core should depend only on Foundation + an async HTTP client abstraction (prefer `async-http-client` OR accept an injected client protocol so the core stays Vapor-free — your call, but keep the core adapter-agnostic).

## 3. The Bugsnag API contract (verified — implement exactly this)

- **Endpoint:** `POST https://notify.bugsnag.com/` (make the base URL configurable; default to this).
- **Headers:**
  - `Bugsnag-Api-Key: <apiKey>`
  - `Bugsnag-Payload-Version: 5`
  - `Bugsnag-Sent-At: <ISO-8601 timestamp>`
  - `Content-Type: application/json`
- **Auth:** the API key in the header. No OAuth. (Do NOT use `api.bugsnag.com` — that is the read-side Data Access API, a different thing.)
- **Success:** HTTP 200.
- **The apiKey ALSO goes in the JSON body** (`apiKey` top-level field) in addition to the header. Send both — the reference notifier does.
- **⚠️ Payload-version open item:** the current schema uses `"5"` and that is the correct default. The best code reference (`bugsnag-go`) historically emits `"4"`; the endpoint accepts both. **Action for the implementer:** default to `5`, and as the very first runtime check, do ONE real test POST with a dummy event and confirm a 200; if the specific fields are rejected, try `4`. Document the result in the repo README.

### 3.1 Payload skeleton (payload version 5)

Only `events[].exceptions[]` is truly required (each exception needs `errorClass` + a `stacktrace` array, which **may be empty**). Everything else is optional-but-valuable. Model all of this as `Codable, Sendable` value types.

```jsonc
{
  "apiKey": "<apiKey>",
  "payloadVersion": "5",
  "notifier": {
    "name": "vapor-bugsnag",
    "version": "<package semver>",
    "url": "<repo url>"
  },
  "events": [
    {
      "exceptions": [
        {
          "errorClass": "AppError",        // String(reflecting: type(of: error)) or a mapped name
          "message": "Habit not found",     // error.localizedDescription / Abort.reason
          "type": "swift",
          "stacktrace": []                   // usually empty on Linux — see §7
        }
      ],
      "context": "GET /v1/habits/:id",       // MATCHED ROUTE, not concrete URL — drives grouping
      "severity": "error",                    // "error" | "warning" | "info"
      "unhandled": true,
      "severityReason": { "type": "unhandledMiddleware" },
      "app":    { "releaseStage": "production", "version": "3.2.x", "type": "vapor" },
      "device": { "osName": "linux", "hostname": "<ecs-task-id>", "runtimeVersions": { "swift": "5.9" } },
      "user":   { "id": "<uuid>", "email": "<optional>" },
      "request": {
        "url": "https://api.../v1/habits/123",
        "httpMethod": "GET",
        "clientIp": "<x-forwarded-for>",
        "headers": { /* FILTERED — strip Authorization, Cookie, etc. */ }
      },
      "metaData": { "request": { "requestId": "..." }, "app": { "abortStatus": 404 } },
      "groupingHash": "AppError|GET /v1/habits/:id"   // set when stacktraces are thin, so events don't collapse
    }
  ]
}
```

## 4. Package structure

Single SwiftPM package, two targets/products:

- **`BugsnagNotifier` (core, no Vapor dependency):**
  - `BugsnagConfiguration` — `Sendable` struct (see §5).
  - Payload model types — `BugsnagEvent`, `Exception`, `StackFrame`, `AppInfo`, `DeviceInfo`, `BugsnagUser`, `RequestInfo`, `Notifier`, `SeverityReason`, `Severity` — all `struct … : Codable, Sendable`.
  - `BugsnagClient` — an `actor` owning config + an HTTP client; `report(_ event: BugsnagEvent)` (fire-and-forget) and `flush()`.
  - `onBeforeNotify` closure typealias: `@Sendable (inout BugsnagEvent) -> Bool` (return false to veto).
- **`BugsnagVapor` (integration, depends on Vapor):**
  - `BugsnagMiddleware: AsyncMiddleware` — the catch/snapshot/rethrow pattern (§6).
  - `Application`/`Request` extensions: `app.bugsnag` accessor (config + client via Application storage, matching Vapor's DI-through-Application-extensions convention), `req.bugsnag.notify(...)` for handled reports.
  - A `RequestInfo` snapshot builder + user extraction from `req.auth` (JWT payload).
  - Middleware registration helper.

This mirrors the core-notifier-vs-framework-adapter split used by bugsnag-go (core) + its `Handler`.

## 5. Configuration surface (v1)

`BugsnagConfiguration: Sendable` with these fields:

| Field | Purpose | Default |
|---|---|---|
| `apiKey` | project notifier key | from `BUGSNAG_KEY` env (consumer passes it) |
| `releaseStage` | `production`/`staging`/… | consumer passes `app.environment.name` |
| `enabledReleaseStages` | only notify on these stages | nil = all; if set and current not in it → drop before POST |
| `appVersion` | correlate errors to a release | consumer passes backend version from `configure.swift` |
| `appType` | e.g. `vapor` | `"vapor"` |
| `notifyEndpoint` | override ingestion URL | `https://notify.bugsnag.com/` |
| `redactedKeys` | header/metadata keys to strip | must include `authorization`, `cookie`, `password` (case-insensitive) |
| `hostname` | server identity | ECS task id / `Host.current().name` |
| `synchronous` | await the POST (tests) vs fire-and-forget (prod) | `false` |
| `onBeforeNotify` | mutate/veto events before send | nil |

## 6. Middleware pattern (the critical strict-concurrency part)

The #1 thing that must be right: **`Request` is not `Sendable`.** Snapshot everything you need into a `Sendable` value struct BEFORE leaving request isolation, then fire the detached task. Never capture `req` inside the `Task`.

```swift
public final class BugsnagMiddleware: AsyncMiddleware {
    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: req)
        } catch {
            // Build a Sendable snapshot NOW.
            let event = req.application.bugsnag.makeEvent(from: error, req: req, unhandled: true)
            req.application.bugsnag.report(event)   // fire-and-forget (or await if synchronous)
            throw error                              // let the existing ErrorMiddleware format the response
        }
    }
}
```

- Register this middleware **before** (outside) the app's existing `ErrorMiddleware`, so it observes the error but `ErrorMiddleware` still renders the HTTP response. (When integrating into the consumer backend specifically, verify the exact registration order in that repo's `configure.swift`.)
- Use an **application-level** HTTP client (not `req.client`) inside the detached task, since the request lifecycle may be ending.
- Timeout the POST (a few seconds) so a hung request can't leak tasks.
- One POST per event; **no batching** in v1.

## 7. Stack traces — ship thin, by design (do not fight this)

- Swift on Linux does **not** attach a throw-site stack to a caught `Error`; by the time the middleware catches it, the frames are unwound. `Thread.callStackSymbols` captures the *current* (middleware) stack, mangled and often incomplete in release builds. Swift 5.9 backtracing exists but is for **crashes/traps**, not thrown errors.
- **Therefore:** send `stacktrace: []` (or minimal) and lean on `errorClass` + `message` + `context`(route) + request + user. This is genuinely enough for an API backend — incidents are diagnosed from "which endpoint, which user, which error, what status," not a frame list.
- **Set `groupingHash`** (e.g. `errorClass + "|" + route`) so thin-stacktrace events group per-endpoint instead of collapsing into one Bugsnag bucket.
- Optional niceties (do NOT block v1 on these): imitate the kinbiko/bugsnag `Wrap()` idea — a custom `AppError` that captures `Thread.callStackSymbols` at the throw site and carries it; and/or build release images with `-Xcc -fno-omit-frame-pointer`. Leave these as documented follow-ups.

## 8. Severity & handled-vs-unhandled semantics

- `severity`: `"error" | "warning" | "info"`. `unhandled`: `true` = escaped to middleware (counts against stability); `false` = deliberate `notify`.
- Mapping policy (make it overridable via `onBeforeNotify`):
  - Error propagating out of the handler to the middleware → **unhandled**, `severity: error`, `severityReason.type: "unhandledMiddleware"`.
  - Vapor `Abort` with a **4xx** status → expected/handled: consider `severity: warning`, or **drop 4xx entirely** to avoid noise from 401/404/422. Treat **5xx / non-`Abort`** as unhandled `error`.
  - Deliberate `req.bugsnag.notify(error, severity:)` → **handled**, `severityReason.type: "handledException"` (or `userSpecifiedSeverity`).

## 9. Public API the consuming Vapor app should get

```swift
// configure.swift
app.bugsnag.configure(.init(
    apiKey: Environment.get("BUGSNAG_KEY")!,
    releaseStage: app.environment.name,
    enabledReleaseStages: ["production", "staging"],
    appVersion: myBackendVersion,     // read from the app
    appType: "vapor",
    redactedKeys: ["authorization", "cookie", "password"],
    synchronous: false
))
app.middleware.use(BugsnagMiddleware())      // BEFORE ErrorMiddleware

// deliberate/handled report anywhere with a Request
try await req.bugsnag.notify(SomeError.badThing, severity: .warning,
                             metadata: ["billing": ["plan": "pro"]])
```

## 10. Testing requirements

- Payload encoding: assert the JSON shape matches §3.1 (field names, `payloadVersion`, headers computed).
- Redaction: `Authorization`/`Cookie`/configured keys are stripped from `request.headers` and metadata before encoding.
- Release-stage gating: with `enabledReleaseStages` set and current stage excluded, no POST is attempted.
- Severity mapping: 4xx `Abort` → warning/dropped per policy; 5xx/non-Abort → unhandled error.
- Delivery: with `synchronous: true`, `report`/`notify` awaits and a stubbed HTTP client receives exactly one correctly-formed request. Use an injected mock client (don't hit the network in unit tests).
- Strict concurrency: the package must build with complete concurrency checking; add a test target that exercises `report` from within a simulated middleware `catch` to prove no `Request` capture.
- **One integration smoke test (manual/opt-in, gated on a real `BUGSNAG_KEY`):** the payload-version 4-vs-5 confirmation POST from §3 — resolve and document which version the live endpoint accepts.

## 11. Repo deliverables

- `Package.swift` (two products), source per §4, tests per §10.
- `README.md`: install snippet, the §9 usage, the stack-trace expectation (§7), and the resolved payload-version note.
- MIT `LICENSE` (courtesy alignment with the Bugsnag notifier ecosystem; a clean-room port carries no obligation, but MIT is the norm here).
- CI (GitHub Actions) building on Linux with strict concurrency.

## 12. Acceptance criteria

1. `swift build` and `swift test` green on Linux with `-strict-concurrency=complete`.
2. A Vapor demo/integration test: an endpoint that throws → the mock client receives a well-formed event with the right `context`(route), `severity`, `unhandled`, `app`, filtered `request`, and (if authed) `user`.
3. Reporting is provably non-blocking (request latency unaffected; a hung/erroring notify endpoint does not fail or delay the request).
4. No sensitive headers/fields leave the process (redaction test passes).
5. Payload-version resolved against the live endpoint and documented.

---

### Source reports (evidence, optional reading)
- `claude/reports/2026-07-04/bugsnag-vapor-integration-researcher-report.md` — feasibility: why custom, the API contract, the middleware/Sendable pattern, the stack-trace limitation.
- `claude/reports/2026-07-04/bugsnag-reference-notifier-researcher-report.md` — the `bugsnag-go` reference architecture, config surface, event pipeline, delivery model, severity semantics, and what does/doesn't port to Linux.
