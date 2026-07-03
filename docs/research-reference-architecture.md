---
goal: "Identify the best REFERENCE Bugsnag server-side notifier library (any language) to use as an architectural model for a from-scratch Swift/Vapor notifier, and extract a transferable design + API contract that can be handed to another Claude instance as an implementation spec."
context: ["claude/reports/2026-07-04/bugsnag-vapor-integration-researcher-report.md"]
confidence: 87%
coherence: 🟢
---

# Bugsnag Reference Notifier — Architecture to Port to Swift/Vapor

> Builds directly on `claude/reports/2026-07-04/bugsnag-vapor-integration-researcher-report.md`. That report already settled: the Swift/Vapor community package is dead (archived Apr 2024), Bugsnag has no Linux SDK, and the plan is a custom notifier POSTing to `https://notify.bugsnag.com`. **This report does not re-argue that** — it answers "which existing notifier's *design* should we copy, and what exactly is that design."

## 1. TL;DR — Chosen Reference

**Primary reference: `bugsnag/bugsnag-go` (v2).** It is the closest architectural analog to our target (statically typed, struct-based payload marshaling ≈ Swift `Codable`; fire-and-forget goroutine delivery ≈ Swift detached `Task`; a `Synchronous` flag ≈ our "await the POST" option; a flat `Configuration` struct ≈ a Swift config struct). It is **actively maintained** (v2.6.4, published **2026-04-14**) and **MIT-licensed**, so studying and porting the design is unambiguously fine. (90%)

**Secondary reference (design teacher): `kinbiko/bugsnag`** — an *unofficial*, MIT-licensed "well-documented, idiomatic, opinionated rewrite" of the Go notifier. It is worth reading **specifically because its author redesigned the official notifier to be cleaner**, and two of its ideas map onto exactly the hard problems the prior report flagged for Swift:
- `Wrap(ctx, err, msg)` captures the **stack trace at the error's origin** — Go has the same "thrown errors carry no stack" problem Swift has on Linux. This is the pattern our `AppError`-captures-`callStackSymbols` idea should imitate. (85%)
- `notifier.Close()` **flushes pending reports on shutdown** — the model for draining an async delivery queue before a Fargate task exits. (80%)

Use **bugsnag-go for the payload/field/delivery mechanics** and **kinbiko/bugsnag for the ergonomic API shape and the stack-trace-at-origin idea.** Everything below is written language-neutrally so it can become the Swift spec.

## 2. Ranked Survey of Official (+ notable community) Notifiers

Verdict axis that matters here = **"how well does its concurrency/type model teach the Swift async/await + Sendable + Codable design?"** — not raw popularity.

| Rank | Library | Latest / maintenance (2026) | License | Type model | Delivery/concurrency model | Swift-analogy verdict |
|---|---|---|---|---|---|---|
| 1 | **bugsnag-go** (`bugsnag/bugsnag-go/v2`) | **v2.6.4, 2026-04-14** — active | MIT | Static structs, `MarshalJSON` | Async goroutine per `Notify` (fire-and-forget); `Synchronous bool` for tests; `MainContext` for graceful shutdown | **Best.** Structs→`Codable`, goroutine→`Task`, `Synchronous`→await-option, config struct→config struct. Primary. |
| 2 | **kinbiko/bugsnag** (unofficial Go) | active, opinionated rewrite | MIT | Static structs, builder `With*` | Sync `Notify`; `Close()` flush-on-shutdown; `Wrap()` captures stack at origin | **Best design teacher.** Cleanest ergonomics; directly models our stack-trace-at-origin + queue-drain problems. Secondary. |
| 3 | **bugsnag-java / bugsnag-spring** (JVM) | maintained | MIT | Static classes | Thread-pool delivery; `Report`/`Delivery` interfaces; Servlet filter | Strong analog (typed + pluggable `Delivery`), but heavier/enterprise idioms; more than we need for v1. |
| 4 | **bugsnag-ruby** (`bugsnag/bugsnag-ruby`) | **v6.29.0, 2026-01-21** — very active | MIT | Dynamic | Background delivery thread; internal session tracker with periodic flush | Great for the **delivery-queue + session-batching** design; concurrency idioms don't map to Swift. |
| 5 | **bugsnag-python** (`bugsnag/bugsnag-python`) | v4.9.0 — maintained | MIT | Dynamic | Background delivery thread/queue; WSGI/ASGI middleware | Similar to Ruby; clean `Configuration` + middleware separation worth a look; dynamic. |
| 6 | **@bugsnag/js** (universal; `@bugsnag/node`) | **v8.9.0** — active; `bugsnag-node` **deprecated** → use `@bugsnag/js` | MIT | TypeScript (typed) | Plugin architecture; `Client`/`Event`/`Breadcrumb` classes; async delivery | Typed and modern, but browser+Node hybrid + plugin system adds complexity not worth copying wholesale. Mine it for the **Event/Client object model** only. |
| 7 | **bugsnag-php** (+ Symfony/Laravel) | maintained | MIT | Static-ish classes | Guzzle HTTP client; framework middleware; `Report`/`Configuration`/`Client` split | Good **middleware-hooks-the-framework** exemplar; PHP per-request model is a weak concurrency analog. |
| — | **bugsnag-elixir** (community) | last meaningful update **2022** — stale | MIT | — | Plug middleware (`plugsnag`) | Skip. BEAM concurrency doesn't map; stale. Only historically interesting. |

