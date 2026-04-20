module c3voxel::world;

import std::collections::list;
import std::math;
import std::io;

import c3voxel::core;
import c3voxel::core::noise;
import c3voxel::voxel;

const int   MAX_NODES_PER_TREE = 1024;
const float WATER_LEVEL_Y      = 16.0f;
const float MAX_HEIGHT         = 128.0f;
const float TERRAIN_SEED_F     = 1337.0f;

struct PlantNode {
    core::Vec3 beg_point;
    core::Vec3 end_point;
    core::Vec3 tangent;             // unit
    core::Vec3 base_shoot;           // orthogonal to tangent; rotated to place children
    float      beg_thickness;
    float      end_thickness;
    float      sphere_rad;
    int        first_child;           // index into scratch; -1 = leaf
    int        num_children;
    bool       is_root_node;
}

alias PlantNodeList = List {PlantNode};

bool plant_overflow_warned @local = false;

fn float plant_frand(uint base_seed, uint* counter) @local
{
    uint h = voxel::voronoi_hash(base_seed, 0u, 0u, *counter);
    *counter += 1u;
    return voxel::voronoi_frand(h);
}

fn float plant_frand_range(uint base_seed, uint* counter, float lo, float hi) @local
{
    return lo + (hi - lo) * plant_frand(base_seed, counter);
}

fn core::Vec3 vec3_cross(core::Vec3 a, core::Vec3 b) @local
{
    return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}

fn core::Vec3 vec3_normalize(core::Vec3 v) @local
{
    float len_sq = v.x * v.x + v.y * v.y + v.z * v.z;
    if (len_sq <= 1e-12) return { 0.0f, 1.0f, 0.0f };
    float inv = 1.0f / (float)math::sqrt(len_sq);
    return { v.x * inv, v.y * inv, v.z * inv };
}

fn core::Vec3 vec3_scale(core::Vec3 v, float s) @local
{
    return { v.x * s, v.y * s, v.z * s };
}

fn core::Vec3 vec3_add(core::Vec3 a, core::Vec3 b) @local
{
    return { a.x + b.x, a.y + b.y, a.z + b.z };
}

fn core::Vec3 vec3_lerp(core::Vec3 a, core::Vec3 b, float t) @local
{
    return { a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t };
}

// Rodrigues rotation of v around unit axis `axis` by `angle` radians.
fn core::Vec3 vec3_rotate_axis(core::Vec3 v, core::Vec3 axis, float angle) @local
{
    float c = (float)math::cos(angle);
    float s = (float)math::sin(angle);
    float d = axis.x * v.x + axis.y * v.y + axis.z * v.z;
    core::Vec3 cr = vec3_cross(axis, v);
    return {
        v.x * c + cr.x * s + axis.x * d * (1.0f - c),
        v.y * c + cr.y * s + axis.y * d * (1.0f - c),
        v.z * c + cr.z * s + axis.z * d * (1.0f - c),
    };
}

fn core::Vec3 any_orthogonal(core::Vec3 n) @local
{
    if (math::abs(n.y) < 0.9) return vec3_normalize(vec3_cross(n, { 0.0f, 1.0f, 0.0f }));
    return vec3_normalize(vec3_cross(n, { 1.0f, 0.0f, 0.0f }));
}

fn float mixf(float a, float b, float t) @local @inline => a + (b - a) * t;

