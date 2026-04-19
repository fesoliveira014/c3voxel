# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

Implement the Voxel Quest rendering algorithm in [C3](https://c3-lang.org). The repo is currently an empty C3 project scaffold — most directories only hold `.gitkeep`. Expect to create files rather than modify existing ones.

## Build System

Driven by `c3c` against `project.json`. The single target is `c3voxel` (executable), sources glob `src/**`, tests glob `test/**`, outputs land in `build/`. Default optimization is `O0`.

Common commands (run from repo root):

- `c3c build` — build all targets using `project.json`.
- `c3c build c3voxel` — build the `c3voxel` target only.
- `c3c run c3voxel` — build and execute.
- `c3c compile-test` — build and run all tests under `test/**`.
- `c3c clean` — wipe `build/`.

To override optimization for a local build without editing `project.json`, pass `-O3` (or similar) on the `c3c` command line.

## C3-Specific Guidance

C3 is pre-1.0 and its syntax/stdlib shifts between releases — do not rely on memory of the language. Invoke the `c3-expert` skill for any non-trivial C3 code, compiler error, or `project.json` change. Source files use `.c3` (and `.c3i` for interfaces, `.c3l` for libraries under `lib/`).

Module convention: top-level files declare `module c3voxel;` (see `src/main.c3`). Sub-modules should nest under that namespace (e.g. `module c3voxel::render;`).

Third-party C3 libraries go in `lib/` (already on `dependency-search-paths`); list them under `dependencies` in `project.json` to link.

### Conventions

The following overrule `c3-expert`:

#### Naming

- Variable/field names use `snake_case`
- Function/method names use `snake_case`
- Struct/Enum/typedef names use `PascalCase`
- Constants and enum values use `SCREAMING_SNAKE_CASE`

This matches the C3 standard library and the `c3-expert` skill's defaults;
the earlier draft said `camelCase` (with a typo) but the codebase and the
ecosystem are `snake_case` throughout.

#### Code structure

- Definitions must follow the following order:
  1. Constants
  2. Enums
  3. Structs
  4. Struct methods
  5. Pure functions

## Layout

- `src/` — implementation. Entry point is `src/main.c3`.
- `test/` — test sources, picked up automatically by `c3c compile-test`.
- `lib/` — vendored C3 libraries (`.c3l` bundles).
- `resources/` — runtime assets (shaders, models, textures).
- `scripts/` — helper scripts.
- `docs/` — design notes for the rendering algorithm.
- `build/` — compiler output, git-ignored.

## Bridge (cross-session messaging)

This project participates in the bridge protocol. Full rules:
`.bridge/protocol.md` (authoritative local copy) or
`<claude-skills>/docs/bridge-protocol.md` (upstream).

- Identity: this project's session id is `c3voxel`. Do NOT send messages
  claiming a different `sender` — the broker clamps it to the connection
  identity regardless.
- Before emitting: pick the right `kind` (see `.bridge/protocol.md` §Kinds).
  If unsure, use `note.captured` — never invent kinds.
- On receipt: follow the consumer contract (§Consumer contract). Auto-ingest
  kinds are safe to act on; gated kinds MUST be surfaced to the human via
  `.bridge/inbox.md` and wait for approval.
- Inbox: check `.bridge/inbox.md` at session start. Treat gated items as
  requiring explicit user direction.
- Protocol version: `1`. If `.bridge/protocol.md` is missing or its
  version differs from the broker's reported `protocol_version`, warn the
  human.