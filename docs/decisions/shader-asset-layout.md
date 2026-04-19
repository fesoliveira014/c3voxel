---
title: Shader asset layout — resources/shaders/ source + resources/shaders/build/ SPIR-V
thread_id: decision/shader-asset-layout
logged_at: 2026-04-19
commit: dccc1f4
---

## Context

Shaders were initially scaffolded under `src/shaders/`, which put runtime
assets into the compiled-source tree. `CLAUDE.md`'s layout section
already reserves `resources/` for runtime assets (shaders, models,
textures). Before M4 adds more compute passes (jump-flood distance
field) and their SPIR-V artefacts, we wanted to stop compounding the
mistake.

## Decision

- GLSL source files live at `resources/shaders/*.glsl`.
- Compiled SPIR-V artefacts land at `resources/shaders/build/*.spv`,
  created on demand by the shader loader via `path::mkdir(...,
  recursive: true)`.
- `gpu::shader` introduces a `SHADER_BUILD_DIR` module constant and
  derives `spv_path` from the GLSL basename, so the build dir is
  configurable in one place.

## Consequences

- Source-vs-artefact separation is now explicit.
- `.gitignore` tightened: root `/build/` (c3c output) stays ignored,
  `resources/shaders/build/*.spv` ignored by name, but the directory
  itself and its `.gitkeep` are tracked so the path exists after a
  fresh clone.
- Shader path constants in `src/main.c3` and
  `src/voxel/{generate,raymarch}.c3` updated to the
  `resources/shaders/` prefix.
- Future runtime assets (model meshes, texture files, palettes) should
  follow the same pattern under `resources/`.

## References

- Commit: `dccc1f4` — "Move shaders under resources/, build SPIR-V into resources/shaders/build"
- Bridge message id: `35`