fn void apply_rules(
    PlantNodeList*          scratch,
    voxel::PlantRules       rules,
    int                     parent_idx,
    int                     cur_gen,
    float                   tot_length,
    float                   max_length,
    uint                    seed,
    uint*                   counter) @local
{
    int num_kids = (int)plant_frand_range(seed, counter, rules.num_children[0], rules.num_children[1] + 0.999f);
    if (num_kids < 1) num_kids = 1;
    if (num_kids > 8) num_kids = 8;

    float cur_length = rules.branch_length[cur_gen];
    if (cur_length <= 0.0f) return;

    int first_child = (int)scratch.len();
    if (first_child + num_kids > MAX_NODES_PER_TREE) {
        if (!plant_overflow_warned) {
            io::eprintfn("[plant] MAX_NODES_PER_TREE exceeded, truncating");
            plant_overflow_warned = true;
        }
        return;
    }

    PlantNode parent = (*scratch)[(usz)parent_idx];
    parent.first_child = first_child;
    parent.num_children = num_kids;
    (*scratch)[(usz)parent_idx] = parent;

    float two_pi = 2.0f * (float)math::PI;
    for (int i = 0; i < num_kids; i++) {
        float jitter = plant_frand(seed, counter) - 0.5f;
        float theta = ((float)i / (float)num_kids) * two_pi
                    + jitter * two_pi * (1.0f - rules.angle_uniformity_u) / (float)num_kids;

        core::Vec3 shoot_rot = vec3_rotate_axis(parent.base_shoot, parent.tangent, theta);
        core::Vec3 end_pt    = vec3_add(parent.end_point, vec3_scale(shoot_rot, cur_length));
        float div_angle      = plant_frand_range(seed, counter, rules.divergence_angle_v[0], rules.divergence_angle_v[1]);
        core::Vec3 new_tangent = vec3_normalize(vec3_lerp(parent.tangent, shoot_rot, div_angle * 0.5f));

        float lerp_start = max_length > 0.0f ? tot_length / max_length : 0.0f;
        float lerp_end   = max_length > 0.0f ? (tot_length + cur_length) / max_length : 0.0f;
        if (lerp_end > 1.0f) lerp_end = 1.0f;

        PlantNode child = {
            .beg_point     = parent.end_point,
            .end_point     = end_pt,
            .tangent       = new_tangent,
            .base_shoot    = any_orthogonal(new_tangent),
            .beg_thickness = mixf(rules.beg_thickness, rules.end_thickness, lerp_start),
            .end_thickness = mixf(rules.beg_thickness, rules.end_thickness, lerp_end),
            .sphere_rad    = cur_gen == rules.sphere_gen ? rules.sphere_rad : 0.0f,
            .first_child   = -1,
            .num_children  = 0,
            .is_root_node  = false,
        };
        scratch.push(child);
    }

    // VQ's check is `curGen < maxGen`, producing `num_generations + 1` levels
    // of children. With num_generations=2 and sphere_gen=2, VQ gets spheres
    // on the deepest level (cur_gen=2). Earlier drafts used `< num_gen - 1`
    // which produced one less level and forced sphere_gen remapping; we now
    // match VQ exactly so the table can stay as-is.
    if (cur_gen < rules.num_generations) {
        for (int i = 0; i < num_kids; i++) {
            apply_rules(scratch, rules, first_child + i, cur_gen + 1,
                        tot_length + cur_length, max_length, seed, counter);
        }
    }
}

fn float compute_max_length(voxel::PlantRules rules) @local
{
    float total = 0.0f;
    for (int i = 0; i < rules.num_generations && i < voxel::MAX_PLANT_GEN; i++) {
        total += rules.branch_length[i];
    }
    return total;
}

