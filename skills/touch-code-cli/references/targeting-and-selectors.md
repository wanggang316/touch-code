# Targeting and Selectors

Inside a touch-code Pane, most `tc` commands resolve their target from the ambient
environment — pass an explicit selector or UUID only when you need to act on a
*different* Pane / Tab / Worktree than the one you're typing from.

Every `tc` command that operates on a node accepts a target in one of three forms:

1. **Selector** — 1-based numeric path (`1/2/3`). Short; matches `index` from
   `tc ls --json`. Reorder-sensitive.
2. **UUID** — stable identifier from the `id` field. Preferred in scripts.
3. **Ambient** — omit the target entirely; `tc` resolves it from `$TOUCH_CODE_PANE_ID`
   / `$TOUCH_CODE_TAB_ID` / `$TOUCH_CODE_WORKTREE_ID` in the invocation's environment.

## Ambient targeting

When a command runs inside a touch-code Pane, most subcommands can omit the target:

```bash
tc pane focus        # focuses the current Pane
tc tab focus          # focuses the current Tab
tc worktree focus     # focuses the current Worktree
tc tab new            # creates a Tab in the current Worktree
tc pane split right  # splits the current Pane
```

Outside touch-code (e.g. a login shell that wasn't spawned by the app), the ambient
env vars are unset; pass an explicit target.

## Selector forms by family

```bash
tc space focus 1
tc space focus <space-uuid>

tc worktree focus 1/2/1
tc worktree focus <worktree-uuid>

tc tab focus 1/2/1/3
tc tab focus <tab-uuid>

tc pane focus 1/2/1/3/2
tc pane focus <pane-uuid>
```

## `--in` for targeted creation

Creation commands use `--in` to say where the new node should live. The target is the
**parent**, one level above the node being created.

```bash
tc tab new --in 1/2/1 -- git status          # Tab inside Worktree 1/2/1
tc tab new --in <worktree-uuid> --focus -- npm run dev

tc pane split --in 1/2/1/3 right            # split the current pane inside Tab 3
tc pane split --in <pane-uuid> down -- tail -f /tmp/server.log
```

Trailing arguments after `--` on `tc tab new` and `tc pane split` are treated as a
command and its arguments — the shell doesn't see them. Use `--script` to pass a raw
shell script instead.

## Creation JSON

Mutation commands support `--json` to emit structured IDs for chaining:

```bash
tc tab new --json -- npm run dev
```

```json
{
  "spaceID":     "BBBDD2AB-3F53-4BCA-B120-CE4A5E8C7F18",
  "projectID":   "AB9E0A59-…",
  "worktreeID":  "…",
  "tabID":       "3734DE02-…",
  "paneID":      "5E6E9773-…",
  "tabIndex":    4,
  "paneIndex":   1
}
```

Use `tabID` or `paneID` from creation output when chaining follow-up commands like
`tc pane split --in <tabID>` or `tc pane send <paneID> …`.

`tc ls --json` returns the full tree; its per-node `id` is the UUID and `index` is the
selector component.

## Target rules by family

| Command family | Accepted target |
|---|---|
| `tc space focus / rename / close` | Space selector or UUID |
| `tc tab focus / close / rename` | Tab selector or UUID |
| `tc tab next / prev / last` | optional Space selector or UUID |
| `tc pane focus / close / capture / resize / notify` | Pane selector or UUID |
| `tc pane split` | Tab or Pane selector/UUID (via `--in`) |
| `tc pane send` | optional Pane selector or UUID (first arg; stdin fallback) |
| `tc send` / `tc broadcast` | Pane or Tab selector/UUID |
