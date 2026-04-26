# Authorization

Flametrench authorization is built on a single primitive: **relational tuples**. Every grant is a row `(subject, relation, object)`; every permission check matches tuples exactly.

This chapter is normative. Rationale and alternatives are in [ADR 0001 — Authorization model](../decisions/0001-authorization-model.md).

## The tuple primitive

### Entity shape

- `id` — UUIDv7; `tup_<hex>`.
- `subject_type` — the type prefix of the subject. In v0.1, MUST be `usr`.
- `subject_id` — the UUIDv7 of the subject.
- `relation` — a string matching `^[a-z_]{2,32}$`. Either a registered relation (below) or an application-custom relation.
- `object_type` — the type prefix of the object. MAY be any valid type prefix (2–6 lowercase ASCII characters, matching `^[a-z]{2,6}$`). v0.1 registered object types include `org`, `mem`, `inv`, `ses`, `cred`, `usr`. Applications MAY introduce custom object types (`project`, `doc`, etc.).
- `object_id` — the UUIDv7 of the object.
- `created_at`, `created_by` (nullable).

The natural key of a tuple is the 5-tuple `(subject_type, subject_id, relation, object_type, object_id)`. This combination MUST be unique; duplicate grants are prohibited.

### Registered relations (v0.1)

Six built-in relations. The spec pins their semantic intent; applications SHOULD use them when the intent matches.

| Relation | Semantic intent |
|---|---|
| `owner` | Full control, including ownership transfer. Typically one per org. |
| `admin` | Manage members, settings, and other admins; cannot transfer ownership. |
| `member` | Default org participant; general-purpose access to the org's features. |
| `guest` | Minimal, typically scoped; limited access. |
| `viewer` | Read-only on the object. |
| `editor` | Read and write on the object. |

#### Org-scoped vs. object-scoped

Typical usage:

- `owner`, `admin`, `member`, `guest` are applied at the org level (`object_type = org`). These are membership relations.
- `viewer`, `editor` are applied at any object level (`object_type = project`, `doc`, etc.).

The spec does not prohibit other combinations; applications MAY use `editor` on an org to mean "can edit any org-level configuration," if that matches their model.

### Custom relations

Applications MAY register relation names not in the built-in registry. Custom relations follow the same format (`^[a-z_]{2,32}$`) and carry no spec-defined semantics — the application defines meaning.

## The `check()` primitive

```
check(subject, relation | [relations], object) → bool
```

Returns `true` iff a tuple exists matching the subject, the object, and one of the given relations.

### Single-relation form

```
check(
  subject_type  = "usr",
  subject_id    = "0190f2a8-1b3c-7abc-8123-456789abcdef",
  relation      = "admin",
  object_type   = "org",
  object_id     = "01abcdef-..."
) → bool
```

### Set form

```
check(
  subject_type  = "usr",
  subject_id    = "...",
  relations     = ["owner", "admin"],
  object_type   = "org",
  object_id     = "..."
) → bool
```

Returns `true` if a tuple exists for `subject` on `object` with any of the listed relations. Equivalent to the logical OR of individual checks, provided as a single call for ergonomics and atomicity.

Implementations MUST accept both forms. The relation set in the set-form MUST be non-empty.

### Exact-match semantics

v0.1 performs EXACT match only. There is:

- **No relation implication.** `admin` does not imply `editor`. `editor` does not imply `viewer`.
- **No parent-child inheritance.** `viewer` of `org_acme` does not imply `viewer` of any project in `org_acme`.
- **No group expansion.** v0.1 has no `grp_` subject type.

If an application's authorization policy requires any of these derivations, the application is responsible for them — either by materializing the implied tuples at state-change time, or by constructing appropriate relation sets at check time.

### Deferred: rewrite rules

Rewrite rules (declarative derivation) are deferred to v0.2+. See [ADR 0001](../decisions/0001-authorization-model.md) for rationale. The v0.1 tuple primitive is forward-compatible with every candidate rewrite-rule system considered.

## Rewrite rules (v0.2 — Proposed)

This section is a preview of v0.2 functionality and is **non-normative until v0.2 is released**. The design is locked in [ADR 0007](../decisions/0007-authorization-rewrite-rules.md) and a reference implementation ships in `flametrench-authz` (Python) today; the full design becomes Accepted alongside the v0.2 spec tag.

