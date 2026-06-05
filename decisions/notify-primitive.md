# Notifications primitive (`not`)

**Status:** Proposed (v0.4)
**Date:** 2026-06-05
**Deciders:** Flametrench stewards
**Filed by:** SiteSource (primary consumer)

> Number-less draft: the ADR number is assigned at PR-open / acceptance per the `decisions/README.md` numbering rule.

## Context

Applications need to tell users about things: a mention, an invitation, an approval request, a job finishing. The durable part of that — *"there is a thing user U should be told about, and U has/hasn't seen it"* — is a small, universal record. The variable part — *how* the user is told (email, SMS, push, in-app), with what copy, retried how — is large, provider-specific, and changes per adopter.

Flametrench owns the small, universal part and **deliberately not** the large variable part. This is the notify analog of "file-metadata is not a blob store": **notify is a record/event primitive, not a delivery engine.** This boundary is an operator-authoritative spec line, not an appetite preference.

This is one of four v0.4 primitives; this ADR is **notifications only**. It depends on [ADR 0019](./0019-audit-primitive.md) (the `aud` audit primitive) for emission and respects `tenancy` (ADR 0002) boundaries.

## Decision

Add `not` (notification) as a Flametrench **v0.4** primitive: a per-recipient record that something happened, with read-state, plus the event of its creation. The `not` prefix moves from "Reserved" to active in [`docs/ids.md`](../docs/ids.md) (v0.4; this ADR amends it).

### The boundary (normative)

- **In scope:** the `not_` record ("a thing a user should be told about"), its lifecycle state (`unread` → `read` → `dismissed`), and the **event of creation** (a notification coming into existence is the signal adopters react to).
- **Out of scope — hard NO at the primitive layer:** SMTP/SMS/push provider integration, message **templating/rendering**, and **retry/backoff/delivery orchestration**. An adopter's delivery layer subscribes to the creation event and decides whether to email/push/etc.; the primitive neither performs nor models delivery. A draft that scopes notify as a delivery system is out of bounds by construction.

### Entity shape

```
Notification = {
  id:             not_<32hex>          // wire; UUIDv7 underneath
  scope:          org_<32hex>          // owning tenancy scope
  recipient_usr_id: usr_<32hex>        // the user who should be told
  type:           string               // adopter-namespaced kind ("comment.mention", "invite.received"); opaque
  subject:        { kind: string, id: string }   // what it is about; Flametrench id (decodable) OR opaque adopter id
  data:           object               // free-form record content for the adopter's own rendering; ≤ 16 KB. NOT a template.
  state:          "unread"|"read"|"dismissed"
  created_at:     timestamptz
  state_changed_at: timestamptz        // updated on each state transition
}
```

**Example:**

```json
{
  "id": "not_0190f2a81b3c7abc8123000000000030",
  "scope": "org_0190f2a81b3c7abc8123000000000004",
  "recipient_usr_id": "usr_0190f2a81b3c7abc8123000000000002",
  "type": "comment.mention",
  "subject": { "kind": "doc", "id": "doc_2f9c1a..." },
  "data": { "actor_name": "Alice", "snippet": "…@bob take a look" },
  "state": "unread",
  "created_at": "2026-06-05T10:00:00.000Z",
  "state_changed_at": "2026-06-05T10:00:00.000Z"
}
```

`data` is the record's content for the adopter to render however it delivers — it is plain data, **not** a template string and **not** rendered by the primitive.

### Lifecycle (normative)

A notification's `state` is a small machine:

- Created as `unread`.
- `unread ⇄ read` — `markRead` / `markUnread` may toggle either direction (a user re-flagging an item as unread is a real pattern).
- `read | unread → dismissed` — `dismiss` is **terminal**; a dismissed notification accepts no further state change.

Every transition updates `state_changed_at`.

### The creation event

Creating a notification **is** the event adopters react to. The primitive guarantees the record exists durably on `createNotification` return; an adopter's delivery layer observes new notifications (via its own subscription/poll or a future realtime mechanism) and performs whatever out-of-scope delivery it wants. The primitive does **not** define a delivery callback, a provider interface, or a retry contract.

### Operations

| Operation | Description |
|---|---|
| `createNotification` | Create a notification for a recipient; emits `aud`. |
| `getNotification` | Fetch by id. |
| `listNotifications` | Cursor-paginated **inbox** for a `recipient_usr_id` within a scope; filterable by `state`, `type`. |
| `countUnread` | Count `unread` notifications for a recipient (badge counts). |
| `markRead` / `markUnread` | Toggle read state. |
| `dismiss` | Terminal-dismiss a notification. |

