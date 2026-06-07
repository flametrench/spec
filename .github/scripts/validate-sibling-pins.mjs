#!/usr/bin/env node
// Tag-pin consistency gate (Release principle-7).
//
// Cross-SDK *dependency* checkouts in conformance.yml MUST pin to a released
// TAG (`ref: vX.Y.Z`), never a default branch — because a sibling's main can
// lag its release tag (e.g. ids-java main at 0.2.0 behind its v0.3.0 tag),
// and an exact dependency pin (`ids:0.3.0`) then resolves to nothing and the
// CI floods red. This gate verifies every explicit `ref:` on a
// `flametrench/<repo>` checkout points at a tag that actually exists on that
// repo. It does NOT require the SDK-under-test checkout to be pinned — that one
// is meant to track its live default branch (you test the live SDK), and it
// carries no `ref:`, so it is simply reported as build-from-default.
//
// Run: node .github/scripts/validate-sibling-pins.mjs
// Network: uses `git ls-remote --tags` per pinned repo.

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { cwd } from "node:process";

const WORKFLOW = join(cwd(), ".github/workflows/conformance.yml");
const lines = readFileSync(WORKFLOW, "utf8").split("\n");

// Walk checkout steps: pair each `repository: flametrench/<x>` with the `ref:`
// in the same step (reset at a step boundary `- name:` / `- uses:`).
const pinned = [];        // { repo, ref }
const unpinned = [];      // repo (built from default branch)
let curRepo = null;
let curRef = null;
let sawRepoThisStep = false;

function flush() {
  if (sawRepoThisStep && curRepo) {
    if (curRef) pinned.push({ repo: curRepo, ref: curRef });
    else unpinned.push(curRepo);
  }
  curRepo = null; curRef = null; sawRepoThisStep = false;
}

for (const raw of lines) {
  const line = raw.trim();
  if (line.startsWith("- name:") || line.startsWith("- uses:")) flush();
  const repoM = line.match(/^repository:\s*flametrench\/(\S+)/);
  if (repoM) { curRepo = repoM[1]; sawRepoThisStep = true; }
  const refM = line.match(/^ref:\s*(\S+)/);
  if (refM) curRef = refM[1];
}
flush();

const errors = [];

for (const { repo, ref } of pinned) {
  // Skip dynamic refs/repos (e.g. matrix expressions) — can't resolve statically.
  if (repo.includes("${{") || ref.includes("${{")) continue;
  const url = `https://github.com/flametrench/${repo}.git`;
  let out = "";
  try {
    out = execFileSync("git", ["ls-remote", "--tags", url, `refs/tags/${ref}`], {
      encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
    });
  } catch (e) {
    errors.push(`${repo}: could not query tags (${e.message.split("\n")[0]})`);
    continue;
  }
  if (!out.trim()) {
    errors.push(`${repo}: conformance.yml pins ref="${ref}" but no tag refs/tags/${ref} exists on flametrench/${repo} (orphaned/stale pin — a sibling dependency pin must point at a released tag).`);
  } else {
    console.log(`✓ ${repo} pinned to ${ref} — tag exists (${out.trim().split(/\s+/)[0].slice(0, 10)})`);
  }
}

if (unpinned.length) {
  // Not an error: the SDK-under-test (and any leg deliberately tracking HEAD)
  // builds from its default branch. Reported so a *dependency* that should be
  // pinned but isn't is visible in review.
  console.log(`ℹ build-from-default (no ref pin): ${[...new Set(unpinned)].join(", ")}`);
}

if (errors.length) {
  console.error(`\n❌ Sibling tag-pin consistency failed with ${errors.length} error(s):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(`\n✅ Sibling tag-pin consistency OK. ${pinned.length} pinned ref(s) verified against live tags.`);
