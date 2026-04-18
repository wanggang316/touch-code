# touch-code

## Quick Start

<!-- The 3-4 commands an agent needs to build, test, and lint -->

```bash
<build command>
<lint command>
<test command>
```

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

<!-- Full commands with inline comments -->

```bash
<build command>          # Build project
<lint command>           # Run linter
<test command>           # Run tests
```

## Code Style & Conventions

<!-- Key coding conventions, one per line -->

- [Linter/formatter tool and key settings]
- [Key code patterns or conventions]
- [Naming conventions]