### Why

Three patterns appear in nearly every application that uses Flametrench v0.1 and quickly become friction points:

- **Role implication.** `admin` should imply `editor` should imply `viewer`. v0.1 forces the application to write all three tuples on every privilege grant and remember to remove all three on revoke.
- **Parent-child inheritance.** Org members SHOULD have viewer access to org-owned projects without per-project tuples. v0.1 apps either denormalize at write time or run a second authz layer in application code.
- **Group-as-subject.** A `team_eng` group with N members should have its tuples apply to each member. v0.1's `subject_type = "usr"` constraint forces fan-out into per-user tuples.

v0.2 solves the first two with rewrite rules. Group-as-subject remains deferred to v0.3+.

### Three primitives

A rule is keyed on `(object_type, relation)` and contains a union of one or more nodes:

- **`this`** — the explicit-tuple set; identical to v0.1 `check()` semantics. Always implicitly part of every rule's union; the v0.1 fast path runs before any rule expansion. Listing `this` explicitly in a rule is documentation, not behavior.
- **`computed_userset { relation: <name> }`** — anyone holding `<name>` on this same object. Used for role implication. The check recurses with the same object but a different relation.
- **`tuple_to_userset { tupleset: { relation: <ttu> }, computed_userset: { relation: <target> } }`** — anyone holding `<target>` on the object at the end of the `<ttu>` relation from this object. Used for parent-child inheritance.

Excluded from v0.2: intersection, exclusion, and recursive transitive closures. Each is a v0.3+ candidate; ADR 0007 documents the rationale.

### Example: role implication and parent-child inheritance

```yaml
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
      this   # admin requires explicit grant; no rewrites
  org:
    viewer:
      union:
        - this
        - computed_userset: { relation: member }
    member:
      this
```

Reads as:
- Anyone with `editor` on a project also has `viewer`.
- Anyone with `admin` on a project also has `editor` (and transitively `viewer`).
- Anyone with `viewer` on a project's parent org also has `viewer` on the project.
- Anyone with `member` on an org also has `viewer` on that org.

### Evaluation order

`check(subject, relation, object)` evaluation:

1. **Direct lookup.** Query for an exact tuple `(subject, relation, object)`. If present, return immediately. This is the v0.1-fast path; it runs unchanged in v0.2 and adds zero overhead for grants that don't use rewrites.
2. **Rule expansion.** On miss, look up the rule for `(object.type, relation)`. If no rule is registered, return `denied`. If a rule exists, expand its primitives in order; the first sub-evaluation that returns `allowed` ends the evaluation.

Implementations MAY parallelize sub-evaluations within a single rule but MUST preserve short-circuit semantics from a caller's perspective.

### Bounded evaluation

`check()` cost is no longer constant under rules. Implementations MUST enforce two bounds:

- **`max_depth`** — the recursion ceiling across `computed_userset` and `tuple_to_userset` hops. Spec floor: `8`. Exceeding raises `EvaluationLimitExceededError`.
- **`max_fan_out`** — the per-`tuple_to_userset` enumeration ceiling. Spec floor: `1024`. Exceeding raises the same error.

Bounds are configurable per-store. Apps with deep rule chains or wide fan-outs SHOULD raise the limits explicitly rather than silently encountering them in production.

### Cycle detection

Rules form a graph; cycles are possible. Implementations MUST detect them per-evaluation by tracking the stack of `(relation, object)` frames visited. A repeat frame returns `denied` for that branch (the cycle adds no information) without raising. Other branches continue.

This is the cleanest semantics: cycles are silently ignored rather than erroring, because legitimate rules CAN be self-referential under non-cyclic paths. For example, "admin implies admin on parent" is a legal rule — the cycle only triggers when a node is its own parent, which is rare and best treated as "no answer" rather than "fatal error".

### Migration from v0.1

A v0.1 SDK upgrades to v0.2 with no behavioral change as long as no rules are registered. This is the central compatibility guarantee. v0.1 conformance fixtures continue to pass on a v0.2 SDK with empty rules — `fixtures/authorization/rewrite-rules/empty-rules-equals-v01.json` enforces this mechanically.

A v0.1 application migrating to use rewrite rules removes its denormalization tuples once the corresponding rules are registered. The migration MUST happen in this order to preserve invariants:

