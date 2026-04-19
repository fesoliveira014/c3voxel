# Specification: Perlin / Simplex Noise + Multi-Octave fBm in C3

A module providing gradient-noise primitives (classic Perlin and simplex) with configurable multi-octave fractional Brownian motion on top. The target module is `vq::core::noise`.

This is a specification, not an implementation. It defines the API surface, algorithmic contracts, numerical properties, test vectors, and references. A developer with moderate graphics-programming familiarity should be able to implement it from this document plus the cited sources.

---

## 1. Scope and Non-Goals

### In scope
- Classic Perlin noise (Ken Perlin's 2002 "Improved Noise" variant) in 2D, 3D, and 4D.
- Simplex noise (Perlin's 2001 "Hardware Noise" variant, per Gustavson's reference) in 2D, 3D, and 4D.
- Multi-octave fBm built on top of both, with `octaves`, `persistence`, `lacunarity`, `scale` parameters.
- Seeded permutation tables so that different worlds / regions produce different noise.
- Deterministic across platforms and compiler versions.

### Out of scope
- 1D noise (not needed for our use case; trivially derivable by setting `y = 0` if ever needed).
- Higher dimensions (5D+).
- Non-fractal noise primitives (Worley, Gabor, wavelet noise).
- Analytic derivatives. These are useful for terrain normal computation but complicate the API; we'll add them as a separate `noise_grad` module if needed.
- GPU (GLSL) implementations. Those go in shader code separately, following Ashima/McEwan's approach [Ref 10].
- SIMD vectorization in the first version. Scalar correct-first, then optimize.

---

## 2. Module Layout

```
src/core/
├── noise.c3           // public API, fBm, the two noise functions
├── noise_perlin.c3    // @private — classic Perlin implementation
├── noise_simplex.c3   // @private — simplex implementation
└── noise_tables.c3    // @private — permutation table, constants
```

Everything outside of `noise.c3` is `@private` to the module. External callers only see `vq::core::noise::perlin2/3/4`, `simplex2/3/4`, `fbm2/3/4` plus the `Noise` struct.

---

## 3. Public API

### 3.1 The `Noise` Struct

```c3
module vq::core::noise;

// Holds a seeded permutation table. Users should create one per noise "world"
// or per logically-distinct noise stream. Two Noise instances with the same
// seed produce identical output.
struct Noise {
    char[512] perm;  // permutation table, doubled to 512 (see §5.1)
}

// Initialize from a 64-bit seed. Uses an internal deterministic PRNG
// (see §5.2) to shuffle 0..255, then duplicates the table.
fn void Noise.init(&self, ulong seed);

// Re-seed an existing Noise. Useful for regenerating without allocating.
fn void Noise.reseed(&self, ulong seed);
```

The `perm` field is exposed as a `char[512]` rather than being opaque. This is deliberate: it's the natural representation (256 permuted bytes, duplicated), it makes the struct trivially copyable, and it makes test reproducibility obvious. Callers should not modify it directly, but we don't bother hiding it behind a typedef.

### 3.2 Primitive Noise Functions

```c3
// Classic Perlin (Improved 2002 variant). Output in approximately [-1, 1].
fn float Noise.perlin2(&self, float x, float y);
fn float Noise.perlin3(&self, float x, float y, float z);
fn float Noise.perlin4(&self, float x, float y, float z, float w);

// Simplex noise. Output in approximately [-1, 1].
fn float Noise.simplex2(&self, float x, float y);
fn float Noise.simplex3(&self, float x, float y, float z);
fn float Noise.simplex4(&self, float x, float y, float z, float w);
```

### 3.3 fBm (Multi-Octave)

```c3
// fBm parameters. Defaults match common procedural-terrain conventions.
struct FbmParams {
    int   octaves;      // default: 4.   Number of noise layers to sum.
    float persistence;  // default: 0.5. Amplitude multiplier per octave.
    float lacunarity;   // default: 2.0. Frequency multiplier per octave.
    float scale;        // default: 1.0. Base frequency.
}

const FbmParams FBM_DEFAULT = { .octaves = 4, .persistence = 0.5, .lacunarity = 2.0, .scale = 1.0 };

// fBm over classic Perlin. Output normalized to approximately [-1, 1].
fn float Noise.fbm_perlin2(&self, float x, float y, FbmParams p);
fn float Noise.fbm_perlin3(&self, float x, float y, float z, FbmParams p);
fn float Noise.fbm_perlin4(&self, float x, float y, float z, float w, FbmParams p);

// fBm over simplex.
fn float Noise.fbm_simplex2(&self, float x, float y, FbmParams p);
fn float Noise.fbm_simplex3(&self, float x, float y, float z, FbmParams p);
fn float Noise.fbm_simplex4(&self, float x, float y, float z, float w, FbmParams p);

// Convenience: scale fBm output to a specific range.
fn float Noise.fbm_perlin2_ranged(&self, float x, float y, float lo, float hi, FbmParams p);
// ... and similarly for others.
```

### 3.4 Usage Sketch

```c3
import vq::core::noise;

Noise n;
n.init(0xDEADBEEF);

// Single-octave 3D noise
float v = n.simplex3(pos.x * 0.01, pos.y * 0.01, pos.z * 0.01);

// Multi-octave 2D terrain heightmap with default params
FbmParams p = FBM_DEFAULT;
p.octaves = 6;
p.scale = 0.005;
float height = n.fbm_simplex2(world_x, world_y, p);

// Scaled output
float temperature = n.fbm_perlin2_ranged(x, y, -20.0, 35.0, FBM_DEFAULT);
```

---

## 4. Algorithmic Contracts

### 4.1 Output Range

| Function | Theoretical range | Practical observed range |
|----------|-------------------|--------------------------|
| `perlin2` | `[-√(N/4), +√(N/4)]` = `[-0.707, +0.707]` | ≈ `[-1, 1]` after normalization constant (see §6.1) |
| `perlin3` | bounded, slightly less than 1 | ≈ `[-1, 1]` |
| `perlin4` | bounded | ≈ `[-1, 1]` |
| `simplex2`, `simplex3`, `simplex4` | exactly bounded by normalization factor | ≈ `[-1, 1]` |

All functions **must** include the conventional normalization constant to map output to approximately `[-1, 1]`. See §6.1 for specifics.

**Note on strictness:** "approximately" means values may slightly exceed `±1` (typically by no more than 0.01) at pathological inputs. Consumers should `clamp()` if strict bounds are required. This is inherited from the reference implementations; fully-strict bounds require extra clamping that would subtly change output and is not typical of production implementations.

### 4.2 Determinism

- For a given `(seed, x, y, z, w)`, every function must produce **bit-identical** output across runs, platforms, and compiler versions.
- Implementation must not depend on floating-point order-of-operations being commutative (e.g., no `(a+b)+c vs a+(b+c)` variance).
- The permutation table derivation from `seed` (see §5.2) is fully specified in this document. No implementation freedom here.

### 4.3 Continuity

Perlin and simplex noise are continuous everywhere (C⁰) and differentiable everywhere except on a measure-zero set. For both variants:

- Classic Perlin uses the quintic fade function `6t⁵ - 15t⁴ + 10t³` [Ref 1]. This gives C² continuity (continuous first and second derivatives), which is required for noise to be usable as a displacement source without producing visible artifacts in normal maps.
- Simplex noise uses a radially-symmetric kernel `(r² - d²)⁴` where `r` is the kernel radius [Ref 4, §2D]. This also gives C² continuity at the kernel boundary.

Implementations **must not** use the older cubic hermite fade `3t² - 2t³` for classic Perlin. That was Perlin's 1985 original and is inferior to the 2002 quintic form. It's still seen in online tutorials and produces visible banding in normal-shaded terrain.

### 4.4 Value at Integer Lattice Points

Both Perlin and simplex return 0 at integer lattice points in the noise coordinate space. This is not a bug but a fundamental property: gradient noise is "zero at the grid, interpolates between." Consumers sampling at integer coordinates should expect zero output. Test vectors below reflect this.

---

## 5. Seeding and Permutation Table

### 5.1 Structure

The permutation table is a `char[512]` where `perm[0..255]` is a permutation of the integers `0..255` and `perm[256..511]` is a duplicate of `perm[0..255]`. The duplication avoids modular arithmetic during the gradient-hashing step; see [Ref 1].

### 5.2 Seeded Generation

From a 64-bit seed, the permutation table must be generated by the following deterministic procedure:

1. Initialize `perm[0..255] = [0, 1, 2, ..., 255]`.
2. Initialize an `xoshiro256**` PRNG state [Ref 8] from the 64-bit seed using its standard `SplitMix64` seed expansion.
3. Fisher-Yates shuffle `perm[0..255]` using the PRNG to produce uniformly-random permutations. Draw 64-bit values, use `value % (i+1)` to pick swap indices at step `i`.
4. Copy `perm[0..255]` into `perm[256..511]` byte-for-byte.

The choice of `xoshiro256**` over `rand()` or a hand-rolled LCG is deliberate:
- **Fully specified and portable** — the algorithm is one page of code and bit-identical across implementations.
- **Small state** (256 bits) so it fits on the stack without pressure.
- **High quality** — passes BigCrush, no known statistical flaws at this use scale.

The default seed used when `seed = 0` is specified as `0x9E3779B97F4A7C15` (the golden-ratio SplitMix64 constant) to ensure `init(0)` produces a well-distributed table rather than a degenerate one.

### 5.3 Reference Permutation (for Testing Only)

For test-vector verification, the canonical Ken Perlin permutation [Ref 2] — the specific byte sequence from his 2002 Java reference — should be reproducible when `seed = SEED_KEN_PERLIN_REFERENCE`. This sentinel seed value should branch to copy the reference table directly rather than running the PRNG. This lets us verify the core noise functions against Perlin's published output without getting confused by seeding differences.

```c3
const ulong SEED_KEN_PERLIN_REFERENCE = 0xFFFF_FFFF_FFFF_FFFF;
```

---

## 6. Implementation Notes

### 6.1 Classic Perlin (§3.2, `perlin2/3/4`)

Algorithm [Refs 1, 2, 3]:

1. Floor input coordinates to get unit-cube corner indices; extract fractional part `(x, y, z)` in `[0, 1)`.
2. Apply quintic fade to fractional part: `fade(t) = 6t⁵ - 15t⁴ + 10t³`.
3. Hash each cube corner via the permutation table. For 3D this is `perm[perm[perm[X]+Y]+Z]` etc., 8 corner hashes total.
4. Map each corner hash through `grad()` to get a gradient direction. The 2002 "improved" variant uses:
   - **3D**: 12 gradients, midpoints of cube edges: `(±1, ±1, 0), (±1, 0, ±1), (0, ±1, ±1)`. Select via `hash & 15`, treating indices 12-15 as aliases to avoid distribution bias [Ref 1, Ref 6].
   - **2D**: typically 8 gradients from the 3D set with `z = 0` dropped.
   - **4D**: 32 gradients, midpoints of 4D hypercube edges.
5. Compute dot product of each gradient with the offset vector from corner to sample point.
6. Trilinear interpolation of the 8 dot products (quadlinear for 4D) using the faded `(u, v, w)` weights.
7. Multiply by a normalization constant to map raw output to approximately `[-1, 1]`. For 3D this is typically `1.0` (the raw output is naturally close to `[-1, 1]`); this must be verified empirically by the implementation against the reference test vectors.

Critical correctness points:
- The `grad()` function must follow Perlin's 2002 form (conditional returns), not a lookup into a gradient table. Both produce identical output, but the conditional form is what Perlin's reference code uses and is more easily verified.
- Floor on negative inputs must use proper mathematical floor, not truncation. `(int)-1.5` is `-1` in C semantics but should be `-2`. C3's `math::floor` gives the correct behavior; raw casts do not.

### 6.2 Simplex Noise (§3.2, `simplex2/3/4`)

Algorithm [Refs 4, 5]:

1. **Skew:** Transform input coordinates from Cartesian to simplex-grid space via the skew factor `F = (√(n+1) - 1) / n`. For 2D, `F₂ = (√3 - 1) / 2 ≈ 0.366`. For 3D, `F₃ = 1/3`. For 4D, `F₄ = (√5 - 1) / 4`.
2. **Cell origin:** Floor the skewed coordinates to get the simplex grid cell.
3. **Unskew:** Transform the cell origin back to Cartesian via the unskew factor `G = (1 - 1/√(n+1)) / n`. For 2D, `G₂ = (3 - √3) / 6 ≈ 0.211`. For 3D, `G₃ = 1/6`. For 4D, `G₄ = (5 - √5) / 20`.
4. **Simplex traversal order:** Determine which of the `n!` simplices within the cell contains the sample point by comparing the magnitudes of the unskewed offsets. In 2D it's a single `x0 > y0` comparison; in 3D a 3-way comparison chain; in 4D a lookup table of 64 entries mapped from 6 pairwise comparisons [Ref 5, §4D].
5. **Per-corner contribution:** For each of the `n+1` simplex corners:
   - Compute the offset from corner to sample point (unskewed).
   - Compute `t = r² - x² - y² - ...` where `r² = 0.5` for 2D/3D, `r² = 0.6` for 4D. If `t < 0`, this corner contributes 0.
   - Otherwise, `contribution = t⁴ × dot(gradient, offset)`, where `gradient` is selected by hashing the skewed corner coordinates through the permutation table.
6. **Sum and normalize:** Sum the `n+1` contributions and multiply by the dimension-specific normalization constant to bring output into approximately `[-1, 1]`. Standard constants from the reference implementations: `70.0` for 2D, `32.0` for 3D, `27.0` for 4D.

Critical correctness points:
- The `t⁴` kernel (not `t³` or `t⁶`) is what gives C² continuity at the kernel boundary. Variants using different exponents exist but are not the standard.
- The gradient table for simplex can reuse the classic-Perlin 12-gradient set for 3D, or can use simplex-specific 8-gradient sets for 2D. Either is correct; the choice affects the visual character slightly. We specify the classic-Perlin 12-gradient set for all dimensions, for consistency with `perlin3`.
- `simplex4` should use the 32-gradient 4D set from Perlin's 2002 paper, identical to the set used for `perlin4`.

### 6.3 Multi-Octave fBm

Algorithm [Ref 7]:

```
fn float fbm_impl(noise_fn, x, y, z, w, p: FbmParams) {
    float total = 0;
    float frequency = p.scale;
    float amplitude = 1.0;
    float max_amplitude = 0;

    for i in 0..p.octaves {
        total += noise_fn(x*frequency, y*frequency, ...) * amplitude;
        max_amplitude += amplitude;
        frequency *= p.lacunarity;
        amplitude *= p.persistence;
    }

    return total / max_amplitude;
}
```

Critical points:
- Normalization by `max_amplitude` (not the theoretical max `1/(1-persistence)`) ensures output stays in the same range as single-octave noise regardless of octave count.
- `frequency` and `amplitude` both update **after** the per-octave call; the first octave uses `scale` and `amplitude = 1.0`.
- The `_ranged` variants should compute raw fBm first, then linearly map from `[-1, 1]` to `[lo, hi]`. Do not scale inside the accumulation loop.

### 6.4 Simplex Permutation Table for Gradient Selection

Simplex noise needs slightly more than 256 permutation entries when 4D gradients are selected (since the 4D gradient set has 32 entries). Implementations must handle this correctly via `(perm[i] & 31)` mod gradient count, not `(perm[i] % 32)` (same result, but `&` is explicitly what the reference does and is cheaper).

---

## 7. Testing and Verification

### 7.1 Unit Tests

| Test | Input | Expected |
|------|-------|----------|
| `perlin2 at origin` | `(0.0, 0.0)` | `0.0` (integer lattice point) |
| `perlin3 at origin` | `(0.0, 0.0, 0.0)` | `0.0` |
| `simplex2 at origin` | `(0.0, 0.0)` | `0.0` |
| `simplex3 at origin` | `(0.0, 0.0, 0.0)` | `0.0` |
| `perlin3 Ken Perlin reference` | reference seed, specific points from [Ref 2] | exact match to Perlin's published Java output |
| `continuity` | Sample 1000 points along a line, compute consecutive deltas | max delta < 0.1 across all adjacent samples |
| `range` | Sample 100k uniformly random points | output in `[-1.01, 1.01]` |
| `determinism` | Same seed + same input, called 1000× | all 1000 outputs bit-identical |
| `seeding sensitivity` | Two seeds differing by 1 bit, same input | outputs differ by at least 0.01 for at least 99% of sample points |

### 7.2 Visual Verification

A debug harness (`tools/noise_viewer.c3` or similar) should be able to render 2D slices of each noise type as grayscale PNGs for eyeballing:

- Classic Perlin 2D: recognizable square-grid bias faintly visible at low octave counts, characteristic "cloudy" pattern.
- Simplex 2D: visually more isotropic than Perlin, no grid bias, slightly "blobbier" appearance.
- fBm 2D at 6 octaves: fractal-looking terrain-like patterns.
- Side-by-side comparison against published reference images [Ref 3, Ref 4].

### 7.3 Performance Targets

| Function | Target (scalar, one core, modern x86) |
|----------|---------------------------------------|
| `perlin3` single call | < 50 ns |
| `simplex3` single call | < 60 ns |
| `fbm_simplex3` with 6 octaves | < 400 ns |

These are guidelines, not hard requirements. Correctness first, performance second. If the first implementation is 2× slower and correct, ship it and optimize later based on actual profiling.

---

## 8. Numerical and Portability Notes

- All arithmetic is `float` (32-bit), not `double`. VoxelQuest's original uses `float`, we match for consistency with existing test vectors. `double` internally would improve precision marginally but add port friction when we eventually share code with GLSL shaders.
- Square roots and divisions in the skew/unskew constants should be precomputed as `const float` at module scope, not recomputed per call.
- `math::floor`, `math::sqrt` come from C3's `std::math`. If C3 lacks a function we need, fall back to C ABI calls (e.g., `floorf`, `sqrtf` from libm) rather than reimplementing.
- No global mutable state anywhere. Every stateful operation goes through a `Noise` instance.
- Thread-safety: `Noise.init` and `Noise.reseed` are not thread-safe on the same instance. All read-only functions (`perlin*`, `simplex*`, `fbm_*`) **are** thread-safe once `init` has completed and no concurrent `reseed` is happening. This matches how the procedural generator will actually use noise (init once, sample many times concurrently across threads).

---

## 9. Integration Points

This module is consumed by:

- `world::block` — terrain heightmap generation via `fbm_simplex2`, `fbm_simplex3`.
- `world::geometry` — tree perturbation and small geometry variation via `perlin3`.
- `voxel::generate` (potentially) — if CPU-side geometry gathering needs noise for scatter patterns.
- `game::camera` (optional) — subtle camera shake via low-amplitude `fbm_perlin2` over time.

The GPU-side simplex noise used in shaders (`Simplex2D.c` in VoxelQuest) lives in GLSL and is not part of this module. For consistency between CPU and GPU noise, both implementations should be seeded and queried identically; test vectors should match between CPU-C3 output and a debug readback from the GPU shader.

---

## 10. References

### Primary sources

1. **Perlin, K. (2002).** "Improving Noise." *SIGGRAPH 2002 Proceedings.* The paper that introduced the 2002 improvements: quintic fade function and restricted 12-gradient set. Available at <https://mrl.cs.nyu.edu/~perlin/paper445.pdf>.
2. **Perlin, K. (2002).** "Improved Noise reference implementation" (Java). <https://mrl.cs.nyu.edu/~perlin/noise/>. The canonical reference code; the permutation table used for our `SEED_KEN_PERLIN_REFERENCE` sentinel comes from here.
3. **Perlin, K. (1985).** "An Image Synthesizer." *SIGGRAPH '85 Proceedings.* The original 1985 paper introducing gradient noise. Useful historical context; the algorithm has been superseded by the 2002 improvements for production use.
4. **Gustavson, S. (2005).** "Simplex noise demystified." Technical report, Linköping University. <https://weber.itn.liu.se/~stegu/simplexnoise/simplexnoise.pdf>. The definitive explanation of simplex noise with clear figures and working reference code. Essential reading for implementing simplex; Perlin's own presentations are too terse.
5. **Gustavson, S.** "SimplexNoise1234" (C reference implementation). <https://github.com/stegu/perlin-noise/blob/master/src/simplexnoise1234.c>. Public-domain C code matching the paper; use for test vector generation.

### Supplementary explanations

6. **NVIDIA GPU Gems 2, Chapter 26** — Green, S. "Implementing Improved Perlin Noise." <https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-26-implementing-improved-perlin-noise>. GPU implementation notes; useful if/when we add shader versions.
7. **Hugo Elias** — "Perlin Noise" tutorial. Widely cited for the fBm formula with `persistence` and `amplitude`, though notably this tutorial describes **value noise**, not gradient noise. Use for fBm pattern only, not for the underlying noise definition. <https://web.archive.org/web/20160530124230/http://freespace.virgin.net/hugo.elias/models/m_perlin.htm>.
8. **Blackman, D. and Vigna, S. (2018).** "xoshiro / xoroshiro generators and the PRNG shootout." <http://prng.di.unimi.it/>. Reference for the `xoshiro256**` PRNG used in seeding.

### GLSL noise (for future shader port)

9. **McEwan, I., Sheets, D., Gustavson, S., and Richardson, M. (2012).** "Efficient computational noise in GLSL." *Journal of Graphics Tools.* <https://arxiv.org/pdf/1204.1461>. Ashima/McEwan's textureless GLSL simplex. This is what VoxelQuest uses in `Simplex2D.c` and what the shader-side port should use for consistency.
10. **Ashima Arts WebGL noise.** <https://github.com/ashima/webgl-noise>. Public-domain GLSL implementations.

### C3 language

11. **C3 language documentation.** <https://c3-lang.org/>. For syntax and standard library reference (`std::math`, `std::core`).