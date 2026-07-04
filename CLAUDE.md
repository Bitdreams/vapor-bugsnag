# vapor-bugsnag

A standalone Swift package: a **Bugsnag error-reporting notifier for Vapor server apps on Linux**. It catches errors in a Vapor request pipeline and POSTs structured event JSON to Bugsnag's Error Reporting API (`https://notify.bugsnag.com`), plus per-request sessions to the sessions API, so a Vapor backend's errors land in Bugsnag alongside any existing mobile crash data.

> The original build brief is [docs/IMPLEMENTATION-SPEC.md](docs/IMPLEMENTATION-SPEC.md) — the API contract, payload schema, and design rationale live there. This file captures conventions.

# Tech Stack
- Swift 6 language mode (`swift-tools-version: 6.0`) — must compile with **zero warnings**; full data-race safety is enforced by the compiler
- SwiftPM package with two products: `BugsnagNotifier` (Vapor-free core) and `BugsnagVapor` (integration adapter)
- Vapor 4 (4.115+) — dependency of the `BugsnagVapor` target only
- HTTP delivery via the injected `BugsnagTransport` protocol; the adapter ships an `AsyncHTTPClient`-backed implementation
- Targets Linux; also builds on macOS for development

# Project Structure
- `Sources/BugsnagNotifier`: core — configuration, Codable+Sendable payload types, the `BugsnagClient` and `SessionTracker` actors, breadcrumbs, error-chain unwrapping, throw-site stack capture. No Vapor import.
- `Sources/BugsnagVapor`: adapter — `BugsnagMiddleware: AsyncMiddleware`, `app.bugsnag` / `req.bugsnag` extensions, request→payload snapshotting, per-request sessions and breadcrumb trails.
- `Tests/`: unit tests with a mock transport (no network); XCTVapor end-to-end tests; opt-in live smoke tests gated on `BUGSNAG_KEY`.
- `docs/`: the implementation spec and research reports behind the design.

# Commands
- `swift build`: build the package
- `swift test`: run the test suite
- `swift test --filter <TestName>`: run a subset
- `swift build -Xswiftc -strict-concurrency=complete`: verify strict-concurrency cleanliness (redundant in Swift 6 mode, kept as a CI-parity check)

# Design Principles (non-negotiable — see spec for rationale)
- The core (`BugsnagNotifier`) must not import Vapor; the adapter (`BugsnagVapor`) owns all Vapor coupling.
- **Reporting must never block or fail the request.** Delivery is fire-and-forget with a timeout; a `synchronous` flag exists only for tests. Session starts are a counter increment — no I/O on the request path.
- **`Request` is not `Sendable`** — snapshot everything needed into a `Sendable` value struct *before* leaving request isolation; never capture `req` inside a `Task`.
- All payload types are `struct … : Codable, Sendable`.
- **Redact sensitive keys** (`Authorization`, `Cookie`, `password`, configurable) before encoding — never send secrets to Bugsnag. The mandatory keys cannot be configured away.
- **Stack traces are thin by default** on Linux; throw-site capture is opt-in via `bugsnagTraced()`. `groupingHash` (`errorClass|route`) keeps events grouped per-endpoint either way.
- Match the API contract in the spec exactly (endpoints, headers, apiKey in header AND body, payload version `5` for events / `1.0` for sessions).

# Code Style
- Swift async/await throughout; `actor` for shared mutable state.
- Value types + `Codable` for payloads (automatically `Sendable`).
- Dependency injection via `Application`/`Request` extensions (the Vapor convention).
- Follow the Swift API design guidelines.

# Testing
- Unit tests use an **injected mock transport** — never hit the network.
- Cover: payload encoding shape, redaction, release-stage gating, severity mapping (4xx `Abort` vs 5xx/unhandled), synchronous delivery assertion, and middleware `catch` paths that prove no `Request` capture.
- Opt-in live smoke tests (gated on a real `BUGSNAG_KEY`) verify the live endpoints; results are documented in the README.

# Do Not
- Never commit secrets — `BUGSNAG_KEY` comes from the environment; never hardcode it or log it.
- Out of scope: **durable retry / persistent queues, error-event batching, stack-trace symbolication, panic/hard-crash capture** (the process dies before any Swift code can POST — handle operationally).
- Don't capture `Request` (or any non-`Sendable`) inside a delivery `Task`.
- Don't add Vapor as a dependency of the `BugsnagNotifier` core target.
- Don't vendor or adopt the archived `nodes-vapor/bugsnag` / `ml-archive/bugsnag` packages — this is a clean-room build.

## Working With Sub-Agents

**FOR MAIN CLAUDE ONLY.** Proactively use specialized agents when they fit:

- **code-reviewer** (`.claude/agents/code-reviewer.md`): use after writing code — validates Swift package design, strict-concurrency/`Sendable` correctness, API-contract fidelity, and test coverage.
- **researcher** (`.claude/agents/researcher.md`): use for any external info gathering (Bugsnag API details, SwiftPM/Vapor/async-http-client specifics beyond training data). The two `docs/research-*.md` reports already cover the Bugsnag integration landscape — build on them rather than re-researching.
