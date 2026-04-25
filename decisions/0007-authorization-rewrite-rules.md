# 0007 — Authorization rewrite rules

**Status:** Proposed (v0.2)
**Date:** 2026-04-25

## Context

[ADR 0001](./0001-authorization-model.md) chose **explicit-only** authorization for v0.1: every grant is an immutable tuple, and `check()` returns true iff a tuple with the exact 5-tuple natural key exists. The decision had two motivations:

1. **Conformance simplicity.** Without a rules engine, every conforming SDK runs the same algorithm — a hash-table lookup. Cross-language parity is a hash-set comparison, not a rule-evaluator comparison.
2. **Adoption simplicity.** New users learn one primitive: write a tuple, check a tuple. No rule grammar, no debugging "why does my role inheritance not work."

This was the right v0.1 choice. It is also, mid-2026, the most common adopter friction point. Every non-trivial application reinvents the same patterns externally:

- **Role implication.** `admin` SHOULD imply `editor` SHOULD imply `viewer`. v0.1 forces apps to write all three tuples on every privilege grant and remember to remove all three on revoke. Bug-prone, especially under partial-failure storage.
- **Parent-child inheritance.** Org members SHOULD have viewer access to org-owned projects without per-project tuples. Apps either denormalize (write per-project tuples on every membership change) or run a second authz layer in application code that bypasses Flametrench's `check()`.
- **Group-as-subject.** A `team_eng` group with N members should have its tuples apply to each member individually. v0.1 supports only `usr` subjects, so apps fan out group memberships into per-user tuples manually.

Solving any one of these in app code is straightforward. Solving all three correctly, identically across SDKs, with cross-cutting concerns like cycle detection and exhaustion bounds — that is hard, and exactly what a spec exists to do once for everyone.

This ADR designs the v0.2 authorization rewrite-rules language: what shapes are normatively expressible, how rules are declared, how `check()` evaluates them, and what the cross-SDK parity contract is.

## Decision

### Adopt a subset of Zanzibar userset_rewrite

The v0.2 rule language is a deliberate subset of Google Zanzibar's `userset_rewrite` ([Zanzibar paper, §2.3](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/)). Zanzibar is the canonical design for this problem; cribbing from it gives Flametrench a battle-tested foundation and a familiar mental model for adopters who have used SpiceDB, OpenFGA, or Permify before.

The subset: **computed_userset**, **tuple_to_userset**, and **union**. Excluded for v0.2: intersection, exclusion, and recursive transitive closures. Each exclusion is documented under "Deferred."

### The rule shape

A rewrite rule is keyed on `(object_type, relation)`. For the relation `proj.viewer`, the rule defines what counts as having viewer access on a project:

```yaml
# proj.viewer = this | proj.editor | (proj#parent_org).viewer
proj:
  viewer:
    rewrite:
      union:
        - this              # explicit (usr, viewer, proj_X) tuples
        - computed_userset:
            relation: editor
        - tuple_to_userset:
            tupleset:
              relation: parent_org    # follow the proj's parent_org tuple
            computed_userset:
              relation: viewer        # check viewer on the resulting org
```

Three primitive rule operators:

1. **`this`** — the explicit-tuple set. Identical to v0.1 `check()` semantics. Always implicitly part of the union; rules that omit `this` are still permitted to satisfy via direct tuples *unless* the rule explicitly excludes them (out of scope for v0.2; see "Deferred").

2. **`computed_userset { relation: <name> }`** — "anyone holding `<name>` on this same object." Used for role implication: `editor` implies `viewer`, `admin` implies `editor`. The check recurses with the same object but a different relation.

3. **`tuple_to_userset { tupleset: { relation: <ttu> }, computed_userset: { relation: <target> } }`** — "anyone holding `<target>` on the object at the end of the `<ttu>` relation from this object." Used for parent-child inheritance: `proj#parent_org` resolves to an `org_X`; `target=viewer` then asks whether the subject is a viewer on `org_X`. The check recurses with a different object and a different relation.

A rule's body is always a `union` over one or more of these primitives. A bare primitive (no union wrapper) is shorthand for a single-item union.

### Rule storage and registration

Rules are registered per `object_type`. The full rule set for an application is normatively expressible as a single YAML or JSON document; SDKs MUST accept both. Example:

```yaml
spec_version: "0.2.0"
rules:
  proj:
    viewer:
      union:
        - this
        - computed_userset: { relation: editor }
        - tuple_to_userset:
            tupleset: { relation: parent_org }
            computed_userset: { relation: viewer }
    editor:
      union:
        - this
        - computed_userset: { relation: admin }
    admin:
      this   # no rewrites; admin requires explicit tuple
  org:
    viewer:
      union:
        - this
        - computed_userset: { relation: member }
    member:
      this
    admin:
      this
```

