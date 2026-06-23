# Domain documentation layout

This repo uses the **single‑context** layout: one root‑level `CONTEXT.md` file and a `docs/adr/` directory.  There is no `CONTEXT-MAP.md`, so architecture decisions and context information are stored directly under the project root.

The engineering skills will look for:

- `CONTEXT.md` at the repo root for terminology.
- `docs/adr/` at the repo root for all Architectural Decision Records.

If you add multiple contexts later, update this file and create a `CONTEXT-MAP.md` that maps each context name to its `CONTEXT.md`.