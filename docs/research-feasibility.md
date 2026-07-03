---
goal: "Evaluate options for integrating Bugsnag error/crash reporting into the consumer Vapor backend: (a) adopt an existing/maintained integration, or (b) assess feasibility and shape of building our own. Recommend a path."
context: []
confidence: 88%
coherence: 🟢
---

# Bugsnag Error Reporting for the Vapor Backend on Linux

## 1. TL;DR Recommendation

**Build a minimal custom notifier that POSTs directly to the Bugsnag Error Reporting API (`https://notify.bugsnag.com`) from a small async ErrorMiddleware.** Do **not** re-adopt `nodes-vapor/bugsnag` (now `ml-archive/bugsnag`).

Deciding factors, in order of weight:

1. **The community package is dead.** `ml-archive/bugsnag` was **archived (read-only) on April 20, 2024**; its last *stable* release is **3.1.0 (Feb 26, 2020, Swift 5.2)**. It **never shipped a stable 4.x** — the `4.0.0-rc.2` this backend previously pinned was a release candidate that was never finalized. It predates Swift concurrency; there is no Sendable/strict-concurrency support. This is the confirmed reason "Vapor has poor Bugsnag support." (95% confidence)
2. **There is no maintained replacement package,** and Bugsnag's official Swift SDK (`bugsnag-cocoa`) is **Apple-platforms-only (iOS/macOS/tvOS/watchOS) — no Linux target** — so it cannot be reused on server-side Linux. The "build our own" path is therefore a **pure HTTP-API integration**, not a wrapper. (90% confidence)
3. **The Error Reporting HTTP API is small, current, well-documented, and stable.** It is the same ingestion endpoint every official SDK uses. A JSON POST with three headers and a Codable payload gets you full events in the existing Bugsnag org. The genuinely trivial part (JSON POST) dominates the effort; the only hard part (server-side stack traces on Linux) is a known limitation you can accept. (85% confidence)
4. **Consolidation preference is satisfiable cheaply.** Because the iOS app is already on Bugsnag, a ~1-day custom notifier lands backend errors in the same org with no new vendor. Switching to Sentry (which has a marginally better server-Swift story) is not justified. (85% confidence)

**Baseline to beat (do-nothing):** Today errors only hit CloudWatch logs. The custom notifier is a strict, low-cost improvement (grouping, alerting, user/request context, cross-referencing with iOS crashes) — recommend building it. If effort must be deferred, the honest interim is **structured JSON logging + a CloudWatch metric-filter alarm on error level**, which is cheap but gives no grouping or stack context.

**One caveat worth a developer decision:** server-side Swift cannot cheaply attach a throw-site stack trace to a *caught* `Error`. Expect events to be rich in `errorClass` + `message` + request/user context but **thin or empty on `stacktrace`**. If per-error stack traces are a hard requirement, that changes the calculus (see §3.3) — flagging as the one item that could warrant a 🛑.

---

## 2. Evidence on Existing Packages

| Package | Role | Last activity | Vapor/Swift | Strict concurrency | Verdict |
|---|---|---|---|---|---|
| `ml-archive/bugsnag` (was `nodes-vapor/bugsnag`) | Vapor middleware + notifier | **Archived Apr 20, 2024**; last stable **3.1.0 = Feb 26, 2020**; 33 releases, 4.x only reached RC | Badges: Vapor 4 / Swift 5.2 | **None** (predates async/await maturity & Sendable) | ❌ Do not adopt. Unmaintained, RC-only 4.x, no Sendable. Confirms the "poor support" hypothesis. |
| `bugsnag/bugsnag-cocoa` (official) | Apple crash/error SDK | Actively maintained | `Package.swift` platforms: iOS/macOS/tvOS/watchOS | N/A | ❌ Not usable server-side. **No Linux platform.** Cannot reuse code on Linux container. |
| Any other Swift-server Bugsnag package/fork | — | None found | — | — | ❌ None exists. `awesome-vapor` still points only at the archived nodes package. |
| `swift-sentry/swift-sentry` + `SentryVapor` (alternative vendor, aside) | Native Swift → Sentry, SwiftLog backend, Vapor request abstraction | Maintained, community | Server-Swift/Vapor | Modern | ⚠️ Only relevant if switching vendors. Better server-Swift story than Bugsnag, but iOS is already on Bugsnag → not recommended. |

