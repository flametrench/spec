# Release checklist

Canonical process for any change that touches a version number, publishes
to a registry, or claims something is "stable." Refer to this document
**every time** you tag, publish, or update a version-bearing surface.

This is the document you reach for when you ask: "I'm about to publish
something — what could go wrong?"

---

## Why this document exists

Multiple incidents accumulated through 2026-04 / 05 made clear that
"green local tests + working source" is not a sufficient proof that a
release is correct:

| Incident | What went wrong |
|---|---|
| `@flametrench/identity@0.2.0-rc.6` (deprecated) | `npm publish` (bare, not pnpm) shipped unresolved `workspace:*` strings in dependencies. Tarball broken at install time for any consumer outside the monorepo. Republished as `rc.7`; `rc.6` left deprecated on the registry. |
| Multi-package pnpm publish silent skip | `pnpm publish --filter "@flametrench/*"` for the v0.2.0 stable cut shipped 3 of 4 packages — `@flametrench/authz` was silently skipped. `npm view --json` revealed authz still at `rc.3` while the others showed `0.2.0`. Re-ran with explicit authz filter to recover. |
| `@flametrench/{identity,tenancy,authz}@0.2.0` | Source had ADR 0013 savepoint cooperation since commit `ff0b826`; published `dist/` did not. `dist/` is gitignored; `files: ["dist", ...]` packs whatever's on disk. `prepublishOnly` only asserted pnpm — didn't rebuild. Stale dist from before the ADR commit got tarballed and shipped. Symptom: every adopter using a caller-owned `PoolClient` got `"Client has already been connected"`. Fixed via 0.2.1 republish. |
| `@flametrench/server@0.0.1` transitive deps | Published before the v0.2.0 stable cut. Pinned `@flametrench/{authz,identity,tenancy}@0.2.0-rc.{3,4,3}` instead of `^0.2.0`. Adopters who installed both server and a stable SDK got two side-by-side copies and TS structural type mismatches. Hearth (the v0.3 demo) had to add `pnpm.overrides` to dedupe. Fixed in `server@0.0.2`. |
| flametrench.dev StatusMatrix lag | After the 0.2.1 republish, the 12 cells on the live homepage still showed `v0.2.0` for Node identity/tenancy/authz. Caught only when an adopter audited. The cells were touched in the v0.2.0 cut but never wired to the publish process. |
| flametrench/node top-level README staleness | Each SDK was listed at its RC version (`v0.2.0-rc.{2,5,6,7}`) — never updated for the v0.2.0 stable cut, then immediately stale again after 0.2.1. Caught in the same audit. |
| Spec README "SDK families ship at v0.2.0" wording | Conflated "spec version" (v0.2.0 — correct) with "package version" (Node SDKs at 0.2.1). Technically inaccurate after the patch. |
| node-repo CI red on main for 5+ commits | `pnpm/action-setup@v4` started rejecting dual-spec configs (`with: version` + `packageManager:`) in a recent release; CI silently failed every push for weeks. Pre-existing schema-drift fail compounded the noise. Discovered only when the next PR landed. |
| Go per-module tag gap — v0.3.0 + v0.3.0-rc.1 uninstallable | Go multi-module repos require per-module tags (`packages/<module>/vX.Y.Z`), not root tags. `v0.3.0` and `v0.3.0-rc.1` were tagged at the root, so `go get github.com/flametrench/flametrench-go/packages/identity@v0.3.0` returned "unknown revision." Release checklist had no Go section and missed the requirement entirely. Adopters saw 404 on install. Fixed by tagging per-module; Go proxy verification gate added to checklist. |
| flametrench.dev spec-vs-SDK version conflation | v0.3.0 release header in spec README stated "v0.3.0 stable" over a matrix where only spec and Go were at v0.3, while PHP/Node/Python/Java remained at v0.2.x. Readers conflated "spec is v0.3" with "all SDKs are v0.3." Clarified via accurate parity wording once all families reached v0.3. |
| Java multi-module version skew (main-pom-behind-tag) | `ids-java` was tagged at v0.3.0 but main's `pom.xml` remained at v0.2.0. Spec conformance CI fetched the tag (v0.3.0) but sibling repos' CI fetched main and got v0.2.0. Cross-repo version assertions failed; 6 spec conformance PRs turned red. Root cause: release process did not verify post-tag that main's version coordinate matches the new tag. |
| Cross-repo version inconsistency (sibling mismatch) | SDK A depends on "SDK B @ v0.3.0"; B's main is at v0.2.0 after tagging B at v0.3.0. CI that consumes A's main gets the dependency-on-0.3.0 lock but can only find B's v0.2.0 in source, causing resolution failures. Sibling-consumption CI (e.g., spec conformance) fails even though the tag exists. Requires explicit cross-repo version alignment checks. |

