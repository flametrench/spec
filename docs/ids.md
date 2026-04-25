# Flametrench Identifier Format

This document is the normative specification for identifiers issued by any Flametrench-compliant implementation. SDKs in every language must produce identical wire-format strings for the same inputs and must reject identical inputs as invalid.

## Design goals

1. **Self-describing on the wire.** A developer reading a log line must be able to tell what kind of resource an ID refers to without consulting the API.
2. **Sortable by creation time.** Time-ordered IDs preserve insertion order in indexes without a separate timestamp column.
3. **Storage-friendly.** The storage representation is a standard UUID that every database, ORM, and language already handles natively.
4. **Collision-resistant without coordination.** Independent processes must be able to generate IDs concurrently without a central coordinator.
5. **Unambiguous.** No character in the wire format is visually confusable with another. No ambiguity at URL or line boundaries.
6. **Stable across languages.** A PHP SDK, a Node SDK, and any future SDK must all produce byte-identical encodings for the same type and UUID.

## Storage format

Identifiers are stored in database columns as **UUIDv7** in canonical hyphenated form:

```
0190f2a8-1b3c-7abc-8123-456789abcdef
```

Postgres implementations MUST use the native `uuid` column type. Implementations targeting databases without a native UUID type MUST use a fixed-width binary or 36-character string column with a unique index.

