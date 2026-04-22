# touch-code

## Quick Start

```bash
# One-time per worktree (fresh clone or `git worktree add`)
mise trust . apps/mac                           # trust mise config for this + apps/mac cwd
make bootstrap                                  # init submodules (ghostty, git-wt) + mise install (tuist/zig/swiftlint/xcbeautify/xcsift)

# Build / run
make mac-generate                               # tuist install + tuist generate (transitively builds Ghostty xcframework)
make mac-build                                  # build touch-code.app + tc CLI
make mac-run-app                                # build + open the app

# Code hygiene
make mac-lint                                   # swiftlint --quiet
make mac-check                                  # swift-format in-place + lint
```

Multi-worktree tip: `ln -s <main>/apps/mac/.build/ghostty apps/mac/.build/ghostty` avoids re-compiling Ghostty (~3.9 GB, ~20 min first time) in every new worktree. `build-ghostty.sh` primes Zig's cache via curl automatically (Zig 0.15.2's TLS handshake is rejected by Cloudflare on `deps.files.ghostty.org`; the prime step is idempotent and a no-op on cache hits).

Requires Xcode **26.0+** (pinned via `apps/mac/Tuist.swift: compatibleXcodeVersions: .upToNextMajor("26.0")`).

## Architecture Overview

<!-- One paragraph: what the system does, architectural style, key domains -->

See [Architecture](docs/architecture.md) for domains, layers, and dependency rules.

## Repository Structure

<!-- Directory tree with one-line comment per directory. Reflect actual layout -->

```
touch-code/
├── src/                        # Source
├── tests/                      # Test suites
├── docs/                       # Project documentation
└── .github/workflows/          # CI workflows
```

## Golden Rules

<!-- Top 5 rules inline. Link to full list for the rest -->

1. **AGENTS.md is a map, not a manual** — keep this file under 150 lines
2. **Validate boundaries** — parse and validate data at system edges, never probe
3. **Prefer shared utilities** — centralize invariants, avoid hand-rolled duplicates
4. **Every complex change gets an execution plan** — plan before building
5. **Fix the environment, not the prompt** — when agents struggle, add missing tools/docs/guardrails

See [Golden Rules](docs/golden-rules.md) for the complete list with rationale and enforcement.

## Documentation

<!-- Table of docs/ subdirectories. Start with the area relevant to your task -->

| Directory | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System architecture, domains, layers |
| [docs/golden-rules.md](docs/golden-rules.md) | Enforced principles and conventions |
| [docs/design-docs/](docs/design-docs/) | Design documents |
| [docs/exec-plans/](docs/exec-plans/) | Execution plans for complex work |
| [docs/product-specs/](docs/product-specs/) | Product specifications |
| [docs/references/](docs/references/) | External docs, API references |
| [docs/generated/](docs/generated/) | Auto-generated artifacts |

## Working with This Repository

<!-- Key workflows and boundaries -->

- Before making changes, read the relevant docs for the area you're touching
- For complex work, create an execution plan before starting
- Run lint and tests before submitting PRs
- Follow the dependency rules in architecture docs
- When something fails, ask: "What capability is missing?" — then add it

## Build & Test Commands

See [Quick Start](#quick-start). Top-level Makefile delegates every `mac-*` target to `apps/mac/Makefile`. Run `make help` for the full list.

## Code Style & Conventions

<!-- Key coding conventions, one per line -->

- [Linter/formatter tool and key settings]
- [Key code patterns or conventions]
- [Naming conventions]
