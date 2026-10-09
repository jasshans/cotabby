#!/usr/bin/env python3
"""Build a small HTML changelog for one Ghostype release.

The release job calls this before generating the appcast. It collects the commit
subjects landed since the previous "Bump version" commit (i.e. everything this
release ships on top of the last one), filters out the mechanical bump commits,
and renders a minimal HTML fragment. That fragment is embedded inline in the
appcast's <description> element, so Sparkle's update dialog shows plain release
notes instead of rendering the GitHub release page in a web view.

Why its own file: turning git history into safe HTML (escaping, CDATA safety,
empty-range fallback) is a pure text transformation. Keeping it out of the
workflow YAML and out of generate_appcast.py (which stays a dumb template
renderer with explicit inputs) makes both easier to test and reason about.
"""

from __future__ import annotations

import argparse
import html
import subprocess
import sys


def run_git(*args: str) -> str:
    process = subprocess.run(
        ["git", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed:\n{process.stderr.strip()}")
    return process.stdout


def previous_bump_commit() -> str | None:
    """Hash of the version-bump commit before the current one, if any."""
    output = run_git("log", "--format=%H", "--grep=^Bump version", "-n", "2")
    hashes = [line.strip() for line in output.splitlines() if line.strip()]
    # hashes[0] is this run's own bump commit; hashes[1] is the previous release's.
    return hashes[1] if len(hashes) == 2 else None


def subjects_since(ref: str | None) -> list[str]:
    """Commit subjects in <ref>..HEAD, minus the mechanical bump commits."""
    rev_range = f"{ref}..HEAD" if ref else "HEAD"
    # Bound the fallback so a missing bump marker can't dump the whole history.
    args = ["log", "--format=%s", rev_range, "--max-count=30"] if ref is None else [
        "log", "--format=%s", rev_range,
    ]
    output = run_git(*args)
    return [
        line.strip()
        for line in output.splitlines()
        if line.strip() and not line.strip().startswith("Bump version")
    ]


def render_html(version: str, subjects: list[str]) -> str:
    """Minimal HTML fragment. Sparkle renders it in the update dialog's notes pane."""
    safe_version = html.escape(version, quote=False)
    if subjects:
        items = "\n".join(f"<li>{html.escape(s, quote=False)}</li>" for s in subjects)
        body = f"<ul>\n{items}\n</ul>"
    else:
        body = "<p>Internal maintenance and build improvements.</p>"
    fragment = f"<h3>What\u2019s new in {safe_version}</h3>\n{body}\n"
    # The fragment is embedded in a CDATA section; make sure it can't terminate it.
    return fragment.replace("]]>", "]]&gt;")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Ghostype release notes HTML.")
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 0.1.3")
    parser.add_argument("--build", required=True, help="Build number, e.g. 15")
    parser.add_argument("--output", required=True, help="Where to write the HTML fragment")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    subjects = subjects_since(previous_bump_commit())
    fragment = render_html(args.version, subjects)
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(fragment)
    print(f"Wrote release notes for {args.version} ({len(subjects)} change(s)) -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