Rule sets are immutable per spec_version; live mutation in production is out of scope for v0.2. Rule loading happens at SDK initialization. The `TupleStore` interface gains an optional `rules` parameter on construction; an SDK with no rules registered MUST behave identically to a v0.1 SDK (every relation is implicitly `this`).

### Evaluation algorithm

`check(subject, relation, object)` evaluation proceeds in three steps:

1. **Direct lookup.** Identical to v0.1: query for an exact tuple `(subject, relation, object)`. If present, return `allowed: true` immediately. This is the v0.1-conformant fast path; rules add cost only when the direct lookup misses.

2. **Rule expansion.** Look up the rule for `(object.type, relation)`. If no rule is registered, return `allowed: false` (v0.1-equivalent behavior). If a rule exists, expand its primitives:
   - `this` is the direct lookup from step 1; if it had matched, we wouldn't be in step 2.
   - `computed_userset { relation: r' }` recursively calls `check(subject, r', object)`.
   - `tuple_to_userset { tupleset: { relation: ttu }, computed_userset: { relation: target } }` enumerates all tuples `(*, ttu, object)`. For each such tuple's *subject* — call it `obj'` — recursively call `check(subject, target, obj')`.

3. **Short-circuit on first match.** Evaluation is `union`-only in v0.2; any sub-check returning `allowed: true` returns the whole evaluation. Implementations MUST short-circuit; they MAY parallelize sub-evaluations.

The algorithm has bounded depth `D` (configurable; spec floor: 8) and bounded fan-out `F` per `tuple_to_userset` step (configurable; spec floor: 1024). Calls exceeding either bound MUST raise `EvaluationLimitExceededError`. The spec normatively recommends but does not require depth ≤ 4 and fan-out ≤ 256 for production rule sets — beyond these, latency becomes hard to predict.

### Cycle detection

Rules are a graph; rule cycles are possible and MUST be detected. Detection is per-evaluation (not at rule registration), tracking a stack of `(relation, object)` pairs visited during the current `check()`. If a recursive sub-call would re-enter a node already on the stack, that branch returns `allowed: false` (the cycle adds no new information). The evaluation continues with other branches of the union.

This is the cleanest semantics: cycles are silently ignored rather than erroring, because legitimate rules CAN be self-referential under non-cyclical paths. For example, "admin implies admin on parent" creates a cycle when a node is its own parent (legal in some hierarchies); we should not error, just stop.

Implementations MUST NOT cache cycle-aborted branches; a different starting point may reach the same `(relation, object)` via a non-cyclical path that should succeed.

### Cross-SDK parity contract

The conformance suite gains a new fixture family `fixtures/authorization/rewrite-rules/` with the following corpus (v0.2 floor; expandable):

- **`union-of-direct.json`** — straightforward union of `this`-only rules; checks role implication.
- **`computed-userset-chain.json`** — `admin` → `editor` → `viewer` chain; verifies depth-2 evaluation.
- **`tuple-to-userset-parent.json`** — org → proj inheritance via `parent_org`.
- **`cycle-self-reference.json`** — a node that is its own parent; check terminates without error.
- **`depth-limit-exceeded.json`** — a chain that exceeds the configured depth limit; verifies `EvaluationLimitExceededError`.
- **`fan-out-limit-exceeded.json`** — a `tuple_to_userset` step expanding to too many objects; verifies the same.
- **`empty-rules-equals-v01.json`** — an SDK with no rules registered MUST behave identically to v0.1 on every existing v0.1 fixture.

The empty-rules fixture is load-bearing: it is the conformance bridge that lets a v0.2 SDK consume the v0.1 fixture corpus unchanged when run against an empty rule set.

### Migration from v0.1

A v0.1 SDK upgrades to v0.2 with no behavioral change as long as no rules are registered. This is the central compatibility guarantee. v0.1 conformance fixtures continue to pass on a v0.2 SDK with empty rules.

A v0.1 application migrating to use rewrite rules removes the explicit denormalization tuples it was writing (e.g., per-project viewer tuples for org members) once the corresponding rules are registered. The migration MUST happen in this order to preserve invariants:

1. Register the rule set.
2. Verify checks return identical results with explicit tuples still present (rule shadowing the direct match).
3. Delete the now-redundant explicit tuples in batches.

Skipping step 2 risks a window where the deletion has happened but the rule has not loaded — a real outage. v0.2 docs MUST describe this migration recipe normatively.

## Consequences

**Positive:**
- Apps stop reinventing role-implication and parent-child inheritance externally; the spec covers the common cases.
- The cross-SDK conformance suite enforces evaluation parity, so `check()` returns the same answer on the same rules in every language.
- The `this`-only path is unchanged for direct grants — v0.2 introduces zero overhead for grants that don't use rewrites.
- Adopters with experience in Zanzibar / SpiceDB / OpenFGA / Permify see familiar primitives and don't learn a new mental model.

**Negative:**
- Conformance complexity grows. The fixture corpus must cover evaluation order, cycle handling, depth/fan-out limits, and rule-set parsing — each of which has SDK bugs to discover and pin down.
- `check()` cost is no longer constant. Apps with deep rule chains observe latency increases proportional to the chain depth and fan-out. The spec floor (depth 8, fan-out 1024) is a hard ceiling but not a typical case.
- Rule debugging is harder than direct-tuple debugging. The SDK MUST expose an `expand()` method (returning the resolved userset tree) so adopters can introspect why a check returned what it did. This is a v0.2 SDK requirement, not a v0.1 carry-over.
- Migration from v0.1 has a real failure mode (delete-then-rule-load ordering). Documentation MUST be explicit; tooling SHOULD warn.

## Deferred

- **Intersection** (`A ∩ B`). Useful for "must hold both relations" patterns. Adds DeMorgan dualities to evaluation reasoning but no new fundamental primitive. Revisit in v0.3 if adopters demand it.
- **Exclusion** (`A \ B`). Negation in authz is a footgun — implicit-deny is a category of bug we don't want to introduce while v0.2 is stabilizing. Revisit in v0.3+ with explicit guard rails.
- **Recursive closures** (`A*`). Useful for hierarchical org trees; the spec floor on depth is the v0.2 substitute. A bounded-recursion form (`A*` up to depth N) may land in v0.3.
- **Live rule mutation.** v0.2 rules are immutable per spec_version; apps deploy rule changes via the same release process as code. A `RuleStore` that admits CRUD on rules at runtime is a v0.3+ feature gated on operational maturity (versioning, drain, rollback).
- **Rule-level audit.** v0.2 emits no audit event when a rule resolution succeeds vs. when an explicit tuple does. v0.3 with the audit-events capability (`aud_`) will distinguish.
- **Rule storage in Postgres.** The reference Postgres schema does not yet have `rule` tables; rules are loaded from a YAML/JSON document at SDK init. v0.2 may add a Postgres adapter for runtime-loaded rules; v0.3 will normatively specify if it does.

## Rejected alternatives

### Full Zanzibar `userset_rewrite`

Rejected for v0.2 scope. The full feature set (intersection, exclusion, recursive closures, computed-userset-with-args) is significant additional surface for the conformance suite and the SDK implementations. Adopting the subset above buys 80%+ of the value at <40% of the implementation cost, with the remainder available in v0.3+ if needed. Zanzibar's full design is the long-term target; v0.2 is the path there.

### CEL or OPA / Rego as the rule language

Rejected. Both are well-designed for their original problem (CEL: Kubernetes admission control; Rego: general policy). For Flametrench they would:

- Add a 1-2 MB runtime to every SDK in every language.
- Make cross-SDK byte-identical evaluation harder; CEL has a reference implementation but Rego does not, and parser-level differences leak into evaluation differences.
- Position Flametrench as a policy engine, not an authorization spec. The two are different products. Adopters who want CEL or Rego have OPA already.

A purpose-built mini-language with three primitives is small enough to specify normatively and large enough to cover the common cases.

### Per-app rule languages (each adopter writes their own evaluator)

This is the v0.1 answer ("write your own external rules layer"). It is the status quo we are replacing. Cross-SDK parity is impossible by construction.

### Rule expansion at write time (denormalization)

Rejected. Denormalization at write time means every grant fans out to N rule-implied tuples. On revoke, all N must be deleted atomically; on rule changes, the entire set must be recomputed. This is the pattern apps reinvent today externally; the bugs they hit are the bugs we'd inherit.

Read-time evaluation (this ADR) trades read latency for write simplicity. The correct trade-off for an authz primitive: writes are infrequent and high-stakes (must be exactly right); reads are frequent and benefit from short-circuit short paths.

### Rules as code (a Lua/JS/Wasm script per relation)

Rejected. Code-as-config is Turing-complete and impossible to make byte-identical across language sandboxes. Every adopter would test against a single SDK's runtime and trust it works elsewhere. The conformance contract evaporates.

## References

- [ADR 0001 — Authorization model: relational tuples, explicit only](./0001-authorization-model.md) — the v0.1 deferral that this ADR resolves.
- [Zanzibar: Google's Consistent, Global Authorization System (USENIX ATC 2019)](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/) — design lineage; this ADR adopts a subset of §2.3.
- SpiceDB, OpenFGA, Permify — open-source Zanzibar derivatives; their schema languages are reference points for adopter expectations.
- [`docs/authorization.md`](../docs/authorization.md) — v0.1 normative authz spec; will gain a "Rewrite rules (v0.2)" section once this ADR is Accepted.
- [`spec/conformance/fixtures/authorization/`](../conformance/fixtures/authorization/) — current v0.1 fixture corpus; v0.2 adds a `rewrite-rules/` subdirectory under it.
