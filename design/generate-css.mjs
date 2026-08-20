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

/// `#F0997B` to `240, 153, 123`, so a stylesheet can build `rgba(…, 0.4)`.
///
/// Emitted because the component system needs colours AT AN OPACITY — a 40%
/// error border, a 60% focus ring (Command 7) — and CSS cannot apply alpha to a
/// hex custom property. Without this the alternative is a literal rgba() in the
/// stylesheet, which is exactly the hardcoded colour Command 1 exists to
/// forbid: it would drift silently the day the accent changes.
const components = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].join(", ");
};

const lines = [
  "/* GENERATED FROM design/tokens.json — DO NOT EDIT.",
  " * Run `node design/generate-css.mjs` after changing tokens.json.",
  " * CI fails if this file does not match the generator's output. */",
  ":root {",
  ...Object.entries(tokens.colors).map(([k, v]) => `  --ds-${kebab(k)}: ${v};`),
  "",
  "  /* Components, for rgba() when a token is needed at an opacity. */",
  ...Object.entries(tokens.colors).map(
    ([k, v]) => `  --ds-${kebab(k)}-rgb: ${components(v)};`
  ),
  "",
  ...Object.entries(tokens.radii).map(([k, v]) => `  --ds-radius-${k}: ${v}px;`),
  "",
  // Indexed rather than named: the scale is the constraint, and naming steps
  // invites off-scale values with plausible names.
  ...tokens.spacing.map((v, i) => `  --ds-space-${i + 1}: ${v}px;`),
  "",
  ...tokens.fontSizes.map((v, i) => `  --ds-font-${i + 1}: ${v}px;`),
  "",
  `  --ds-fast: ${tokens.motion.fast}ms;`,
  `  --ds-base: ${tokens.motion.base}ms;`,
  `  --ds-ease: cubic-bezier(${tokens.motion.easeControlPoints.join(", ")});`,
  "}",
  "",
];
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, lines.join("\n"));
console.log(`wrote ${out}`);
