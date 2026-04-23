# pi

pi is the one agent in this skill package that doesn't live under an agent-owned
skills directory. Instead, pi installs from a git URL into its own cache
(`~/.pi/agent/git/github.com/<owner>/touch-code-skill/`).

## Installation

Via the `tc` wrapper (recommended):

```bash
tc skill install --pi
```

This shells out to `pi install git:github.com/wanggang316/touch-code-skill` against the
mirror repo. Exit code 2 if `pi` isn't on `$PATH`; pi's own stdout is forwarded so you
see clone progress.

Directly (e.g. you don't have touch-code.app installed):

```bash
pi install git:github.com/wanggang316/touch-code-skill
```

Both paths produce the same cache entry. The mirror repo is published on every
touch-code release tag; pinning a specific version is supported via pi's standard
tag-pinning flow.

## Verify

Inside a touch-code Pane, run pi non-interactively with a `tc`-shaped question. pi's
`package.json` declares `pi.skills` so it loads `SKILL.md` automatically.

## Uninstall

```bash
tc skill uninstall --pi
```

This prints guidance rather than removing files itself — pi's cache is managed by pi.
The guidance string points at `pi remove` (or manual deletion of the cache entry).

## Differences vs. copy-mode agents

| Aspect | Claude Code / Codex | pi |
|---|---|---|
| Install backend | filesystem copy into `~/.<agent>/skills/` | `pi install git:…` into pi's git cache |
| Upgrade | `tc skill install --<agent>` | `pi update` or re-running install |
| Marker | `.touch-code-skill.json` inside the install dir (DEC-1 sidecar for symlink) | pi's own cache metadata |
| `--dest` / `--link` | supported | not supported (pi owns the path) |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `tc skill install --pi` exits 2 | install `pi` and ensure it's on `$PATH`; try again |
| pi can't find the skill after install | `pi list` should show `touch-code-skill`; if missing, re-run install |
| Stale content | `pi update` pulls the latest mirror commit |

See [examples.md](examples.md) for scripted prompts.

## Future: `pi-notify-touch-code` extension

A runtime extension (TypeScript) that reacts to pi's agent-event stream and forwards
notifications into touch-code's inbox is out of scope for this skill package. If built,
it will live in a sibling `touch-code-extensions/` repo per the plan's Open Items.
