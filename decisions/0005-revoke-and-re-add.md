# 0005 — Revoke-and-re-add lifecycle pattern

**Status:** Accepted
**Date:** 2026-04-23

## Context

Three v0.1 entities undergo **privilege-meaningful state changes** over their lifetime:

- `cred_` — credential rotation (password change, passkey re-registration, OIDC re-link).
- `mem_` — membership role changes (promotion, demotion, suspension, reinstate).
- `ses_` — session refresh (new token on expiration or rotation).

For each, we chose between two lifecycle mechanisms:

1. **Mutate in place.** Update the row with new values. Audit happens in a separate log table or via triggers.
2. **Revoke and re-add.** Transition the existing row to terminal `revoked`; insert a new row with the new values; link them via a `replaces` pointer.

This ADR records the rationale for choosing (2) everywhere applicable, and documents the shape of the resulting chain so future entities can adopt it consistently.

## Decision

Revoke-and-re-add is the normative lifecycle mechanism for any `cred_` or `mem_` state change that alters the entity's privilege footprint. Sessions (`ses_`) adopt the `revoked_at` semantics but do NOT form a chain — see "Which entities adopt the pattern" below.

### The pattern

Every entity adopting the pattern has:

- A `status` field with values `active`, `suspended`, `revoked`.
  - `active` — only live state.
  - `suspended` — optional pause state (for `cred_` and `mem_`).
  - `revoked` — terminal; a revoked row is never mutated again.

- A `replaces` field: nullable self-referencing FK to the previous row in the chain.
  - Chain root has `replaces = NULL`.
  - Walking the chain backward yields complete history.

- Monotonic timestamps. `created_at` on each row strictly exceeds the `created_at` of the row it replaces. This is enforced by transactional insertion order; no additional constraint is needed.

### A change transaction

```sql
BEGIN;
  UPDATE cred SET status = 'revoked' WHERE id = :old_id;
  INSERT INTO cred (..., replaces = :old_id, ...) VALUES (...);
  -- For credential rotation specifically, cascade to sessions:
  UPDATE ses SET revoked_at = now() WHERE cred_id = :old_id AND revoked_at IS NULL;
COMMIT;
```

Either the entire transaction commits or none of it. No observable intermediate state.

### Querying history

The "original" state of an entity — when did Alice first join Acme? — is at the chain root:

```sql
WITH RECURSIVE chain AS (
    SELECT * FROM mem WHERE id = :current_id
  UNION ALL
    SELECT m.* FROM mem m
      JOIN chain c ON m.id = c.replaces
)
SELECT * FROM chain ORDER BY created_at;
```

The row with `replaces IS NULL` is the origin. Downstream analytical systems flatten the chain on ingestion.

### Tamper-evidence

The chain is append-only and timestamps are monotonic. Forging history — inserting a `replaces` row out of order, deleting a historical row — is detectable:

- Timestamps must increase along the chain.
- The chain must terminate at a root (`replaces = NULL`); orphan references indicate deletion.
- Counting distinct entities and comparing to chain counts surfaces tampering.

Not cryptographic audit (no Merkle hashing), but for the zero-trust posture v0.1 targets, append-only with monotonic timestamps is sufficient.

### Which entities adopt the pattern

- **`cred_` — yes.** Every credential rotation creates a new row with `replaces`.
- **`mem_` — yes.** Every role change, suspension, or reinstate creates a new row with `replaces`.
- **`ses_` — partial.** Sessions adopt `revoked_at` for termination but NOT the `replaces` chain. Refresh is "close one session, open a new one" — each session is its own authentication event, not an evolution of the previous. Chaining would imply a causal relationship that isn't present.
- **`inv_` — no.** Invitations have a terminal state machine; the terminal states ARE the audit trail. Chaining adds nothing.
- **`tup_` — no.** Tuples are append-only at the row level; a deleted tuple is simply gone. If a tuple's history matters (who granted it, when), that belongs in `created_by` and optionally an external audit log.

### Why `ses_` doesn't get a chain

A refreshed session has no meaningful connection to the previous session beyond "same user." The new session bears its own `cred_id`, its own TTL, its own observable lifetime. Chaining would imply causal continuity that is not actually present.

If we need to correlate pre-refresh and post-refresh sessions for analytics, we do it via `usr_id` joins in the analytics layer, not via spec-level chain traversal.

## Consequences

**Positive:**

- Every privilege-meaningful state has a unique ID. Audit reconstructions never ask "what was Alice's role at 14:32?" — they ask "which `mem_` row was active at 14:32?"
- No shadow audit tables. The business-entity table IS the history.
- Tamper-evidence is intrinsic, not an add-on.
- Revocation cascade semantics are uniform across entities.

**Negative:**

- Tables grow monotonically. Archival requires care — deleting revoked rows destroys audit.
- Queries for "current state" need a `WHERE status = 'active'` filter or a partial index.
- Row-count estimates for capacity planning must account for historical accumulation.

**Neutral:**

- Writes on state change are 2× what they would be with in-place mutation. Acceptable at the entity scale we're designing for.

## Rejected alternatives

- **In-place mutation with an audit table.** Two sources of truth invite drift. Audit tables are a classic security gap — teams forget to log or silently skip fields.
- **In-place mutation with a mirroring trigger.** Better than manual audit but still two tables; schema changes must propagate to both.
- **Chain with a separate archive table.** "Active" in `mem`, "revoked" in `mem_archive`. Simpler current-state queries; more complex history queries; DDL burden of maintaining parallel schemas.

## References

- [ADR 0002 — Tenancy model](./0002-tenancy-model.md) — uses the pattern for `mem_`.
- [ADR 0004 — Identity model](./0004-identity-model.md) — uses the pattern for `cred_`.
- `spec/reference/postgres.sql`.
