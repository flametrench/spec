# OpenAPI

The HTTP surface of Flametrench.

## Files

- **`flametrench-v0.1.yaml`** — the v0.1 specification, OpenAPI 3.1.
- **`flametrench-v0.2-additions.yaml`** — v0.2 additive surface (MFA enrollment + verification, MFA policy CRUD, organization display name + slug, user display name, user enumeration). Composes additively with v0.1; bundle the two for a complete v0.2 spec via `npx @redocly/cli bundle` or equivalent.
- **`flametrench-v0.3-additions.yaml`** — v0.3 additive surface (personal access tokens, ADR 0016). Composes additively with v0.1 + v0.2; bundle all three for a complete v0.3 spec.

## Relationship to the rest of the spec

The OpenAPI document defines the **wire contract**: paths, parameters, request/response shapes. The chapter documents (`../docs/identity.md`, `../docs/tenancy.md`, `../docs/authorization.md`) define the **data model and state-machine semantics** that the wire contract operates on. Design rationale lives in `../decisions/`.

When the OpenAPI and the chapter documents disagree, the chapter documents are authoritative. The OpenAPI will be updated to match; treat such disagreements as spec bugs.

## Validating the document

```bash
# With spectral (https://stoplight.io/open-source/spectral)
npx @stoplight/spectral-cli lint spec/openapi/flametrench-v0.1.yaml

# With openapi-cli (https://redocly.com/docs/cli/)
npx @redocly/cli lint spec/openapi/flametrench-v0.1.yaml
```

## Generating clients

The OpenAPI is designed to pass through standard code generators (openapi-generator, oapi-codegen, etc.). SDKs in the Flametrench family do not necessarily generate client code from this document — they hand-write for ergonomics — but third-party implementations MAY generate against it directly.

## What's in v0.1

Every operation listed in the `docs/*.md` chapters has a corresponding path in the OpenAPI. Pagination uses cursor-based, UUIDv7-ordered cursors; error responses share a common `Error` schema with a `code` field for stable, machine-readable error identifiers.

## What's deferred (not yet in OpenAPI)

- Rewrite-rule **HTTP surface** for authorization (the SDK ships rewrite rules in v0.2 via the in-memory store; declarative HTTP definition of rules is deferred).
- Share-token **HTTP surface** (the SDK ships the `ShareStore` interface in v0.2 across all four families; HTTP routes for mint/verify/revoke are deferred to a later version).
- Group-subject tuples (`grp_` as a subject type).
- SAML / magic-link credentials.
- Batch operations and subscription/webhook endpoints.

## What's in v0.2 (Proposed; release-candidate)

- **MFA factor enrollment + verification.** New `/users/{usr_id}/mfa-factors`, `/mfa-factors/{mfa_id}/confirm`, `/mfa-factors/{mfa_id}/revoke`, `/users/{usr_id}/mfa/verify` endpoints; new `mfa_` ID prefix. TOTP, WebAuthn (ES256/RS256/EdDSA per ADR 0010), and recovery-code factor types.
- **`usr_mfa_policy`.** New `/users/{usr_id}/mfa-policy` GET/PUT. The `verifyPassword` 200 response gains an additive `mfa_required: true` discriminator when policy is active and grace has elapsed.
- **Security backport into v0.1**: `acceptInvitation` request body now requires `accepting_identifier` when `as_usr_id` is supplied (ADR 0009 / spec#5). Documented in the v0.1 file's `AcceptInvitationRequest` schema; the constraint applies to all v0.1.x and forward.

## What's in v0.3 (Proposed; in development)

- **Personal access tokens.** New `pat_` ID prefix; new `/users/{usr_id}/pats` (POST + GET), `/pats/{pat_id}` (GET), `/pats/{pat_id}/revoke` (POST) endpoints. Token wire format is `pat_<32hex-id>_<base64url-secret>`; the auth middleware prefix-routes incoming bearer tokens to session / share / PAT verifiers per ADR 0016. Verification is SDK-only (no public `/pats/verify` route — mirrors the share-token precedent).

## Status

**Draft.** The file is expected to evolve as conforming implementations come online and surface interoperability questions. Breaking changes will be recorded in ADRs and tracked via the spec version number.
