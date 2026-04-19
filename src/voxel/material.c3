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

// Debug palette: replaced by a proper palette LUT texture in M8.
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
    { 0.85f, 0.95f, 1.00f, 0.4f },  // GLASS
    { 0.35f, 0.25f, 0.18f, 1.0f },  // EARTH
    { 0.28f, 0.20f, 0.15f, 1.0f },  // BARK
};
