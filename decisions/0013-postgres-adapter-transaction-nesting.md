# 0013 — Postgres adapter transaction nesting

**Status:** Proposed (v0.2)
**Date:** 2026-04-28

## Context

Flametrench's reference Postgres adapters open their own transactions to make multi-row writes atomic. `PostgresTenancyStore::createOrg`, `PostgresTenancyStore::acceptInvitation`, every multi-statement op in `PostgresIdentityStore`, and `PostgresShareStore::verifyShareToken` (single-use consume) each wrap their work in `BEGIN ... COMMIT` against the supplied connection. This is correct for the single-SDK-call case — the unit of atomicity is the SDK call.

It breaks down when an adopter needs to wrap **multiple SDK calls** — and possibly host-side writes — in one outer transaction. PHP PDO does not support nested transactions on Postgres without explicit savepoints; the same is true at the wire level for every Postgres client across our four SDK families. An outer `beginTransaction()` followed by an inner adapter call that itself calls `beginTransaction()` either raises an error or quietly commits the inner work, depending on the client library's behavior.

The use case driving the ADR is `sitesource/admin`'s install bootstrap (filed at [`flametrench/laravel#1`](https://github.com/flametrench/laravel/issues/1)). The bootstrap sequence is:

1. `IdentityStore::createUser` — owner principal.
2. `IdentityStore::createPasswordCredential` — owner credential.
3. `TenancyStore::createOrg` — root org.
4. `TupleStore::createTuple` — `SYSTEM_ADMIN` relation on `system_<install_id>`.
5. Write `admin_install` marker row — admin-local, single-table, **not an SDK call**.

If any of 1–4 fails, partial state is orphan data: a `usr_` with no creds, an `org_` with no system-admin tuple, and so on. Even with admin's "marker last" rule (their ADR 0006), every failed install leaves orphaned rows that accumulate over time. The adopter wants the entire 1–5 sequence to commit-or-rollback as a unit.

Today they cannot wrap 1–5 in a single PDO transaction because each `Postgres*Store::*` method opens its own. The fix has to live in the adapter, not the adopter — the contract change is that adapters cooperate with an outer transaction when one is active.

## Decision

A Postgres reference adapter MUST detect an active outer transaction on the connection it was constructed with, and convert its own internal `BEGIN`/`COMMIT`/`ROLLBACK` into `SAVEPOINT`/`RELEASE SAVEPOINT`/`ROLLBACK TO SAVEPOINT` when one is present. When no outer transaction is active, the adapter MUST behave exactly as it does today: open its own transaction with `BEGIN` and commit on success.

This is normative across all four reference SDKs (Node, PHP, Python, Java).

### Detection

The adapter MUST query the connection for active-transaction state at the start of every method that would otherwise call `BEGIN`. The detection mechanism is per-language:

- **PHP (PDO)**: `\PDO::inTransaction()`.
- **Node (`pg`)**: clients pooled via `pg.Pool` expose no portable in-transaction flag; the adapter SHOULD accept either a `pg.Client` (single connection, where the adapter tracks transaction state explicitly) or a `pg.PoolClient` (caller-owned, caller-tracked). The "outer transaction" semantic is established by the caller passing in a `PoolClient` already inside a `BEGIN`.
- **Python (`psycopg`)**: `Connection.info.transaction_status` returning `psycopg.pq.TransactionStatus.INTRANS` or `INERROR`.
- **Java (JDBC)**: `Connection.getAutoCommit() == false` AND a prior statement has been issued on the connection (or, more simply, the adapter accepts a connection with auto-commit disabled as a signal that the caller owns the transaction).

The exact mechanism is a per-SDK implementation detail; the normative requirement is that the adapter behaves correctly when an outer transaction is active and when one is not.

### Savepoint naming

Savepoint names MUST follow the pattern `ft_<method>_<random>`, where:

- `<method>` is a stable identifier of the originating adapter method (e.g. `createOrg`, `acceptInvitation`, `verifyShareToken`). It SHOULD use the literal method name from the SDK surface to maximize log readability.
- `<random>` is at least 32 bits of non-cryptographic entropy, lowercase hex-encoded. 8 hex characters is the recommended length.

