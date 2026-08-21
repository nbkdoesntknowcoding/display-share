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
    (re.compile(r"0x%[@xX]|Display 0x|radix: 16"), "raw display identifier"),
    # A caught error interpolated straight into a sentence. Command 3 replaced
    # every raw transport error with human copy and this still reached users on
    # the discovery path, because the string was a TEMPLATE LITERAL and nothing
    # here read backticks. That blind spot is the reason this rule exists.
    (
        re.compile(r"\$\{\s*(e|err|error|ex)\s*\}|\\\((error|err|e)\)"),
        "raw error text shown to a user",
    ),
    # Role names from our own architecture. A person holding the Windows app
    # has no idea they are holding "the receiver".
    (re.compile(r"\b(receivers?|senders?)\b", re.I), "internal role name"),
]

# Identifier-ish text: CSS class lists, element ids, event names. Never prose.
IDENTIFIERS = re.compile(r"^[a-z][a-z0-9-]*$")


def looks_like_prose(text: str) -> bool:
    """True for something a person would read, false for a class list.

    `btn btn--row sender` and `Type this on the receiver to pair it.` both
    contain the word "sender"/"receiver"; only one of them is copy.
    """
    tokens = text.split()
    if len(tokens) < 2:
        return False
    return not all(IDENTIFIERS.match(token) for token in tokens)


def user_facing_strings(path: Path) -> list[tuple[int, str]]:
    found = []
    for number, line in enumerate(path.read_text(encoding="utf8").splitlines(), 1):
        stripped = line.strip()
        # Comments are for us, not for users.
        if stripped.startswith(("//", "///", "*", "/*", "#", "<!--")):
            continue
        for quoted in re.findall(r'"([^"]{4,})"', line):
            found.append((number, quoted))
        # Template literals. Omitting these is how a raw JavaScript error
        # shipped as body copy for weeks after the command that removed them.
        for template in re.findall(r"`([^`]{4,})`", line):
            found.append((number, template))
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
                if why == "internal role name" and not looks_like_prose(text):
                    continue
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
