module c3voxel::voxel;

import std::math;

const int MAX_PLANT_GEN = 6;

enum PlantType : char {
    OAK_TRUNK,
    OAK_ROOTS,
    OAK2_TRUNK,
    OAK2_ROOTS,
    BARE_OAK_TRUNK,
    BARE_OAK_ROOTS,
}

const int PLANT_TYPE_COUNT = 6;

struct PlantRules {
    float[2]             num_children;          // {min, max}
    float[2]             divergence_angle_v;    // {min, max}, radians
    float                beg_thickness;          // world units at the root of the plant
    float                end_thickness;          // world units at the tip
    float[MAX_PLANT_GEN] branch_length;           // length per generation
    int                  sphere_gen;              // generation that sprouts leaves; -1 = none
    float                sphere_rad;              // leaf sphere radius
    int                  num_generations;
    float                angle_uniformity_u;       // 0 = random spacing, 1 = perfectly regular
    Material             branch_material;
    Material             leaf_material;
}

const float PLANT_PI = (float)math::PI;

const PlantRules[PLANT_TYPE_COUNT] PLANT_TABLE = {
    // OAK_TRUNK — ported from VQ f00341_gameplant.hpp
    {
        .num_children       = { 2.0f, 5.0f },
        .divergence_angle_v = { PLANT_PI / 3.0f, PLANT_PI / 6.0f },
        .beg_thickness      = 1.0f,
        .end_thickness      = 0.4f,
        .branch_length      = { 6.0f, 8.0f, 0.0f, 0.0f, 0.0f, 0.0f },
        .sphere_gen         = 2,
        .sphere_rad         = 6.0f,
        .num_generations    = 2,
        .angle_uniformity_u = 0.75f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.GRASS,
    },
    // OAK_ROOTS — narrower angles, deeper generations, no leaves
    {
        .num_children       = { 2.0f, 4.0f },
        .divergence_angle_v = { PLANT_PI / 8.0f, PLANT_PI / 12.0f },
        .beg_thickness      = 1.0f,
        .end_thickness      = 0.0f,
        .branch_length      = { 2.0f, 2.0f, 2.0f, 2.0f, 0.0f, 0.0f },
        .sphere_gen         = -1,
        .sphere_rad         = 0.0f,
        .num_generations    = 4,
        .angle_uniformity_u = 0.6f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.NULL,
    },
    // OAK2_TRUNK — stockier variant, slightly wider divergence
    {
        .num_children       = { 3.0f, 5.0f },
        .divergence_angle_v = { PLANT_PI / 2.5f, PLANT_PI / 5.0f },
        .beg_thickness      = 1.4f,
        .end_thickness      = 0.5f,
        .branch_length      = { 5.0f, 7.0f, 0.0f, 0.0f, 0.0f, 0.0f },
        .sphere_gen         = 2,
        .sphere_rad         = 7.0f,
        .num_generations    = 2,
        .angle_uniformity_u = 0.7f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.GRASS,
    },
    // OAK2_ROOTS
    {
        .num_children       = { 2.0f, 4.0f },
        .divergence_angle_v = { PLANT_PI / 10.0f, PLANT_PI / 14.0f },
        .beg_thickness      = 1.2f,
        .end_thickness      = 0.0f,
        .branch_length      = { 2.5f, 2.5f, 2.0f, 2.0f, 0.0f, 0.0f },
        .sphere_gen         = -1,
        .sphere_rad         = 0.0f,
        .num_generations    = 4,
        .angle_uniformity_u = 0.6f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.NULL,
    },
    // BARE_OAK_TRUNK — same as OAK_TRUNK but without leaves
    {
        .num_children       = { 2.0f, 5.0f },
        .divergence_angle_v = { PLANT_PI / 3.0f, PLANT_PI / 6.0f },
        .beg_thickness      = 1.0f,
        .end_thickness      = 0.3f,
        .branch_length      = { 6.0f, 8.0f, 0.0f, 0.0f, 0.0f, 0.0f },
        .sphere_gen         = -1,
        .sphere_rad         = 0.0f,
        .num_generations    = 2,
        .angle_uniformity_u = 0.75f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.NULL,
    },
    // BARE_OAK_ROOTS
    {
        .num_children       = { 2.0f, 4.0f },
        .divergence_angle_v = { PLANT_PI / 8.0f, PLANT_PI / 12.0f },
        .beg_thickness      = 1.0f,
        .end_thickness      = 0.0f,
        .branch_length      = { 2.0f, 2.0f, 2.0f, 2.0f, 0.0f, 0.0f },
        .sphere_gen         = -1,
        .sphere_rad         = 0.0f,
        .num_generations    = 4,
        .angle_uniformity_u = 0.6f,
        .branch_material    = Material.WOOD,
        .leaf_material      = Material.NULL,
    },
};