UUIDv7 is specified by [RFC 9562](https://datatracker.ietf.org/doc/rfc9562/). Implementations MUST generate UUIDv7 values using a library with a maintained, reviewed implementation. Implementations MUST NOT generate UUIDv7 values by hand-rolling timestamp and random byte concatenation.

## Wire format

Identifiers appear on the wire as:

```
{type}_{hex}
```

Where:

- `{type}` is a lowercase ASCII type prefix from the registry below.
- `_` is a literal underscore character.
- `{hex}` is the storage UUID with hyphens stripped, rendered in lowercase.

Example:

```
Storage:  0190f2a8-1b3c-7abc-8123-456789abcdef
Wire:     usr_0190f2a81b3c7abc8123456789abcdef
```

### Why underscore, not hyphen

Hyphens are ambiguous at the end of a URL. When an identifier appears at the end of a line in an email, a chat message, or an auto-linked log entry, a trailing hyphen may be elided or interpreted as a soft break. Underscores survive all of these boundaries intact.

Hyphens also already appear in canonical UUID form. Using underscore as the type separator eliminates parser ambiguity.

### Why lowercase hex

Consistent casing guarantees byte-identical encodings across SDKs and simplifies comparison. Implementations MUST emit lowercase and MUST reject uppercase-hex payloads during decoding. A strict decoder surfaces encoding bugs in sister SDKs quickly.

## Type prefix registry

The following type prefixes are reserved for Flametrench v0.1:

| Prefix | Resource                | Capability     |
| ------ | ----------------------- | -------------- |
| `usr`  | User                    | Identity       |
| `ses`  | Session                 | Identity       |
| `cred` | Credential              | Identity       |
| `org`  | Organization            | Tenancy        |
| `mem`  | Membership              | Tenancy        |
| `inv`  | Invitation              | Tenancy        |
| `tup`  | Authorization tuple     | Authorization  |

Implementations MUST NOT invent new type prefixes. New prefixes are added by amending this document through the specification's change process.

Reserved prefixes for future capabilities (not usable in v0.1 implementations):

| Prefix  | Planned resource        | Capability      |
| ------- | ----------------------- | --------------- |
| `aud`   | Audit event             | Audit (v0.2)    |
| `not`   | Notification            | Notifications   |
| `file`  | File                    | Files           |
| `flag`  | Feature flag            | Feature flags   |
| `sub`   | Subscription            | Billing         |

Prefix selection rules for future additions:

- 2 to 6 characters.
- Lowercase ASCII letters only (`[a-z]`).
- Pronounceable when possible.
- Unambiguous when skimming logs alongside existing prefixes.
- Not a substring of any other prefix (prevents accidental match in string searches).

## Encoding rules

An implementation's `encode(type, uuid)` function:

1. MUST reject the input if `type` is not in the current registered prefix set, raising the SDK's equivalent of `InvalidTypeError`.
2. MUST reject the input if `uuid` is not a valid UUID, raising the SDK's equivalent of `InvalidIdError`.
3. MUST NOT verify that the UUID is specifically UUIDv7. Older UUID versions MAY appear in backfilled data; version checking happens during generation, not encoding.
4. MUST strip all hyphens from the UUID and render the result in lowercase.
5. MUST return the string `{type}_{hex}`.

## Decoding rules

An implementation's `decode(id)` function:

1. MUST locate the first `_` character. If none exists, raise `InvalidIdError`.
2. MUST verify that the prefix before the separator is in the registered set, raising `InvalidTypeError` otherwise.
3. MUST verify that the payload after the separator is exactly 32 characters of lowercase hex (`[0-9a-f]{32}`), raising `InvalidIdError` otherwise. Uppercase hex MUST be rejected.
4. MUST reconstruct the canonical UUID form by inserting hyphens at positions 8, 12, 16, and 20 of the payload.
5. MUST verify that the reconstructed UUID's version nibble (position 13 of the hyphenated form, i.e. the first character of the third group) is one of `1` through `8`, raising `InvalidIdError` otherwise. This explicitly rejects the Nil UUID (version 0) and the Max UUID (version 15 / `f`), which some general-purpose UUID validators accept but which are not valid Flametrench identifiers.
6. MUST return a structured result containing the type and the canonical UUID string.

## Generation

An implementation's `generate(type)` function:

1. MUST verify that `type` is in the registered prefix set.
2. MUST generate a fresh UUIDv7.
3. MUST return the result of `encode(type, new_uuid)`.

Generated identifiers are sortable by creation time by virtue of UUIDv7's structure. Implementations MAY rely on this for ordering in lists, but applications that require strict time ordering across a distributed system SHOULD use explicit timestamp columns in addition to IDs.

## Wire format vs registered types

The Flametrench wire format (`{prefix}_{32-hex-of-uuidv7}`) is structurally well-defined independent of the registered-type list. The registered-type list is normative for **Flametrench-managed entities** — `usr_`, `org_`, `mem_`, `inv_`, `ses_`, `cred_`, `tup_`. An application MAY choose to use the same wire-format shape for its own object types when writing authorization tuples. For example, an app modeling projects, documents, and teams MAY use `proj_<hex>`, `doc_<hex>`, and `team_<hex>` as `object_id` values in `tup_` rows, with `object_type` set to `"proj"`, `"doc"`, `"team"` respectively.

This is a host choice, not a spec requirement. The authorization layer treats `object_id` as an opaque application-chosen string keyed by `object_type` (subject to the format rule on `object_type` itself, which is `^[a-z]{2,6}$`). Applications MAY use bare UUIDs, integers serialized as strings, slugs, or any other identifier shape they prefer.

### The `decodeAny` adapter helper

Implementations MUST provide a second decoder, `decodeAny(id)`, alongside the strict `decode(id)`:

1. MUST follow steps 1, 3, 4, and 5 of the `decode(id)` rules above (separator presence, payload format, canonical reconstruction, version nibble).
2. MUST NOT consult the registered-type set. Step 2 of `decode(id)` is omitted.
3. MUST raise `InvalidIdError` on any structural failure. Never raises `InvalidTypeError`.
4. MUST return the same structured `(type, uuid)` shape as `decode(id)`.

A predicate counterpart, `isValidShape(id)`, MUST also be provided. Its semantics mirror `isValid(id)` except that registry membership is not checked: any well-formed wire-format string returns true.

These helpers exist for two host scenarios:

- **Backend storage adapters** (Postgres, Redis, etc.) that need to convert wire-format object IDs back to canonical UUIDs without knowing in advance which application types are in use. Adapter code calls `decodeAny` on `object_id` values; it cannot use the strict `decode` because application-defined types are not in the registry.
- **Generic introspection** of unknown wire-format IDs surfaced via logs, support tickets, or external integrations.

`decodeAny` is **not a relaxation of the registered-type contract.** Code paths that operate on Flametrench-managed entities (`usr_`, `org_`, etc.) MUST continue to use `decode` so that an unregistered prefix is caught immediately. Use `decodeAny` only when the calling context is known to legitimately accept application-defined types.

### What `decodeAny` does NOT do

- It does NOT register new types. The registry remains spec-controlled and immutable at runtime.
- It does NOT validate that an `object_type` matches the format rule from the authorization layer (`^[a-z]{2,6}$`). That validation happens at tuple creation, not at ID decode.
- It does NOT guarantee that the prefix has a meaning. `decodeAny("xyz_0190f2a8...")` returns `(type: "xyz", uuid: "...")` even if `xyz` has no registered or application-defined meaning. The caller is responsible for interpreting the prefix in context.

### Conformance status

`decodeAny` and `isValidShape` are SHOULD-implement helpers across all SDKs. They are not part of the cross-SDK fixture corpus because there is no observable wire behavior to test — the helpers are pure functions of input format. SDKs SHOULD use the names `decodeAny` and `isValidShape` (or the language-idiomatic equivalent) for adapter-author ergonomics across languages.

## Conformance fixtures

The following fixtures are part of the conformance suite. Every SDK MUST produce byte-identical encodings for these inputs:

| Type  | UUID                                   | Wire format                                |
| ----- | -------------------------------------- | ------------------------------------------ |
| `usr` | `0190f2a8-1b3c-7abc-8123-456789abcdef` | `usr_0190f2a81b3c7abc8123456789abcdef`     |
| `org` | `01000000-0000-7000-8000-000000000000` | `org_01000000000070008000000000000000`     |
| `ses` | `01ffffff-ffff-7fff-bfff-ffffffffffff` | `ses_01ffffffffff7fffbfffffffffffffff`     |

And MUST reject the following inputs as invalid:

| Input                                            | Reason                         |
| ------------------------------------------------ | ------------------------------ |
| `usr0190f2a81b3c7abc8123456789abcdef`            | Missing separator              |
| `xyz_0190f2a81b3c7abc8123456789abcdef`           | Unregistered type prefix       |
| `usr_0190f2a8`                                   | Payload too short              |
| `usr_0190f2a81b3c7abc8123456789abcdef0000`       | Payload too long               |
| `usr_0190F2A81B3C7ABC8123456789ABCDEF`           | Uppercase hex                  |
| `usr_0190f2a81b3c7abc8123456789abcdeg0`          | Non-hex character              |
| `usr_`                                           | Empty payload                  |
| empty string                                     | Empty input                    |
| `usr_00000000000000000000000000000000`           | Nil UUID (version nibble = 0)  |
| `usr_ffffffffffffffffffffffffffffffff`           | Max UUID (version nibble = f)  |

## Change history

- **v0.1 (draft, 2026)** — Initial specification. Registered prefixes for identity, tenancy, authorization. Reserved prefixes for future capabilities. Decoding rule 5 clarified to require version nibble in `[1-8]`, explicitly rejecting Nil and Max UUIDs.