**Maintenance takeaway:** bugsnag-go, bugsnag-ruby, and @bugsnag/js are the most actively maintained; bugsnag-go wins on type-model analogy. (88%)

## 3. Extracted Portable Architecture (language-neutral → becomes Swift design)

### 3.1 Public configuration surface
Union of `bugsnag-go` `Configuration` and `kinbiko` config, trimmed to what a server notifier needs:

| Field | Purpose | v1? | Notes for Swift |
|---|---|---|---|
| `apiKey` | project notifier key | **yes** | from `BUGSNAG_KEY` env (same var the dead package used) |
| `releaseStage` | e.g. `production`/`staging` | **yes** | from environment; default `production` |
| `enabledReleaseStages` | only notify on these stages (go: `EnabledReleaseStages`; older alias `NotifyReleaseStages`) | **yes** | if set and current stage not in it → drop before POST |
| `appVersion` | correlate errors to a release | **yes** | backend `3.2.x` from `configure.swift` |
| `appType` | e.g. `rails`/`celery`; ours `vapor` | yes | one-line, cheap |
| `endpoints.notify` / `endpoints.sessions` | override ingestion URLs | yes | default `https://notify.bugsnag.com` / `https://sessions.bugsnag.com`; keep configurable but default to public |
| `paramsFilters` / keys-to-filter | redact matching keys in metadata/headers (go default: `["password","secret"]`) | **yes** | must strip `Authorization`, `Cookie`, plus configurable keys — matches CLAUDE.md "never log sensitive data" |
| `hostname` | server identity | yes | ECS task id / `Host.current().name` |
| `projectPackages` / sourceRoot | grouping "in-project" frames | defer | weak value on Linux where frames are thin |
| `synchronous` | await the POST (tests) vs fire-and-forget (prod) | **yes** | maps to a `Bool`/enum controlling `await` vs detached `Task` |
| `onBeforeNotify` hook | mutate/veto events before send | **yes (thin)** | a `Sendable` closure `(inout Event) -> Bool`; enables redaction/sampling/drop |

### 3.2 Event/report construction pipeline (error → exception → event)
Both Go notifiers build the same shape (confirmed from `payload.go`). Pipeline stages:

