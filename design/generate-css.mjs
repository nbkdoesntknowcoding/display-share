#!/usr/bin/env node
/**
 * Generates windows/src/styles/tokens.css from design/tokens.json.
 *
 * Command 1 of the UI/UX audit. The two apps previously shared no colours,
 * radii, spacing or type scale and did not read as the same product; this file
 * and its Swift counterpart are the single source they both consume.
 *
 * Do not edit the generated file. CI regenerates it and fails on any difference.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const tokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
const out = join(here, "..", "windows", "src", "styles", "tokens.css");

/// camelCase to kebab-case, so `surfaceRaised` becomes `--ds-surface-raised`.
const kebab = (name) => name.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();

const lines = [
  "/* GENERATED FROM design/tokens.json — DO NOT EDIT.",
  " * Run `node design/generate-css.mjs` after changing tokens.json.",
  " * CI fails if this file does not match the generator's output. */",
  ":root {",
  ...Object.entries(tokens.colors).map(([k, v]) => `  --ds-${kebab(k)}: ${v};`),
  "",
  ...Object.entries(tokens.radii).map(([k, v]) => `  --ds-radius-${k}: ${v}px;`),
  "",
  // Indexed rather than named: the scale is the constraint, and naming steps
  // invites off-scale values with plausible names.
  ...tokens.spacing.map((v, i) => `  --ds-space-${i + 1}: ${v}px;`),
  "",
  ...tokens.fontSizes.map((v, i) => `  --ds-font-${i + 1}: ${v}px;`),
  "}",
  "",
];
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join("\n"));
console.log(`wrote ${out}`);