fn void flatten_tree(PlantNodeList* scratch, PageGeometry* out, voxel::Material branch_mat, voxel::Material leaf_mat)
{
    for (usz i = 0; i < scratch.len(); i++) {
        PlantNode n = (*scratch)[i];
        if (n.is_root_node) continue;

        // Find parent — scan backwards for the node whose child range contains i.
        // With MAX_NODES_PER_TREE=1024 the quadratic scan is a few hundred µs worst
        // case and avoids storing an explicit parent index on every PlantNode.
        int parent_idx = 0;
        for (int j = (int)i - 1; j >= 0; j--) {
            PlantNode pn = (*scratch)[(usz)j];
            if (pn.first_child >= 0 && pn.first_child <= (int)i && (int)i < pn.first_child + pn.num_children) {
                parent_idx = j;
                break;
            }
        }
        PlantNode parent = (*scratch)[(usz)parent_idx];

        // For real parents, p0 = parent midpoint (Bezier anchor). For nodes
        // directly parented by the virtual seed, using the seed's midpoint
        // puts p0 above (or below, for roots) the ground — tree appears to
        // float. VQ's initTree uses the parent's endPoint in that case, which
        // coincides with this node's beg_point (the base of the trunk).
        core::Vec3 p0_v = parent.is_root_node
            ? parent.end_point
            : vec3_lerp(parent.beg_point, parent.end_point, 0.5f);
        core::Vec3 p1_v = vec3_lerp(n.beg_point, n.end_point, 0.5f);
        core::Vec3 p2_v = n.beg_point;

        float r_max = math::max(math::max(n.beg_thickness, n.end_thickness), n.sphere_rad);
        core::Vec3 vmin = {
            math::min(math::min(p0_v.x, p1_v.x), p2_v.x) - r_max,
            math::min(math::min(p0_v.y, p1_v.y), p2_v.y) - r_max,
            math::min(math::min(p0_v.z, p1_v.z), p2_v.z) - r_max,
        };
        core::Vec3 vmax = {
            math::max(math::max(p0_v.x, p1_v.x), p2_v.x) + r_max,
            math::max(math::max(p0_v.y, p1_v.y), p2_v.y) + r_max,
            math::max(math::max(p0_v.z, p1_v.z), p2_v.z) + r_max,
        };

        core::Vec3 center = vec3_lerp(p0_v, p2_v, 0.5f);

        voxel::TreeEntry entry = {
            .vis_min      = { vmin.x, vmin.y, vmin.z, 0.0f },
            .vis_max      = { vmax.x, vmax.y, vmax.z, 0.0f },
            .p0           = { p0_v.x, p0_v.y, p0_v.z, 0.0f },
            .p1           = { p1_v.x, p1_v.y, p1_v.z, 0.0f },
            .p2           = { p2_v.x, p2_v.y, p2_v.z, 0.0f },
            .power_vals   = { 0.0f, 0.0f, 0.0f, 0.0f },
            .power_vals_2 = { 0.0f, 0.0f, 0.0f, 0.0f },
            // thick_vals.w = leaf material id for this entry (tree-specific packing)
            .thick_vals   = { n.beg_thickness, n.end_thickness, n.sphere_rad, (float)leaf_mat.ordinal },
            .center_point = { center.x, center.y, center.z, 0.0f },
            .mat          = { .material_id = (float)branch_mat.ordinal, .normal_id = 0.0f, .modifier = 0.0f, ._pad = 0.0f },
        };
        out.tree.push(entry);
    }
}

// Sample terrain height at (wx, wz). In flat-terrain mode returns a
// constant world-y matching terrain.c3::FLAT_TERRAIN_H01. Trees land on
// the flat plane; buildings/roads have already flattened their own patches
// so local elevation doesn't break placement.
fn float heightmap_sample_at(float wx, float wz) @local
{
    return FLAT_TERRAIN_H01 * MAX_HEIGHT;
}

