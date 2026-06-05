# 0021 — Feature-flags primitive (`flag`)

**Status:** Proposed (v0.4)
**Date:** 2026-06-05
**Deciders:** Flametrench stewards
**Filed by:** SiteSource (primary consumer)

## Context

Every application past its first month wants feature flags: gradual rollouts, kill switches, per-tenant enablement, dark launches. Without a spec primitive each adopter rebuilds three pieces — flag storage, an evaluation engine, and **targeting**. The first two are easy; targeting is where home-grown flag systems metastasize into a bespoke rules DSL ("user in segment X AND org on plan Y AND …") that **duplicates the application's authorization model** and immediately drifts from it.

Flametrench already has that model: relational tuples and `check()` (ADR 0001). The single most important decision for this primitive is therefore a reconciliation, not an invention — **flag targeting reuses `authz`, it does not introduce a parallel targeting language.** This is the `flags ↔ authz` analog of `audit ↔ 0016`, so it leads.

This is one of four v0.4 primitives; this ADR is **flags only**. It depends on `authz` (ADR 0001) for targeting and on [ADR 0019](./0019-audit-primitive.md) (the `aud` audit primitive) for config-change emission.

## Decision

Add `flag` (feature flag) as a Flametrench **v0.4** primitive: a named boolean flag with an ordered list of targeting rules, evaluated deterministically. The `flag` prefix moves from "Reserved" to active in [`docs/ids.md`](../docs/ids.md) (v0.4; this ADR amends it).

### The reconciliation: targeting reuses `authz` (normative)

A targeting rule **MUST NOT** introduce a new predicate language for "who is this user." Identity- and tenancy-based targeting is expressed as an **`authz` relation match** and evaluated with `check()` (ADR 0001):

- A rule of kind `authz` carries `{ relation, object: { type, id } }`. It matches a subject `S` **iff** `check(S, relation, (object.type, object.id))` is true.
- This reuses the **exact** patterns in `docs/authorization.md` — Pattern A (materialized grants) and Pattern B (relation-set checks). "Enable for editors of org O" is `{ relation: "editor", object: ("org", O) }`. "Enable for user U specifically" is a single-subject tuple the adopter already knows how to write. Roles, org membership, share grants, and (later) ADR 0007 rewrite rules all compose for free.

The **only** non-authz targeting dimension is the percentage rollout (below), because "is this subject in the rollout bucket" is genuinely not an authorization question. Everything else is `check()`.

### Entity shape

```
Flag = {
  id:              flag_<32hex>        // wire; UUIDv7 underneath
  scope:           org_<32hex>         // owning tenancy scope
  key:             string              // stable identifier code references; unique within scope; ^[a-z0-9._-]{1,128}$
  enabled:         boolean             // master switch; false ⇒ evaluation returns default_variant, rules not consulted
  default_variant: boolean             // value when enabled and no rule matches
  rules:           Rule[]              // ordered; first match wins
  created_at:      timestamptz
  updated_at:      timestamptz
}

Rule =
  | { kind: "authz",      relation: string, object: { type: string, id: string }, variant: boolean }
  | { kind: "percentage", basis_points: integer /* 0–10000 */,                    variant: boolean }
```

**Example** — flag on for org editors, plus a 10% rollout to everyone else:

```json
{
  "id": "flag_0190f2a81b3c7abc8123000000000020",
  "scope": "org_0190f2a81b3c7abc8123000000000004",
  "key": "new-checkout",
  "enabled": true,
  "default_variant": false,
  "rules": [
    { "kind": "authz", "relation": "editor", "object": { "type": "org", "id": "org_0190f2a81b3c7abc8123000000000004" }, "variant": true },
    { "kind": "percentage", "basis_points": 1000, "variant": true }
  ],
  "created_at": "2026-06-05T10:00:00.000Z",
  "updated_at": "2026-06-05T10:00:00.000Z"
}
```

### Evaluation (normative)

`evaluate(key, subject, scope) → boolean`:

1. Resolve the flag by `(scope, key)`. If none, return `false` (an undefined flag is off — safe default) and the SDK SHOULD surface "unknown flag" out-of-band.
2. If `enabled` is `false`, return `default_variant`.
3. Otherwise evaluate `rules` **in order**; the **first** matching rule's `variant` is returned.
   - `authz` rule matches iff `check(subject, relation, (object.type, object.id))`.
   - `percentage` rule matches iff `bucket(key, subject) < basis_points` (below).
4. If no rule matches, return `default_variant`.

`evaluate` is read-only, side-effect-free, and the latency-sensitive hot path.

### Deterministic bucketing (normative — pinned for cross-SDK identity)

Percentage rollouts MUST be **sticky and identical across all SDK families**. The bucket function is pinned:

```
bucket(key, subject_id):
  h  = SHA-256( utf8(key) || 0x00 || utf8(subject_id) )   // domain-separated by a NUL byte
  n  = uint32_big_endian(h[0..4])                          // first 4 bytes, big-endian
  return n mod 10000                                       // basis points, 0–9999
```

**Exact byte inputs (normative — this is what decides cross-SDK identity):**
- `key` is the flag's `key` string, UTF-8 encoded with no normalization.
- `subject_id` is the subject's **full wire-format id string** — the `{type}_{32hex}` form, e.g. the literal bytes of `usr_0190f2a81b3c7abc8123000000000002` — UTF-8 encoded. **Not** the bare 32-hex payload, **not** the hyphenated UUID, **not** the decoded bytes. SDKs hash the wire string exactly as it appears on the wire.
- `||` is byte concatenation; `0x00` is a single NUL byte separating the two UTF-8 strings.

