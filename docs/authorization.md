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
