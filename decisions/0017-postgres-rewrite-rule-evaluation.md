# 0017. Postgres rewrite-rule evaluation

Status: Proposed (v0.3 — in development)

Date: 2026-05-01

## Context

ADR 0007 specified the v0.2 rewrite-rule language and a three-step evaluation algorithm: direct lookup → rule expansion → short-circuit on first match. All four SDK families shipped that algorithm in v0.2 via their `InMemoryTupleStore`. The reference document `docs/authorization.md` then explicitly deferred Postgres-backed rule evaluation to v0.3:

> Postgres-backed rule evaluation is deferred to v0.3 — adopters who need Postgres durability today can keep the rules-relevant tuple subset in-memory and use the in-memory `check()` for those queries.

`PostgresTupleStore.check()` in v0.2 is exact-match-only: a single SELECT against the natural key with no rule expansion. Adopters whose tuples live in Postgres but who want rule-based authorization have, until v0.3, had to load the relevant tuple subset into an `InMemoryTupleStore` at request time. That works for small graphs but is operationally awkward — it forces a parallel data path, doubles the memory footprint, and breaks down once the tuple set is too large to materialize.

This ADR retires the deferral. It pins the implementation strategy that `PostgresTupleStore` (across all four SDK families) MUST follow when evaluating rewrite rules, and the corresponding SDK-internal API change that lets the rule evaluator drive async tuple lookups against a database.

## Decision

### Iterative async expansion, not SQL push-down

`PostgresTupleStore.check()` evaluates rewrite rules using the same algorithm specified in ADR 0007 (direct lookup, recursive expansion, union short-circuit, cycle detection, depth + fan-out bounds). The difference vs. `InMemoryTupleStore` is that each tuple lookup is a single async SELECT against Postgres rather than a synchronous map probe.

A worked example. For the rule `proj.viewer = this | computed_userset(editor) | tuple_to_userset(parent_org → org.viewer)` and a check `(usr_a, viewer, proj_x)`:

1. Direct lookup: `SELECT id FROM tup WHERE subject_type = 'usr' AND subject_id = $usr_a AND relation = 'viewer' AND object_type = 'proj' AND object_id = $proj_x LIMIT 1`. One round trip. Hit ⇒ return.
2. Miss ⇒ rule expansion. `computed_userset(editor)` recurses into `(usr_a, editor, proj_x)` — the same shape against the same table.
3. `tuple_to_userset(parent_org → org.viewer)` runs `SELECT subject_type, subject_id FROM tup WHERE object_type = 'proj' AND object_id = $proj_x AND relation = 'parent_org'`, then for each result recurses into `(usr_a, viewer, $resulting_org)`.

Total cost is bounded by the rule's static depth and the per-step fan-out bound. For a depth-3 rule with fan-out of 2, that's ~7 round trips — well within the spec floor of D=8 / F=1024 (ADR 0007).

### Why not SQL push-down via recursive CTEs

The fully-pushed-down alternative would compile each rule into a single recursive CTE and execute one round trip per `check()`. This is the design SpiceDB uses internally (its "query planner" + "dispatcher"). For Flametrench it is rejected for v0.3:

- **Implementation cost.** Each rule shape (`computed_userset`, `tuple_to_userset`, nested unions) maps to a different CTE skeleton. Generating these correctly across the parameter ranges adopters use is a multi-month project that is hard to verify against the conformance corpus.
- **Marginal latency win.** Postgres recursive CTEs against a properly-indexed `tup` table return in single-digit milliseconds. The 7-round-trip iterative approach in the worked example above costs ~3-5ms in a colocated deployment — the saved milliseconds are not the bottleneck.
- **Rule-evaluation parity.** The iterative approach reuses ADR 0007's algorithm verbatim. Cycle detection, depth bounds, fan-out bounds, and short-circuit semantics are guaranteed identical to the in-memory store — there is nothing to re-prove via conformance fixtures. A push-down implementation would require its own correctness proof per rule shape.

SQL push-down may land in v0.4+ as a `PostgresTupleStore` constructor option for adopters running rule sets with deep chains and high fan-out (the regime where round-trip count actually dominates). It will NOT replace the iterative path — it will be a performance-tuning escape hatch alongside it.

### SDK API: async-capable rule evaluator