**Verified facts with dates:**
- Archive date **Apr 20, 2024** and last stable **3.1.0 / Feb 26, 2020** come from the GitHub repo page for `nodes-vapor/bugsnag` (redirects to `ml-archive/bugsnag`). (95%)
- `bugsnag-cocoa` `Package.swift` declares only Apple platforms (macOS 10.11, iOS 9.0, tvOS 9.2, watchOS 6.3); the product is described as "for iOS, macOS, tvOS and watchOS." No Linux. (90%)
- **Could not independently verify** whether any private fork of the nodes package has been kept alive; public search shows none. (flagged)

### Alternative-vendor aside (one paragraph, as requested)
The server-side Swift ecosystem does have a somewhat healthier story for **Sentry** than for Bugsnag: `swift-sentry/swift-sentry` is a native Swift implementation with a `SentryVapor` companion and a SwiftLog backend, and `ericlewis/swift-log-sentry` offers a breadcrumb-based SwiftLog backend. These are community (not vendor) projects, but they are more current than anything Bugsnag-shaped for Linux. Despite that, switching vendors is **not** recommended here: our iOS app already reports heavily to Bugsnag, and the value of one org spanning client + server (shared releases, user correlation, single alerting surface) outweighs a marginally nicer server SDK. Keep Sentry only as a fallback if the custom Bugsnag notifier proves unexpectedly costly.

---

## 3. Custom-Integration Blueprint (the recommended path)

### 3.1 Endpoint, headers, auth
Verified against the official Error Reporting API and a concrete server-side (ColdFusion) implementation that hits the same endpoint:

