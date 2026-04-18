# Documentation

This directory is the **system of record** for all project knowledge. If it's not here, it doesn't exist to the agent.

## Structure

| Directory / File | Purpose |
|---|---|
| [architecture.md](architecture.md) | System architecture, domains, layers |
| [golden-rules.md](golden-rules.md) | Enforced principles and conventions |
| [product-specs/](product-specs/) | Product specifications and requirements |
| [design-docs/](design-docs/) | Feature and system design documentation |
| [exec-plans/](exec-plans/) | Versioned execution plans with progress |
| [references/](references/) | External references, API docs, integration notes |
| [generated/](generated/) | Auto-generated artifacts — do not edit manually |

## Conventions

- Every document should be self-contained enough for an agent to act on it
- Use relative links between documents
- Keep documents focused: one concept per file
- Mark documents as deprecated rather than deleting them
