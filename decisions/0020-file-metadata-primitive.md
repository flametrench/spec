# 0020 — File-metadata primitive (`file`)

**Status:** Proposed (v0.4)
**Date:** 2026-06-05
**Deciders:** Flametrench stewards
**Filed by:** SiteSource (primary consumer)

## Context

Nearly every application stores files: avatars, attachments, document uploads, exports. Each adopter rebuilds the same two pieces around them — **metadata tracking** (what is this file, who owns it, how big, what type, has it changed) and **access control** (who may read or replace it). Without a spec primitive, every adopter reinvents both, and access control in particular tends to grow into a bespoke per-file ACL that drifts from the app's real authorization model.

Flametrench already provides the load-bearing pieces this needs: `identity` (owners), `tenancy` (scope), and `authz` (ADR 0001 relational tuples + `check()`). A file-metadata primitive is the natural completion — it does **not** require Flametrench to become a blob store.

This is one of four v0.4 primitives (audit, notifications, feature flags, file-metadata); this ADR is **file-metadata only**. It depends on [ADR 0019](./0019-audit-primitive.md) (the `aud` audit primitive) for its audit emission and on the authorization primitive (ADR 0001) for access.

## Decision

Add `file` (file **metadata**) as a Flametrench **v0.4** primitive: a record describing a file and its lifecycle, with access mediated by the existing authorization primitive. The `file` prefix moves from "Reserved" to active in [`docs/ids.md`](../docs/ids.md) (v0.4; this ADR amends it).

### Two hard lines (normative)

1. **Storage-agnostic — no blob bytes in the contract.** The primitive carries **metadata and lifecycle only**. It MUST NOT define how or where the bytes are stored, and MUST NOT provide upload/download/streaming of file contents. A `file_` record carries an opaque `storage_ref` (an adopter-defined pointer — an object-store key, a path, a URL) that the primitive stores and returns but MUST NOT interpret, fetch, or validate. (Flametrench declines to define backend storage; see the project README. File-metadata is the metadata layer over whatever store the adopter runs.)

2. **Access via `authz`, not a parallel ACL.** A `file_` **is an authorization object**: `object_type = "file"`, `object_id = file_<32hex>`. Every access decision is an `authz.check()` against existing tuples and the built-in relations (ADR 0001) — the primitive MUST NOT define a separate file-permission model. There is no `file`-private ACL, no per-file role enum, no second grant table.

### Entity shape

```
FileMetadata = {
  id:            file_<32hex>          // wire; UUIDv7 underneath
  scope:         org_<32hex>           // owning tenancy scope
  owner_usr_id:  usr_<32hex>           // the user who registered the file
  name:          string                // display filename, 1–255 Unicode code units
  content_type:  string                // IANA media type, e.g. "image/png"
  size_bytes:    integer | null        // non-negative; adopter-asserted; null only while status = "pending"
  checksum:      Checksum | null        // null only while status = "pending"
  // Checksum = { algo: "sha-256" /* pinned; only v0.4 algo */, value: string /* 64 lowercase hex */ }
  storage_ref:   string | null         // OPAQUE adopter pointer; null only while status = "pending"
  status:        "pending"|"active"|"deleted"   // lifecycle, below
  created_at:    timestamptz
  updated_at:    timestamptz
}
```

**Example:**

```json
{
  "id": "file_0190f2a81b3c7abc8123000000000010",
  "scope": "org_0190f2a81b3c7abc8123000000000004",
  "owner_usr_id": "usr_0190f2a81b3c7abc8123000000000002",
  "name": "q3-report.pdf",
  "content_type": "application/pdf",
  "size_bytes": 184320,
  "checksum": { "algo": "sha-256", "value": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
  "storage_ref": "s3://app-uploads/2026/06/q3-report.pdf",
  "status": "active",
  "created_at": "2026-06-05T10:00:00.000Z",
  "updated_at": "2026-06-05T10:00:00.000Z"
}
```

### Lifecycle (`status`)

- **`pending`** — metadata registered, the adopter has not yet confirmed the bytes are durably stored (e.g. a pre-signed-upload handshake is in flight). `size_bytes`, `checksum`, and `storage_ref` **MAY be null** in this state — they are typically unknown until the upload completes.
- **`active`** — the file is usable. On the `pending → active` transition, `size_bytes`, `checksum`, and `storage_ref` **MUST be set** (non-null), and they become **immutable** thereafter. A file registered directly as `active` (no upload handshake) MUST supply all three at create.
- **`deleted`** — soft-deleted; the record is retained (for audit reconstruction and reference integrity) but the file is treated as gone. Hard deletion / storage reclamation is the adopter's responsibility against `storage_ref`.

There is no transition back to `pending`. The only transitions are `pending → active`, `pending → deleted`, and `active → deleted`.

### Access (normative)

Access decisions reuse `authz.check()` (ADR 0001) on the file as object:

