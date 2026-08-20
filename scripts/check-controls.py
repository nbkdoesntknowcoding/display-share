#!/usr/bin/env python3
"""Every control comes from the shared system (Command 7 of the UI/UX audit).

The audit counted three unrelated button treatments across two screens, and a
fourth (an underlined text link) had appeared since. None of them was a bug —
each was a reasonable-looking local decision, styled by its own id selector or
its own `.buttonStyle`, and no test could have objected.

So this is a lint. It reads the stylesheet for the list of variants rather than
restating it, then checks the markup and the Swift against what it found: a
variant added in one place cannot silently disagree with the rule that uses it.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTROLS_CSS = ROOT / "windows" / "src" / "styles" / "controls.css"
INDEX_HTML = ROOT / "windows" / "index.html"
MAC_VIEWS = sorted((ROOT / "mac" / "DisplayShare").glob("*.swift"))

# A size, not a meaning — it composes with a variant rather than replacing one.
MODIFIER_CLASSES = {"hero"}


def variants_from_stylesheet() -> set[str]:
    """The list of variants, taken from the stylesheet that defines them."""
    css = CONTROLS_CSS.read_text(encoding="utf8")
    found = set(re.findall(r"\.btn--([a-z]+)", css))
    return found - MODIFIER_CLASSES


def strip_comments(html: str) -> str:
    """Blanks HTML comments while preserving line numbers.

    Comments in this project explain the markup and frequently name the tags
    they are about, so scanning them finds `<button>` written in prose.
    """
    def blank(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    return re.sub(r"<!--.*?-->", blank, html, flags=re.DOTALL)


def buttons(html: str) -> list[tuple[int, str]]:
    """Every <button …> open tag, with the line it starts on."""
    html = strip_comments(html)
    found = []
    for match in re.finditer(r"<button\b[^>]*>", html, re.DOTALL):
        line = html.count("\n", 0, match.start()) + 1
        found.append((line, match.group(0)))
    return found


def classes_of(tag: str) -> list[str]:
    match = re.search(r'class="([^"]*)"', tag)
    return match.group(1).split() if match else []


def identify(tag: str) -> str:
    match = re.search(r'id="([^"]*)"', tag)
    return match.group(1) if match else tag[:48]


def check_markup(variants: set[str]) -> list[str]:
    problems = []
    html = INDEX_HTML.read_text(encoding="utf8")
    heroes = 0

    for line, tag in buttons(html):
        classes = classes_of(tag)
        name = identify(tag)
        where = f"windows/index.html:{line}  <button {name}>"

        if "btn" not in classes:
            problems.append(f"{where} is not in the button system (missing `btn`)")
            continue

        chosen = [c[len("btn--"):] for c in classes if c.startswith("btn--")]
        chosen = [c for c in chosen if c not in MODIFIER_CLASSES]

        if not chosen:
            problems.append(
                f"{where} has no variant — pick one of: {', '.join(sorted(variants))}"
            )
        elif len(chosen) > 1:
            problems.append(f"{where} has {len(chosen)} variants: {', '.join(chosen)}")
        else:
            unknown = set(chosen) - variants
            if unknown:
                problems.append(
                    f"{where} uses `btn--{unknown.pop()}`, which controls.css does not define"
                )

        if "btn--hero" in classes:
            heroes += 1

    # "The single hero action" is the audit's wording, and it is the whole
    # mechanism by which one thing on a screen reads as the thing to press.
    if heroes > 1:
        problems.append(
            f"windows/index.html has {heroes} hero buttons — there may be at most one"
        )
    return problems


def check_focus_rings() -> list[str]:
    """A suppressed outline must be replaced, never simply removed.

    The audit found no visible focus indicator anywhere in either app. Both
    were operable by keyboard; neither showed where the keyboard was.
    """
    problems = []
    for path in [CONTROLS_CSS, INDEX_HTML]:
        text = path.read_text(encoding="utf8")
        suppressed = re.search(r"outline:\s*(none|0)\b", text)
        if suppressed and ":focus-visible" not in text:
            line = text.count("\n", 0, suppressed.start()) + 1
            rel = path.relative_to(ROOT)
            problems.append(
                f"{rel}:{line} suppresses the focus outline without a :focus-visible replacement"
            )
    return problems


def check_swift_views() -> list[str]:
    """The Mac app builds controls from the system, not from SwiftUI defaults.

    `DisplayShare/` is the app's views; `DisplayShareCore/Design/Components/` is
    where the system itself is allowed to call the primitives.
    """
    banned = [
        (re.compile(r"\.buttonStyle\("), "use DSButton instead of a bare .buttonStyle"),
        (re.compile(r"\.textFieldStyle\(\.roundedBorder\)"), "use DSTextField"),
        (re.compile(r"(?<!DS)\bButton\s*\("), "use DSButton"),
        (re.compile(r"(?<!DS)\bTextField\s*\("), "use DSTextField"),
    ]
    problems = []
    for path in MAC_VIEWS:
        for number, line in enumerate(path.read_text(encoding="utf8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("//", "///", "*", "/*")):
                continue
            for pattern, advice in banned:
                if pattern.search(line):
                    rel = path.relative_to(ROOT)
                    problems.append(f"{rel}:{number}  {advice}: {stripped[:66]}")
    return problems


def main() -> int:
    variants = variants_from_stylesheet()
    if not variants:
        print("FAIL: controls.css defines no .btn-- variants")
        return 1

    problems = check_markup(variants) + check_focus_rings() + check_swift_views()

    if problems:
        print(f"FAIL: {len(problems)} control(s) outside the shared system:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(
        f"ok: every control is in the system "
        f"({len(variants)} variants: {', '.join(sorted(variants))})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
