#!/usr/bin/env python3
"""Fetch a published release the way the apps do, and prove it is usable.

    scripts/verify-release.py [--tag v1.2.3] [--repo owner/name]
    scripts/verify-release.py --self-test        # no network

Every update failure this project has shipped passed a green build, because the
release job checks the files it has just written to disk. The apps do not read
those. They read a public URL, through a CDN, after the release is finalised —
and that is where things have gone wrong:

* **v0.10.0** — the tag said 0.10.0, the installer inside said 0.9.4. Every app
  updated, came back reporting the older version, and updated again on the next
  launch. An infinite loop that stops only when a person notices.
* **The 404** — the manifest was perfect and the URL inside it pointed at a file
  that did not exist, because GitHub rewrites spaces in uploaded asset names.
  Anything that stops at "latest.json parses" sees a healthy release.
* **The CDN** — a fixed manifest kept serving the broken one for minutes, so a
  check that reads once and believes the answer reports the wrong thing.

`audit()` holds the judgement and touches no network: `--self-test` replays each
of the failures above through it, so the check is known to catch them without
waiting for a bad release to happen again.
"""

import argparse
import base64
import json
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TAURI_CONF = ROOT / "windows" / "src-tauri" / "tauri.conf.json"


class TransportError(Exception):
    """Could not reach the URL at all, after retries."""


# ----------------------------------------------------------------- the rules


def audit(release: dict, manifest: dict | None, fetch, *, is_latest: bool) -> list[str]:
    """Everything that must be true of a release, given what was fetched.

    `fetch(url, limit)` returns `(status, first_bytes)` or raises. Passed in so
    the rules can be replayed against the historical failures offline.
    """
    problems: list[str] = []

    def fail(message: str) -> None:
        problems.append(message)

    tag = release.get("tag_name", "")
    version = tag.lstrip("v")

    # A draft is invisible to the /releases/latest/download/ alias every app
    # uses, so it looks published from the repository page and reaches nobody.
    if release.get("draft"):
        fail(f"{tag} is still a draft — the updater alias will not see it")

    assets = {asset["name"]: asset for asset in release.get("assets", [])}
    installers = [n for n in assets if n.endswith("-setup.exe")]
    dmgs = [n for n in assets if n.endswith(".dmg")]

    if not installers:
        fail("no Windows installer (*-setup.exe) attached")
    if not dmgs:
        fail("no macOS disk image (*.dmg) attached")
    if "latest.json" not in assets:
        fail("no latest.json attached — the Windows updater has nothing to read")
    for sums in ("SHA256SUMS-windows.txt", "SHA256SUMS-macos.txt"):
        if sums not in assets:
            fail(f"no {sums} attached — downloads cannot be verified by hand")

    # The version the artifacts were BUILT at. The tag is not evidence for it:
    # believing the tag is what published a manifest that looped.
    for name in installers + dmgs:
        found = re.search(r"[_-](\d+\.\d+\.\d+)[_.-]", name)
        if not found:
            fail(f"no version in the asset name {name}")
        elif found.group(1) != version:
            fail(f"{name} was built at {found.group(1)} but the tag says {version}")

    if manifest is None:
        fail("the updater endpoint served nothing usable — no app can update")
        return problems

    served = manifest.get("version", "")
    # Only meaningful for the newest release: an older tag is expected to
    # disagree with whatever /latest/ is serving today.
    if is_latest and served != version:
        fail(
            f"the endpoint serves version {served} but the release is {version}"
            " — an app that updates will report the older version and update again"
        )

    platform = manifest.get("platforms", {}).get("windows-x86_64", {})
    payload = platform.get("url", "")
    signature = platform.get("signature", "")

    if not payload:
        fail("the manifest names no Windows payload URL")
    else:
        if served and served not in payload:
            fail(f"the payload URL does not carry version {served}: {payload}")
        try:
            status, head = fetch(payload, 2)
            if status != 200:
                fail(f"the payload URL returns HTTP {status}")
            elif head[:2] != b"MZ":
                # A redirect to an HTML error page is also a 200.
                fail(f"the payload does not begin with an executable header (got {head!r})")
        except urllib.error.HTTPError as error:
            fail(f"the payload URL returns HTTP {error.code}: {payload}")
        except TransportError as error:
            fail(f"could not reach the payload: {error}")

    if not signature:
        fail("the manifest carries no signature — Tauri will refuse the update")
    else:
        try:
            decoded = base64.b64decode(signature, validate=True)
            if len(decoded) < 32:
                fail(f"the signature is implausibly short ({len(decoded)} bytes)")
        except Exception:  # noqa: BLE001
            fail("the signature is not valid base64")

    # The Mac updater downloads the disk image itself, so a listed-but-
    # unfetchable asset is the same failure in the other direction.
    for name in dmgs[:1]:
        url = assets[name].get("browser_download_url", "")
        try:
            status, head = fetch(url, 512)
            if status != 200:
                fail(f"{name} returns HTTP {status}")
            elif len(head) < 512:
                fail(f"{name} is too small to be a disk image")
        except urllib.error.HTTPError as error:
            fail(f"{name} returns HTTP {error.code}")
        except TransportError as error:
            fail(f"could not reach {name}: {error}")

    return problems


