# Agent instructions

Repo-specific conventions, tech stack, and code style live in [CLAUDE.md](CLAUDE.md).

This repo is a **standalone Swift package** (`vapor-bugsnag`) — a Bugsnag error-reporting notifier for Vapor server apps on Linux. It is not part of the Tangerine backend; it is a dependency the backend (and any other Bitdreams Vapor service) will consume.

## Start here

The full build brief is [docs/IMPLEMENTATION-SPEC.md](docs/IMPLEMENTATION-SPEC.md) — read it first; it is the source of truth for what to build. The two research reports behind it (`docs/research-feasibility.md`, `docs/research-reference-architecture.md`) are optional evidence.

## Organization knowledge base

Cross-repo context — product overview, system architecture, decisions, and how Bitdreams services fit together — lives in the Bitdreams knowledge base:

- Local clone (sibling of this repo): `../knowledge/` — start at `bitdreams-overview.md`
- Remote: https://github.com/Bitdreams/knowledge

The consuming service, for reference on how this package will be wired in, is the sibling `../TangerineBackend/` (Vapor 4, Swift strict concurrency). When you learn something with cross-repo relevance (architecture, decisions, operational gotchas), record it in the knowledge base, not just here.

## Environment setup

Run `/onboarding` if tooling/auth/Linear is not configured — it follows `../knowledge/tools/ONBOARDING.md`. Linear tickets for this work belong to the Bitdreams (Tangerine) workspace.