The internal `evaluate()` function defined per SDK in `rewrite-rules.{ts,php,py,java}` MUST accept async tuple-lookup callbacks. Concretely:

- **Node**: `DirectLookup` and `ListByObject` callbacks return `Promise<...>` (in v0.2 they returned the value directly). `evaluate()` returns `Promise<EvaluationResult>`. The in-memory store passes `Promise.resolve(...)`-wrapped synchronous lookups.
- **PHP**: callbacks remain synchronous (PHP has no async). `PostgresTupleStore` issues blocking PDO queries inside the callbacks. No interface change needed; the existing `evaluate()` works as-is once `PostgresTupleStore` implements the callbacks.
- **Python**: callbacks remain synchronous. Same as PHP — psycopg3's blocking API is fine; the iterative algorithm is naturally sequential.
- **Java**: callbacks remain synchronous (the SDK is JDBC-based, blocking by design). No interface change; `PostgresTupleStore` implements the callbacks against `Connection`.

Only the Node interface changes shape (the others were already synchronous and Postgres lookups can run synchronously inside them). Adopters who held a reference to `evaluate()` in TypeScript see a compile-time error; the migration is to `await` the result.

### `PostgresTupleStore.check()` becomes rule-aware

The v0.2 `PostgresTupleStore` constructor accepted a `pool` (Node) / `pdo` (PHP) / `connection` (Python) / `dataSource` (Java) and nothing else. v0.3 adds an optional `rules` parameter, mirroring `InMemoryTupleStore`. With `rules` unset (or empty), `check()` behavior is byte-identical to v0.2 — the v0.1 conformance fixtures pass unchanged.

```ts
// Node v0.3
new PostgresTupleStore({ pool, rules: loadedRules });
```

```php
// PHP v0.3
new PostgresTupleStore($pdo, rules: $loadedRules);
```

```python
# Python v0.3
PostgresTupleStore(connection, rules=loaded_rules)
```

```java
// Java v0.3
new PostgresTupleStore(dataSource, loadedRules);
```

When `rules` is set, `check()` dispatches to the rule evaluator on direct-lookup miss, exactly as `InMemoryTupleStore` does today.

### `checkAny()` over a relation set

ADR 0001 introduced `checkAny()` for "is the subject in any of these relations" queries. v0.2's `PostgresTupleStore` implemented it as a single SQL `relation = ANY($3)` predicate. v0.3 keeps the v0.2 implementation as the fast path: when no rule matches any relation in the set, the single SQL query short-circuits before any rule expansion. When at least one relation has a rule, the implementation MUST evaluate each relation in turn until the first match (or all rejected) — there is NO union-of-rules optimization in v0.3.

### Cycle detection in async evaluation

The cycle-detection rule from ADR 0007 (per-evaluation stack of `(relation, objectType, objectId)` frames; repeat-frame returns `denied`) is unchanged. Implementations MUST track the stack across async boundaries — TypeScript adopters, in particular, MUST NOT lose the stack to an `await` that drops the closure.

### Conformance contract update

The v0.2 conformance fixture `empty-rules-equals-v01.json` is now load-bearing for `PostgresTupleStore` too: a `PostgresTupleStore` constructed without a `rules` argument MUST pass the v0.1 conformance corpus identically to `InMemoryTupleStore` constructed without rules.

The full v0.2 rewrite-rules fixture corpus (`union-of-direct.json`, `computed-userset-chain.json`, `tuple-to-userset-parent.json`, `cycle-self-reference.json`, `depth-limit-exceeded.json`, `fan-out-limit-exceeded.json`) MUST also pass against `PostgresTupleStore` configured with the corresponding rule set. SDK conformance runners gain a `--postgres` mode that exercises the same fixtures against a real database.

### Schema change: relax `subject_type` constraint

`tuple_to_userset` requires object-to-object tuples — for example, `(org_X, parent_org, proj_Y)` where the subject is an org, not a user. The v0.1/v0.2 reference schema constrained `subject_type IN ('usr')`, which silently blocked this in any Postgres deployment and was one of the gaps that forced the in-memory shadow workaround for v0.2 rule users.

v0.3 reference schema relaxes the constraint to match the existing `object_type` pattern:

```sql
-- v0.1/v0.2:
CHECK (subject_type IN ('usr'))

-- v0.3 (ADR 0017):
CHECK (subject_type ~ '^[a-z]{2,6}$')
```

