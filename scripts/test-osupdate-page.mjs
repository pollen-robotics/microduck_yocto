#!/usr/bin/env node
// Test the osupdate page's build list and install warnings, before a board.
//
// Why this exists: a board running the shipping image trusts the production CA
// only, so it refuses every dev and candidate build, and once both slots hold a
// shipping image only a reflash gets back to dev. The page hides what the board
// would refuse and warns before those one-way installs, keyed on channel names
// and status's "production". Rename a channel or change the status JSON and the
// list can go empty or the warning silent, with nothing failing -- so each case is
// run here against index.html's own functions and a fixed status.
//
// Runs anywhere with node, in well under a second:
//
//   node scripts/test-osupdate-page.mjs
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const page = new URL("../meta-microduck/recipes-microduck/microduck-osupdate/files/index.html", import.meta.url);
const html = readFileSync(page, "utf8");
const src = html.slice(html.indexOf("const shipping"), html.indexOf("// The list, grouped"));
const { installable, installPrompt } = new Function(src + "; return { installable, installPrompt };")();

const builds = [
  { channel: "dev", build: "20261029140209", version: "0.1.0-20261029140209" },
  { channel: "stable", build: "20261029140210", version: "1.0.0" },
  { channel: "dev", build: "20261029170630", version: "0.1.0-20261029170630" },
  { channel: "stable", build: "20261029170631", version: "1.0.1" },
  { channel: "dev", build: "20261030102609", version: "1.0.1+20261030102609" },
  { channel: "candidate", build: "20261030102610", version: "1.0.1+20261030102610" },
  { channel: "candidate-x", build: "20261030120001", version: "1.0.1+20261030120001" },
];
const find = (v) => builds.find((b) => b.version === v);
const shown = (s) => builds.filter((b) => installable(b, s)).map((b) => b.version);
const warns = (b, s) => installPrompt(b, s).includes("\n\n");

// A dev board: everything is installable; only a shipping image warns.
const dev = { production: false, slot: "A", installed_build: "20261030102609", builds,
  other: { slot: "B", build: "20261029170631", good: true } };
assert.equal(shown(dev).length, builds.length);
assert.match(installPrompt(find("1.0.1+20261030102610"), dev), /shipping image.*slot B takes stable builds only/s);
assert.ok(warns(find("1.0.1+20261030120001"), dev), "a branch candidate is a shipping image too");
assert.ok(warns(find("1.0.1"), dev), "so is stable");
assert.ok(!warns(find("0.1.0-20261029170630"), dev), "a dev build is not one-way");

// A production board on 1.0.0: stable only, none older than the running one.
const prod = { production: true, slot: "B", installed_build: "20261029140210", builds,
  other: { slot: "A", build: "20261030102609", good: true } };
assert.deepEqual(shown(prod), ["1.0.0", "1.0.1"]);
// Its other slot holds a dev image, which the install overwrites.
assert.match(installPrompt(find("1.0.1"), prod), /the dev image 1\.0\.1\+20261030102609.*reflashing/s);
// A flashed slot (no RAUC record) may be dev too.
assert.match(installPrompt(find("1.0.1"), { ...prod, other: { slot: "A", build: "", good: true } }), /cannot name/);
// Stable in the other slot, or a slot that is not good: nothing to lose.
assert.ok(!warns(find("1.0.1"), { ...prod, other: { slot: "A", build: "20261029140210", good: true } }));
assert.ok(!warns(find("1.0.1"), { ...prod, other: { slot: "A", build: "20261030102609", good: false } }));

// A production board flashed before BUILD_ID: no installed build, every stable shown.
assert.deepEqual(shown({ ...prod, installed_build: "" }), ["1.0.0", "1.0.1"]);

console.log("osupdate page: ok");