fn void plant_grow_tree(
    PageGeometry*    out,
    PlantNodeList*   scratch,
    voxel::PlantType type,
    core::Vec3       origin,
    uint             tree_seed)
{
    scratch.clear();
    voxel::PlantRules rules = voxel::PLANT_TABLE[(usz)type.ordinal];

    bool is_root = type == voxel::PlantType.OAK_ROOTS
                || type == voxel::PlantType.OAK2_ROOTS
                || type == voxel::PlantType.BARE_OAK_ROOTS;
    core::Vec3 initial_tangent = is_root ? (core::Vec3){ 0.0f, -1.0f, 0.0f } : (core::Vec3){ 0.0f, 1.0f, 0.0f };

    float cur_length_0 = rules.branch_length[0];
    PlantNode seed_node = {
        .beg_point     = origin,
        .end_point     = vec3_add(origin, vec3_scale(initial_tangent, cur_length_0)),
        .tangent       = initial_tangent,
        .base_shoot    = { 1.0f, 0.0f, 0.0f },
        .beg_thickness = rules.beg_thickness,
        .end_thickness = rules.beg_thickness,
        .sphere_rad    = 0.0f,
        .first_child   = -1,
        .num_children  = 0,
        .is_root_node  = true,
    };
    scratch.push(seed_node);

    float max_length = compute_max_length(rules);
    uint counter = 0u;
    apply_rules(scratch, rules, 0, 0, 0.0f, max_length, tree_seed, &counter);

    flatten_tree(scratch, out, rules.branch_material, rules.leaf_material);
}

// Check the block's building map_data at world (wx, wz). Returns true
// if the tile there is tagged as a ROAD/WING/MAINHALL — tree placement
// should skip these to avoid trees growing through buildings or roads.
fn bool tile_is_built(Block* block, float wx, float wz) @local
{
    if (block == null || block.map_data.len == 0) return false;
    float block_origin_x = (float)(int)block.cx * (float)BLOCK_HEIGHTMAP_PIXELS;
    float block_origin_z = (float)(int)block.cz * (float)BLOCK_HEIGHTMAP_PIXELS;
    float lx = wx - block_origin_x;
    float lz = wz - block_origin_z;
    int tile_i = (int)(lx / (float)BUILDING_TILE_PX);
    int tile_j = (int)(lz / (float)BUILDING_TILE_PX);
    if (tile_i < 0 || tile_i >= BUILDING_GRID_X || tile_j < 0 || tile_j >= BUILDING_GRID_Z) return false;
    ConType t = block.map_data[tile_j * BUILDING_GRID_X + tile_i].connection_props[0];
    return t != ConType.NONE;
}

fn void plant_generate_page(
    PageGeometry*  out,
    Page*          page,
    Block*         block,
    uint           world_seed,
    PlantNodeList* scratch)
{
    uint px = (uint)(int)page.px;
    uint pz = (uint)(int)page.pz;
    uint base_h = voxel::voronoi_hash(px, pz, world_seed, 0u);
    // Uniform 3..8 via (0..5) + 3. Earlier `& 0x5u` variant only yielded
    // {0, 1, 4, 5}, collapsing to tree counts {3, 4, 7, 8}.
    int count = 3 + (int)(((base_h >> 24) & 0x7u) % 6u);

    for (int i = 0; i < count; i++) {
        uint pos_h = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 1));
        float fx = (float)(pos_h & 0xFFFFu) / 65535.0f;
        float fz = (float)((pos_h >> 16) & 0xFFFFu) / 65535.0f;
        float wx = page.world_min.x + fx * (page.world_max.x - page.world_min.x);
        float wz = page.world_min.z + fz * (page.world_max.z - page.world_min.z);
        float wy = heightmap_sample_at(wx, wz);
        if (wy < WATER_LEVEL_Y) continue;

        // Skip trees growing through buildings or down the middle of roads.
        if (tile_is_built(block, wx, wz)) continue;

        uint type_h = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 100));
        voxel::PlantType type = (voxel::PlantType)(type_h % (uint)voxel::PLANT_TYPE_COUNT);
        // Prefer trunk variants 3:1 over roots so surface density matches visual expectation.
        if (type == voxel::PlantType.OAK_ROOTS
            || type == voxel::PlantType.OAK2_ROOTS
            || type == voxel::PlantType.BARE_OAK_ROOTS) {
            type = (voxel::PlantType)(((type_h >> 8) % 3u) * 2u);
        }

        uint tree_seed = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 2000));
        plant_grow_tree(out, scratch, type, { wx, wy, wz }, tree_seed);
    }
}
