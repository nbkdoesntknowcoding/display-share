#!/usr/bin/env python3
"""No internal references or raw identifiers in user-facing strings.

The UI/UX audit found two shipped to production: "(Task 3.3)", an internal
build-plan reference, and "Display 0xb", a raw CGDirectDisplayID. Both had been
visible to every user of the app for weeks, and both read as an unfinished build.

Neither was caught by a test, because both were valid code. This is a lint, not a
test: it reads the source and fails on the pattern rather than the behaviour.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Only files that render text to a person.
TARGETS = [
    *(ROOT / "mac" / "DisplayShare").glob("*.swift"),
    *(ROOT / "mac" / "DisplayShareCore" / "Design").glob("*.swift"),
    ROOT / "windows" / "index.html",
    ROOT / "windows" / "src" / "main.ts",
    ROOT / "windows" / "src" / "errors.ts",
]

# Matches the literal text inside Text("…") / textContent = "…" / plain HTML.
FORBIDDEN = [
    (re.compile(r"(Task|Phase)\s+\d"), "internal build-plan reference"),
    (re.compile(r"0x%[@xX]|Display 0x"), "raw display identifier"),
]

def user_facing_strings(path: Path) -> list[tuple[int, str]]:
    found = []
    for number, line in enumerate(path.read_text(encoding="utf8").splitlines(), 1):
        stripped = line.strip()
        # Comments are for us, not for users.
        if stripped.startswith(("//", "///", "*", "/*", "#", "<!--")):
            continue
        for quoted in re.findall(r'"([^"]{4,})"', line):
            found.append((number, quoted))
        # HTML body text between tags.
        for text in re.findall(r">([^<>{}]{6,})<", line):
            found.append((number, text))
    return found

def main() -> int:
    problems = []
    for path in TARGETS:
        if not path.exists():
            continue
        for number, text in user_facing_strings(path):
            for pattern, why in FORBIDDEN:
                if pattern.search(text):
                    rel = path.relative_to(ROOT)
                    problems.append(f"{rel}:{number}  {why}: {text.strip()[:70]}")

    if problems:
        print(f"FAIL: {len(problems)} user-facing string(s) leak internal detail:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print("ok: no internal references or raw identifiers in user-facing strings")
    return 0

if __name__ == "__main__":
    sys.exit(main())
