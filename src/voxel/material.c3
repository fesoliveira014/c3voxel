module c3voxel::voxel;

import c3voxel::core;

// Material IDs follow the VoxelQuest enumeration (docs/procedural-generation-vq.md §6)
// compacted into a contiguous enum. A palette LUT in M8 will replace the debug
// palette below; for now it exists so the smoke test renders distinguishable colors.
enum Material : char {
    NULL,
    GOLD,
    DIRT,
    STONE,
    GRASS,
    SAND,
    MORTAR,
    WOOD,
    BRICK,
    SHINGLE,
    PLASTER,
    DEBUG,
    WATER,
    METAL,
    GLASS,
    EARTH,
    BARK,
}

const int MATERIAL_COUNT = 17;

// Linear-space RGBA palette shared by code paths that want float colors
// (e.g. debugging, CPU previews). The M8 lighting pass uploads
// `MATERIAL_COLORS_RGBA8` into a 17×1 palette LUT and samples it with
// `texelFetch`, so GLSL no longer needs the big if-chain previously in
// generate.comp.glsl's `material_color()`.
const core::Vec4[MATERIAL_COUNT] MATERIAL_DEBUG_PALETTE = {
    { 0.00f, 0.00f, 0.00f, 0.0f },  // NULL
    { 0.95f, 0.80f, 0.10f, 1.0f },  // GOLD
    { 0.55f, 0.40f, 0.25f, 1.0f },  // DIRT
    { 0.45f, 0.45f, 0.48f, 1.0f },  // STONE
    { 0.30f, 0.60f, 0.25f, 1.0f },  // GRASS
    { 0.90f, 0.85f, 0.55f, 1.0f },  // SAND
    { 0.70f, 0.70f, 0.65f, 1.0f },  // MORTAR
    { 0.50f, 0.32f, 0.18f, 1.0f },  // WOOD
    { 0.65f, 0.30f, 0.22f, 1.0f },  // BRICK
    { 0.45f, 0.35f, 0.30f, 1.0f },  // SHINGLE
    { 0.90f, 0.88f, 0.82f, 1.0f },  // PLASTER
    { 1.00f, 0.00f, 1.00f, 1.0f },  // DEBUG
    { 0.20f, 0.40f, 0.70f, 0.6f },  // WATER
    { 0.75f, 0.75f, 0.80f, 1.0f },  // METAL
    { 0.85f, 0.95f, 1.00f, 1.0f },  // GLASS — 1.0 so raymarch registers as opaque; translucency comes in M8.
    { 0.35f, 0.25f, 0.18f, 1.0f },  // EARTH
    { 0.28f, 0.20f, 0.15f, 1.0f },  // BARK
};

// Packed RGBA8 palette, laid out as MATERIAL_COUNT consecutive
// (R, G, B, A) quads ready to upload into a 17×1 RGBA8 Texture2D. Values
// mirror MATERIAL_DEBUG_PALETTE (*255, rounded) so the lit scene looks
// identical to the pre-M8 baked-color pipeline.
const char[MATERIAL_COUNT * 4] MATERIAL_COLORS_RGBA8 = {
      0,   0,   0,   0,   // NULL
    242, 204,  26, 255,   // GOLD    (0.95, 0.80, 0.10)
    140, 102,  64, 255,   // DIRT    (0.55, 0.40, 0.25)
    115, 115, 122, 255,   // STONE   (0.45, 0.45, 0.48)
     77, 153,  64, 255,   // GRASS   (0.30, 0.60, 0.25)
    230, 217, 140, 255,   // SAND    (0.90, 0.85, 0.55)
    179, 179, 166, 255,   // MORTAR  (0.70, 0.70, 0.65)
    128,  82,  46, 255,   // WOOD    (0.50, 0.32, 0.18)
    166,  77,  56, 255,   // BRICK   (0.65, 0.30, 0.22)
    115,  89,  77, 255,   // SHINGLE (0.45, 0.35, 0.30)
    230, 224, 209, 255,   // PLASTER (0.90, 0.88, 0.82)
    255,   0, 255, 255,   // DEBUG   (1.00, 0.00, 1.00)
     51, 102, 179, 153,   // WATER   (0.20, 0.40, 0.70, 0.6)
    191, 191, 204, 255,   // METAL   (0.75, 0.75, 0.80)
    217, 242, 255, 255,   // GLASS   (0.85, 0.95, 1.00)
     89,  64,  46, 255,   // EARTH   (0.35, 0.25, 0.18)
     71,  51,  38, 255,   // BARK    (0.28, 0.20, 0.15)
};
