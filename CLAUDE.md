# vapor-bugsnag

A standalone Swift package: a **Bugsnag error-reporting notifier for Vapor server apps on Linux**. It catches errors in a Vapor request pipeline and POSTs structured event JSON to Bugsnag's Error Reporting API (`https://notify.bugsnag.com`), so a Vapor backend's errors land in Bugsnag alongside the org's existing iOS crash data.

Org-wide context lives in the Bitdreams knowledge base at `../knowledge/` — see [AGENTS.md](AGENTS.md). The primary consumer is the sibling `../TangerineBackend/`.

> **The build brief is [docs/IMPLEMENTATION-SPEC.md](docs/IMPLEMENTATION-SPEC.md). Read it first — it is the source of truth for scope, the API contract, package layout, and acceptance criteria.** This file only captures conventions.

# Tech Stack
- Swift 5.9+ with **strict concurrency** enabled (must compile clean under `-strict-concurrency=complete`)
- SwiftPM package with two products: `BugsnagNotifier` (Vapor-free core) and `BugsnagVapor` (integration adapter)
- Vapor 4 (4.115+) — dependency of the `BugsnagVapor` target only
- Async HTTP delivery (`async-http-client`, or an injected client protocol to keep the core adapter-agnostic)
- Targets Linux (AWS Fargate); also builds on macOS for development

# Project Structure (to be created per the spec)
- `Sources/BugsnagNotifier`: core — `BugsnagConfiguration`, Codable+Sendable payload types, a `BugsnagClient` actor, severity/notify types. No Vapor import.
- `Sources/BugsnagVapor`: adapter — `BugsnagMiddleware: AsyncMiddleware`, `app.bugsnag` / `req.bugsnag` extensions, request→payload snapshot, JWT user extraction.
- `Tests/`: unit tests with a mock HTTP client (no network); a strict-concurrency test target.
- `docs/`: the implementation spec and research reports.

# Commands
- `swift build`: build the package
- `swift test`: run the test suite
- `swift test --filter <TestName>`: run a subset
- `swift build -Xswiftc -strict-concurrency=complete`: verify strict-concurrency cleanliness

# Design Principles (non-negotiable — see spec for rationale)
- The core (`BugsnagNotifier`) must not import Vapor; the adapter (`BugsnagVapor`) owns all Vapor coupling.
- **Reporting must never block or fail the request.** Delivery is fire-and-forget (detached `Task`), with a timeout; a `synchronous` flag exists only for tests.
- **`Request` is not `Sendable`** — snapshot everything needed into a `Sendable` value struct *before* leaving request isolation; never capture `req` inside a `Task`. This is the exact failure the dead `nodes-vapor/bugsnag` package could not handle.
- All payload types are `struct … : Codable, Sendable`.
- **Redact sensitive keys** (`Authorization`, `Cookie`, `password`, configurable) before encoding — never send secrets to Bugsnag.
- **Ship thin/empty stack traces** on Linux by design; rely on `errorClass` + `message` + `context`(route) + request/user metadata, and set `groupingHash` so events group per-endpoint. Do not try to force full stack traces in v1.
- Match the API contract in the spec exactly (endpoint, the four headers, apiKey in header AND body, payload version `5`).

# Code Style
- Swift async/await throughout; `actor` for shared mutable state (the client).
- Value types + `Codable` for payloads (automatically `Sendable`).
- Dependency injection via `Application`/`Request` extensions (mirrors the Bitdreams Vapor convention).
- Follow the Swift API design guidelines.

# Testing
- Unit tests use an **injected mock HTTP client** — do not hit the network.
- Cover: payload encoding shape, redaction, release-stage gating, severity mapping (4xx `Abort` vs 5xx/unhandled), synchronous delivery assertion, and a middleware `catch` that proves no `Request` capture.
- One opt-in integration smoke test (gated on a real `BUGSNAG_KEY`) resolves the payload-version 4-vs-5 question with a live POST — document the result in the README.

# Do Not
- Never commit secrets — `BUGSNAG_KEY` comes from the environment; never hardcode it or log it.
- Don't build v2 features in v1: **no session tracking, no breadcrumbs, no durable retry, no error-event batching, no stack-trace symbolication.**
- Don't capture `Request` (or any non-`Sendable`) inside a delivery `Task`.
- Don't add Vapor as a dependency of the `BugsnagNotifier` core target.
- Don't re-adopt or vendor `nodes-vapor/bugsnag` / `ml-archive/bugsnag` (archived, pre-concurrency) — this is a clean-room build.

## Working With Sub-Agents

**FOR MAIN CLAUDE ONLY.** Proactively use specialized agents when they fit:

- **code-reviewer** (`.claude/agents/code-reviewer.md`): use after writing code — validates Swift package design, strict-concurrency/`Sendable` correctness, API-contract fidelity, and test coverage.
- **researcher** (`.claude/agents/researcher.md`): use for any external info gathering (Bugsnag API details, SwiftPM/Vapor/async-http-client specifics beyond training data). The two `docs/research-*.md` reports already cover the Bugsnag integration landscape — build on them rather than re-researching.

Reports are artifacts: agents write detailed reports under `claude/reports/YYYY-MM-DD/` — don't auto-read them into the main context unless recommended.