**Why both components.** Postgres treats savepoint names as a LIFO stack: a duplicate name shadows the prior frame and is released by `RELEASE SAVEPOINT` in reverse order. This works correctly when bookkeeping is correct, but it masks pairing bugs as silent commits with no Postgres error. Unique-per-call names turn the same bug into a loud `savepoint "ft_<method>_<random>" does not exist` error pointing at the exact call site. The `<method>` prefix preserves grep-ability in `pg_stat_activity`, `auto_explain` output, and `pgBadger` reports without sacrificing uniqueness.

**Example traces.**

```sql
-- Adopter wraps createOrg (which internally creates a tuple) in their own DB::transaction.
BEGIN                                            -- adopter
SAVEPOINT ft_createOrg_a1b2c3d4                  -- createOrg detects outer
  -- inserts org row
  SAVEPOINT ft_createTuple_e5f6g7h8              -- createTuple detects outer
    -- inserts tup row
  RELEASE SAVEPOINT ft_createTuple_e5f6g7h8
RELEASE SAVEPOINT ft_createOrg_a1b2c3d4
COMMIT                                            -- adopter
```

```sql
-- Same shape, but the inner createTuple fails.
BEGIN
SAVEPOINT ft_createOrg_a1b2c3d4
  SAVEPOINT ft_createTuple_e5f6g7h8
    -- INSERT raises 23505 (duplicate tuple)
  ROLLBACK TO SAVEPOINT ft_createTuple_e5f6g7h8
  RELEASE SAVEPOINT ft_createTuple_e5f6g7h8
  -- exception propagates out of createTuple
ROLLBACK TO SAVEPOINT ft_createOrg_a1b2c3d4
RELEASE SAVEPOINT ft_createOrg_a1b2c3d4
-- exception propagates out of createOrg; adopter decides whether to ROLLBACK the outer
```

The random suffix MUST NOT be reused across calls within the same connection's lifetime within practical bounds. 32 bits is sufficient for any realistic per-connection call rate; SDKs MAY use 64 bits for additional headroom.

### Error semantics

When an adapter's inner work raises, the adapter MUST:

1. Issue `ROLLBACK TO SAVEPOINT <name>`.
2. Issue `RELEASE SAVEPOINT <name>` to remove the savepoint frame from the stack.
3. Rethrow the original exception unchanged.

Step 2 is non-obvious but normative: leaving a rolled-back savepoint on the stack causes the next outer-level `RELEASE`/`ROLLBACK TO` to operate on stale state, and accumulates unbounded server-side state if the outer transaction is long-lived. `ROLLBACK TO SAVEPOINT` does NOT release the savepoint by itself in Postgres.

When no outer transaction is active, the adapter follows its existing `BEGIN`/`COMMIT`/`ROLLBACK` flow.

### Shared-connection requirement

For the savepoint nesting to compose, all SDK store instances participating in an outer transaction MUST be constructed with the **same** underlying connection object. A common adopter mistake is to construct two stores with two different `\PDO` instances (or two `pg.PoolClient`s, or two JDBC `Connection`s) and assume an outer transaction on one applies to the other. It does not.

SDK adapters SHOULD document this requirement prominently in their constructor docblocks. SDK adapters MAY implement a runtime assertion (e.g. object identity check) when sharing a connection across multiple store constructors via a factory.

### Conformance

A new conformance fixture `shared/transaction-nesting.json` (in `spec/conformance/fixtures/shared/`) covers the cross-cutting contract:

- An adapter call inside an active outer transaction does not raise a "transaction already active" error.
- An adapter call inside an active outer transaction does not commit on its own — committed effects are only visible after the outer commit.
- An adapter call inside an active outer transaction that raises rolls back its own writes via `ROLLBACK TO SAVEPOINT`, leaving the outer transaction live and able to commit other work.
- Two adapter calls inside the same outer transaction can both be rolled back together by rolling back the outer transaction.

The fixture is shared rather than per-capability because the contract is uniform across every Postgres adapter; per-SDK test suites consume the fixture via their existing harness.

## Consequences

- **Backwards compatibility.** Pure addition. Existing single-SDK-call adopter code keeps working unchanged — when no outer transaction is active, the adapter's behavior is identical to v0.2-rc.5.
- **Performance.** A negligible per-call overhead: one detection check, two `SAVEPOINT`/`RELEASE` round-trips when nested. Random-suffix generation is a single non-cryptographic RNG call.
- **Debuggability.** `pg_stat_activity`, `auto_explain`, and pg log output gain method-named savepoints (`ft_createOrg_a1b2c3d4`) where they previously saw bare `BEGIN`/`COMMIT` boundaries. Net positive.
- **Cross-SDK symmetry.** All four reference adapters expose the same outer-transaction contract; adopter code that learned the pattern in one ecosystem ports cleanly to another.
- **Adopter footgun: shared connection.** New documentation surface and (where feasible) runtime assertions help, but the requirement is still implicit at the type level. Adopters who construct stores from disparate connections will get silent partial commits. Mitigation lives in adapter docs and (Phase 2) optional factory helpers.

