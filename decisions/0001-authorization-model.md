# 0001 — Authorization model: relational tuples, explicit only

**Status:** Accepted
**Date:** 2026-04-23

## Context

Every multi-tenant application needs an authorization primitive that answers *"can this subject perform this action on this object?"* Three well-established families exist:

1. **Zanzibar-style relational tuples.** Every grant is a row `(subject, relation, object)`. A `check()` resolves by graph traversal, optionally with schema-defined rewrite rules. Used by Google, GitHub, Uber, Airbnb. Open-source implementations: OpenFGA, SpiceDB.
2. **Classical role-based access control (RBAC).** Users have roles within a scope; roles have permissions; permissions are checked directly.
3. **Attribute-based access control (ABAC).** Policies are predicates over subject/object/environment attributes, expressed in a policy language (Rego, Cedar, Casbin). Evaluation typically happens in a separate service.

Flametrench v0.1 must pick one and specify it precisely enough that every conforming SDK produces byte-identical authorization decisions for byte-identical inputs. The choice shapes the tenancy model, the SDK surface, the database schema, and the operational characteristics of every conforming implementation.

## Decision

Flametrench v0.1 adopts **relational tuples as its sole authorization primitive**, with a deliberate simplification: **no rewrite rules, no derivations**. All authorization grants are stored as explicit tuples.

### Tuple shape

Every grant is a row:

```
(subject_type, subject_id, relation, object_type, object_id)
```

A tuple carries its own UUIDv7 (`tup_…`) plus creation metadata (`created_at`, `created_by`). The 5-tuple natural key above is `UNIQUE`; duplicate grants are impossible.

### The `check()` primitive

```
check(subject, relation | [relations], object) → bool
```

Returns `true` iff a tuple exists for the given subject and object with any of the given relations. No derivation; exact match only.

A conforming SDK MUST accept both a single-relation form and a non-empty-set form.

### v0.1 registered relations

Six built-in relations with defined semantic intent:

| Relation | Typical meaning |
|---|---|
| `owner` | Full control of a scope; typically one per org |
| `admin` | Management rights on membership/config, not ownership |
| `member` | Default participation |
| `guest` | Minimal, usually scoped |
| `viewer` | Read-only |
| `editor` | Read + write |

Applications MAY register additional relation names (`dispatcher`, `approver`, `publisher`, etc.). v0.1 imposes no semantics on custom relations. Relation names MUST match `^[a-z_]{2,32}$` — the pattern permits underscores and longer names to keep them readable.

### What v0.1 does NOT include

- **Rewrite rules.** There is no way to declare "admin implies editor" or "members of an org are viewers of its projects" inside the spec. Applications needing these patterns either materialize the implied tuples at state-change time, or pass a relation set to `check()` at query time. Both patterns are spec-supported (see `docs/authorization.md`); neither is favored.
- **Group subjects.** Tuples in v0.1 may only have `usr`-type subjects. Group-subject tuples (`grp_team.viewer`) are deferred to v0.2+.
- **Schema language.** No per-application relation-type schema. Relations are just strings.

## Consequences

**Positive:**

- Tenancy and authorization share one primitive. Every membership `mem_(alice, role, acme)` has a corresponding tuple `tup_(usr_alice, role, org_acme)`. Semantic drift is impossible.
- Offboarding cascade is trivial: `DELETE FROM tup WHERE subject_type='usr' AND subject_id=:user_id`.
- Postgres-native. One table, three indexes cover 95% of workloads (exact-match check, enumeration, cascade).
- Audit is flat: every grant is visible as a single row. "Who can view X?" is a single SQL query.
- SpiceDB and OpenFGA provide a charted path to v0.2+ rewrite rules when we need them.

**Negative:**

- Applications wanting "org members can view all org projects" must either materialize N×M tuples at state-change time or encode the check as a relation set. Most real apps will mix both.
- Role hierarchies (`admin > editor > viewer`) aren't automatic — callers pass relation sets or materialize implications.

**Neutral:**

- The spec does not choose between Pattern A (materialize) and Pattern B (relation sets). Both are valid; both appear in `docs/authorization.md`.

## Deferred to v0.2+

Based on real-world usage of v0.1, we expect to add SOME of the following in v0.2 — not all, and not necessarily as described:

1. **Role implication within a scope** — `admin > editor > viewer` declarative chains.
2. **Parent-child inheritance** — rules like `project.viewer inherits org.member`.
3. **Group expansion** — `grp_` subject type with automatic member expansion at check time.

Deferring is deliberate: speccing any of these without production telemetry risks shipping the wrong abstraction. The v0.1 tuple primitive is forward-compatible with every candidate rewrite-rule system considered.

## Rejected alternatives

### Classical RBAC

- **Strength:** Simplest to spec, simplest to audit.
- **Weakness:** Resource-scoped grants (a contractor with access to a single project) require a second primitive. Sharing/delegation patterns don't fit. Teams outgrow RBAC and bolt on ACLs, which is a worse version of tuples.
- **Why rejected:** Many production SaaS teams that start with RBAC end up reinventing Zanzibar-lite. Ship the right primitive up front.

### ABAC with a policy language

- **Strength:** Maximal expressivity; handles time-of-day, purpose-of-use, regulatory conditions.
- **Weakness:** Requires the spec to own the semantics of a programming language. Postgres-native evaluation is hard. Auditing is a theorem-prover problem.
- **Why rejected:** A power ceiling we would not use at v0.1 scale, at a spec cost we cannot pay.

## References

- [ADR 0002 — Tenancy model](./0002-tenancy-model.md) — memberships are tuples.
- [ADR 0005 — Revoke-and-re-add lifecycle pattern](./0005-revoke-and-re-add.md).
- Zanzibar paper: <https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/>
- SpiceDB: <https://authzed.com/spicedb>
- OpenFGA: <https://openfga.dev/>
