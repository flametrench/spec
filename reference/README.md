# Reference material

Non-normative implementation artifacts. Anything here clarifies or demonstrates the specification; it does not extend or modify it.

## What's in this directory

- **`postgres.sql`** — reference Postgres schema implementing the v0.1 data model. The bottom of the file carries v0.2 additions (MFA tables, `ses.mfa_verified_at`) under a clearly marked section; everything above is byte-identical to v0.1, so a v0.1 deployment can adopt v0.2 by running the additive DDL block.
- **`postgres-rls.sql`** — optional Row-Level Security policies. Apply AFTER `postgres.sql`. Installs per-table policies that read two session GUCs (`flametrench.current_usr_id`, `flametrench.actor_role`) and scope visibility/writes by user identity and org membership. The application sets the GUCs at the start of each request from its authentication context; RLS then enforces isolation regardless of whether the application's own checks are bug-free.

## What's normative vs. reference

The specification defines the **shape** of Flametrench's data model:

- The set of entities (`usr`, `cred`, `ses`, `org`, `mem`, `inv`, `tup`).
- The fields each entity carries and their lifecycle semantics.
- The relationships between entities (e.g. `mem` references `usr` and `org`; `tup` references a subject and an object by type and ID).
- The state machines (invitation transitions, membership status, credential rotation).
- The authorization check semantics (exact-match over tuples, no derivations in v0.1).

Those are **normative** — an implementation that deviates is not Flametrench-conformant.

Everything else — index choices, trigger implementations, storage parameters, the exact SQL dialect — is **reference**. An implementation may adapt these to its database and workload.

## Conventions used in `postgres.sql`

| Convention | Why |
|---|---|
| `UUID` for all IDs | Matches the spec's storage format (UUIDv7 canonical). The wire format (`"usr_01..."`) is computed at the SDK layer. |
| `TIMESTAMPTZ` for all timestamps | Naive timestamps are a tracking bug waiting to happen. |
| Status columns as `CHECK`-constrained `TEXT` | Postgres enums are painful to evolve; text with a CHECK is portable and self-documenting. |
| Partial unique indexes (`WHERE status = 'active'`) | Enforces "at most one active X" while allowing historical revoked rows to accumulate. |
| `replaces` self-referencing FKs on `cred` and `mem` | Encodes the revoke-and-re-add lifecycle. Walking the chain yields full history; timestamps are monotonic (tamper-evident). |
| Composite `UNIQUE` on `tup` | The natural key of a tuple is `(subject_type, subject_id, relation, object_type, object_id)`. The surrogate `id` exists so individual tuples can be referenced (audit, external joins). |

## Spec invariants not enforced in SQL

A handful of invariants are part of the spec but are enforced at the SDK / application layer rather than in SQL:

1. **Sole-owner protection.** Every org with any active `mem` must have at least one active `mem` with `role='owner'`. Expressing this as a SQL constraint requires a deferred trigger that complicates bulk operations; the `self_leave` and `admin_remove` flows enforce it procedurally.
2. **Session revocation cascade on cred rotation.** When a `cred` moves to `revoked`, sessions bound to that `cred` should be terminated. The SDK performs this transaction; no DB trigger.
3. **Tuple materialization on membership and invitation.** When a `mem` becomes active, a `tup_(usr, role, org)` row must be created in the same transaction. When an `inv` is accepted, the `pre_tuples` JSON is expanded into `tup` rows in the same transaction.
4. **(v0.2) MFA-required signal.** When `usr_mfa_policy.required = true` and `grace_until` is NULL or past, the SDK's `verifyPassword` MUST return an MFA-required signal instead of minting a session. The DB enforces nothing here; the policy row is data, the gate is in the SDK.
5. **(v0.2) Pending-factor expiry.** Pending TOTP/WebAuthn factors expire after `pending_expires_at`. The SDK MUST refuse to confirm a pending factor after that timestamp and MAY garbage-collect old pending rows; no Postgres-side TTL.
6. **(v0.2) Recovery-code consumption.** When a recovery code is used, the matching slot in `recovery_consumed[]` flips to `true` in the same transaction as the session being minted. The DB enforces array-length parity (CHECK constraint) but not the consumption-on-success semantics.
7. **(v0.2) WebAuthn counter monotonicity.** `webauthn_sign_count` MUST advance strictly per WebAuthn §6.1.1 cloned-authenticator detection. The SDK rejects the assertion before the UPDATE; no DB-level trigger guards it.
8. **(v0.2) `ses.mfa_verified_at` advancement.** This column is updated only by the `verifyMfa` path, which writes the current timestamp on success. Apps reading the column for step-up freshness MUST treat NULL as "never verified" and never write the column directly from app code.

These are spec requirements; they are reference-only in the sense that the DDL doesn't catch violations, but any conforming SDK must guarantee them.

## v0.2 additions (Proposed; ADR 0008)

The schema gained two tables and one column in v0.2:

| Addition | Purpose |
|---|---|
| `mfa` | Per-user factor records — TOTP secrets, WebAuthn public keys + counter, recovery code hashes. Type-discriminated payload columns; revoke-and-re-add lifecycle via `replaces`. |
| `usr_mfa_policy` | Per-user enforcement: `required` flag and optional `grace_until` rollout window. Absent row means "MFA not required." |
| `ses.mfa_verified_at` | Nullable column. Records the last `verifyMfa` success on this session, so apps can gate sensitive ops on freshness without inventing parallel session tracking. |

WebAuthn factors are stored separately from the v0.1 `cred.passkey_*` columns. ADR 0008 §"Why factors not credentials" explains the split — the short version is that a passkey-as-credential (password-less login) and a passkey-as-factor (second factor on top of a password) are operationally distinct objects that just happen to share crypto primitives.

The v0.2 block is purely additive. A v0.1 deployment can run the additive DDL on an existing database without touching any v0.1 row.

## What's not in the reference yet

- **Performance tuning notes.** Hot-path query tuning, autovacuum settings for high-churn tables like `ses` and `tup`, partitioning guidance for very large `tup` tables.
- **Migration scaffolding.** Up/down patterns for schema evolution between spec versions.

These will land as the spec matures and real implementations surface the questions.