The change is additive — every `subject_type='usr'` row from v0.1/v0.2 continues to satisfy the new constraint. Existing deployments upgrade with a single `ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT ...` migration; the upgrade is included in the v0.2→v0.3 migration document.

The application contract still recommends `'usr'` for principal-grant tuples; non-`'usr'` subject types are reserved for the `tuple_to_userset` hop pattern. Group-subject expansion (`'grp'`) and per-prefix authorization remain future work.

## Consequences

- `PostgresTupleStore` becomes equivalent to `InMemoryTupleStore` in expressive power. Adopters with rules-based authorization can use Postgres durability without the in-memory shadow workaround.
- Per-check round-trip count grows from 1 to O(rule_depth × fan-out_per_step). For rule sets at the spec floor recommendation (depth ≤ 4, fan-out ≤ 256), the practical cost is 5-15ms in a colocated deployment.
- The Node SDK's `rewrite-rules.ts` evaluator is no longer synchronous. Adopters who call `evaluate()` directly (a small set; most use `tupleStore.check()`) MUST migrate to `await evaluate(...)`. The change is mechanical — nothing about the algorithm itself changes.
- The cross-SDK rewrite-rule fixture corpus, which previously ran only against in-memory stores, now runs against Postgres adapters too. This catches a class of bugs (subtle off-by-one in fan-out enumeration, cycle-detection stack lifecycle across awaits) that the in-memory tests can't surface.
- ADR 0007's "Deferred / Rule storage in Postgres" bullet — about persisting *rule definitions* in Postgres — remains deferred. This ADR addresses *evaluation* against Postgres-stored *tuples*; rule-definition storage in YAML/JSON at construction time is unchanged.

## Deferred

- **SQL push-down** (recursive CTE per rule). v0.4+ optimization once an adopter's rule profile demonstrates the round-trip count is the bottleneck.
- **Async rule evaluation in PHP/Python/Java** via the language's coroutine/async story (PHP Fibers, Python asyncio, Java virtual threads). The SDK base in v0.3 stays blocking — async wrappers are a v0.4+ concern.
- **Cross-process query batching.** Multiple concurrent `check()` calls for the same `(subject, *, object)` could share their rule expansion across SDK instances via a Redis-backed dispatcher. Out of scope for v0.3; tracked as a v0.4+ note.
- **Rule-evaluation tracing.** A debug API that returns the matched rule path (`this` ⇒ `computed_userset(editor)` ⇒ direct hit) for diagnostics. Useful for adopters writing complex rule sets; not gating v0.3.

## Rejected alternatives

### SQL push-down via per-rule recursive CTEs

Discussed in §"Why not SQL push-down via recursive CTEs" above. Rejected for v0.3 on implementation cost and marginal latency win; revisit in v0.4+ as an opt-in escape hatch.

### Materialized rule-expansion table

A background job pre-computes and writes `(subject, relation, object)` rows for every rule match into a `tup_materialized` companion table. `check()` then becomes a single SELECT against the materialized table.

Rejected: writes are O(rule_fan_out) on every tuple insertion; the materialized table can become an order of magnitude larger than `tup`; staleness windows make `check()` results lag tuple writes. Adopters who need this latency profile can build it in their application layer; the SDK should not make it a default.

### Synchronous Node API (unchanged from v0.2)

The Node `evaluate()` could keep its synchronous shape, with `PostgresTupleStore` blocking on a synchronous query helper. Rejected: there is no synchronous query API in `pg` (the Node Postgres client), and adopting one would force a different driver. The `Promise<>`-returning API is the natural Node shape and matches how every other Node async primitive is composed.

## References

- [ADR 0001](./0001-authorization-model.md) — Authorization model: relational tuples, explicit only.
- [ADR 0007](./0007-authorization-rewrite-rules.md) — Authorization rewrite rules (defines the evaluation algorithm this ADR adapts to async).
- [ADR 0013](./0013-postgres-adapter-transaction-nesting.md) — Postgres adapter transaction nesting (for the SAVEPOINT cooperation pattern).
- `docs/authorization.md` — chapter on authorization, updated by this ADR.
- Zanzibar paper, §3 ("Architecture: Aclservers and Watch") — for the dispatcher / iterative-resolution pattern Flametrench adopts in microcosm.
