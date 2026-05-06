# touch-code

A native macOS app that orchestrates terminals into a four-level hierarchy — Project → Worktree → Tab → Pane — for CLI-agent power users. Ships with the `tc` companion CLI and a published Agent Skill, all built from a Tuist-managed monorepo.

## Requirements

- macOS with Xcode **26.0+** (pinned via `apps/mac/Tuist.swift`)
- [`mise`](https://mise.jdx.dev/) for tool version pinning (`tuist`, `zig`, `swiftlint`, `xcbeautify`, `xcsift`)

## Quick Start

```bash
# One-time per worktree
mise trust . apps/mac
make bootstrap            # init submodules (ghostty, git-wt) + mise install

# Generate + build + run
make mac-generate         # tuist install + tuist generate (builds Ghostty xcframework)
make mac-build            # build TouchCode.app + tc CLI
make mac-run-app          # build + open the app
```

> First-time Ghostty build is ~3.9 GB / ~20 min. In additional worktrees, symlink the cache:
> `ln -s <main>/apps/mac/.build/ghostty apps/mac/.build/ghostty`

## Commands

| Command | Description |
|---|---|
| `make bootstrap` | Init submodules + `mise install` |
| `make mac-generate` | Generate `touch-code.xcworkspace` from Tuist |
| `make mac-build` | Build the Mac app + `tc` CLI |
| `make mac-run-app` | Build and launch `TouchCode.app` |
| `make mac-lint` | Run `swiftlint --quiet` |
| `make mac-check` | `swift-format` in-place + lint |
| `make mac-test` | Run test bundles (placeholder) |
| `make mac-release` | Archive → notarize → DMG → staple |
| `make help` | Full target list |

The top-level `Makefile` delegates every `mac-*` target to `apps/mac/Makefile`.

## Documentation

All project knowledge lives in [`docs/`](docs/):

- [Golden Rules](docs/golden-rules.md) — non-negotiable principles
- [Architecture](docs/architecture.md) — domains, layers, dependency rules
- [Product specs](docs/product-specs/) — what the product is
- [Design docs](docs/design-docs/) — feature and system designs
- [Execution plans](docs/exec-plans/) — versioned plans with progress

Agent-facing entry point: [`AGENTS.md`](AGENTS.md) (also exposed as `CLAUDE.md`).

## License

See [`NOTICES.md`](NOTICES.md) for third-party attributions.
