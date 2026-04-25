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
