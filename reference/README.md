# Reference material

Non-normative implementation artifacts. Anything here clarifies or demonstrates the specification; it does not extend or modify it.

## What's in this directory

- **`postgres.sql`** — reference Postgres schema implementing the v0.1 data model.

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

These are spec requirements; they are reference-only in the sense that the DDL doesn't catch violations, but any conforming SDK must guarantee them.

## What's not in the reference yet

- **Row-level security** policies. The spec doesn't mandate RLS, but production deployments generally want it to prevent data leaks across orgs. A future `postgres-rls.sql` companion is planned.
- **Performance tuning notes.** Hot-path query tuning, autovacuum settings for high-churn tables like `ses` and `tup`, partitioning guidance for very large `tup` tables.
- **Migration scaffolding.** Up/down patterns for schema evolution between spec versions.

These will land as the spec matures and real implementations surface the questions.