The pattern across these is the same: **"it works on my machine" or "the
source is correct" was treated as a release proof.** Proof must be
post-publish, against the actual published artifact, against the actual
live surfaces.

---

## Principles

1. **Source CI green ≠ published package correct.** The published
   tarball / wheel / jar is a separate artifact. Verify it directly.
2. **Built artifacts are not source artifacts.** Anything generated by a
   build step (Node `dist/`, Java compiled jars, Python wheels) needs a
   build hook that runs unconditionally before pack — not a "hopefully
   the dev built before tagging" assumption.
3. **Doc is part of the release surface.** Version pins live in: per-package
   READMEs, top-level READMEs, the spec README, the website (StatusMatrix,
   code-sample snippets), and adopter project READMEs. Any of these out
   of sync after a publish is a release defect.
4. **Quote registry truth, not local intent.** A version number in a
   commit message, package.json, or README does not prove that version
   was published successfully. Hit the registry's HTTP API.
5. **Cross-registry skew is normal but must be documented.** When an
   ecosystem-specific issue forces a patch in only one ecosystem (e.g.
   the Node 0.2.1 republish), the version axis split must be explained
   in user-facing docs — not left for adopters to puzzle out.
6. **Don't claim "stable" lightly.** A surface is stable when (a) the
   published artifact correctly implements the spec, (b) all docs reflect
   the published state, (c) at least one adopter has run the published
   artifact in a non-trivial flow, (d) CI is green and exercises the
   built artifact, not just source.
7. **CI and conformance must never depend on unpublished registries.** Build and test from source or sibling checkouts — never assume a package is live on PyPI, Maven, npm, or Go proxy during development. Publish workflows must be guarded (manual trigger or gated job) until their registry publisher/credentials are live, to prevent CI floods from auto-firing against non-existent infrastructure. This prevents the class of failures where a tag triggers publish CI that fails before the registry gate exists.

---

## Pre-publish checklist (per package, before tagging)

Run through this **every** time you bump a published package's version,
even for a one-line patch. Time cost: ~5 minutes per package. Bug cost
of skipping: hours-to-days.

### Source

- [ ] All tests pass locally with the same database / runtime environment
      the registry consumer will use.
- [ ] CI is green on `main` for the commit you intend to tag. If main is
      red, fix it first — even if the failure looks "unrelated." Red CI
      hides regressions.
- [ ] `pnpm -r typecheck` (or language equivalent) passes across the
      whole workspace, not just the package you're bumping. Cross-package
      type drift is a common after-effect of a version bump.

### Built artifacts (Node specifically; analogous for others)

- [ ] **`prepack` (or equivalent) rebuilds before pack.** Confirm by
      running `pnpm publish --dry-run` and checking the rebuild ran. If
      `prepack` only does sanity asserts (e.g. "use pnpm not npm"),
      promote to also include `pnpm build`.
- [ ] **Built `dist/` is gitignored AND on disk.** Both. If `dist/` is
      tracked, you're shipping whatever was last committed regardless of
      what `prepack` does. If it's missing entirely, `npm pack` ships an
      empty package.
- [ ] **Spot-check the built artifact contains an expected source marker.**
      For Node Postgres adapters, that marker is `clientIsCallerOwned` +
      `SAVEPOINT`. For each package, identify a string that exists in
      source but cannot exist in a stale build (an identifier from a
      commit you specifically want shipped). Run `grep` against `dist/`.
      If the marker isn't there, your build is broken or stale.
- [ ] **Add a CI-enforced regression test** that asserts the marker is
      in built `dist/`. The test runs after `pnpm build` in CI on every
      push. Any future build that fails to compile the code path fails
      CI before publish has a chance to repeat the mistake.

### package.json hygiene

- [ ] `version` field reflects the new version exactly (no leading `v`).
- [ ] `files` field includes the build output dir but excludes source,
      tests, and config. Publishing source defeats minification and
      leaks internals.
- [ ] `dependencies` use `^x.y.z` or `~x.y.z` for runtime SDK siblings —
      not `workspace:*` (pnpm rewrites these at publish, but if your
      publish flow ever bypasses the rewrite, broken tarballs ship).