- **Read** metadata / resolve `storage_ref`: `check(usr, ["viewer","editor","owner"], ("file", file_id))`.
- **Mutate** metadata (`name`, `status`) or **delete**: `check(usr, ["editor","owner"], ("file", file_id))`.
- At `createFileMetadata`, the implementation MUST write an ownership tuple `(usr_owner, "owner", "file", file_id)` so the registrant can subsequently access it. Sharing a file = writing a `viewer`/`editor` tuple on it via the normal `authz` surface; revocation = deleting that tuple. No `file`-specific sharing API.
- **`listFileMetadata` is not a `check()` bypass.** Listing is gated like `IdentityStore.listUsers` (ADR 0015): the caller MUST hold an adopter-defined org-scoped read relation on the `scope` (e.g. `check(usr, [<org-read relation>], ("org", scope))`), **and** the implementation MUST return only files the caller is authorized to read — equivalently, the result set is filtered to `file_`s for which the per-file read `check()` above would pass. A caller MUST NOT learn of files they could not `getFileMetadata`. The org-scoped gate is the coarse filter; the per-file `check()` is the fine one.

### Operations

| Operation | Description |
|---|---|
| `createFileMetadata` | Register a file's metadata; writes the owner tuple; emits `aud`. |
| `getFileMetadata` | Fetch by id (after a read `check`). |
| `listFileMetadata` | Cursor-paginated, scoped to an `org`; filterable by `owner_usr_id`, `status`, `content_type`. |
| `updateFileMetadata` | Mutate the mutable subset (`name`, `status`); emits `aud`. |
| `deleteFileMetadata` | Transition to `status: "deleted"` (soft); emits `aud`. |

`content_type`, `owner_usr_id`, and `scope` are immutable after create. `size_bytes`, `checksum`, and `storage_ref` are immutable **once set** (at create for a directly-`active` file, or at the `pending → active` transition). A changed file's bytes are a new `file_`.

### Audit emission

Every mutating operation MUST emit an `aud` event (per [ADR 0019](./0019-audit-primitive.md)) with `action ∈ {"file.create","file.update","file.delete"}`, `target = { kind: "file", id: file_<id> }`, the acting `scope` (present — `file_`s are org-scoped), and the `outcome`. A denied access follows ADR 0019's denied-op / cross-scope non-disclosure rule.

### Tenancy

A `file_` is scoped to one `org`. Cross-scope access is impossible through the primitive; a cross-scope probe MUST NOT disclose a foreign file's existence (same existence-non-disclosure discipline the audit primitive applies to denied operations).

### Constraints (normative)

- `id` is `file_<32hex>` per `docs/ids.md`.
- `name` is 1–255 Unicode code units (counted as code units, not bytes).
- `content_type` is an IANA media type string; the primitive does not validate it against the bytes (it cannot — it does not hold the bytes).
- `size_bytes` is a non-negative integer; `checksum.algo` is `sha-256` (v0.4); `checksum.value` is 64 lowercase hex.
- `storage_ref` is an opaque non-empty string; the primitive never dereferences it.

## Consequences

**Positive:**
- Every adopter gets file metadata + access control "for free," reusing the authz model they already run — no per-app ACL drift.
- Storage-agnostic: works over S3, GCS, local disk, a CDN, anything — the adopter keeps full control of where bytes live.
- `file_` as an authz object composes with everything authz already does (sharing, org-scoping, future rewrite rules in ADR 0007).

**Negative:**
- The primitive cannot guarantee that `storage_ref` points at real, matching bytes — metadata/bytes consistency is the adopter's responsibility (the cost of staying out of the blob-storage business).
- `checksum`/`size_bytes` are adopter-asserted; the primitive cannot recompute them without the bytes.

## Deferred

- **Blob storage / streaming** — out of scope **permanently**, not deferred; this primitive is metadata only.
- **Content scanning, image transforms, thumbnailing** — adopter/edge concerns.
- **Content versioning** (a history of byte revisions for one logical file) — candidate for a later version; v0.4 models a changed file as a new `file_`.
- **Quotas / storage accounting** — belongs with a billing/usage primitive (`sub`, Reserved), not here.
- **Additional checksum algorithms** — `sha-256` only in v0.4; more can be added when an adopter needs them.

## Rejected alternatives

- **A `file`-private ACL / per-file role enum.** Rejected: it is a worse, drift-prone duplicate of the authz primitive. Files are authz objects; access is `check()`.
- **Storing bytes in Flametrench (a blob store).** Rejected: Flametrench does not define backend storage; this would be a categorically different, much larger commitment, and most adopters already have object storage.
- **Embedding access grants inside the `file_` record** (e.g. an `acl: [...]` field). Rejected: grants live in `tup_` rows so they are queryable, revocable, and consistent with tenancy/membership — same reason ADR 0002 makes membership a tuple.

## References

- [ADR 0001 — Authorization model](./0001-authorization-model.md): `check(subject, relation, object)` and the built-in relations this primitive reuses; a `file_` is an `object_type: "file"` authz object.
- [ADR 0019 — Audit primitive (`aud`)](./0019-audit-primitive.md): `file.*` operations emit `aud` events on its event schema; the denied-op / cross-scope non-disclosure rule applies.
- [`docs/ids.md`](../docs/ids.md): `file` promoted Reserved → active (v0.4; this ADR amends it); `file_<32hex>` wire format.
- Project README: the storage-agnostic principle (Flametrench does not define backend storage).
