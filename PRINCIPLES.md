# Flametrench: north star and guiding principles

*Approved by the owner, 2026-09-26. This file is the text of record. Changing it is itself a spec change and needs the owner's decision (P2).*

**The spec is the product.** Flametrench is an open specification for the load-bearing parts of every application: a small, carefully guarded contract that any team, on any of five stacks, can build on for years and get identical behaviour over the wire. The SDKs are reference implementations of it. Hearth (the example project) is a showcase. Adopters are how we learn what belongs in it.

- **For:** backend and platform teams building multi-tenant applications in Python, Node, PHP, Java or Go. Adopters: SiteSource Admin (the first adopter) and SiteSource Platform.
- **Is:** the spec; five first-class SDK families that behave the same once a change is accepted (same contract, same fixtures; version numbers may differ); conformance you can run.
- **Isn't:** a hosted service, a framework, an admin product, or a home for features no adopter has proven.

## Principles

- **P1. The spec is the product.** SDKs are reference implementations; Hearth is a showcase. The spec leads; released code never defines it.
- **P2. The owner decides every normative change.** Spec, Security and the PO analyse and recommend. Nobody else declares anything admissible, ready or settled.
- **P3. Admission tests are necessary, not sufficient.** A proposal must pass all five before it can reach the owner: named adopter production need; coupled to identity, tenancy or authz; general; expressible in fixtures; at most one new primitive per minor version (a new operation on an existing primitive passes tests 1-4 and is paced by roadmap ranking).
- **P4. Test first, with two owner gates:** (a) the owner says yes to drafting; the ADR is merged as Proposed (not normative); one reference SDK is built in the proving adopter's language and the adopter integrates it in production; (b) the owner decides accept, amend or hold on that evidence; only after acceptance, fan-out to five languages; a release tag once 5/5 conformance passes.
- **P5. Decisions are explicit and permanent.** An ADR is merged as Proposed only after gate (a), and becomes Accepted only by the owner's recorded gate-(b) decision (the Deciders line names him, with the date). A release never ratifies anything by itself. Accepted ADRs are frozen; changes come as a superseding ADR.
- **P6. Narrow by default.** Leaving something out is a feature. Every addition is permanent surface in five languages; the burden of proof is on the addition.
- **P7. Conformance gives the contract its force.** Normative behaviour must be expressible in fixtures. A fixture that doesn't gate isn't conformance.
- **P8. The spec is internally consistent.** ADRs, capability docs, the reference schema, the README and the ADR index don't contradict each other. A known contradiction blocks a release.
- **P9. Security review before acceptance** for anything touching auth, tenancy boundaries, disclosure or enumeration.
- **P10. Say only what's true.** Public claims match accepted, shipped reality.

## Success measures

1. **Adopters in production.** Two SiteSource adopters declare Flametrench dependencies: SiteSource Admin (PHP; ids, identity, tenancy, authz) and SiteSource Platform (Go; identity, tenancy, authz; a Node dependency is planned). Production use to be confirmed by each. External adopters: 0 today; at least 1 is the next milestone.
2. **Proven parity:** every accepted primitive passes the same fixtures in all five languages, and later the same black-box runner.
3. **The contract leads the code:** no SDK ships unaccepted behaviour as stable, and reference builds made before acceptance are published only as clearly labelled pre-release.