# -------------------------------------------------------------- the fetching


def _context() -> ssl.SSLContext:
    """A verified TLS context, using certifi when the interpreter has no store.

    Several python.org builds ship without a CA bundle. Falling back to an
    unverified context would be the wrong fix: this script exists to check what
    real users download, and skipping certificate verification is not that.
    """
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


ATTEMPTS = 4


def request(url: str, limit: int | None = None):
    """Fetches a URL with caching defeated, retrying transient failures.

    `Cache-Control` alone is not enough against every layer, so a changing query
    parameter goes on as well — a fixed manifest served its broken predecessor
    long enough to make a working fix look like a failed one.

    Retries exist for the opposite reason: a release CDN 404s for a few seconds
    after an upload, and a check that read once would fail every release.
    """
    separator = "&" if "?" in url else "?"
    last: Exception | None = None
    for attempt in range(ATTEMPTS):
        busted = f"{url}{separator}cachebust={int(time.time() * 1000)}-{attempt}"
        req = urllib.request.Request(busted)
        for header, value in [
            ("Cache-Control", "no-cache"),
            ("Pragma", "no-cache"),
            ("Accept", "*/*"),
            ("User-Agent", "display-share-release-check"),
        ]:
            req.add_header(header, value)
        try:
            with urllib.request.urlopen(req, timeout=60, context=_context()) as response:
                return response.status, (response.read(limit) if limit else response.read())
        except urllib.error.HTTPError as error:
            # 404 right after an upload is the transient case; every other 4xx
            # will say the same thing next time, so do not disguise it as slow.
            if error.code != 404 or attempt == ATTEMPTS - 1:
                raise
            last = error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            if attempt == ATTEMPTS - 1:
                # Reported, never raised as a stack trace: a network wobble has
                # to read as a diagnosis someone can act on.
                raise TransportError(f"{type(error).__name__}: {error}") from error
            last = error
        time.sleep(2 * (attempt + 1))
    raise TransportError(str(last))


def api(repo: str, path: str):
    try:
        status, body = request(f"https://api.github.com/repos/{repo}/{path}")
    except urllib.error.HTTPError as error:
        return error.code, None
    except TransportError:
        return 0, None
    return status, json.loads(body)


def detect_repo() -> str:
    remote = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        capture_output=True, text=True, cwd=ROOT,
    ).stdout.strip()
    match = re.search(r"github\.com[:/]([^/]+/[^/.]+)", remote)
    if not match:
        sys.exit("could not work out the repository from git remote origin")
    return match.group(1)


def configured_endpoint() -> str | None:
    """The updater URL the shipped app actually uses.

    Read from the config rather than restated here, so a changed endpoint is
    followed instead of quietly going unchecked.
    """
    conf = json.loads(TAURI_CONF.read_text())
    endpoints = conf["plugins"]["updater"]["endpoints"]
    return endpoints[0] if endpoints else None


# --------------------------------------------------------------- the self-test


