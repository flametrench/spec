#!/usr/bin/env node
// Validate that every fixture path listed in conformance/index.json exists,
// that its declared capability/operation/conformance_level match what the
// fixture file itself says, and that no fixture file is missing from the
// index. Keeps the index honest.

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { cwd, argv } from "node:process";

const ROOT = cwd();
const INDEX_PATH = join(ROOT, "conformance/index.json");
const FIXTURES_DIR = join(ROOT, "conformance/fixtures");
const FIX = argv.includes("--fix");

const errors = [];
function err(msg) { errors.push(msg); }

const index = JSON.parse(readFileSync(INDEX_PATH, "utf8"));

// Track the highest spec_version any fixture declares — the corpus's
// effective version is derived from the fixtures, not hand-maintained.
let maxFixtureVersion = "0.0.0";

// Check each declared fixture exists and matches its metadata.
for (const entry of index.fixtures) {
  const fixturePath = join(ROOT, "conformance", entry.path);
  let fixture;
  try {
    fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
  } catch (e) {
    err(`index.json references ${entry.path} but the file cannot be read: ${e.message}`);
    continue;
  }
  if (fixture.capability !== entry.capability) {
    err(`${entry.path}: index says capability=${entry.capability} but fixture says capability=${fixture.capability}`);
  }
  if (fixture.operation !== entry.operation) {
    err(`${entry.path}: index says operation=${entry.operation} but fixture says operation=${fixture.operation}`);
  }
  if (fixture.conformance_level !== entry.conformance_level) {
    err(`${entry.path}: index says conformance_level=${entry.conformance_level} but fixture says conformance_level=${fixture.conformance_level}`);
  }
  if (semverGreaterThan(fixture.spec_version, maxFixtureVersion)) {
    maxFixtureVersion = fixture.spec_version;
  }
}

// The index's spec_version MUST be at least the highest version any
// fixture declares (a fixture can't target a version the corpus hasn't
// reached). This is auto-derived: the floor is max(fixture.spec_version),
// so adding the first fixture of a new spec minor without bumping the
// index — the exact break that reddened main when the v0.4 audit fixture
// landed under a 0.3.0 index — is caught at PR time, not after merge.
// `--fix` raises index.spec_version to the derived floor in place.
// (The index may legitimately LEAD the fixtures — a higher in-development
// target with no fixtures yet — so we enforce >=, not ==.)
if (semverGreaterThan(maxFixtureVersion, index.spec_version)) {
  if (FIX) {
    index.spec_version = maxFixtureVersion;
    writeFileSync(INDEX_PATH, JSON.stringify(index, null, 2) + "\n");
    console.log(`🔧 --fix: bumped index spec_version to ${maxFixtureVersion} (max fixture version).`);
  } else {
    err(`index spec_version=${index.spec_version} lags the corpus: a fixture declares spec_version=${maxFixtureVersion}. Bump index.spec_version to ${maxFixtureVersion} (or re-run with --fix).`);
  }
}

function semverGreaterThan(a, b) {
  const [aa, ab, ac] = a.split(".").map(Number);
  const [ba, bb, bc] = b.split(".").map(Number);
  if (aa !== ba) return aa > ba;
  if (ab !== bb) return ab > bb;
  return ac > bc;
}

// Check no .json fixture file on disk is missing from the index.
// (Exclude schema files and README.md etc.)
function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(p));
    else if (entry.isFile() && entry.name.endsWith(".json")) out.push(p);
  }
  return out;
}

const declared = new Set(
  index.fixtures.map((e) => relative(FIXTURES_DIR, join(ROOT, "conformance", e.path))),
);
const onDisk = walk(FIXTURES_DIR).map((p) => relative(FIXTURES_DIR, p));
for (const f of onDisk) {
  if (!declared.has(f)) {
    err(`${f}: on disk in fixtures/ but not declared in index.json`);
  }
}

// Check every test id within a fixture is unique within that fixture.
for (const entry of index.fixtures) {
  const fixturePath = join(ROOT, "conformance", entry.path);
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
  const ids = new Set();
  for (const t of fixture.tests) {
    if (ids.has(t.id)) {
      err(`${entry.path}: duplicate test id "${t.id}"`);
    }
    ids.add(t.id);
  }
}

if (errors.length) {
  console.error(`❌ Conformance index validation failed with ${errors.length} error(s):`);
  for (const e of errors) console.error(`  - ${e}`);
  process.exit(1);
}
console.log(`✅ Conformance index valid. ${index.fixtures.length} fixture files declared; all consistent.`);
