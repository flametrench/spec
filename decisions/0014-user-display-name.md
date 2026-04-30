# 0014 — User display name

**Status:** Accepted
**Date:** 2026-04-28

## Context

The v0.1 `User` entity is intentionally minimal: `{id, status, created_at, updated_at}` (per ADR 0004). Identity is opaque — handles, emails, names, and other user-meaningful identifiers live on `cred_` rows, not on `usr_`. This was a deliberate choice to keep the user model neutral with respect to credential mix and adopter PII strategy.

The first PHP adopter (`sitesource/admin`) reported the cost in [`spec#9`](https://github.com/flametrench/spec/issues/9): admin and account-management UIs need a string to render in chrome ("Welcome, Nate"; the user-list row; mention surfaces; audit logs). The current options are all bad:

1. **Render the credential identifier.** Works for password creds (typically an email), fails for passkey-only users (no human-meaningful identifier on the credential), fails for OIDC creds (the IdP `sub` is opaque). For mixed-credential users the choice of "primary" credential is nondeterministic.
2. **Maintain a parallel host-side users table** with `first_name` / `last_name` / `display_name` columns. This is exactly the pattern ADR 0011 (org `name` + `slug`) was filed to eliminate on the tenancy side; the same anti-pattern is reappearing on identity.
3. **Show "User" or the opaque `usr_id`.** Fails the user-experience bar that adopters with admin product surfaces are trying to clear.

The shape of the fix is the same as ADR 0011's resolution for `Organization.name`: lift the field into the canonical entity, add a partial-update operation, and let adopters who want stricter rules layer them at the application boundary.

## Decision

The `User` entity gains one optional field in v0.2:

```
User = {
  id, status, created_at, updated_at,    // v0.1 — unchanged
  display_name: string | null,           // v0.2 — optional display string
}
```

### `display_name`

- Type: nullable `TEXT`. No length cap pinned at the spec level — adopters who want to enforce one (e.g. 255 chars to match a CSV import column, or 64 chars to fit a side-nav cell) MAY do so at the application layer. This matches the `Organization.name` precedent in ADR 0011.
- Full Unicode allowed. The spec does NOT mandate normalization (NFC, case-folding, trimming); adopters that need a normalized variant for search or uniqueness MAY derive it host-side.
- The spec says **SHOULD set when the user has a human-meaningful identity rendered in adopter UIs.** Always-required is a host-side enforcement decision. CI / programmatic / test-fixture / service-principal users routinely have no display name, and the spec stays permissive so those flows don't need placeholders.
- No uniqueness constraint. Two users may share a display name. Users are identified by `usr_id`; `display_name` is a render hint, not a key.
- May be updated freely via `updateUser`.

### Why `display_name` and not `name`

ADR 0011 chose `name` for `Organization` because organizations have a clearer notion of "the name of this thing." On users, `name` is ambiguous — adopters in different jurisdictions and industries read `name` as legal name, full name, billing name, or rendered handle. `display_name` is unambiguous: it is the string a UI renders in chrome.

A first/last split is rejected. Anglocentric, fails for multiple-given-name patterns common across non-Western cultures, fails for users who use a single mononym, and fails for service principals where neither field has meaning.

### New operation: `updateUser`

```
updateUser(usr_id, *, display_name?) → User
```

Partial update. Semantics across all four SDK languages:

- An **omitted** parameter means "don't change this field."
- An explicit **`null`** means "set this field to NULL."

This matches the partial-update contract introduced for `updateOrg` in ADR 0011. Each SDK uses its own idiomatic sentinel — Python `_UNSET`, TypeScript `undefined` vs `null`, PHP an `UNSET` constant on the store interface, Java `Optional<String>` — but the spec mandates the semantic, not the calling convention.

`updateUser` raises:

- `NotFoundError` if the user does not exist.
- `AlreadyTerminalError` if the user is in a terminal state (revoked).

Suspended users MAY be updated. The display name is a UI render hint; allowing it to change while suspended supports renaming the row in admin tooling without first reinstating the user. Revoked is terminal.

### `createUser` extension

```
createUser(*, display_name?) → User
```

Optional positional/keyword argument depending on language. Default null preserves v0.1 behavior (create with no display name). No new errors; the field is unconstrained at create time.

## Consequences

- **Backwards compatibility.** Pure addition; no v0.1 caller breaks. Pre-v0.2 stores that round-trip a `User` payload without `display_name` continue to work — the field defaults to `null`.
- **Postgres reference.** One new nullable column. The DDL block lands in the v0.2 additive section of `postgres.sql`:
  ```sql
  ALTER TABLE usr ADD COLUMN display_name TEXT;
  ```
- **OpenAPI.** `User` schema gains the optional `display_name`; `flametrench-v0.2-additions.yaml` declares the new `PUT /users/{usr_id}` endpoint with `UpdateUserRequest` body.
- **Conformance.** New fixture `identity/user-display-name.json` covers round-trip, partial-update sentinel-vs-null distinction, and the suspended-vs-revoked update gate.
- **`tup_check` semantics unchanged.** Authorization is unaffected. Tuples reference `usr.id`; display-name changes never affect grants.
- **Sessions / credentials unchanged.** No coupling between `display_name` and any auth surface. Renaming a user does not invalidate sessions or rotate credentials.
- **Cross-link to ADR 0015** (forthcoming, [`spec#10`](https://github.com/flametrench/spec/issues/10) — `IdentityStore.listUsers`). Once `listUsers` lands, it MUST return `display_name` in each `User` page entry. The fixture for `listUsers` SHOULD include a mix of display-named and unnamed users to exercise the optional-field surface.

## Alternatives considered

### Generic `metadata` JSONB column

Adds an opaque object to `User` and lets adopters put whatever they want there. Rejected for the same reasons ADR 0011 rejected it for `Organization`: it punts the cross-tool interoperability question instead of answering it; JSONB columns degrade to junk drawers; the SDK can't drive built-in features (admin tooling, invitation rendering, audit-log display) without an agreed structural field.

### Required `display_name`

Forces every `createUser` to supply one. Rejected because programmatic / CI / service-principal flows have no meaningful value to provide; spec stays permissive and adopters who want it required enforce at the application layer. Same reasoning as ADR 0011's permissive `Organization.name`.

### First / last name split (`given_name`, `family_name`)

The schema shape used by some IdPs (OIDC `claims.given_name` / `family_name`). Rejected because:
1. Anglocentric — fails for many naming conventions (Eastern-name-order cultures, mononyms, multi-given-name patterns, patronymic systems).
2. Doesn't actually solve the use case — admin UIs render a single string in chrome, so adopters end up concatenating `given + family` and inventing a normalization rule per locale.
3. Adopters who genuinely need structured name parts (e.g. for legal billing or tax forms) can still maintain that data host-side; the spec doesn't preclude it. Display rendering does not need it.

### Display name on `cred_` instead of `usr_`

Push the display name to the credential, since credentials already carry identifiers. Rejected because:
1. Users have N credentials. The spec already documented the "no deterministic primary credential" pain point as the motivating problem; moving display-name to `cred_` reproduces it.
2. Display name is a property of the principal, not of any single way that principal authenticates. Renaming a user shouldn't require finding "the credential that owns the display name."
3. Users with no credential (mid-onboarding, post-revocation-pre-archive) would have no display name surface.

### Host-side extension tables only

The status quo. Rejected because the first adopter is feeling the cost; subsequent adopters will hit it identically. Spec stays minimal but the cost is paid in N places, and the cross-tool / cross-language interoperability question stays unanswered.

### Pronouns / locale / timezone

Same rationale as ADR 0011's deferral of these for `Organization`. They are user-preferences territory, not identity-render territory; they belong in adopter-owned settings stores. Tracked for a future spec issue if cross-tool demand emerges.

## Migration

Pure addition. No v0.1 row needs to change. Adopters who already maintain a host-side `users.display_name` column can:

1. Apply the v0.2 DDL: `ALTER TABLE usr ADD COLUMN display_name TEXT`.
2. Backfill the new column from the host-side mirror: `UPDATE usr SET display_name = host_users.display_name FROM host_users WHERE usr.id = host_users.usr_id`.
3. Remove the host-side column once the canonical field is the source of truth.
4. Update host-side rendering paths to read `usr.display_name` instead of joining the mirror.

No changes to sessions, credentials, tuples, memberships, or invitations.

## Compatibility

- The `usr.display_name` column is new; no existing v0.1 columns are altered.
- The OpenAPI `User` schema gains the optional field; v0.1 servers that omit the key remain wire-compatible (clients MUST tolerate absence).
- A v0.2 deployment that does not need display names MAY skip applying the `ALTER TABLE` DDL; the rest of the schema stays byte-identical to v0.1+v0.2 baseline.
- `cred_`, `ses_`, `mfa_`, `mem_`, `tup_`, `inv_`, `org_` schemas unchanged.

## Open questions (deferred)

- **Display-name normalization for sort / search.** The spec leaves normalization to adopters. If `listUsers` (ADR 0015) develops case-insensitive search semantics, a normative normalization rule may be needed there.
- **Display-name length cap as a normative MUST** rather than a SHOULD. Deferred until cross-tool interop demand surfaces. Most ecosystems accept that the canonical store is permissive and individual UIs truncate as needed.

## References

- Spec issue [`flametrench/spec#9`](https://github.com/flametrench/spec/issues/9) — original report from `sitesource/admin`.
- [`decisions/0011-org-display-name-slug.md`](./0011-org-display-name-slug.md) — the tenancy-side precedent this ADR mirrors.
- [`decisions/0004-identity-model.md`](./0004-identity-model.md) — the original opaque-user decision this ADR amends.
- [`docs/identity.md`](../docs/identity.md) — gains a normative paragraph on `display_name` semantics and the `updateUser` operation.

## Filed by

`sitesource/admin` Phase 2 admin SPA, via `flametrench/spec#9`. Tag: `feedback:sitesource-admin`.
