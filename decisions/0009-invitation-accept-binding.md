# 0009 — Invitation acceptance binding

**Status:** Accepted
**Date:** 2026-04-25

## Context

The v0.1 `acceptInvitation` SDK method accepts a `usr_id` for the accepting subject and the invitation's `inv_id`. Until this ADR, the SDK performed no check that the supplied `usr_id` corresponds to the invitation's `identifier` (the email or handle the invitation was issued for).

The first PHP adopter (sitesource/admin) reported the gap as a privilege-escalation primitive. The reproduction is straightforward:

1. Org `A` has an admin who issues `inv_1` with `identifier = victim@example.org`, `role = owner`.
2. An unrelated low-privilege user authenticates with `usr_attacker_id`.
3. The application's wire layer (an OpenAPI controller, in the reporter's case) accepts `as_usr_id` from the request body and forwards it to the SDK.
4. The SDK happily creates a `mem_(usr_attacker_id, role=owner, org=A)` row and materializes the `tup_` rows.

The invitation's `identifier` was never consulted. The attacker is now an owner of org A.

The vulnerability is reproducible in every conforming SDK because the contract for `acceptInvitation` does not require the binding check. The host application is responsible for a correctness step the spec never explicitly delegated, and the SDK exposes no signal that the host needs to do that work.

## Decision

`acceptInvitation` MUST enforce that the accepting user's identifier matches the invitation's `identifier` when an existing `usr_id` is supplied. The check happens inside the SDK; the host supplies the identifier explicitly as a new parameter.

### API change

```
acceptInvitation(inv_id, *, as_usr_id=None, accepting_identifier=None)
```

The semantics:

- **Mint-new-user path** (`as_usr_id is None`): `accepting_identifier` MAY be omitted. The SDK creates a fresh `usr_` and returns its id; the host's responsibility is to wire the corresponding credential (typed `password`, `passkey`, or `oidc`) with `identifier = invitation.identifier` in the same logical flow. The binding is enforced post-hoc by the Identity layer at credential creation.
- **Existing-user path** (`as_usr_id` provided): `accepting_identifier` is REQUIRED. The SDK byte-compares `accepting_identifier == invitation.identifier`. Mismatch raises `IdentifierMismatchError`. Omission raises `IdentifierBindingRequiredError` — the SDK fails closed rather than silently allow the v0.1 behavior.

### Error types

Two new typed errors join the existing tenancy error hierarchy:

- `IdentifierBindingRequiredError` — `code: precondition.identifier_binding_required`
- `IdentifierMismatchError` — `code: precondition.identifier_mismatch`

Both carry the `identifier` and the `invitation.identifier` (or just one, depending on which arm fired) so callers can log the mismatch without re-querying. Both are subclasses of the existing `PreconditionError` hierarchy so existing `except PreconditionError` blocks catch them.

### Sourcing requirement (normative)

The host application MUST source `accepting_identifier` from the authenticated session context — typically the canonical email or handle attached to the bearer token's `usr_id`. The host MUST NOT source it from the request body without an authenticity check that ties the body field to the authenticated subject.

This is the only host-side step that closes the vulnerability. The SDK's check guarantees the byte-equality; the host's auth layer guarantees the source authenticity. Neither layer alone is sufficient.

The reference behavior, expressed as pseudo-code in `docs/tenancy.md`:

```
# In the wire-layer controller:
authed_usr = authenticate(request.bearer_token)        # auth layer
authed_identifier = identity.canonical_identifier(authed_usr.id)  # auth layer
result = tenancy.accept_invitation(
    inv_id=request.path_params.inv_id,
    as_usr_id=authed_usr.id,
    accepting_identifier=authed_identifier,            # NEVER from request.body
)
```

## Consequences

- **v0.1 contract change.** This is technically a breaking change to a v0.1 API: callers that previously passed only `as_usr_id` now error. We treat it as a security fix because the previous contract was unsafe by default, and v0.1 implementations have only been live for a few weeks. The change ships in the v0.1.x patch line for all four SDKs simultaneously and the conformance suite rejects implementations that don't enforce it.
- **Wire format change.** The OpenAPI body for `POST /v1/invitations/{inv_id}/accept` gains a required `accepting_identifier` field. Adopters update their controller to source it from the auth context.
- **Conformance fixture.** A new `tenancy/invitation-accept-binding.json` fixture pins the four cases: missing param + as_usr_id provided (rejected); identifier mismatch (rejected); identifier match (accepted); mint-new-user path with `as_usr_id = null` (accepted, no `accepting_identifier` required).

## Alternatives considered

### IdentityStore reference passed into TenancyStore

Strongest from the reporter's perspective: the SDK calls into an `IdentityStore` to verify ownership directly, leaving no room for the host to lie about the identifier. Rejected because:

1. It couples the Tenancy and Identity layers — every Tenancy adopter would need to wire up an IdentityStore even if they don't otherwise use one.
2. Adopters that have a non-Flametrench identity layer (LDAP, Auth0, Okta) would have to build a Flametrench IdentityStore adapter just to call `acceptInvitation`.
3. The decoupling was deliberate in v0.1; reversing it requires re-deriving the layer separation.

The parameter approach gets >95% of the security benefit with none of the coupling cost. The remaining 5% — host lying about the identifier — is closed by the spec's normative sourcing requirement and the OpenAPI request-body schema (the field is on the wire, not derived from `as_usr_id`).

### Optional callback `identifier_verifier(usr_id, identifier) -> bool`

Slightly more flexible: host implements the callback against IdentityStore or any other source. Rejected because:

1. Callbacks are awkward in Java and PHP; the parameter is uniform across all four SDKs.
2. The callback approach hides the fail-closed behavior — if a host implements it incorrectly (always returns true), the SDK can't tell.
3. Two parameters (`as_usr_id` + `accepting_identifier`) is a smaller cognitive surface than three (`as_usr_id` + `accepting_identifier` + `verifier`).

### Spec delegates entirely to the host

The reporter's option (2). Rejected because the spec already had this semantics implicitly and it produced the bug. Pushing the binding into adopter documentation produces another bug class: adopters who read the spec carefully but miss the binding paragraph.

## References

- Spec issue [flametrench/spec#5](https://github.com/flametrench/spec/issues/5) — original report and reproduction.
- [`decisions/0003-invitation-state-machine.md`](./0003-invitation-state-machine.md) — invitation lifecycle this ADR amends.
- [`docs/tenancy.md`](../docs/tenancy.md) — the user-facing spec section that gains the normative paragraph.
