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
5. MUST verify the reconstructed UUID is a valid UUID, raising `InvalidIdError` otherwise.
6. MUST return a structured result containing the type and the canonical UUID string.

## Generation

An implementation's `generate(type)` function:

1. MUST verify that `type` is in the registered prefix set.
2. MUST generate a fresh UUIDv7.
3. MUST return the result of `encode(type, new_uuid)`.

Generated identifiers are sortable by creation time by virtue of UUIDv7's structure. Implementations MAY rely on this for ordering in lists, but applications that require strict time ordering across a distributed system SHOULD use explicit timestamp columns in addition to IDs.

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

## Change history

- **v0.1 (draft, 2026)** — Initial specification. Registered prefixes for identity, tenancy, authorization. Reserved prefixes for future capabilities.