- [ ] `peerDependencies` are listed for any imported package that the
      adopter's project provides (`pg`, `react`, etc.). Adopters
      installing without the peer should see a warning, not a runtime
      error.
- [ ] `exports` map covers every entry point you advertise (root,
      `/postgres`, `/server`, etc.). Consumers using newer Node
      resolution algorithms will fail on missing exports.

### Cross-package

- [ ] If this package depends on another package in the same monorepo,
      and you're bumping both, **bump the dependency first** (or simultaneously),
      then publish in dependency order. Otherwise consumers can install
      the new version of the dependent before the new version of the
      dependency, getting an old transitive resolve.
- [ ] If this is a workspace with `workspace:*`, run a dry-run publish
      to confirm the workspace ref is rewritten to a real version range.

### Doc surfaces (do not skip — see the StatusMatrix lag incident)

A non-exhaustive checklist of where version pins live; identify everywhere
the published version is mentioned and update them in lockstep with the
publish:

- [ ] Per-package `README.md`: any "Status: vX.Y.Z" line, install snippet
      with version pin, badge URL.
- [ ] Per-package `CHANGELOG.md`: new entry for the version with date
      and what changed. **Required** even for republish-only changes —
      explain why the version moved.
- [ ] Top-level repo `README.md`: each package version line.
- [ ] `flametrench/spec/README.md`: any "ships at vX.Y.Z" wording across
      the SDK matrix.
- [ ] `flametrench/www/components/status-matrix.tsx`: the cell for
      `(this package, this language)`.
- [ ] `flametrench/www/components/code-sample.tsx`: any install snippet
      that pins a version (currently the Maven snippet does).
