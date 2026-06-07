# Architecture Decision Records

Flametrench v0.1 reached its shape through a series of high-leverage decisions. Each ADR here records one decision, the context that forced it, the alternatives considered, and the consequences — positive and negative — that follow from accepting it.

ADRs are historical: once accepted, the content of an ADR is frozen. Future design changes that contradict an ADR are recorded in a new ADR that explicitly supersedes the old one; the old one is not edited.

## Status values

- **`Accepted`** — the decision is current Flametrench specification.
- **`Proposed`** — design committed for an upcoming spec version (e.g., v0.2). Normative once the version it targets is released.
- **`Superseded by NNNN`** — replaced by a newer ADR; retained for historical context.
- **`Deprecated`** — no longer reflects current practice but has not been formally replaced.

## Numbering

ADRs are numbered sequentially from 0001 in the order accepted. Numbers never change, are never reused, and are never reclaimed from withdrawn ADRs.

**Drafts are number-less.** Because the number is determined by *acceptance order* — not by when drafting begins — do not bake an ADR number into a draft (filename, title, or cross-references) while it is still being written. Refer to a pending ADR by its primitive/topic name. **Assign the next free number at PR-open time**, in the order PRs are opened for merge, and open **one ADR per PR**. This prevents the collision class where two concurrently-drafted ADRs (or an adopter's externally-numbered draft) both claim the same number and one has to be renumbered late. A number is only *fixed* once its PR merges.

## Current ADRs

| # | Title | Topic |
|---|---|---|
| [0001](./0001-authorization-model.md) | Authorization model: relational tuples, explicit only | Authorization primitive; check semantics; relation registry |
| [0002](./0002-tenancy-model.md) | Tenancy model: flat organizations, membership-as-tuple | Orgs; memberships; self-leave vs admin-remove; sole-owner invariant |
| [0003](./0003-invitation-state-machine.md) | Invitation state machine | Invitation lifecycle; pre-declared tuples; atomic acceptance |
| [0004](./0004-identity-model.md) | Identity model: opaque users, layered credentials | Users; credential types; Argon2id pinning; sessions; MFA deferral |
| [0005](./0005-revoke-and-re-add.md) | Revoke-and-re-add lifecycle pattern | Cross-cutting `replaces` chain pattern used by `cred_` and `mem_` |
| [0006](./0006-legacy-password-migration.md) | Legacy password migration: host-side verify-then-rotate | Migration story for bcrypt/PBKDF2/scrypt apps adopting Flametrench |
| [0007](./0007-authorization-rewrite-rules.md) | Authorization rewrite rules (v0.2 — Proposed) | Subset of Zanzibar userset_rewrite: computed_userset, tuple_to_userset, union |
| [0008](./0008-mfa.md) | Multi-factor authentication (v0.2 — Proposed) | TOTP (RFC 6238) + WebAuthn assertion verification + recovery codes; new mfa_ entity |
| [0009](./0009-invitation-accept-binding.md) | Invitation acceptance binding | acceptInvitation requires `accepting_identifier` and byte-matches it to `invitation.identifier`; closes a privilege-escalation primitive in v0.1 |
| [0010](./0010-webauthn-rs256-eddsa.md) | WebAuthn RS256 + EdDSA (v0.2 — Proposed) | Extends ADR 0008 verifier to dispatch on COSE `alg`; adds RSA-PKCS1v15-SHA256 and Ed25519 alongside ES256 |
| [0011](./0011-org-display-name-slug.md) | Organization display name + slug (v0.2 — Proposed) | Adds optional `name` and `slug` to `Organization`; new `updateOrg` operation; closes spec#6 |
| [0012](./0012-share-tokens.md) | Share tokens for time-bounded resource access (v0.2 — Proposed) | New `shr` resource and `ShareStore` interface; opaque-token bearer access without authenticated principal; closes spec#7 |
| [0013](./0013-postgres-adapter-transaction-nesting.md) | Postgres adapter transaction nesting (v0.2 — Proposed) | Adapters detect outer transactions and use `SAVEPOINT ft_<method>_<random>` instead of `BEGIN`; enables multi-SDK-call atomicity; closes laravel#1 |
| [0014](./0014-user-display-name.md) | User display name (v0.2 — Proposed) | Adds optional `display_name` to `User`; new `updateUser` operation; closes spec#9 |
| [0015](./0015-list-users.md) | IdentityStore.listUsers (v0.2 — Proposed) | Cursor-paginated user enumeration with status filter and credential-identifier substring; mirrors `listMembers`; closes spec#10 |
| [0016](./0016-personal-access-tokens.md) | Personal access tokens (v0.3 — Proposed) | New `pat` primitive for non-interactive (CLI / CI / server-to-server) auth; id-then-secret wire format with prefix-routed bearer dispatch; Argon2id storage; `auth.kind` audit discriminator; closes spec#14 |
| [0017](./0017-postgres-rewrite-rule-evaluation.md) | Postgres rewrite-rule evaluation (v0.3 — Proposed) | `PostgresTupleStore` gains rule-aware `check()` via iterative async expansion (not SQL push-down); Node `evaluate()` becomes async-capable; retires the v0.2 deferral in `docs/authorization.md` |
| [0018](./0018-go-sdk-family-addition.md) | Add Go to the first-party SDK family matrix (v0.3 — Accepted) | Reverses the locked-at-four SDK policy on concrete adopter demand; adds Go as the 5th family as a `flametrench-go` monorepo (one `go.mod` per package); holds v0.3.0 for 5-family lockstep |
| [0019](./0019-audit-primitive.md) | Audit primitive (`aud`) (v0.4 — Proposed) | Append-only action log; fulfills ADR 0016's forward reference for the `aud` primitive, event schema, and `auth.kind = system`; `on_behalf` for delegated non-human actors (orthogonal to `auth.kind`); denied-op cross-scope non-disclosure; promotes `aud` in `docs/ids.md`. Filed by SiteSource |
| [0020](./0020-file-metadata-primitive.md) | File-metadata primitive (`file`) (v0.4 — Proposed) | `file_` metadata + lifecycle, storage-agnostic (opaque `storage_ref`, no blob bytes); access via `authz.check()` on the file as an object — no parallel ACL; emits `aud`; promotes `file` in `docs/ids.md`. Filed by SiteSource |
| [0021](./0021-flags-primitive.md) | Feature-flags primitive (`flag`) (v0.4 — Proposed) | Boolean flags + ordered targeting rules; targeting reuses `authz` `check()`/tuples (no new DSL); deterministic SHA-256 bucketing pinned for cross-SDK identity; `evaluate` hot-path/unaudited; emits `aud`; promotes `flag` in `docs/ids.md`. Filed by SiteSource |
| [0022](./0022-notify-primitive.md) | Notifications primitive (`not`) (v0.4 — Proposed) | Per-recipient record/event primitive (NOT a delivery engine — no SMTP/SMS/push/templating/retry); lifecycle `unread ⇄ read → dismissed`; strictly recipient-scoped access; emits `aud`; promotes `not` in `docs/ids.md`. Filed by SiteSource |
| [0023](./0023-v03-implementation-constants.md) | v0.3 implementation constants (cross-SDK parity) (Accepted) | Consolidated source-of-truth table for 7 v0.3 constants the SDK families must agree on (PAT parse / dummy-hash / secret-cap / `auth.kind` / bearer-order; rewrite bounds 8/1024; tuple regexes); cites each value's authoritative home + enforcing fixture. Surfaced by the Go reference SDK |

## Writing a new ADR

1. Copy the most recent ADR as a template.
2. Assign the next sequential number (e.g., `0006-...`).
3. Draft the sections: Context → Decision → Consequences → Deferred → Rejected alternatives → References.
4. Submit a PR against `flametrench/spec` with the new file and an entry in this README.
5. ADRs are merged only when the decision is actually made — not speculatively.

## Writing style

- Prefer active voice and present tense for the Decision section.
- Use RFC 2119 keywords (MUST, SHOULD, MAY) where behavior is being pinned.
- Include at least one concrete example in each ADR where possible.
- Document what is *deferred* as explicitly as what is *decided* — readers will want to know when a capability is coming, not just that it is missing.
