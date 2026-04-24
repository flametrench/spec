# OpenAPI

The HTTP surface of Flametrench.

## Files

- **`flametrench-v0.1.yaml`** — the v0.1 specification, OpenAPI 3.1.

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

## What's NOT in v0.1 (deferred to v0.2+)

- Rewrite rules / derived authorization (would add new endpoints around policy definitions).
- Group-subject tuples (`grp_` as a subject type).
- MFA-specific operations.
- SAML / magic-link credentials.
- Batch operations and subscription/webhook endpoints.

## Status

**Draft.** The file is expected to evolve as conforming implementations come online and surface interoperability questions. Breaking changes will be recorded in ADRs and tracked via the spec version number.