- [ ] Any adopter project README that pins this version (e.g.
      `flametrench/hearth`, the demo app's `backends/<lang>/README.md`).
      If you don't know which adopters pin you, that's a problem on its
      own — adopter coordination is part of release process.

### Decision: is the change actually publishable?

- [ ] If the change is functional, the version bump is `0.x.Y` → `0.x.(Y+1)`
      patch (additive bug fix), `0.X.0` → `0.(X+1).0` minor (additive
      feature), or major (breaking) — choose by spec, not by gut feel.
- [ ] If the change is doc-only with no source impact, **don't publish.**
      Push the doc fix to the repo; the registry doesn't care about README
      changes between published versions (npm shows the README from the
      latest tarball, but a doc fix doesn't justify a new patch).
- [ ] If the change is a *republish* (e.g. fixing a build that shipped
      stale dist), bump the patch version. Never republish the same
      version — npm refuses, and even if it didn't, cached resolution
      would serve adopters the old broken tarball indefinitely.

---

## Publish checklist (during the publish itself)

- [ ] **Use the workspace tool, not the registry tool.** `pnpm publish`,
      `composer` semver tagging, `mvn deploy`, `twine upload`. Never
      `npm publish` directly in a workspace — it doesn't resolve
      `workspace:*`, and you'll ship broken tarballs (the
      `@flametrench/identity@0.2.0-rc.6` deprecation is the prior art).
- [ ] **Publish one package at a time** when bumping multiple. Multi-package
      publishes can silently skip (the `pnpm publish --filter "@flametrench/*"`
      authz-skip incident from the v0.2.0 cut). The 30-second cost of
      sequential publishes is dwarfed by the hour cost of debugging a
      partial publish.
- [ ] **Verify each publish before moving to the next.** `npm view <pkg>
      versions --json` (plural — singular returns only the `latest` dist-tag
      and hides the version you just published if there's a delay). If
      the version you just tried to publish isn't in the list, **don't**
      assume it'll show up. Investigate.
- [ ] **Tag the git commit that was published.** Annotated tag with a
      message. Convention: `<scope>/<package>@<version>` (e.g.
      `@flametrench/identity@0.2.1`). Push tags after the publish
      succeeds, not before — a tagged-but-unpublished version is a
      release-process lie.

---

## Post-tag hygiene (recommended — release-to-main synchronization for maintainability)

**After tagging vX.Y.Z, main's version coordinates SHOULD be bumped to forward-SNAPSHOT or the next minor, depending on the project's convention.** This keeps the repository in a clean, maintainable state and prevents *accidental* consumption of stale main versions during manual builds or debugging.

**⚠️ IMPORTANT:** This hygiene check is NOT the load-bearing gate for preventing version-skew flooding. The actual flood prevention is the **tag-pin consistency check** (documented under "Cross-repo version consistency" below). Sibling-repo CI must pin to RELEASED TAGS (`ref: vX.Y.Z`), never default-branch. As long as CI pins to tags, main's version is irrelevant.

- [ ] The commit(s) that added the version bump for the tag are on `main`
      (not just on a release branch). If the tag was cut from a `release/` branch,
      you must cherry-pick the version bump back to main or rebase main to
      include it.
- [ ] **Main's version coordinate (package.json, pom.xml, pyproject.toml, go.mod)
      should be:**
  - The same version as the tag (e.g., if you tagged `v0.3.0`, main has `0.3.0` or
    `0.3.0-SNAPSHOT`), OR
  - Explicitly forward of the tag (e.g., tag `v0.3.0`, main has `0.3.1-SNAPSHOT` or `0.4.0-SNAPSHOT`).
  
  Leaving main behind the tag (e.g., tag `v0.3.0` while main is `0.2.0`) is not a
  blocking issue *if* sibling CI pins to the tag, but it's poor hygiene and makes
  local debugging confusing.

- [ ] CI is green on `main` after the version bump. If CI goes red from the
      bump alone, investigate before merging — version-coordinate changes
      should not cause CI to fail.

---

## Cross-repo version consistency (THE load-bearing gate for flood prevention)

**All sibling pins in CI must point to RELEASED TAGS (`ref: vX.Y.Z`), never
default-branch.** This is the structural gate that prevents version-skew
flooding. Because multi-repo CI never reads main's version, main can be
SNAPSHOT or stable without risk — the tag pins are what matter.

- [ ] **For multi-repo CI (e.g., spec conformance):** Every SDK pin must
      point to an existing released tag:
  - ✅ `ref: v0.3.0` (existing tag) — safe, always resolves correctly
  - ❌ `ref: main` or default-branch (may be SNAPSHOT, may not match expectations) — unsafe, causes version mismatch
  - ❌ `ref: v0.3.1-SNAPSHOT` (non-existent tag) — unsafe, won't resolve

- [ ] **Required CI gate:** A status check that validates every sibling `ref:`
      in CI config points to an actual released tag:
  - `git ls-remote --tags <repo> refs/tags/<ref>` must succeed for every pin
  - Fails if any pin is stale, future, or non-existent
  - This gate prevents the flood structurally: the flood cannot occur if
    every pin is locked to a released tag

- [ ] **After tagging vX.Y.Z:** Ensure all dependents either pin the new tag
      (vX.Y.Z) before their own release, or have a released tag that pins the
      sibling version they need. Never leave a tag that pins a non-existent
      sibling version.

---

## Post-publish verification (mandatory — this is what catches stale dist)

- [ ] `npm pack <pkg>@<just-published-version>` → extract → grep `dist/`
      for the source marker you identified in the pre-publish checklist.
      If the marker isn't there, **the publish is broken**; bump the patch
      and re-publish immediately. Don't wait for adopters to find it.
- [ ] `npm view <pkg> versions --json` → confirm the version you intended
      to publish is in the list.
- [ ] If the package has dependencies on other packages in the monorepo,
      `npm view <pkg>@<version> dependencies` → confirm the resolved
      versions match what you expected (no leftover `workspace:*`, no
      stale RC pins like the `@flametrench/server@0.0.1` situation).
- [ ] Smoke-test the published artifact in a clean directory:
      ```bash
      cd /tmp && mkdir smoke && cd smoke
      pnpm init
      pnpm add <pkg>@<just-published-version>
      node -e 'import("<pkg>").then(m => console.log(Object.keys(m)))'
      ```
      Catches packaging regressions that source CI can't see.

---

## Doc / surface sync (within ~10 minutes of publish)

The publish is not done when the registry has the new version. It's done
when every surface that quotes a version reflects it.

- [ ] flametrench.dev StatusMatrix updated and deployed (Vercel auto-deploys
      from `flametrench/www` main).
- [ ] All affected per-package READMEs updated.
- [ ] Top-level monorepo README's package list updated.
- [ ] `flametrench/spec/README.md` SDK-version mentions updated if they
      drift across families.
- [ ] Memory file `~/.claude/projects/.../memory/project_v0X_*.md`
      updated with the new state, so the next session resumes from
      reality rather than the snapshot.
- [ ] Any adopter project (e.g. `flametrench/hearth`) that pins this
      package gets a follow-up commit with the new pin. If the adopter's
      `pnpm.overrides` was a workaround for the broken version, drop it
      in the same commit.

---

## "Stable" gating

You may **not** label a version "stable" in any user-facing surface
unless all of the following are true:

1. The published artifact passes the post-publish verification above
   (markers present, deps clean, smoke-install works).
2. At least one adopter has run the published artifact through a
   non-trivial flow that exercises the changed surface (not just an
   import smoke). For SDKs, this means the adopter's e2e suite runs
   against the published version and is green.
3. The doc surfaces (this checklist's "Doc / surface sync" section) all
   reflect the published version.
4. CI on the producing repo's `main` is green and exercises the built
   artifact, not just source.

If any of these aren't true, the version is "released" but not "stable."
Use a different word ("preview", "rc", "early", "patch") on user-facing
surfaces until the gating clears.

The pattern of declaring stable, then patching the same day to fix the
released stable, then patching the patch — happens when this gating is
treated as advisory. It must be a hard gate.

---

## Per-ecosystem specifics

### npm (Node monorepo at `flametrench/node`)

- pnpm workspace, `workspace:*` between packages.
- `dist/` is gitignored and produced by `tsup`. **`prepack` must run `pnpm
  build`** — already wired as of 2026-05-01 PR #1, but verify if you're
  spinning up a new package.
- Multi-package publish: `pnpm publish --filter "@flametrench/<one-package>"`
  per package, NOT `--filter "@flametrench/*"` (silent-skip incident).
- Verification: `npm pack` + `tar -tzf` + grep dist for marker.

### Packagist (PHP packages at `flametrench/{ids,identity,tenancy,authz,laravel}-php` + `flametrench/laravel`)

- composer.json has no `version` field — Packagist auto-syncs from git
  tags. Bumping == push a new annotated git tag.
- No build step (PHP is interpreted) — what's in source IS what's
  published. The Node "stale dist" failure mode doesn't apply here.
- `flametrench/laravel` requires manual one-time submission to Packagist
  on first publish (we did this 2026-05-01 for the laravel package). After
  the first submit, Packagist's webhook auto-syncs every tag.

### PyPI (Python packages)

- **Status:** Published via Trusted Publishing (GitHub Actions OIDC); org migration deferred.
- **Process:** `twine upload`, in dependency order: `ids` first (others depend on it), then identity / tenancy / authz in any order. Use GitHub Actions Trusted Publisher credentials (no long-lived API token).
- Wheel content vs source: wheels include the full src tree (no separate `dist/` build). Stale-build risk lower than Node.
- **PyPI Org note:** A PyPI Organization is purely a management/namespace layer, not a prerequisite for publishing. The four package names (`flametrench-ids`, `flametrench-identity`, `flametrench-tenancy`, `flametrench-authz`) can migrate to an org later via PyPI's project-move feature with zero disruption to consumers.

### Go (multi-module packages)

- **Per-module tags (mandatory):** Go multi-module repos require per-module tags, not root tags. Every module under `packages/{ids,identity,tenancy,authz}` must have its own tag `packages/<module>/vX.Y.Z` at the release commit. Root `vX.Y.Z` tags do NOT version submodules and will cause `go get` to fail with "unknown revision."
- **Proxy verification (mandatory):** After tagging, verify each module is reachable via the Go module proxy before declaring "released." For each module:
  ```bash
  curl https://proxy.golang.org/github.com/flametrench/flametrench-go/packages/<module>/@v/<ver>.info
  ```
  Must return a valid JSON response with the module name and version (not 404 or timeout). Proxy indexing is automatic but can lag 5–30 seconds; retry if needed.
- **Install smoke:** In a clean temp module, test each package:
  ```bash
  go get github.com/flametrench/flametrench-go/packages/ids@<ver>
  go get github.com/flametrench/flametrench-go/packages/identity@<ver>
  # etc for tenancy, authz
  # Then a trivial build: go build ./main.go
  ```
  Must succeed with no "unknown revision" errors.
- **Doc/surface sync:** Update flametrench.dev Go status-matrix cells and the README's Go installation snippet to the new version.

### Maven Central (Java packages)

- Currently externally blocked on Sonatype Central Portal user-token
  regen.
- When unblocked: `mvn -P release deploy` from each `*-java/` repo.
- Local `mvn -P release verify -Dgpg.skip=true` already passes for
  authz-java + tenancy-java.
- `dev.flametrench` namespace is DNS-verified on flametrench.dev.

---

## When to update this checklist

Add an incident to the "Why this document exists" table whenever a
release-related bug ships to a registry or a live user-facing surface.
The table is the institutional memory; update it before the lesson
fades.