def self_test() -> int:
    """Replays the failures this project has actually shipped."""
    healthy_release = {
        "tag_name": "v1.2.3",
        "draft": False,
        "assets": [
            {"name": "Display.Share.Receiver_1.2.3_x64-setup.exe", "browser_download_url": "u"},
            {"name": "DisplayShare-1.2.3.dmg", "browser_download_url": "d"},
            {"name": "latest.json", "browser_download_url": "m"},
            {"name": "SHA256SUMS-windows.txt", "browser_download_url": "sw"},
            {"name": "SHA256SUMS-macos.txt", "browser_download_url": "sm"},
        ],
    }
    healthy_manifest = {
        "version": "1.2.3",
        "platforms": {
            "windows-x86_64": {
                "url": "https://example/Display.Share.Receiver_1.2.3_x64-setup.exe",
                "signature": base64.b64encode(b"x" * 64).decode(),
            }
        },
    }

    def ok_fetch(url, limit):
        return 200, (b"MZ" if limit == 2 else b"\0" * limit)

    def missing(url, limit):
        if limit == 2:
            raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
        return 200, b"\0" * limit

    def html_error(url, limit):
        return 200, b"<!"[:limit]

    cases: list[tuple[str, dict, dict | None, object, bool]] = [
        ("a healthy release passes", healthy_release, healthy_manifest, ok_fetch, True),
        (
            "v0.10.0: artifacts older than the tag",
            {**healthy_release,
             "assets": [{**a, "name": a["name"].replace("1.2.3", "1.2.2")}
                        if a["name"].endswith((".exe", ".dmg")) else a
                        for a in healthy_release["assets"]]},
            healthy_manifest, ok_fetch, True,
        ),
        (
            "v0.10.0: the endpoint serves a different version",
            healthy_release, {**healthy_manifest, "version": "1.2.2"}, ok_fetch, True,
        ),
        ("the 404: manifest fine, payload missing", healthy_release, healthy_manifest, missing, True),
        ("the payload is an HTML error page", healthy_release, healthy_manifest, html_error, True),
        (
            "no signature, so Tauri refuses the update",
            healthy_release,
            {**healthy_manifest,
             "platforms": {"windows-x86_64": {**healthy_manifest["platforms"]["windows-x86_64"],
                                              "signature": ""}}},
            ok_fetch, True,
        ),
        ("a draft release reaches nobody", {**healthy_release, "draft": True},
         healthy_manifest, ok_fetch, True),
        ("no disk image, so the Mac cannot update",
         {**healthy_release,
          "assets": [a for a in healthy_release["assets"] if not a["name"].endswith(".dmg")]},
         healthy_manifest, ok_fetch, True),
        ("the endpoint served nothing", healthy_release, None, ok_fetch, True),
    ]

    failures = 0
    for name, release, manifest, fetch, is_latest in cases:
        found = audit(release, manifest, fetch, is_latest=is_latest)
        should_pass = name.startswith("a healthy")
        if should_pass and found:
            print(f"  FAIL  {name}: unexpectedly reported {found}")
            failures += 1
        elif not should_pass and not found:
            print(f"  FAIL  {name}: NOT CAUGHT")
            failures += 1
        else:
            detail = "clean" if should_pass else found[0]
            print(f"  ok    {name}\n          → {detail}")

    print()
    if failures:
        print(f"self-test: {failures} of {len(cases)} cases wrong")
        return 1
    print(f"self-test: {len(cases)} cases, every known failure caught")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="release tag; defaults to the latest release")
    parser.add_argument("--repo", help="owner/name; defaults to git remote origin")
    parser.add_argument("--self-test", action="store_true", help="replay known failures, no network")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    repo = args.repo or detect_repo()
    print(f"repository: {repo}")

    path = f"releases/tags/{args.tag}" if args.tag else "releases/latest"
    status, release = api(repo, path)
    if status != 200 or release is None:
        print(f"FAIL: no release at {path} (HTTP {status})")
        return 1

    tag = release["tag_name"]
    print(f"release: {tag}")

    latest_status, latest = api(repo, "releases/latest")
    is_latest = latest_status == 200 and latest is not None and latest.get("id") == release.get("id")
    print(f"is the latest release: {is_latest}")

    endpoint = configured_endpoint()
    print(f"updater endpoint: {endpoint}")
    manifest = None
    if endpoint:
        try:
            code, body = request(endpoint)
            manifest = json.loads(body) if code == 200 else None
        except (urllib.error.HTTPError, TransportError, json.JSONDecodeError) as error:
            print(f"  could not read the updater endpoint: {error}")

    if manifest:
        print(f"manifest version: {manifest.get('version')}")

    problems = audit(release, manifest, request, is_latest=is_latest)

    print()
    if problems:
        print(f"FAIL: {len(problems)} problem(s) with {tag}:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"ok: {tag} is published, complete, and reachable by both updaters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
