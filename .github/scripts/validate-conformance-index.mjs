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
  if (fixture.spec_version !== index.spec_version) {
    err(`${entry.path}: fixture spec_version=${fixture.spec_version} does not match index spec_version=${index.spec_version}`);
  }
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
