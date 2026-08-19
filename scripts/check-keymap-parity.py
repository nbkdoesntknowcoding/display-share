#!/usr/bin/env python3
"""Every key the Mac viewer can send must resolve on the Windows side (Task 8.3).

The two key maps live in different languages and cannot import each other, so
nothing stops one drifting from the other. The failure is silent and specific:
a key the Mac emits but Windows cannot resolve is simply dropped, and the user
finds one dead key with no error anywhere.

This parses both sources and compares the sets. It is deliberately dumb about
Rust and Swift syntax — it only needs the string literals.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "mac" / "DisplayShare" / "ViewerInput.swift"
RUST = ROOT / "windows" / "src-tauri" / "src" / "keymap.rs"


def mac_codes() -> set[str]:
    """Codes MacKeyCodes can emit: the switch returns plus the modifier table."""
    text = SWIFT.read_text()
    codes = set(re.findall(r'case \d+: return "([A-Za-z0-9]+)"', text))
    codes |= set(re.findall(r'\(\.\w+, "([A-Za-z0-9]+)"\)', text))
    return codes


def windows_resolves(code: str, rust: str) -> bool:
    """Mirrors keymap::lookup's structure closely enough to catch drift."""
    if re.fullmatch(r"Key[A-Z]", code):
        return True
    if re.fullmatch(r"Digit[0-9]", code):
        return True
    if re.fullmatch(r"Numpad[0-9]", code):
        return True
    m = re.fullmatch(r"F([0-9]+)", code)
    if m:
        return 1 <= int(m.group(1)) <= 24
    # Everything else must appear as an explicit match arm.
    return re.search(rf'"{re.escape(code)}" =>', rust) is not None


def main() -> int:
    for path in (SWIFT, RUST):
        if not path.exists():
            print(f"FAIL: {path} is missing")
            return 1

    rust = RUST.read_text()
    emitted = mac_codes()
    if not emitted:
        print("FAIL: parsed no key codes from the Swift side — the parser has drifted")
        return 1

    missing = sorted(c for c in emitted if not windows_resolves(c, rust))
    if missing:
        print(f"FAIL: {len(missing)} key(s) the Mac sends have no Windows mapping:")
        for code in missing:
            print(f"  {code}")
        return 1

    print(f"ok: all {len(emitted)} key codes the Mac can send resolve on Windows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
