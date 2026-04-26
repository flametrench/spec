#!/usr/bin/env node
// Validate that every fixture path listed in conformance/index.json exists,
// that its declared capability/operation/conformance_level match what the
// fixture file itself says, and that no fixture file is missing from the
// index. Keeps the index honest.

import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { cwd } from "node:process";

const ROOT = cwd();
const INDEX_PATH = join(ROOT, "conformance/index.json");
const FIXTURES_DIR = join(ROOT, "conformance/fixtures");

const errors = [];
function err(msg) { errors.push(msg); }

const index = JSON.parse(readFileSync(INDEX_PATH, "utf8"));

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
  // Each fixture declares the spec_version it was introduced under.
  // The index's spec_version is the current target. v0.2 fixtures may
  // coexist with v0.1 fixtures in the same index — what we enforce is
  // that no fixture targets a version higher than the index.
  if (semverGreaterThan(fixture.spec_version, index.spec_version)) {
    err(`${entry.path}: fixture spec_version=${fixture.spec_version} exceeds index spec_version=${index.spec_version}`);
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