1. **Normalize the error** → `errorClass` (Go uses the error's type name; Swift: `String(reflecting: type(of: error))` or a mapped name for `Abort`), `message` (localized description / `Abort.reason`).
2. **Build the exception array** — primary exception first, then chained "causes" (Go walks the error cause chain). Each exception = `{ errorClass, message, stacktrace[] }`. `stacktrace` MAY be empty (see §5).
3. **Assign severity + severityReason + unhandled** (see §3.5).
4. **Attach context** — a short grouping-friendly label. Go uses request path; **for Vapor use the matched route** (e.g. `GET /v1/habits/:id`), not the concrete URL, so events group per-endpoint.
5. **Attach sections**: `app` (releaseStage, version, type), `device` (hostname, osName, runtimeVersions), `user` (id/email/name), `request` (url, httpMethod, clientIp, filtered headers), `metaData` (arbitrary tabbed dictionaries), optional `breadcrumbs`, optional `session`.
6. **Set `groupingHash`** when stack traces are thin, so events don't collapse into one bucket (see §5).
7. **Run `onBeforeNotify`** hook (redaction/veto) → then hand to delivery.

### 3.3 Delivery model
- **bugsnag-go:** each `Notify` spawns a **goroutine** that marshals JSON and POSTs; **no batching** for error events (one POST per event); `Synchronous:true` makes it block (used in tests). Expects **HTTP 200**. Failures are logged, not retried aggressively. `MainContext` allows graceful shutdown.
- **kinbiko:** synchronous `Notify` but `Close()` **flushes** any in-flight work on shutdown — the pattern for not losing the last errors when a task terminates.
- **Ruby/Python:** a **background delivery thread/queue** decouples reporting from the request thread; sessions are **batched and flushed periodically** (this is where batching lives, and it's for *sessions*, not error events).

**Portable rules for Swift v1:**
- One detached `Task` per event, fire-and-forget; reporting **never blocks or fails the request**. (matches prior report §3.4)
- **No error-event batching in v1** (mirrors bugsnag-go). Add an optional rate-limiting/coalescing `actor` queue only if volume demands it.
- **Timeout** the POST (e.g. a few seconds) so a hung request can't leak tasks.
- **Retry:** minimal — a single best-effort attempt is what bugsnag-go effectively does for errors; do not build durable retry in v1.
- Provide a **`synchronous`/flush hook** so tests can await delivery, echoing `Synchronous` + `Close()`.

### 3.4 Framework-integration (middleware) pattern
Every server notifier hooks the framework's error path and enriches the event with request context:
- **Go:** `bugsnag.Handler(next)` wraps `http.Handler`; `AttachRequestData(ctx, r)` stashes the `*http.Request` on the context so a later `Notify` can read method/url/headers.
- **PHP/JVM/Python:** a framework middleware/filter catches the exception, snapshots the request, reports, then rethrows so the framework still renders the response.

**Portable rule → Vapor:** an `AsyncMiddleware` that wraps `next.respond`, and on `catch`: **snapshot the request into a `Sendable` value struct *before* leaving request isolation** (Vapor `Request` is **not** `Sendable`), fire the detached delivery `Task`, then rethrow so the existing `ErrorMiddleware` still formats the client response. Order it **outside** `ErrorMiddleware`. (matches prior report §3.4–3.5)

### 3.5 Severity & handled-vs-unhandled semantics
- **`severity`** enum: `"error" | "warning" | "info"` (Go: `SeverityError/Warning/Info`).
- **`unhandled`** boolean: `true` = the app did not catch it (crash/panic/uncaught) → counts against **stability score**; `false` = you called `notify` deliberately on a handled error.
- **`severityReason`**: `{ "type": <reason>, ... }` telling Bugsnag *why* this severity — e.g. `unhandledException`, `handledException`, `unhandledMiddleware`, `userSpecifiedSeverity`, `userCallbackSetSeverity`. Drives default severity + whether it's overridable.

**Mapping framework errors → Swift/Vapor:**
- An error that **propagates out of the route handler to the middleware** = **unhandled** (`severity: error`, `severityReason.type: unhandledMiddleware` or `unhandledException`). This is the primary path.
- Vapor `Abort` with a **4xx** status is arguably an expected/handled condition → consider **`severity: warning`** or dropping 4xx entirely (avoid noise from `401/404/422`), and treat **5xx / non-`Abort` as unhandled `error`**. Make this a policy in `onBeforeNotify`.
- A **deliberate** `bugsnag.notify(error, severity:)` call = **handled** (`severityReason.type: handledException` or `userSpecifiedSeverity`).

### 3.6 Sessions / stability tracking — **defer to v2**
Session tracking is a **separate endpoint** (`sessions.bugsnag.com`), a **separate payload**, and adds a **background batch-flush loop** (Go `AutoCaptureSessions`, Ruby/Python session trackers). It powers the "stability score" dashboards but is **not required for error reporting** and roughly doubles the moving parts (batching, periodic flush, per-request `StartSession`). **Recommendation: ship errors-only in v1; add sessions in v2** if the stability dashboard is wanted. (85%)

## 4. What the Swift/Vapor Package Should Look Like (derived sketch)

### 4.1 Module boundaries (single SwiftPM package, own repo)
- `BugsnagNotifier` (core, no Vapor dependency ideally):
  - `BugsnagConfiguration` — the struct from §3.1 (`Sendable`).
  - `BugsnagPayload` model types — `BugsnagEvent`, `Exception`, `StackFrame`, `AppInfo`, `DeviceInfo`, `BugsnagUser`, `RequestInfo`, `Notifier`, `SeverityReason` — all `struct … : Codable, Sendable`.
  - `BugsnagClient` (actor) — owns config + an HTTP client; `report(_ event:)` fire-and-forget; `flush()`.
  - `Severity` enum; `onBeforeNotify` closure typealias (`@Sendable (inout BugsnagEvent) -> Bool`).
- `BugsnagVapor` (integration target, depends on Vapor):
  - `BugsnagMiddleware: AsyncMiddleware` — the catch/snapshot/rethrow pattern.
  - `Request`/`Application` extensions: `app.bugsnag` accessor, `req.bugsnag.notify(...)` for handled errors, request→`RequestInfo` snapshot + user extraction from `req.auth` (JWT).
  - Middleware registration helper.

This mirrors the **core-notifier vs framework-adapter split** that bugsnag-go (core) + its `Handler` and PHP (`Client` vs Symfony bundle) both use.

### 4.2 Minimal v1 feature set vs deferred
**v1 (ship):** config surface (§3.1 "yes" rows) · error→event pipeline · exceptions with (possibly empty) stacktrace · `context`=route · `groupingHash` fallback · app/device/user/request/metaData sections · header-filtering redaction · `onBeforeNotify` veto/redact · fire-and-forget async delivery with timeout · `AsyncMiddleware` (unhandled path) · `notify()` for handled errors · a `synchronous`/`flush` test hook.

**Defer (v2+):** session tracking + stability score · breadcrumbs · error-event batching/durable retry · `projectPackages`/source-root grouping niceties · rich stack-trace symbolication.

### 4.3 Public API shape a Vapor app would use
```swift
// configure.swift
app.bugsnag.configure(.init(
    apiKey: Environment.get("BUGSNAG_KEY")!,
    releaseStage: app.environment.name,          // "production"/"staging"
    enabledReleaseStages: ["production", "staging"],
    appVersion: "3.2.12",
    appType: "vapor",
    redactedKeys: ["authorization", "cookie", "password"],
    synchronous: false
))
app.middleware.use(BugsnagMiddleware())          // BEFORE ErrorMiddleware in the chain

// deliberate/handled report anywhere with a Request
try await req.bugsnag.notify(SomeError.badThing, severity: .warning,
                             metadata: ["billing": ["plan": "pro"]])
```
This is intentionally close to bugsnag-go's `Configure(...)` + `Notify(err, Severity, MetaData, User)` ergonomics, restyled for Swift + Vapor DI (`app.bugsnag`, `req.bugsnag`), matching this codebase's "dependency injection via Application extensions" convention.

### 4.4 Notifier API-contract details the references reveal (not obvious from bare docs)
- **`notifier` object is mandatory-in-practice** and self-identifying: `{ name, version, url }`. Ours: `{ "name": "Tangerine Vapor Notifier", "version": "<pkg semver>", "url": "<repo url>" }`. Bugsnag uses this to badge the source SDK.
- **`apiKey` goes in BOTH the header AND the body.** bugsnag-go sets header `Bugsnag-Api-Key` **and** a body `apiKey` field. Send both. (85%)
- **Headers** (from bugsnag-go `PrefixedHeaders`): `Bugsnag-Api-Key`, `Bugsnag-Payload-Version`, `Bugsnag-Sent-At` (ISO-8601), `Content-Type: application/json`. Expect **HTTP 200** on success.
- **`events` is an array**; a single POST can carry multiple events, but one-event-per-POST is standard for error notifiers.
- **Per-event `payloadVersion`**: see the version note below.
- **Required vs optional:** the only truly required event content is **`exceptions[]` with each exception having `errorClass` + a `stacktrace` array (array may be empty)**. Everything else (`severity`, `unhandled`, `context`, `app`, `device`, `user`, `request`, `metaData`) is optional-but-valuable. (from prior report's schema analysis, corroborated by bugsnag-go payload)

**⚠️ Payload-version reconciliation (important):** the **live bugsnag-go notifier emits `payloadVersion "4"`** (constant `notifyPayloadVersion`, both in the header and per-event), while the **current documented schema / prior report use `"5"`.** The ingestion endpoint accepts both; v5 is the current top value and the right default for a *new* integration, but **do not be surprised** that the best code reference emits `4`. **Action: send `5`, but verify with one test POST** and fall back to `4` if the specific fields we send are rejected. (80%)

## 5. What Does NOT Port to Swift/Linux (and the substitute)

| Reference feature | Why it doesn't port | Swift/Linux substitute |
|---|---|---|
| Rich language stack-trace capture (Go runtime frames; JS `Error.stack`; JVM `getStackTrace`) | Swift on Linux does **not** attach a throw-site stack to a caught `Error`; `Thread.callStackSymbols` gives the *current* (middleware) stack, mangled/incomplete in release builds | Send **empty/minimal `stacktrace`**; lean on `errorClass` + `message` + `context`(route) + request/user metadata. Optionally imitate **kinbiko `Wrap()`**: a custom `AppError` that captures `Thread.callStackSymbols` **at throw site** and carries it — accepting mangled frames. (ties to prior report §3.3) |
| Platform `device` sections (mobile OS/model/battery; Go build info) | Server has no device; those fields are mobile-SDK-shaped | Minimal `device`: `{ osName:"linux", hostname:<task id>, runtimeVersions:{ swift:"5.9" } }` |
| `projectPackages`/source-root in-project grouping | Depends on resolvable frames we won't have | Skip; rely on `context`(route) + `groupingHash` (e.g. `errorClass + route`) for grouping |
| Goroutine/thread-pool delivery internals | Different concurrency runtime | Detached `Task` + an optional `actor` queue; `Sendable` payload snapshot (the #1 strict-concurrency constraint) |
| Global process-wide singleton + panic handler (`bugsnag.Configure` installs a global `recover`) | Swift server has no equivalent global uncaught-throw hook; and Vapor is the boundary | Vapor `AsyncMiddleware` is the "unhandled" boundary; DI via `app.bugsnag` instead of a global |
| Session auto-capture background loop | Extra endpoint + batch flush | Defer to v2 (§3.6) |

## 6. Licensing

- **bugsnag-go** — **MIT** (confirmed via pkg.go.dev module page). ✅
- **kinbiko/bugsnag** — **MIT** (repo). ✅
- **bugsnag-ruby, bugsnag-python, @bugsnag/js, bugsnag-php/Symfony, bugsnag-java/spring, bugsnag-elixir** — **MIT** across the board (Bugsnag's notifiers are uniformly MIT). ✅

MIT permits studying and porting the design freely with attribution of the license text if code is copied. Since we are doing a **clean-room reimplementation** (reading the design, writing original Swift), there is **no licensing obstacle**; we are not even obligated to carry their license, though a courtesy acknowledgment is fine. (90%)

## 7. Sources (with dates + credibility)

**Tier 1 — official notifier source / package registries**
- `bugsnag/bugsnag-go` — `payload.go` (payload shape, `payloadVersion "4"`, `MarshalJSON`, `deliver()`, `PrefixedHeaders`), `notifier.go`, `CHANGELOG.md`. GitHub, accessed 2026-07-04. (high)
- `pkg.go.dev/github.com/bugsnag/bugsnag-go/v2` — **v2.6.4, published 2026-04-14, License MIT**; `Configuration` fields, `Configure/Notify/Recover/AutoNotify`, `Handler`, `AttachRequestData`, `OnBeforeNotify`, session API. Accessed 2026-07-04. (high)
- `bugsnag/bugsnag-ruby` releases — **v6.29.0, 2026-01-21** (active). (high)
- `bugsnag-python` (PyPI v4.9.0), `@bugsnag/js` (npm v8.9.0; `bugsnag-node` deprecated). Accessed 2026-07-04. (high)

**Tier 2 — clean design reference + schema mirror**
- `kinbiko/bugsnag` (`pkg.go.dev` + repo) — unofficial idiomatic Go rewrite, **MIT**; `New/Notify/Wrap/Close/StartSession`, `With*` builders, flush-on-shutdown, stack-at-origin. Accessed 2026-07-04. (medium-high)
- `api-evangelist/bugsnag` — mirror of official error-event JSON schema / OpenAPI / Postman (used for required-field analysis in the prior report). (medium)

**Tier 1 — API contract (corroborated; some pages render-gated)**
- Bugsnag docs "Writing a notifier" (`docs.bugsnag.com/platforms/writing-a-notifier/`) → points to the Error Reporting API (`developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions`). Nav/render-gated on automated fetch, but the header/endpoint/payload facts are triple-corroborated by bugsnag-go source + the prior report's schema work + the ColdFusion example cited there. (medium-high)

**Prior report (context)**
- `claude/reports/2026-07-04/bugsnag-vapor-integration-researcher-report.md` — endpoint/headers/payload-v5/Sendable-middleware/stack-trace-on-Linux findings this report builds on. (high)

### Flagged / uncertainties
- **Payload version 4 vs 5** — best code reference emits `4`; current schema is `5`. Both accepted; verify with one test POST (§4.4). (80%)
- **SmartBear/Apiary API pages** did not fully render via automated fetch; contract facts rest on official-notifier *source code* + prior corroboration rather than the prose docs. (noted)
- **Exact `severityReason.type` string** for the middleware path (`unhandledMiddleware` vs `unhandledException`) should be confirmed against the schema enum when writing the encoder; both are valid, choice affects dashboard labeling only. (75%)
