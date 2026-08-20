#!/usr/bin/env node
/**
 * Generates mac/DisplayShareCore/Design/DesignTokens.swift from tokens.json.
 *
 * Written in Node rather than Swift so one runtime generates both outputs and
 * CI needs no toolchain it does not already have.
 *
 * Hex is converted to component values HERE, at generation time, rather than
 * shipping a runtime hex parser: a parser is code that can be wrong, and these
 * numbers never change between builds.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const tokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
const out = join(here, "..", "mac", "DisplayShareCore", "Design", "DesignTokens.swift");

const rgb = (hex) => {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => (c / 255).toFixed(4));
};

const colours = Object.entries(tokens.colors)
  .map(([name, hex]) => {
    const [r, g, b] = rgb(hex);
    return `    /// ${hex}\n    public static let ${name} = Color(red: ${r}, green: ${g}, blue: ${b})`;
  })
  .join("\n");

const swift = `// GENERATED FROM design/tokens.json — DO NOT EDIT.
// Run \`node design/generate-swift.mjs\` after changing tokens.json.
// CI fails if this file does not match the generator's output.
import SwiftUI

/// The colours both apps share. Never hardcode a hex value in app code.
public enum DSColor {
${colours}
}

public enum DSRadius {
${Object.entries(tokens.radii).map(([k, v]) => `    public static let ${k}: CGFloat = ${v}`).join("\n")}
}

/// The spacing scale. Indexed rather than named, because naming steps invites
/// off-scale values with plausible names.
public enum DSSpacing {
${tokens.spacing.map((v, i) => `    public static let s${i + 1}: CGFloat = ${v}`).join("\n")}
}

public enum DSFont {
${tokens.fontSizes.map((v, i) => `    public static let f${i + 1}: CGFloat = ${v}`).join("\n")}
}
`;
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, swift);
console.log(`wrote ${out}`);