## Alternatives considered

### `Flametrench::transaction(fn)` bootstrap helper

A new top-level helper that takes a closure, exposes the SDK stores to it, and wraps the work in a single transaction. Rejected because:

1. **It does not solve the bootstrap use case.** Step 5 of the install bootstrap is a non-SDK write (the `admin_install` marker). A helper that only exposes SDK stores has nowhere to put that write; the adopter still needs an outer `DB::transaction()` wrapping the helper. Once you have that, the helper is redundant.
2. **It does not compose with framework transaction middleware.** Laravel apps already wrap controllers in `DB::transaction()`; layering `Flametrench::transaction()` inside means the framework's transaction is the *outer* and the helper still has to use savepoints — exactly Option A's solution.
3. **It is speculative API surface.** Once the savepoint-pass-through contract exists, an ergonomic helper can be built on top of it in ~30 lines whenever real demand surfaces. Building it now risks a long-term API commitment for a problem that may never materialize independently of the savepoint solution.

### Fixed savepoint name (`ft_outer`)

Every adapter call uses the same savepoint name. Rejected because pairing bugs commit silently. Postgres's LIFO stack rules make the trace correct when bookkeeping is correct, but a missing `RELEASE` or a misordered `ROLLBACK TO` rolls back the wrong frame with no error and no log signal. The unique-suffix scheme turns the same bug into a loud `savepoint does not exist` error.

### Per-method name without random suffix (`ft_createOrg`)

Beautiful logs, but breaks under recursion (a future bulk-accept that loops over `acceptInvitation`) or when two adapter methods happen to share a name across packages. Same silent-pairing-bug problem as fixed names. Rejected for the same reason.

### Pure random name (`ft_a1b2c3d4`)

Eliminates shadowing but loses log readability — `pg_stat_activity` shows opaque hex strings instead of method names. The combined `ft_<method>_<random>` shape costs 8 extra characters and gets both properties.

### Document the limitation; require adopters to know that wrapping multiple SDK calls is unsupported

The status quo. Rejected because the use case is real and recurrent (every adopter eventually wants atomicity across multiple SDK ops) and the SDK contract should not push this onto every adopter to discover and work around individually.

## Out of scope / Deferred

- **Distributed transactions / two-phase commit.** Out of PDO/JDBC scope and out of the spec's single-Postgres-instance reference posture.
- **Cross-process transaction handoff** (e.g. queue worker continues a transaction started in a web request). Inherently cross-process; not addressable at the SDK layer.
- **Idempotency tokens.** A different mitigation pattern. Adopters who want safe-retry-on-failure semantics can layer them on top of the transaction-nesting fix, but the spec does not require them.
- **`Flametrench::transaction(fn)` ergonomic helper.** Deferred to a future ADR if and when adopter feedback shows the savepoint-pass-through contract is insufficient on its own.
- **MySQL / SQLite adapter behavior.** The reference adapter is Postgres-only. If a non-Postgres reference adapter ships in the future, this ADR's guidance ports directly (both engines support `SAVEPOINT`), but the named ADR scope is Postgres.

## References

- Adopter use case: [`flametrench/laravel#1`](https://github.com/flametrench/laravel/issues/1) — install-bootstrap atomicity requirement.
- `sitesource/admin` ADR 0006 — installer self-lockout; the "marker last" rule that this ADR lets adopters supersede.
- [Postgres SAVEPOINT documentation](https://www.postgresql.org/docs/current/sql-savepoint.html) — semantics of LIFO naming and `ROLLBACK TO SAVEPOINT` not releasing the frame.
- [`decisions/0012-share-tokens.md`](./0012-share-tokens.md) — `verifyShareToken` is one of the three current sites where this ADR's guidance applies.

## Filed by

`sitesource/admin` install-bootstrap atomicity, via `flametrench/laravel#1`. Tag: `feedback:sitesource-admin`.
