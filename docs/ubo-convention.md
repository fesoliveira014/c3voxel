# UBO std140 Convention

All Uniform Buffer Object structs shared with GLSL shaders follow `std140`
layout. C3 does not generate std140 layouts automatically, so we pin the
layout by hand and guard it with `$assert`.

## Rules

1. Struct attribute: `@packed @align(16)`.
2. Allowed field types:
   - `core::Vec4`, `core::IVec4` (16 B each)
   - `core::Vec4[N]`, `core::IVec4[N]` (arrays of 16 B elements)
   - scalar `float`, `int`, `uint` (4 B)
   - `float[N]`, `int[N]` used only as explicit padding
   - nested structs that themselves follow this convention
3. **No `core::Vec3`.** std140 rounds `vec3` up to 16 B but `float[3]` does
   not — mismatches silently corrupt the first field after the vec3. Either
   pad to `Vec4` or split into three scalars.
4. Arrays only of 16-byte-aligned element types (`Vec4`, `IVec4`, or
   compatible nested structs). std140 pads every array element to 16 B, so
   `float[N]` in a UBO is an escape hatch for trailing pad bytes only.
5. After all real fields, add a trailing `_pad` array of `float` / `int`
   such that the total struct size is a multiple of 16.
6. At module scope, assert the struct is 16-aligned:
   ```c3
   $assert(MyUniforms.sizeof % 16 == 0);
   ```
7. In GLSL, bind the UBO at an explicit binding index and match the field
   order + types exactly.

## Promotion Path

This doc + `$assert` is deliberately minimal. Four UBOs today
(`GenerateUniforms`, `RayMarchUniforms`, `CompositeUniforms`,
`DistanceFieldStepUniforms`). If a fifth lands, promote to a macro:

```c3
macro @std140(#s) { ... }   // walks fields, emits per-field offset asserts
```

That buys per-field alignment guarantees instead of just total-size.

## Checklist for a New UBO

- [ ] Struct has `@packed @align(16)`.
- [ ] No `Vec3` fields.
- [ ] Trailing `_pad` makes size a multiple of 16.
- [ ] `$assert(T.sizeof % 16 == 0)` at module scope.
- [ ] Comment block references this file + promotion note.
- [ ] GLSL counterpart binding, field order, and types match.
