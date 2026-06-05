# 0018 — Add Go to the first-party SDK family matrix

**Status:** Accepted
**Date:** 2026-05-16
**Targets:** v0.3.0 (held until all 5 SDK families ship in lockstep)

## Context

Flametrench's first-party SDK family was locked at four languages — Python, Node (TypeScript), PHP, and Java — in early v0.2-cycle planning. The constraint was deliberate: every additional SDK adds permanent maintenance overhead (each cross-SDK fix lands in N places; each conformance fixture must pass in N languages). Adding a language without concrete adopter demand was treated as a speculative cost.

On **2026-05-16**, the constraint flipped. The driving event was expansion work on sitesource/admin (the bellwether adopter for the v0.2 cycle) into territory that needed a Go-implemented service. Adding Go now is the difference between sitesource shipping their expansion on Flametrench primitives versus reimplementing them — and "no fifth family" was a self-imposed rule, not a contract obligation. With concrete adopter demand on the table, the rule's purpose was served.

Three structural questions had to be answered before scaffolding could begin:

1. **Repo layout.** Python / PHP / Java each ship as four separate repos (`ids-*`, `identity-*`, `tenancy-*`, `authz-*`). Node ships as one monorepo (`flametrench/node`). Go's module system has matured to first-class support for repos containing multiple modules (Go 1.18+ workspaces) with low overhead.
2. **Release positioning.** v0.3.0 was queued for cut at the time the decision landed — PHP + Node ready, PyPI + Maven Central externally blocked. Adding Go could either slip v0.3.0 (5-family lockstep) or land as a v0.3.1 patch (mixed-version matrix briefly).
3. **Conformance posture.** The Go family must consume the same JSON conformance fixtures as Python/Node/PHP/Java, or the cross-language semantic-parity guarantee collapses.

## Decision

### Add Go as a first-party SDK family at v0.3.0

The Flametrench SDK matrix moves from four families to five at the v0.3.0 release. Python, Node, PHP, Java, **Go** — each conforms to the same fixture corpus; each implements the same operations with the same wire shapes.

### Monorepo at `github.com/flametrench/flametrench-go`

The Go family ships as one repository containing four Go modules. Layout:

```
flametrench-go/
├── go.work                          (workspace file; pinned for local dev)
├── packages/
│   ├── ids/
│   │   └── go.mod                   github.com/flametrench/flametrench-go/packages/ids
│   ├── identity/
│   │   └── go.mod                   github.com/flametrench/flametrench-go/packages/identity
│   ├── tenancy/
│   │   └── go.mod                   github.com/flametrench/flametrench-go/packages/tenancy
│   └── authz/
│       └── go.mod                   github.com/flametrench/flametrench-go/packages/authz
├── conformance/                     fixture runner (consumes vendored spec fixtures)
├── CHANGELOG.md
├── LICENSE
├── NOTICE
└── README.md
```

Adopters import with: `go get github.com/flametrench/flametrench-go/packages/identity`.

Rationale:
- **Idiomatic for Go.** Multi-module repos are the canonical pattern for SDK families since Go 1.18 workspaces (kubernetes-go-client, aws-sdk-go-v2, sentry-go all use this shape).
- **Single cross-package fix flow.** A change touching `ids` + `identity` is one PR on one branch with one CI run. Four-repo layouts force coordinated multi-repo PRs for the same change.
- **Tag once, version each.** Multi-module repos support per-module semver tags (`packages/ids/v0.3.0`, `packages/identity/v0.3.0`) via Go's standard `go get` resolution. Family-wide tags can stack on top.
- **`go.work` for local development.** Sibling-package edits surface immediately without `replace` directives in adopter projects.

### Hold v0.3.0 until all 5 families are ready

The v0.3.0 release date slips by an estimated 2-3 weeks so all five SDK families publish in lockstep. This is the cleanest narrative for the v0.3 release ("v0.3 = PATs, Postgres rule evaluation, audit-cleared, plus Go") and avoids a mixed-version SDK matrix on the StatusMatrix during the gap.

