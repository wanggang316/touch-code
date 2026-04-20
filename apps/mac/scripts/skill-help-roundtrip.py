#!/usr/bin/env python3
"""
Tier-A check: every `tc <subcommand>` string referenced in the skill's markdown must
exist in the `tc help-json` dump. Fails with a diff when the skill claims a subcommand
the binary no longer exposes (e.g. a rename). Allows the binary to have extra unused
subcommands — the skill is the consumer contract, not the binary's shape.

Usage:
  skill-help-roundtrip.py <references-dir> <tc-help-json>

Exit codes:
  0 — every referenced subcommand resolves to a node in tc help-json
  1 — at least one referenced subcommand is missing
  2 — input error (missing file / bad JSON)
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def collect_commands(node: dict, prefix: str = "") -> set[str]:
    """Flatten the tc help-json tree into {"tc", "tc skill", "tc skill install", ...}."""
    name = node.get("name", "")
    full = f"{prefix} {name}".strip() if prefix else name
    paths = {full}
    for child in node.get("subcommands", []):
        paths |= collect_commands(child, full)
    return paths


# Only match `tc <subcommand>` tokens that live inside a fenced code block or an inline
# backtick span. Prose like "run tc foo first" without backticks is intentionally
# ignored — a real CLI claim is always set in `backticks` or a ``` fenced block by
# convention. This keeps the check strict about what counts as a contract assertion.
TC_IN_CODE_RE = re.compile(r"\btc(?:\s+[a-z][a-z0-9-]*)+", re.IGNORECASE)
FENCE_RE = re.compile(r"^```")
INLINE_CODE_RE = re.compile(r"`([^`]+)`")


def find_references(dir_path: Path) -> dict[str, list[tuple[Path, int]]]:
    """Walk every .md under dir_path and yield every code-scope `tc …` mention."""
    refs: dict[str, list[tuple[Path, int]]] = {}
    for md in sorted(dir_path.rglob("*.md")):
        with md.open("r", encoding="utf-8") as fh:
            in_fence = False
            for lineno, line in enumerate(fh, start=1):
                if FENCE_RE.match(line.lstrip()):
                    in_fence = not in_fence
                    continue
                segments: list[str] = []
                if in_fence:
                    segments.append(line)
                else:
                    # Inline spans only; everything outside backticks is prose.
                    segments.extend(INLINE_CODE_RE.findall(line))
                for segment in segments:
                    for match in TC_IN_CODE_RE.finditer(segment):
                        token = normalise(match.group(0))
                        if token is None:
                            continue
                        refs.setdefault(token, []).append((md, lineno))
    return refs


# Commands that are known to appear in examples but aren't real subcommands (global
# flags, option words that happened to follow "tc"). Gated here rather than scattered
# through the markdown.
IGNORED_TOKENS = {
    "tc --help",
    "tc --version",
    "tc help",
}


# Subcommand subtrees that are documented as planned but not yet implemented in `tc`.
# A reference under any of these prefixes is treated as satisfied even if `tc help-json`
# doesn't list it, so the skill can teach the full product surface ahead of C1-C4
# landing. Each entry is paired with the exec plan that delivers it, so when that plan
# ships we delete the entry and the checker starts demanding the real subcommand.
PLANNED_TOKENS: dict[str, str] = {
    "tc ls":       "exec plan 0002 (Terminal + Hierarchy)",
    "tc space":    "exec plan 0002",
    "tc worktree": "exec plan 0002",
    "tc tab":      "exec plan 0002",
    "tc panel":    "exec plan 0002",
    "tc send":     "exec plan 0003 (C4 CLI)",
    "tc broadcast":"exec plan 0003",
    "tc open":     "exec plan 0003",
    "tc agent":    "exec plan 0003",
}


def normalise(raw: str) -> str | None:
    """Return the canonical "tc …" command path, or None if it should be skipped."""
    tokens = raw.split()
    # Drop -- flag segments past the first subcommand token.
    cleaned: list[str] = []
    for token in tokens:
        if token.startswith("-"):
            break
        cleaned.append(token.lower())
    if len(cleaned) < 2:
        return None  # just "tc" alone — no subcommand claim
    normalised = " ".join(cleaned)
    if normalised in IGNORED_TOKENS:
        return None
    return normalised


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    refs_dir = Path(sys.argv[1])
    help_json = Path(sys.argv[2])
    if not refs_dir.is_dir():
        print(f"references dir not found: {refs_dir}", file=sys.stderr)
        return 2
    if not help_json.is_file():
        print(f"help-json not found: {help_json}", file=sys.stderr)
        return 2

    try:
        tree = json.loads(help_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"help-json invalid: {exc}", file=sys.stderr)
        return 2

    known = collect_commands(tree)
    references = find_references(refs_dir)

    unknown: list[tuple[str, list[tuple[Path, int]]]] = []
    planned_hit = 0
    for cmd, locs in sorted(references.items()):
        if cmd in known:
            continue
        if matches_planned_prefix(cmd):
            planned_hit += 1
            continue
        unknown.append((cmd, locs))

    if not references:
        print("skill-help-roundtrip: no `tc …` references in markdown yet (M8 writes content)")
        return 0

    if unknown:
        print("skill-help-roundtrip: references to unknown tc subcommands:", file=sys.stderr)
        for cmd, locs in unknown:
            for path, line in locs:
                print(f"  {path}:{line}: {cmd}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Known commands:", file=sys.stderr)
        for cmd in sorted(known):
            print(f"  {cmd}", file=sys.stderr)
        if PLANNED_TOKENS:
            print("", file=sys.stderr)
            print("Planned (allowed) subtrees:", file=sys.stderr)
            for prefix, owner in sorted(PLANNED_TOKENS.items()):
                print(f"  {prefix}  — {owner}", file=sys.stderr)
        return 1

    shipped = len(references) - planned_hit
    print(
        f"skill-help-roundtrip: {shipped} shipped + {planned_hit} planned reference(s) "
        f"verified"
    )
    return 0


def matches_planned_prefix(command: str) -> bool:
    """Return True if `command` falls under one of PLANNED_TOKENS' subtrees."""
    for prefix in PLANNED_TOKENS:
        if command == prefix or command.startswith(prefix + " "):
            return True
    return False


if __name__ == "__main__":
    sys.exit(main())