### Access — strictly recipient-scoped (normative)

A notification is **not** a general authz object. Access is **strictly bound to the recipient**, like a `ses_` is bound to its user: `get`, `listNotifications`, `countUnread`, `markRead`, `markUnread`, and `dismiss` operate **only** on notifications whose `recipient_usr_id` is the authenticated caller. An operation targeting another user's notification is denied as if it did not exist (per the tenancy-non-inference rule below) — there is no cross-recipient read path in the primitive. Administrative or "see all notifications in an org" views are an **adopter concern** layered outside this primitive (e.g. the adopter queries its own store, or models an admin capability via `authz` on a different object); the `not` primitive itself exposes only the recipient's own inbox.

### Audit emission

`createNotification` and `dismiss` MUST emit an `aud` event (`action ∈ {"notify.create","notify.dismiss"}`, `target = { kind: "not", id: not_<id> }`, scope, outcome). High-frequency routine transitions (`markRead`/`markUnread`) need not each emit an event (adopters MAY enable it). A denied access follows ADR 0019's cross-scope non-disclosure rule.

### Tenancy non-inference (normative)

A notification is scoped to one `org` and addressed to one recipient. The `listNotifications`/`countUnread`/`get` surface MUST NOT let a caller observe notifications outside their own recipient scope, and a cross-scope or cross-recipient probe MUST NOT disclose the existence of a foreign notification (presence, count, or error-code differential) — the same existence-oracle discipline ADR 0019 applies to denied operations.

### Constraints (normative)

- `id` is `not_<32hex>` per `docs/ids.md`.
- `type` is an adopter-namespaced string, opaque to the primitive (`^[a-z0-9._-]{1,64}$`).
- `subject.id` follows the Flametrench-vs-adopter id split (decodable Flametrench ids; opaque adopter ids).
- `data` is a JSON object ≤ 16 KB. The primitive stores and returns it; it does not interpret or render it.

## Consequences

**Positive:**
- Every adopter gets a durable, per-user, read-stateful notification record + inbox queries + badge counts — the part everyone rebuilds — without Flametrench taking on provider integrations it would do worse than dedicated services.
- The creation-event seam lets adopters plug any delivery stack (Postmark, SES, FCM, a websocket) without the primitive constraining them.
- Read-state and tenancy non-inference are pinned once, correctly.

**Negative:**
- Delivery is entirely the adopter's — the primitive offers no "send an email" convenience. Deliberate; it's the boundary. Adopters wanting batteries-included delivery layer it on top.
- No cross-channel dedup / preference center in v0.4 (deferred).

## Deferred

- **Delivery, templating, provider integration, retry** — out of scope **permanently**, not deferred.
- **Notification preferences / channels / digesting** (per-user "email me mentions, don't email me likes") — a useful adjacent capability, deferred pending demand; it is preference state, still not delivery.
- **Grouping / threading** (collapsing N "liked your post" into one) — adopter-side or a later extension.
- **A first-class realtime push of the creation event** — depends on a separate realtime/subscription mechanism Flametrench does not yet have; v0.4 adopters poll or wire their own.

## Rejected alternatives

- **A delivery engine** (SMTP/SMS/push, templating, retry). Rejected — operator-authoritative boundary; provider integration is large, fast-moving, and better served by dedicated services. The primitive is the record + state + creation event.
- **A shared rendered "message" string instead of structured `data`.** Rejected — rendering is delivery-channel-specific (an email body ≠ a push title); the primitive carries structured data and lets each channel render.
- **Global (no-recipient) broadcasts as `not_` records.** Rejected for v0.4 — fan-out/broadcast is a different shape; v0.4 notifications are per-recipient. A broadcast primitive can come later.

## References

- [ADR 0019 — Audit primitive (`aud`)](./0019-audit-primitive.md): `notify.*` lifecycle emits `aud` events; the cross-scope non-disclosure rule applies.
- [ADR 0002 — Tenancy model](./0002-tenancy-model.md): the org-scope and recipient boundaries this primitive respects.
- [`docs/ids.md`](../docs/ids.md): `not` promoted Reserved → active (v0.4; this ADR amends it).
- Project README: Flametrench does not own provider/delivery infrastructure — the principle behind the notify boundary.
