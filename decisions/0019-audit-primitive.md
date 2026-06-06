# 0019 — Audit primitive (`aud`) for append-only action logging

**Status:** Proposed (v0.4)
**Date:** 2026-06-05
**Deciders:** Flametrench stewards
**Filed by:** SiteSource (primary consumer; upstreamed from the SiteSource ADR 0014 working set)

## Context

Every backend application needs an append-only log of significant actions: who did what, when, on what target, and whether it succeeded. Compliance frameworks (SOC 2, ISO 27001, HIPAA) require it; operators ask for it; without a spec primitive every adopter rebuilds the same machine and at least one gets the security-critical pieces (immutability, tenancy scoping, attribution) wrong.

Flametrench's existing primitives supply everything an audit event references — `identity` (`usr`), `tenancy` (`org`), `authz` (`tup`) — but the audit primitive itself does not exist. It is a natural completion of the stack: identity-aware and tenancy-aware from the spec level.

**This ADR fulfills a forward reference already pinned by an accepted ADR.** [ADR 0016 (Personal Access Tokens)](./0016-personal-access-tokens.md) §"Audit log integration" did not wait for audit to define its semantics — it pinned the **canonical discriminator vocabulary** `auth.kind ∈ {session, pat, share, system}` ("adopters MUST emit, audit-log consumers MAY rely") and twice deferred to "the audit ADR": (a) the formal definition of the `aud` primitive and its event schema, and (b) the definition of `auth.kind = system` ("automation that has no human owner"). This ADR (0019) provides both. (0016 speculatively labeled the forthcoming audit ADR "ADR-0017 working set"; 0017 became Postgres rewrite-rule evaluation. Per the ADR-frozen rule, 0016 is not edited; this ADR is the real one and conforms to 0016's vocabulary verbatim.)

`aud` is one of four v0.4 primitives (audit, notifications, feature flags, file-metadata). This ADR is **audit only**; the others are separate appetite calls.

## Decision

Add `aud` (audit event) as a Flametrench **v0.4** primitive: an append-only, identity- and tenancy-aware record of a significant action.

The `aud` prefix moves from "Reserved" to the active type-prefix registry in [`docs/ids.md`](../docs/ids.md) (v0.4; this ADR) — `aud_<32hex>`, UUIDv7 underneath, exactly like every other Flametrench id. This PR amends `docs/ids.md`.

### Event shape (normative)

```
AuditEvent = {
  id:            aud_<32hex>            // wire; UUIDv7 underneath
  occurred_at:   timestamptz            // when the action occurred (emitter clock)
  recorded_at:   timestamptz            // server-authoritative: when the audit service durably recorded it
  actor_usr_id:  usr_<32hex> | null     // owning human; null when no human principal (system, or pre-auth/anonymous)
  auth?: {                              // OPTIONAL — absent when there is no established principal (pre-auth / anonymous / failed login)
    kind:        "session"|"pat"|"share"|"system"   // ADR 0016 canonical vocabulary, verbatim
    session_id?: ses_<32hex>            // present IFF kind = "session"
    pat_id?:     pat_<32hex>            // present IFF kind = "pat"
    share_id?:   shr_<32hex>            // present IFF kind = "share"
    system_id?:  string                 // present IFF kind = "system"; opaque adopter-defined principal
  }
  on_behalf?: {                         // present IFF a delegated non-human actor performed the action
    agent_id:    string                 // REQUIRED; opaque, adopter-defined; primitive does not parse it
  }
  action:        string                 // adopter-namespaced "{capability}.{verb}[.{object}]"; opaque to the primitive
  target: {
    kind:        string                 // Flametrench entity type, OR adopter object_type (^[a-z]{2,6}$)
    id:          string                 // Flametrench id (decodable), OR opaque adopter resource id
  }
  scope?: {                             // OPTIONAL — absent for global / non-org-scoped events (e.g. login, or no resolvable scope)
    kind:        string                 // tenancy boundary kind, e.g. "org"
    id:          string                 // e.g. org_<32hex>
  }
  outcome:       "success"|"failure"|"denied"|"pending"
  metadata:      object                 // free-form; adopter protocol layering (e.g. {"mcp":true}) lives here — the ONLY place for protocol markers
  context?: {                           // OPTIONAL request context
    request_id?: string
    ip?:         string
    user_agent?: string
  }
}
```

**Example** (a CLI agent acting under a PAT creates an application resource):

```json
{
  "id": "aud_0190f2a81b3c7abc8123000000000001",
  "occurred_at": "2026-06-05T10:00:00.000Z",
  "recorded_at": "2026-06-05T10:00:00.014Z",
  "actor_usr_id": "usr_0190f2a81b3c7abc8123000000000002",
  "auth": { "kind": "pat", "pat_id": "pat_0190f2a81b3c7abc8123000000000003" },
  "on_behalf": { "agent_id": "assistant-prod-7" },
  "action": "data.create.record",
  "target": { "kind": "doc", "id": "doc_2f9c1a..." },
  "scope": { "kind": "org", "id": "org_0190f2a81b3c7abc8123000000000004" },
  "outcome": "success",
  "metadata": { "mcp": true },
  "context": { "request_id": "req-abc123", "ip": "192.0.2.1" }
}
```

The MCP protocol marker lives **only** in `metadata` (`{"mcp": true}`); `on_behalf` carries just the opaque `agent_id`.

**Pre-authentication example** (a failed login — no established principal, no org scope):

```json
{
  "id": "aud_0190f2a81b3c7abc8123000000000005",
  "occurred_at": "2026-06-05T10:01:00.000Z",
  "recorded_at": "2026-06-05T10:01:00.009Z",
  "actor_usr_id": null,
  "action": "identity.login",
  "target": { "kind": "usr", "id": "usr_0190f2a81b3c7abc8123000000000002" },
  "outcome": "failure",
  "metadata": { "reason": "bad_credential" },
  "context": { "ip": "192.0.2.9" }
}
```

Here `auth` and `scope` are both **absent**: the login attempt established no principal and is not org-scoped. `actor_usr_id` is `null`. The claimed identity, if any, MAY appear in `target` or `metadata` — but it is unverified, so it is not an `actor`.

### `auth.kind` and `system` (fulfilling ADR 0016)

`auth` is **optional**. When present, `auth.kind` is ADR 0016's frozen vocabulary, adopted verbatim, and exactly one kind-specific id field MUST be present and MUST match `kind`. **`auth` is absent when there is no established principal** — a pre-authentication attempt, an anonymous request, or a **failed login**. These are core audit events (a failed login is one of the most important things to log), and they have no representable `(actor_usr_id, auth.kind)`; absence of `auth` (with `actor_usr_id: null`) is exactly how they are recorded. Making `auth` optional does **not** fork 0016's vocabulary — the four kinds are unchanged; an event simply may have no `auth` at all. A claimed-but-unverified identity on a failed attempt MAY appear in `target`/`metadata`, but it is unverified and therefore not an `actor`.

This ADR defines the kind 0016 deferred:

- **`system`** — automation with no human owner (service-to-service calls, scheduled jobs, platform actions). For `kind = "system"`, `actor_usr_id` MUST be `null` and `auth.system_id` MUST carry an opaque, adopter-defined principal (a service name or automation id). The primitive does not parse `system_id`. Service-to-service authentication is `system`; there is no separate `service` kind (it would fork the frozen vocabulary for no benefit).

### `on_behalf` — delegated non-human actors (orthogonal to `auth.kind`)

A delegated non-human actor (e.g. an AI agent) is a **different axis** from the credential type: an agent typically authenticates with a `session` or `pat`. It is therefore carried in an optional top-level `on_behalf` object, **not** by adding a value to `auth.kind`:

- `on_behalf` is present IFF a delegated non-human actor performed the action.
- `on_behalf.agent_id` is REQUIRED and is an **opaque, adopter-defined string**. This ADR does **not** mint an `agt_` (or any) id prefix — agent identity is a separate concern that would be its own primitive; smuggling it in here would violate one-primitive-at-a-time and require an `ids.md` amendment this ADR does not make. If a future agent-identity primitive lands, `on_behalf.agent_id` becomes its reference; until then it is opaque.
- `on_behalf` carries **only** `agent_id`. Protocol-specific markers (e.g. an MCP flag) are adopter layering and MUST live in `metadata` — never inside `on_behalf`, and never as a normative `aud` field. The primitive stays protocol-agnostic.
- `on_behalf` is orthogonal to `auth` and MAY co-occur with **any** `auth.kind` (including `system`) **or with no `auth` at all** — an autonomous agent with no granting human is `actor_usr_id: null`, `auth.kind: "system"`, `on_behalf.agent_id: <opaque>`.

### `scope` (optional)

`scope` is **optional**. It names the tenancy boundary the action occurred within (typically `{ kind: "org", id: org_<32hex> }`). It is **absent for events that are not org-scoped**: global identity actions (a login is not scoped to an org), and the no-resolvable-scope case (e.g. a `system` actor, or the cross-scope-probe fallback below). An absent `scope` denotes a **global / system event**, recorded to the system/global audit stream. Consumers querying a specific org's events filter on `scope.id`; global events are reached via the system/global stream, not an org-scoped query.

### Identifiers in `target` and `scope` (Flametrench vs adopter)

`target` and `scope` reference two id populations and the primitive treats them differently:

- **Flametrench-managed entities** (`org`, `usr`, `tup`, …) MUST follow [`docs/ids.md`](../docs/ids.md) and are decodable via `decode(id)`.
- **Adopter resources** (an application's documents, projects, records, …) are referenced by **opaque adopter strings**. `target.kind` for an adopter resource is the adopter's `object_type` (`^[a-z]{2,6}$`, per the authorization layer's existing rule) and `target.id` is whatever shape the adopter uses. The primitive MUST NOT prefix-validate or `decode` adopter resource ids — use `decodeAny`/`isValidShape` semantics only where a caller legitimately accepts application-defined types.

### `action`

`action` is an adopter-namespaced string of the form `{capability}.{verb}` or `{capability}.{verb}.{object}` (e.g. `identity.login`, `tenancy.invitation_accepted`, `data.create.record`). The capability namespace is owned by the emitting service; Flametrench owns `identity.*`/`tenancy.*`/`authz.*`/`audit.*` and the v0.4 primitive namespaces `file.*`/`flag.*`/`notify.*`; adopters own theirs. (The `notify.*` action namespace pairs with the `not` id prefix — action namespaces follow the capability name, not the id prefix, exactly as `audit.*` pairs with `aud`.) The primitive treats `action` as **opaque** — it stores and filters on it (including prefix filters) but does not interpret it.

### `outcome` (each value defined)

- **`success`** — the operation completed.
- **`failure`** — the operation was attempted and errored (a fault, not a permission decision).
- **`denied`** — the operation was blocked by an authorization decision (an `authz` rejection). Distinct from `failure`: `denied` is a policy outcome, `failure` is a fault.
- **`pending`** — a long-running/asynchronous operation has started but is not yet resolved. A terminal event (`success`/`failure`) is expected later; correlation is via `metadata`/`context`.

### Timestamps (`occurred_at` vs `recorded_at`)

- `occurred_at` is the **emitter's** clock — when the action happened. It MAY be slightly skewed or, for backfill, historical.
- `recorded_at` is **server-authoritative** — when the audit service durably committed the event. The service sets it on `write`; emitters MUST NOT supply it. It is the trustworthy timeline for forensic ordering and for "what did we know, when," and is not subject to emitter clock skew. `recorded_at >= occurred_at` in the normal (non-backfill) case.

### Append-only semantics (normative)

- Audit events are **immutable** once written. The primitive defines **no** `update` or `delete` operation. Implementations MAY compact or archive beyond a retention policy but MUST NOT modify an event's content.
- `write` MUST be **durable before it returns success** (no fire-and-forget buffering that can lose acknowledged writes). Audit is fail-closed: if the audit write cannot be durably committed, the emitter MUST treat the audited operation as failed rather than silently proceed unlogged.
- Implementations MUST provide total ordering of events within a single Flametrench instance (UUIDv7 `id` + `recorded_at`).

### Operations

| Operation | Description |
|---|---|
| `write` | Append an event; synchronous, durable-before-return; returns the `aud` id. |
| `get` | Fetch an event by id. |
| `query` | Filter by `actor_usr_id`, `auth.kind`, `action` prefix, `target`, `scope`, `outcome`, time range. Cursor-paginated. |
| `count` | Count matching events without returning them. |
| `export` | Stream matching events to a sink (SIEM integration). |

Mutation operations (`update`, `delete`) intentionally do not exist.

### Constraints (normative)

- The whole event (including `metadata`) MUST be ≤ **64 KB**. Implementations MUST reject larger payloads; emitters truncate/summarize (for before/after diffs, keep structure, replace large values with sentinels).
- `aud_<32hex>` per `docs/ids.md`; `id` is a UUIDv7.
- Exactly one of `auth.{session_id,pat_id,share_id,system_id}` is present and matches `auth.kind`.

### Denied-operation and cross-scope disclosure (normative)

The audit surface must not become a cross-tenant existence oracle. Therefore:

> A denied operation MUST produce an `aud` event with `outcome: "denied"`. When the denial is a **cross-scope** access — the actor is not a member of the target `scope` — the event MUST be recorded **only against the actor's own scope** and MUST NOT be emitted to, or be observable from, the **target scope's audit stream**. An audit consumer scoped to the target organization MUST NOT be able to infer the existence of the probed target from the **presence, count, content, or ordering** of events in that scope's audit stream.

Three clarifications:

1. **No resolvable actor scope.** If the actor has no resolvable scope (e.g. `auth.kind = "system"` / `actor_usr_id: null` performing a cross-scope probe), the event MUST be recorded to a system/global audit stream that is **not observable from the target scope**. The non-inference invariant holds regardless of whether an actor scope exists.
2. **Timing is scoped to the audit stream, not the API.** The MUST above governs the target scope's **observable audit stream** (presence/count/content/ordering). Wall-clock side channels of the underlying API response (a response that is measurably slower when the target exists) are real but are an **adopter security-hardening** concern; see [`docs/security.md`](../docs/security.md). This ADR does not over-promise constant-time API behavior at the event-contract layer.
3. **The ordering channel covers cursors and the event `id` itself.** The "ordering" channel of the MUST above extends to **pagination cursors and any sequence position surfaced through a scoped read** (`query`/`count`/`export` and their cursors): a scope-scoped read MUST NOT reveal a global or cross-scope sequence position. The only ordering observable within a scope is the relative (`recorded_at`, `id`) order of events **in that scope**; events recorded to other scopes (or the system/global stream) MUST NOT be inferable from gaps, cursor jumps, or count deltas in a scope's view. An implementation using a global monotonic sequence MUST NOT encode it into a scoped cursor in a gap-observable form (cursor over per-scope (`recorded_at`, `id`), never over a global offset). This includes any monotonic counter embedded in the event `id`: a UUIDv7 monotonic sub-counter (RFC 9562 `rand_a`, "method 1") MUST be per-scope or random, **never a global cross-scope counter** — otherwise two same-millisecond events in one scope with counter values `c` and `c+2` would reveal a hidden event `c+1` in another scope. The (UUIDv7 `id` + `recorded_at`) total ordering of §"Append-only semantics" is a property of the global/system stream; it MUST NOT be exposed as a dense cross-scope ordinal through any scoped view.

## Consequences

**Positive:**
- Every Flametrench adopter gets append-only, identity/tenancy-aware audit as the natural completion of the stack; no adopter reinvents it.
- The discriminator vocabulary stays coherent: 0016's `auth.kind` is fulfilled, not forked, and `system` is finally defined.
- Cross-cutting concerns (`actor`, `auth`, `scope`, `action` namespace, denied-op non-disclosure) are pinned once at the primitive level.
- Conformance fixtures can guarantee cross-SDK identical behavior (follow-on across the five SDK families).

**Negative:**
- Flametrench grows by a primitive — more surface across SDK families.
- The wire format is a commitment: once adopters write events under this shape it is costly to change. Mitigated by reusing 0016's frozen vocabulary and the existing `ids.md` format rather than inventing.
- `on_behalf.agent_id` and adopter `target.id`/`system_id` are opaque, so the primitive cannot validate them — by design; validation is the adopter's.

## Deferred

- **Retention policy specifics** (default window, compaction/archival mechanics) — left to implementation/deployment; the primitive mandates only immutability and durability.
- **Pluggable storage sinks** beyond a built-in store — the wire format and operations are the load-bearing contract; a storage interface can be added later.
- **An agent-identity primitive.** `on_behalf.agent_id` stays opaque until/unless such a primitive is filed separately. Not in scope here.
- **`export`/SIEM wire detail** — the operation is named; its streaming envelope can be specified in the capability doc (`docs/audit.md`, follow-on) without blocking this ADR.
- **Tamper-evidence** — cryptographic integrity of the log itself (per-event or per-segment hash-chaining, or signing) so that after-the-fact modification or deletion is detectable, not merely forbidden by the append-only contract. A valuable hardening for high-assurance deployments; deferred to keep v0.4 to the wire/semantics contract, and addable without changing the event shape (an integrity field can be additive).

## Rejected alternatives

- **Adopter-owned audit (no Flametrench primitive).** Rejected: duplicates work across the ecosystem; audit is naturally identity/tenancy-coupled, so owning it in Flametrench is cleaner and gives `auth.kind` a real home.
- **Add `auth.kind = "agent"`.** Rejected: agent-ness is orthogonal to credential type (an agent uses a `session`/`pat`), and `auth.kind` is frozen at four values by 0016. Modeled as orthogonal `on_behalf` instead.
- **Add `auth.kind = "service"`.** Rejected: service-to-service is automation with no human owner — that is exactly `system`. A `service` value forks the frozen vocabulary for no benefit.
- **Mint an `agt_` id prefix for agents.** Rejected: smuggles a second primitive (agent identity) into the audit ADR and requires an `ids.md` amendment out of scope here. `on_behalf.agent_id` is opaque.
- **Put protocol markers (`mcp`) in a normative field.** Rejected: protocol-specific; the primitive stays protocol-agnostic. Such markers live in `metadata`.

## References

- [ADR 0016 — Personal access tokens](./0016-personal-access-tokens.md): source of the `auth.kind ∈ {session, pat, share, system}` vocabulary; this ADR fulfills its forward reference for the `aud` primitive, the event schema, and the `system` kind.
- [`docs/ids.md`](../docs/ids.md): `aud` promoted from Reserved to active (v0.4; this ADR amends it); id wire-format rules for Flametrench-entity references; `decodeAny`/`isValidShape` for adopter ids.
- [`docs/security.md`](../docs/security.md): adopter-level hardening for wall-clock API side channels (the audit-stream MUST above is the event-contract-layer guarantee).
- ADR 0001 (authorization), ADR 0002 (tenancy), ADR 0004 (identity): the actors, scopes, and permissions audit events reference.