A `percentage` rule with `basis_points = B` matches iff `bucket(key, subject_id) < B`. Properties this guarantees: a given `(key, subject)` always lands in the same bucket (sticky — no flicker on re-evaluation); raising `B` only ever **adds** subjects to the rollout (monotonic); and every SDK computes byte-identical buckets. SHA-256 is the only v0.4 hash; the conformance corpus pins `(key, subject_id) → bucket` vectors that carry the **exact input string** (e.g. `key="new-checkout"`, `subject_id="usr_0190f2a81b3c7abc8123000000000002"` → a fixed bucket), so any SDK feeding the wrong byte representation fails the fixture immediately.

### Operations

| Operation | Description |
|---|---|
| `createFlag` | Create a flag in a scope; emits `aud`. |
| `getFlag` | Fetch a flag's config by id or `(scope, key)`. |
| `listFlags` | Cursor-paginated, scoped to an `org`. |
| `updateFlag` | Mutate `enabled`, `default_variant`, `rules` (not `key`/`scope`); emits `aud`. |
| `deleteFlag` | Remove a flag; emits `aud`. |
| `evaluate` | Resolve a flag for a subject → boolean. Hot path; **not** audited. |

### Authorization

Flag **configuration** operations are gated by `authz`. Reading/managing flags is a scope-level concern (flags are not per-flag authz objects the way files are):

- `createFlag`/`updateFlag`/`deleteFlag`/`getFlag`/`listFlags` require the caller to hold an adopter-defined scope-level relation on the `scope` — e.g. `check(usr, [<flag-read relation>], ("org", scope))` for reads and a write relation for mutations. `listFlags` is gated exactly like `IdentityStore.listUsers` (ADR 0015): an authorized, org-scoped enumeration — never an unauthenticated catalog of a foreign org's flags.
- `evaluate` is the exception: it is called on behalf of a subject in the request path and does **not** require the caller to be a flag-admin; it answers "is this flag on for this subject" and is governed by the request's own authentication, not a flag-management grant.

### Audit emission

Flag **configuration** changes (`createFlag`/`updateFlag`/`deleteFlag`) MUST emit an `aud` event (`action ∈ {"flag.create","flag.update","flag.delete"}`, `target = { kind: "flag", id: flag_<id> }`, scope, outcome). **`evaluate` MUST NOT emit an audit event** — it runs per-request at scale and per-evaluation audit would be prohibitive. (Adopters that need evaluation telemetry use metrics, not the audit log.)

### Tenancy

A `flag` is scoped to one `org`. Cross-scope access is impossible through the primitive, and a cross-scope probe MUST NOT disclose a foreign flag's existence (the existence-non-disclosure discipline ADR 0019 applies to denied operations).

### Constraints (normative)

- `id` is `flag_<32hex>` per `docs/ids.md`.
- `key` matches `^[a-z0-9._-]{1,128}$` and is unique within `scope`.
- `basis_points` is an integer in `[0, 10000]`.
- A rule's `relation` matches the authz relation grammar (`^[a-z_]{2,32}$`, ADR 0001); `object.type`/`object.id` follow the authz object rules (Flametrench-entity ids decodable, adopter ids opaque).

## Consequences

**Positive:**
- Targeting is the application's real authorization model — no second source of truth, no drift, and it composes with roles, membership, shares, and future rewrite rules for free.
- Deterministic bucketing gives sticky, monotonic, cross-SDK-identical rollouts — the property home-grown systems most often get wrong.
- The contract is small: a flag is a key + switch + ordered rules.

**Negative:**
- Targeting expressiveness is bounded by what `check()` can answer plus a percentage. Attribute-based targeting ("users whose `plan == enterprise`") is **not** modeled unless that attribute is expressed as an authz relation — deliberate (it's the discipline that prevents DSL sprawl), but adopters must map segments onto relations.
- `evaluate` not being audited means flag exposure is not reconstructable from the audit log; that is the right trade for hot-path cost.

## Deferred

- **Multivariate flags** (string/JSON variants, A/B/n) — v0.4 is boolean on/off; multivariate is a natural later extension of `variant`.
- **Attribute-based targeting** beyond authz relations + percentage — deferred pending real demand; would risk the DSL sprawl this ADR avoids.
- **Scheduling / time-windowed rules** — adopters can flip `enabled` on a schedule at the app layer for v0.4.
- **Global (cross-org) flags** — v0.4 flags are org-scoped; a platform/global tier can be added later.

## Rejected alternatives

- **A bespoke targeting DSL.** Rejected — it duplicates and drifts from the authz model. Targeting reuses `check()`; this is the central decision.
- **Random (non-sticky) percentage rollout.** Rejected — a subject flickering in and out of a rollout between requests is a correctness and UX bug. Bucketing is deterministic.
- **Per-SDK hash choice.** Rejected — rollouts must be byte-identical across SDKs or a multi-language deployment splits its population. SHA-256 is pinned.
- **Auditing every `evaluate`.** Rejected — prohibitive at hot-path scale; config changes are audited, evaluation is metered.

## References

- [ADR 0001 — Authorization model](./0001-authorization-model.md) and `docs/authorization.md` (Patterns A/B): the `check()` + relation model that targeting reuses.
- [ADR 0019 — Audit primitive (`aud`)](./0019-audit-primitive.md): `flag.*` config changes emit `aud` events; the cross-scope non-disclosure rule applies.
- [ADR 0007 — Authorization rewrite rules](./0007-authorization-rewrite-rules.md): future rewrite rules compose into flag targeting for free, since targeting is `check()`.
- [`docs/ids.md`](../docs/ids.md): `flag` promoted Reserved → active (v0.4; this ADR amends it).