1. Register the rule set.
2. Verify checks return identical results with the explicit tuples still present (the rule shadows the direct match).
3. Delete the now-redundant explicit tuples in batches.

Skipping step 2 risks a window where the deletion has happened but the rule has not loaded — a real outage. Apply this recipe.

### Conformance fixtures

[`spec/conformance/fixtures/authorization/rewrite-rules/`](../conformance/fixtures/authorization/rewrite-rules/) ships three MUST-level fixtures for v0.2:

- `computed-userset.json` — role implication chains; missing intermediate rule breaks the chain.
- `tuple-to-userset.json` — parent-child inheritance; relation match is exact (org admin does not become proj admin via a member tuple).
- `empty-rules-equals-v01.json` — the compatibility bridge; every check returns the v0.1 answer when no rules are registered.



## Patterns for working without rewrite rules

Applications face two patterns for expressing implied grants in v0.1. Both are spec-supported; neither is favored.

### Pattern A — Materialize at state-change time

When the state that implies a grant changes, the application writes the grant as an explicit tuple.

**Example: "every org member can view every project in that org"**

- When Alice joins `org_acme`, the application writes one additional `tup_(alice, viewer, project_X)` for every existing project in `org_acme`.
- When a new project is created in `org_acme`, the application writes one additional `tup_(member, viewer, project)` for every active member of the org.
- When Alice leaves, the application deletes her membership tuple AND all the implied project-viewer tuples.

**When to prefer Pattern A:**

- When "who can view X?" must be a trivial SQL query.
- When membership churn is low relative to resource churn.
- When audit must show every grant as an explicit row.

### Pattern B — Combined checks at query time

The application does not materialize implied grants. Instead, `check()` calls pass a relation set and the application inspects multiple tuples.

**Example: same policy, different implementation**

- `check(user, [viewer, editor, owner, admin], project)` — first, check direct grants on the project.
- If that returns false, `check(user, [owner, admin, member], project.parent_org)` — check org-level membership.

**When to prefer Pattern B:**

- When state-change volume would otherwise cause tuple explosions.
- When derivation logic is narrow and localizable in the application.
- When audit can tolerate "who can view X?" being a computed query rather than a row lookup.

### Mixing patterns

Most real applications use both. Use Pattern A for default grants (org membership implies certain resource grants) and Pattern B for exceptional cases (Carol-the-contractor's per-project scope).

## Supporting operations

- `createTuple(subject_type, subject_id, relation, object_type, object_id, created_by?) → tup_id`.
- `deleteTuple(tup_id)`.
- `check(...)` — as defined above.
- `listTuplesBySubject(subject, cursor, limit) → [tup]` — enumerate what a subject holds.
- `listTuplesByObject(object, relation?, cursor, limit) → [tup]` — enumerate who has grants on an object.
- `cascadeRevokeSubject(subject)` — delete all tuples with the given subject. Used on user revocation and membership termination.

Enumeration operations MUST paginate with UUIDv7-ordered cursors (seek-based). Applications SHOULD authz-gate enumeration operations via `check()` with appropriate relations; the spec does not mandate default policy.

## Conformance fixtures

- **Exact-match check.** Given `tup_(alice, editor, project_42)` and no other tuples for that subject/object, `check(alice, editor, project_42)` MUST return true; `check(alice, viewer, project_42)` MUST return false.

- **Set-form check.** Given `tup_(alice, editor, project_42)`, `check(alice, [viewer, editor], project_42)` MUST return true.

- **No derivation.** Given only `tup_(alice, admin, org_acme)` and no other tuples, `check(alice, editor, org_acme)` MUST return false. The spec does NOT imply `editor` from `admin`.

- **Uniqueness of tuples.** Attempting to create a second tuple with identical `(subject_type, subject_id, relation, object_type, object_id)` MUST return an error or be idempotent (returning the existing tuple's ID). Implementations MUST NOT store duplicate rows.

- **Invalid UUID in subject or object.** Any tuple operation that would store `subject_id = ffffffff-ffff-ffff-ffff-ffffffffffff` (Max UUID) or `00000000-0000-0000-0000-000000000000` (Nil UUID) MUST fail; these are not valid Flametrench identifiers per `docs/ids.md`.

More fixtures will land in `spec/conformance/` as implementations surface questions.