PHP + Node remain publish-ready locally; PyPI + Maven Central blocks unchanged from their existing posture. The hold is on the Go side reaching parity, not on the other families.

### Conformance: Go consumes the spec/conformance/fixtures/ corpus unchanged

The `flametrench-go/conformance/` directory carries a Go test runner that loads JSON from a pinned spec tag, executes each fixture against the Go SDK, and asserts byte-equality with the fixture's expected output. The same model Node/PHP/Python/Java already use.

No Go-only behaviors. If a behavior isn't pinned by the fixture corpus, it isn't normative.

## Consequences

### Spec surface

- `decisions/0018-go-sdk-family-addition.md` (this document) — Accepted at v0.3.0.
- `README.md` §Status: "five SDK families" wording everywhere; SDK families table grows from four rows to five; ASCII repo structure adds Go.
- `CHANGELOG.md`: v0.3.0 entry explicitly notes Go's addition and the 2-3 week hold.
- `docs/migrating-to-v0.3.md`: §6 (SDK bumps) gains Go install snippet.

### Site

- `flametrench.dev` StatusMatrix grows from 4 columns to 5. Each row picks up a Go cell in `planned` channel state at the spec change, moving to `pending` once the Go SDK lands locally, then `live` once the Go module proxy serves the tag.

### Adopter impact

- v0.3.0 adopters using Python/Node/PHP/Java are unaffected by Go's addition. Wire format, fixture corpus, and migration steps are unchanged.
- Adopters who want Go: `go get github.com/flametrench/flametrench-go/packages/{ids,identity,tenancy,authz}@v0.3.0` once v0.3.0 publishes.

### Implementation cost

- 4 packages × (in-memory store + Postgres adapter + tests + conformance binding) — roughly the same surface area as Python or PHP took to implement initially.
- Argon2id parameters pinned to OWASP floor (m=19456 KiB, t=2, p=1) — `golang.org/x/crypto/argon2` exposes a low-level `IDKey` that takes these directly. PHC string formatting needs an explicit encoder/decoder; conformance fixture `identity/argon2id.json` pins the expected output.
- Postgres driver: `jackc/pgx/v5` (with `pgxpool` for adapter use, `database/sql` not preferred — pgx's typed API matches the per-language Postgres adapters' shape better and is the dominant Go Postgres library in 2026).

### Hearth (the v0.3 demo app)

Hearth will eventually add `backends/go/` (port 5005, Gin or chi). That's a separate Hearth M7 milestone, not in scope for the Go SDK family addition itself.

### Future SDK additions

The 4-family cap was conditional on "wait for adopter demand." Lifting the cap doesn't remove the discipline — Ruby, Rust, .NET, etc. each remain "wait for adopter demand."

## Alternatives considered

### Four separate repos (`{ids,identity,tenancy,authz}-go`)

Rejected. This is the Python/PHP/Java shape but it's a poor fit for Go:

- Multi-repo PRs for cross-package changes (changing the `ids` package's signature flows into `identity`, `tenancy`, `authz`).
- No native `go.work` for local development across the family — adopters with all four packages installed locally would either pin to a tag or pollute `go.mod` with `replace` directives.
- Tag proliferation. Four repos × per-tag releases means 4× the bookkeeping with no real benefit.

The only argument for four-repo is "matches PHP/Python/Java." That's a weak reason to add operational friction on the Go side.

### v0.3.1 patch release (don't hold v0.3.0)

Rejected. The mixed-version matrix during the gap (PHP + Node at v0.3.0; Python + Java + Go pending; one of those bumping to v0.3.1 mid-cycle) is harder to communicate cleanly than a one-time 2-3 week hold. Adopters tracking the SDK matrix get a single transition point.

### v0.4.0 minor for the Go addition

Rejected. v0.3 already has substantive surface (PATs, Postgres rule evaluation, audit-cleared). Bumping to v0.4 just for the Go family addition implies a much larger spec change than the Go SDK actually represents — adding a 5th implementation of the same spec contract is not a spec minor bump. v0.4 should be earned by spec-level changes (the L4 + F2 deferrals, group subjects, etc.).
