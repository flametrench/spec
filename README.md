# Flametrench

**An open specification for the load-bearing parts of every application.**

Identity. Tenancy. Authorization. Every application needs them. Every team rebuilds them. Flametrench is the contract that lets you stop.

---

## What this is

Flametrench is a language-agnostic specification for the capabilities every serious application needs but nobody wants to own: who your users are, what organizations they belong to, what they're allowed to do, and who did what when.

The specification lives in this repository. Reference implementations live in parallel SDK repositories, one per supported language. A framework-agnostic admin UI speaks the specification and works against any compliant backend.

The promise is semantic parity. A Laravel backend and a Next.js backend implementing Flametrench produce identical behavior over the wire — identical error codes, identical event shapes, identical audit trails, identical permission checks. You can move between stacks without rebuilding your foundation.

## Why "Flametrench"

At every rocket launch pad, beneath the visible spectacle, there's a flame trench — a concrete channel that redirects exhaust sideways during liftoff. It absorbs acoustic and thermal forces that would otherwise destroy the rocket on the pad. Everyone watches the launch. Nobody watches the trench. But the launch only succeeds because the trench is there.

This project is named for that piece of infrastructure. Identity, tenancy, and authorization are load-bearing. They absorb real stress so your product can ship. They're almost always invisible when they work, and ruinous when they don't.

## The v0.1 scope

Flametrench v0.1 covers three capabilities. Detailed specs live in [`docs/identity.md`](docs/identity.md), [`docs/tenancy.md`](docs/tenancy.md), and [`docs/authorization.md`](docs/authorization.md); the design decisions behind them are recorded in [`decisions/`](decisions/).

**Identity.** Opaque users (`usr_`); multiple credentials per user (`cred_`) with three types — password (Argon2id, parameters pinned), passkey (WebAuthn), OIDC. User-bound sessions (`ses_`) with rotation on refresh. MFA is deferred to v0.2+; applications can layer it on by chaining credential verifications.

**Tenancy.** Flat organizations (`org_`); multi-organization memberships (`mem_`); five-state invitations (`inv_`) with atomic acceptance and resource-scoped pre-declared tuples. Role changes use a revoke-and-re-add chain for tamper-evident history. Sole-owner protection on both self-leave and admin-remove paths.

**Authorization.** Relational tuples (`tup_`) as the only authz primitive; exact-match `check()` over single relations or non-empty relation sets. Six built-in relations (`owner`, `admin`, `member`, `guest`, `viewer`, `editor`) plus application-registered custom relations. No rewrite rules or derivations in v0.1 — applications materialize implied grants or compose checks at call sites. Rewrite rules, group subjects, and parent-child inheritance are deferred to v0.2+.

Everything else — audit logs, notifications, file handling, billing hooks, feature flags — is explicitly out of scope for v0.1 and arrives in later versions. Shipping narrow is the point.

## The two-language promise

Flametrench ships initial support for Laravel and Next.js, and the specification is designed so any language can implement it.

- **Laravel SDK** (PHP 8.3+, Laravel 11+) lives at [github.com/flametrench/laravel](https://github.com/flametrench/laravel)
- **Node SDK** (Node 20+, Next.js 15+ App Router) lives at [github.com/flametrench/node](https://github.com/flametrench/node)
- **Admin UI** (framework-agnostic, works against any compliant backend) lives at [github.com/flametrench/admin](https://github.com/flametrench/admin)

A conformance test suite lives alongside the specification. SDKs claim compliance by running the suite against themselves and passing. A passing badge on a third-party implementation means it behaves identically to the reference implementations in ways that matter.

## What this specification defines

At a high level, Flametrench defines:

- **The resources** a compliant backend exposes over HTTP — users, sessions, credentials, organizations, memberships, invitations, authorization tuples, and a meta-schema introspection endpoint.
- **The wire protocol** — OpenAPI 3.1 documents for every resource, with a JSON Schema for every payload.
- **The semantics OpenAPI can't express** — idempotency rules, error taxonomy, pagination behavior, event ordering, ID format, timestamp format, and version negotiation.
- **The conformance suite** — a black-box test runner that hits a configured `FLAMETRENCH_URL` and runs hundreds of test cases covering every contract endpoint.

What this specification does not define:

- **How a backend stores data.** Postgres, MySQL, SQLite, something else — the specification doesn't care, as long as the wire behavior is correct.
- **How a backend is architected internally.** Hexagonal, layered, MVC, serverless — irrelevant to compliance.
- **What a backend does beyond Flametrench.** Your application does whatever it does. Flametrench is the boring load-bearing layer underneath.

## Status

**Pre-release.** The specification is actively being written. OpenAPI documents are in draft. The conformance suite is a skeleton. Neither SDK is installable yet. Nothing here should be trusted for production.

This README will update as capabilities move from draft to stable. The `docs/versioning.md` document explains how the specification versions and how SDKs track compatibility.

## Structure of this repository

```
flametrench/spec/
├── README.md                    this document
├── LICENSE                      Apache 2.0
├── NOTICE                       copyright attribution
├── docs/
│   ├── ids.md                   ID format (normative)
│   ├── identity.md              identity capability (normative)
│   ├── tenancy.md               tenancy capability (normative)
│   └── authorization.md         authorization capability (normative)
├── decisions/                   Architecture Decision Records
│   ├── README.md                index + ADR writing guide
│   ├── 0001-authorization-model.md
│   ├── 0002-tenancy-model.md
│   ├── 0003-invitation-state-machine.md
│   ├── 0004-identity-model.md
│   └── 0005-revoke-and-re-add.md
├── reference/                   non-normative implementation artifacts
│   ├── README.md                conventions; what's normative vs reference
│   └── postgres.sql             reference Postgres DDL
├── openapi/                     HTTP surface (in progress)
└── conformance/                 conformance fixtures (in progress)
```

## How to follow along

- Watch this repository for specification changes.
- Watch the SDK repositories for implementation progress.
- Join GitHub Discussions (once v0.1 stabilizes) for design conversations.
- Read the commit history — specification work is happening in the open, with reasoning in commit messages where it matters.

## Contributing

The specification is still in draft and the surface area is small, so direct contributions are limited until v0.1 stabilizes. What helps most right now:

- **Questions and challenges.** If something in the specification looks wrong, unclear, or underdefined, open an issue. Early feedback has disproportionate impact.
- **Prior art pointers.** If you know of a project that has solved one of these problems well, we want to learn from it.
- **Real-world requirements.** If you're running a Laravel or Next.js application in production and dealing with identity, tenancy, or authorization pain, tell us what hurts.

When the specification stabilizes and the conformance suite is mature, pull requests for additional SDK languages will be welcomed.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution workflow, including the Developer Certificate of Origin (DCO) signoff requirement.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright 2026 NDC Digital, LLC.