- **URL:** `POST https://notify.bugsnag.com/`
- **Headers:**
  - `Bugsnag-Api-Key: <BUGSNAG_KEY>` (the project's notifier API key; same env var name the old integration used — `BUGSNAG_KEY`)
  - `Bugsnag-Payload-Version: 5` (current payload version)
  - `Bugsnag-Sent-At: <ISO-8601 timestamp>`
  - `Content-Type: application/json`
- No OAuth/token exchange; the API key in the header is the auth. (Do not confuse with the **Data Access API** at `api.bugsnag.com`, which is a different, read-side API.)

### 3.2 Payload skeleton (payload version 5)
Top-level and event shape confirmed from the official JSON schema + a working server example. Required fields: `events[].exceptions[]` with at least one exception, each exception requiring `errorClass` and a `stacktrace` array (the array **may be empty**). Everything else is optional but valuable.

```jsonc
{
  "apiKey": "<BUGSNAG_KEY>",
  "payloadVersion": "5",
  "notifier": {
    "name": "vapor-bugsnag",
    "version": "1.0.0",
    "url": "https://github.com/Bitdreams/vapor-bugsnag"
  },
  "events": [
    {
      "exceptions": [
        {
          "errorClass": "AppError",          // e.g. String(reflecting: type(of: error))
          "message": "Habit not found",       // error.localizedDescription / reason
          "type": "swift",
          "stacktrace": [                       // often empty on Linux; see 3.3
            { "file": "HabitController.swift", "lineNumber": 42, "method": "get(_:)" }
          ]
        }
      ],
      "context": "GET /v1/habits/:id",          // route path — great for grouping
      "severity": "error",                       // "error" | "warning" | "info"
      "unhandled": true,
      "severityReason": { "type": "unhandledMiddleware" },
      "app": {
        "releaseStage": "production",            // from environment
        "version": "3.2.12",                      // backend version from configure.swift
        "type": "vapor"
      },
      "device": {
        "osName": "linux",
        "hostname": "<ecs-task-id>",
        "runtimeVersions": { "swift": "5.9" }
      },
      "user": { "id": "<uuid>", "email": "<optional>" },  // from JWT payload if authenticated
      "request": {
        "url": "https://api.../v1/habits/123",
        "httpMethod": "GET",
        "clientIp": "<x-forwarded-for>",
        "headers": { /* filtered — strip Authorization, Cookie */ }
      },
      "metaData": {
        "request": { "requestId": "...", "route": "..." },
        "app": { "abortStatus": 404 }
      }
    }
  ]
}
```

**Grouping tip:** Bugsnag groups by the top stack frame by default. With thin stack traces, set `context` to the route and optionally a `groupingHash` (e.g. `errorClass + route`) so events group sensibly instead of collapsing into one bucket. (80%)

### 3.3 Stack traces server-side (the one hard part — read carefully)
This is where realistic expectations matter:

- **Swift 5.9+ has built-in backtracing on Linux, but it is for _crashes_** — fatal errors, traps, signals — via the runtime signal handler and the `SWIFT_BACKTRACE` env var. It does **not** attach a backtrace to an ordinary caught, thrown `Error` value. (85%)
- **Swift does not record a throw-site stack on `Error`** by default. By the time your ErrorMiddleware catches it, the throwing frames are already unwound. (85%)
- **`Thread.callStackSymbols` works on Linux but is weak:** it captures the *current* stack (i.e. the middleware, not the throw site), symbols are **mangled** and frequently **incomplete**, especially in `-fomit-frame-pointer` release builds. This is a long-standing, documented server-Swift pain point (swift-nio #1144, swift-backtrace symbol-resolution issues). (80%)
- **Practical consequence:** send events with **empty or minimal `stacktrace`** and lean on `errorClass`, `message`, `context` (route), request, and user metadata. That is genuinely useful for an API backend — most server incidents are diagnosed from "which endpoint, which user, which error type, what status" rather than a Swift frame list.
- **If real stack traces become a hard requirement:** options are (a) capture `Thread.callStackSymbols` at the throw site inside a custom `AppError` initializer and carry it on the error (adds boilerplate, still mangled), or (b) build release images with `-Xcc -fno-omit-frame-pointer` to improve completeness, or (c) rely on Swift's crash backtraces (JSON output mode) for *fatal* crashes only and ship those separately. None are free. **This is the single decision that could warrant pausing.**

### 3.4 Async, non-blocking delivery from the middleware
Reporting must never block or fail the request. Pattern:

- Implement `AsyncMiddleware`. In the `catch`, **extract everything needed into a `Sendable` value struct** *before* leaving the request's isolation, then fire-and-forget:

```swift
struct BugsnagEvent: Content, Sendable { /* the payload above */ }

final class BugsnagMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: req)
        } catch {
            // Build a Sendable snapshot NOW (Request is not Sendable).
            let event = BugsnagEvent(from: error, request: req, app: req.application)
            let client = req.application.client            // app-level client, safe after req ends
            let key = req.application.bugsnagKey
            Task {                                          // detached-style fire-and-forget
                _ = try? await client.post("https://notify.bugsnag.com/") { out in
                    out.headers.add(name: "Bugsnag-Api-Key", value: key)
                    out.headers.add(name: "Bugsnag-Payload-Version", value: "5")
                    out.headers.add(name: "Bugsnag-Sent-At", value: ISO8601.now())
                    try out.content.encode(event, as: .json)
                }
            }
            throw error   // let the existing ErrorMiddleware produce the HTTP response
        }
    }
}
```

- Order it **outside** (before) the existing `ErrorMiddleware` in the chain so it observes the thrown error but lets `ErrorMiddleware` still format the client response. (75% — verify against the current middleware registration order in `configure.swift`.)
- Use `req.application.client` (or a dedicated `HTTPClient`) rather than `req.client` for the detached task, since the request lifecycle may be ending. (80%)

### 3.5 Strict-concurrency / Sendable gotchas
- **`Request` is not `Sendable`.** Never capture `req` inside the `Task`. Capture only the `Sendable` payload struct + the key + a client reference. This is the #1 thing that would fail to compile under strict concurrency and is exactly what the old package couldn't handle.
- Make the payload types (`BugsnagEvent`, `Exception`, `StackFrame`, etc.) `struct … : Content, Sendable`. Codable + value types = automatically Sendable.
- Filter sensitive headers (`Authorization`, `Cookie`, password/email fields) **before** encoding — matches the old integration's field-filtering feature and the CLAUDE.md "never log sensitive data" rule.
- For `User: BugsnagUser`-style user tracking, pull the user id/email from the already-decoded JWT payload on `req.auth`, into the snapshot struct — do not carry the model into the Task.
- Consider a tiny in-process batching/queue actor if error volume is high (an `actor` is Sendable and lets you coalesce/rate-limit POSTs). Optional for v1.

---

## 4. Effort / Maintenance Comparison

| Option | Build effort | Ongoing maintenance | Strict-concurrency fit | Stack traces | Data lands in existing Bugsnag org | Verdict |
|---|---|---|---|---|---|---|
| **Custom notifier (recommended)** | ~0.5–1.5 days (JSON POST trivial; payload + middleware + filtering) | Low — you own ~200 lines; API v5 is stable | ✅ Clean, you control Sendable | ⚠️ thin/empty (accepted) | ✅ Yes | ✅ **Build this** |
| Re-adopt `ml-archive/bugsnag` | Days of fighting/forking | ❌ You inherit an archived, RC-only, pre-concurrency package you must fork & maintain forever | ❌ Would need rewrite for Sendable anyway | ~same limitation | ✅ Yes | ❌ Worse than writing fresh |
| Switch to Sentry (`swift-sentry`) | ~1–2 days | Medium — third-party dep, but maintained | ✅ Modern | ✅ Better (SwiftLog integration) | ❌ New vendor, splits from iOS | ⚠️ Only if Bugsnag path fails |
| Do nothing (CloudWatch logs only) | 0 | 0 (status quo) | n/a | n/a | ❌ | ⚠️ Baseline; no grouping/alerting/context |
| Interim: structured logs + CloudWatch alarm | ~0.25 day | Low | n/a | n/a | ❌ | ⚠️ Cheap stopgap, not a substitute |

**Key insight:** re-adopting the archived package is *strictly worse* than a fresh custom notifier — you'd have to make it Sendable-clean anyway (i.e. rewrite it), while inheriting dead code and an RC pin. The custom notifier is less code than the fork you'd otherwise maintain.

---

## 5. Sources (with credibility + access date 2026-07-04)

**Tier 1 — official / primary**
- Bugsnag Error Reporting API (Apiary): `https://bugsnagerrorreportingapi.docs.apiary.io/` and `/reference/0/notify/send-error-reports` — official API spec (page body did not render fully via fetch; corroborated below). (endpoint/headers verified elsewhere)
- Bugsnag docs / SmartBear portal: `https://docs.bugsnag.com/api/` → redirects to `https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions` — confirms `notify.bugsnag.com` (errors) and `sessions.bugsnag.com`. Current & supported.
- `bugsnag/bugsnag-cocoa` `Package.swift` + repo: `https://github.com/bugsnag/bugsnag-cocoa` — confirms Apple-only platforms, no Linux. (Tier 1, high)
- `nodes-vapor/bugsnag` → `github.com/ml-archive/bugsnag` — repo page: **archived Apr 20, 2024**, last stable **3.1.0 Feb 26, 2020**, Swift 5.2 badge, 33 releases (4.x RC-only). (Tier 1 primary metadata, high)
- Swift.org "On-Crash Backtraces in Swift" (`https://www.swift.org/blog/swift-5.9-backtraces/`) + `swiftlang/swift docs/Backtracing.rst` — confirm 5.9 backtracing is crash-oriented, `SWIFT_BACKTRACE`, frame-pointer caveat. (Tier 1, high)
- Vapor docs: Client (`docs.vapor.codes/basics/client/`), Middleware, Errors, and `vapor/Sources/Vapor/Middleware/ErrorMiddleware.swift` — confirm async client POST + JSON encode and ErrorMiddleware role. (Tier 1, high)

**Tier 2 — schemas / mirrors / notifier source**
- `api-evangelist/bugsnag` repo — mirrors official **JSON schema** (`bugsnag-error-event-schema.json`), OpenAPI, Postman collection; used to confirm event/exception/stacktrace/app/device/user/request/metaData shape and that `exceptions` (with `errorClass` + `stacktrace`) is the only required event field. (Tier 2, medium-high)
- `bugsnag/bugsnag-go/payload.go` — official notifier payload construction, cross-checks field names & payload versioning. (Tier 2, high)
- `swift-server/swift-backtrace`, `apple/swift-nio#1144`, swift-backtrace symbol issues — corroborate weak/mangled/incomplete `Thread.callStackSymbols` on Linux. (Tier 2/3, medium-high)

**Tier 3 — practitioner example**
- Ben Nadel, "Using BugSnag As A Server-Side Logging Service In ColdFusion" (`bennadel.com/blog/4462`) — a working server-side POST: **verified** endpoint `https://notify.bugsnag.com/`, headers `Bugsnag-Api-Key`, `Bugsnag-Payload-Version: 5`, `Bugsnag-Sent-At`, `Content-Type: application/json`, and payload skeleton. Author notes it's "far from feature complete." (Tier 3, but directly corroborates Tier 1/2 → raises confidence)

**Tier 3 — alternative vendor aside**
- `swift-sentry/swift-sentry`, `ericlewis/swift-log-sentry` — maintained community Sentry backends for server Swift/Vapor.

### Flagged / unverified
- The Apiary and SmartBear doc *bodies* did not fully render via automated fetch; endpoint, headers, and payload-version `5` are nonetheless **triple-corroborated** (official docs mention + JSON schema + working ColdFusion example + bugsnag-go). Confidence high despite the render gaps.
- **Payload version:** `5` is current for the JSON body format; bugsnag-go tests reference `4` historically. Treat `5` as correct for a new integration but easy to confirm in one test POST. (80%)
- Exact **current middleware registration order** in this backend's `configure.swift` was not read this session — verify before slotting the new middleware. (flagged)
- No evidence found of any maintained public fork of the nodes package. (absence, not proof)
