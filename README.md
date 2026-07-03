# vapor-bugsnag

A Bugsnag error-reporting notifier for [Vapor](https://vapor.codes) server apps on Linux.

Bugsnag has no Linux SDK and the old community Vapor package is archived, so this is a small, clean-room, pure-HTTP-API integration: an `AsyncMiddleware` catches errors in the request pipeline and POSTs structured events to Bugsnag's Error Reporting API, landing backend errors in the same Bugsnag org as your iOS/mobile crash data.

> **Status: not yet implemented.** This repo currently contains the build brief and research. The implementation is done in a dedicated session against the spec.

## Build brief

- **[docs/IMPLEMENTATION-SPEC.md](docs/IMPLEMENTATION-SPEC.md)** — the source of truth: scope, the exact API contract, package layout, the strict-concurrency middleware pattern, severity mapping, testing requirements, and acceptance criteria. Start here.
- [docs/research-feasibility.md](docs/research-feasibility.md) — why custom (no Linux SDK, dead package), the API contract, and the server-side stack-trace limitation.
- [docs/research-reference-architecture.md](docs/research-reference-architecture.md) — the `bugsnag-go` reference design that this package models on.

## Intended usage (target public API)

```swift
// configure.swift
app.bugsnag.configure(.init(
    apiKey: Environment.get("BUGSNAG_KEY")!,
    releaseStage: app.environment.name,
    enabledReleaseStages: ["production", "staging"],
    appVersion: MyBackendVersion,
    appType: "vapor",
    redactedKeys: ["authorization", "cookie", "password"],
    synchronous: false
))
app.middleware.use(BugsnagMiddleware())      // before ErrorMiddleware

// deliberate/handled report anywhere with a Request
try await req.bugsnag.notify(SomeError.badThing, severity: .warning,
                             metadata: ["billing": ["plan": "pro"]])
```

## Development

```
swift build
swift test
swift build -Xswiftc -strict-concurrency=complete   # must be clean
```

See [CLAUDE.md](CLAUDE.md) for conventions and the non-negotiable design principles.

## License

MIT.
