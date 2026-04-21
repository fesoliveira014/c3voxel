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
        // Clamp branches to grow upward only. Without this, gen-1 shoots
        // rotating around a non-vertical parent tangent can flip downward,
        // and the resulting gen-2 tips (where leaf spheres sit) land below
        // the tree origin. The leaf sphere then bakes half-buried in the
        // terrain; from iso only the top of the canopy pokes through.
        // Mirror shoot_rot across the horizontal plane when it points down
        // — preserves the random theta distribution projected onto the
        // upper hemisphere.
        if (shoot_rot.y < 0.0f) shoot_rot = { shoot_rot.x, -shoot_rot.y, shoot_rot.z };
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

// Scale branch thicknesses to voxel space. PlantRules stores VQ-style
// "meters" values (beg ~1.0, end ~0.3–0.4) which render as sub-voxel
// cylinders — most branches fall between the voxel grid entirely,
// especially for BARE_OAK variants that have no leaf sphere to mask
// the gap. Scaling gives VQ-like trunks a few voxels in diameter.
// Sphere rad stays in world units so leaves don't become
// building-sized.
const float BRANCH_VOXEL_SCALE = 2.5f;

fn void push_tree_entry(
    PageGeometry*       out,
    core::Vec3          p0,
    core::Vec3          p1,
    core::Vec3          p2,
    float               beg_t_vox,
    float               end_t_vox,
    float               sphere_rad,
    voxel::Material     branch_mat,
    voxel::Material     leaf_mat) @local
{
    float r_max = math::max(math::max(beg_t_vox, end_t_vox), sphere_rad);
    core::Vec3 vmin = {
        math::min(math::min(p0.x, p1.x), p2.x) - r_max,
        math::min(math::min(p0.y, p1.y), p2.y) - r_max,
        math::min(math::min(p0.z, p1.z), p2.z) - r_max,
    };
    core::Vec3 vmax = {
        math::max(math::max(p0.x, p1.x), p2.x) + r_max,
        math::max(math::max(p0.y, p1.y), p2.y) + r_max,
        math::max(math::max(p0.z, p1.z), p2.z) + r_max,
    };
    core::Vec3 center = vec3_lerp(p0, p2, 0.5f);

    voxel::TreeEntry entry = {
        .vis_min      = { vmin.x, vmin.y, vmin.z, 0.0f },
        .vis_max      = { vmax.x, vmax.y, vmax.z, 0.0f },
        .p0           = { p0.x, p0.y, p0.z, 0.0f },
        .p1           = { p1.x, p1.y, p1.z, 0.0f },
        .p2           = { p2.x, p2.y, p2.z, 0.0f },
        .power_vals   = { 0.0f, 0.0f, 0.0f, 0.0f },
        .power_vals_2 = { 0.0f, 0.0f, 0.0f, 0.0f },
        // thick_vals.w = leaf material id (tree-specific packing).
        .thick_vals   = { beg_t_vox, end_t_vox, sphere_rad, (float)leaf_mat.ordinal },
        .center_point = { center.x, center.y, center.z, 0.0f },
        .mat          = { .material_id = (float)branch_mat.ordinal, .normal_id = 0.0f, .modifier = 0.0f, ._pad = 0.0f },
    };
    out.tree.push(entry);
}

fn void flatten_tree(PlantNodeList* scratch, PageGeometry* out, voxel::Material branch_mat, voxel::Material leaf_mat)
{
    // Emit the SEED (root) node as a dedicated straight-line trunk entry:
    // p0 = ground origin, p2 = top of trunk, p1 = chord midpoint. All
    // other entries below also use p1 = chord midpoint so each bezier is
    // a straight segment — the shader's tangent-line distance
    // approximation (project onto p0→p2 chord, evaluate bezier at that
    // t) is EXACT only when p1 lies on the chord. Before this split the
    // gen-0 children used p0 = origin and p1 = midpoint of (top_beg, top_end),
    // giving a strongly arched bezier; the approximation then placed
    // on_bezier ~6 units above the voxel's actual world position near
    // the ground, so mid-trunk voxels read as empty and the canopy
    // floated above an invisible trunk stub.
    if (scratch.len() > 0) {
        PlantNode seed = (*scratch)[0];
        if (seed.is_root_node) {
            core::Vec3 p0 = seed.beg_point;
            core::Vec3 p2 = seed.end_point;
            core::Vec3 p1 = vec3_lerp(p0, p2, 0.5f);
            float beg_t_vox = seed.beg_thickness * BRANCH_VOXEL_SCALE;
            float end_t_vox = seed.end_thickness * BRANCH_VOXEL_SCALE;
            push_tree_entry(out, p0, p1, p2, beg_t_vox, end_t_vox,
                            0.0f, branch_mat, leaf_mat);
        }
    }

    for (usz i = 0; i < scratch.len(); i++) {
        PlantNode n = (*scratch)[i];
        if (n.is_root_node) continue;

        // Find parent — scan backwards for the node whose child range contains i.
        // With MAX_NODES_PER_TREE=1024 the quadratic scan is a few hundred µs
        // worst case and avoids storing an explicit parent index on every
        // PlantNode.
        int parent_idx = 0;
        for (int j = (int)i - 1; j >= 0; j--) {
            PlantNode pn = (*scratch)[(usz)j];
            if (pn.first_child >= 0 && pn.first_child <= (int)i && (int)i < pn.first_child + pn.num_children) {
                parent_idx = j;
                break;
            }
        }
        PlantNode parent = (*scratch)[(usz)parent_idx];

        // ALWAYS use parent.end_point for p0 (including gen-0 children of
        // the seed). The trunk itself is emitted above as its own entry,
        // so gen-0 branches now start at the top of the trunk and extend
        // outward. Because n.beg_point == parent.end_point, p1 below
        // collapses to the chord midpoint and the bezier is straight.
        core::Vec3 p0_v = parent.end_point;
        core::Vec3 p1_v = vec3_lerp(n.beg_point, n.end_point, 0.5f);
        core::Vec3 p2_v = n.end_point;

        float beg_t_vox = n.beg_thickness * BRANCH_VOXEL_SCALE;
        float end_t_vox = n.end_thickness * BRANCH_VOXEL_SCALE;
        push_tree_entry(out, p0_v, p1_v, p2_v, beg_t_vox, end_t_vox,
                        n.sphere_rad, branch_mat, leaf_mat);
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

    // Trunk (seed) is stretched by this factor so the first branching
    // level sits well above the ground; gen-0..gen-2 still use
    // rules.branch_length[cur_gen] for their own segment lengths, so the
    // canopy size is unaffected.
    const float TRUNK_BOOST = 2.5f;
    float cur_length_0 = rules.branch_length[0];
    float trunk_len    = cur_length_0 * TRUNK_BOOST;

    // Lean the trunk a small random amount away from vertical so no two
    // trees look like identical pillars. For roots (grow downward) keep
    // the stem perfectly axial. A straight TILTED line is still straight
    // — p1 = chord midpoint below — so the shader's tangent approximation
    // stays exact.
    uint counter = 0u;
    core::Vec3 initial_tangent;
    if (is_root) {
        initial_tangent = { 0.0f, -1.0f, 0.0f };
    } else {
        float tilt_x = plant_frand_range(tree_seed, &counter, -0.22f, 0.22f);
        float tilt_z = plant_frand_range(tree_seed, &counter, -0.22f, 0.22f);
        initial_tangent = vec3_normalize((core::Vec3){ tilt_x, 1.0f, tilt_z });
    }

    PlantNode seed_node = {
        .beg_point     = origin,
        .end_point     = vec3_add(origin, vec3_scale(initial_tangent, trunk_len)),
        .tangent       = initial_tangent,
        .base_shoot    = any_orthogonal(initial_tangent),
        .beg_thickness = rules.beg_thickness,
        .end_thickness = rules.beg_thickness,
        .sphere_rad    = 0.0f,
        .first_child   = -1,
        .num_children  = 0,
        .is_root_node  = true,
    };
    scratch.push(seed_node);

    float max_length = compute_max_length(rules);
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

// Emit trees whose ORIGIN lies in the page at (src_px, src_pz). If
// `is_home` is true, push all branches unconditionally. If false, the
// source is a neighbour — keep only branches whose vis-AABB overlaps
// the home page's XZ extent, so a tree whose canopy crosses a page
// boundary still renders on the far side.
fn void plant_emit_trees_from(
    PageGeometry*  out,
    Page*          home_page,
    Block*         block,
    uint           world_seed,
    PlantNodeList* scratch,
    int            src_px_i,
    int            src_pz_i,
    bool           is_home) @local
{
    uint px = (uint)src_px_i;
    uint pz = (uint)src_pz_i;
    uint base_h = voxel::voronoi_hash(px, pz, world_seed, 0u);
    int  count  = 3 + (int)(((base_h >> 24) & 0x7u) % 6u);

    float src_x0 = (float)src_px_i * (float)PIXELS_PER_PAGE;
    float src_z0 = (float)src_pz_i * (float)PIXELS_PER_PAGE;
    float src_w  = (float)PIXELS_PER_PAGE;

    float home_x0 = home_page.world_min.x;
    float home_z0 = home_page.world_min.z;
    float home_x1 = home_page.world_max.x;
    float home_z1 = home_page.world_max.z;

    for (int i = 0; i < count; i++) {
        uint pos_h = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 1));
        float fx = (float)(pos_h & 0xFFFFu) / 65535.0f;
        float fz = (float)((pos_h >> 16) & 0xFFFFu) / 65535.0f;
        float wx = src_x0 + fx * src_w;
        float wz = src_z0 + fz * src_w;
        float wy = heightmap_sample_at(wx, wz);
        if (wy < WATER_LEVEL_Y) continue;

        // tile_is_built needs the origin page's block. For neighbour pages
        // that sit in a different block we don't have that block here, so
        // the check runs against THIS page's block. Origins outside its
        // map_data range safely return false — neighbour-block trees may
        // pierce a building at the edge, acceptable until M8 gets a
        // BlockPool-lookup.
        if (is_home && tile_is_built(block, wx, wz)) continue;

        uint type_h = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 100));
        uint trunk_pick = type_h & 1u;
        voxel::PlantType type = trunk_pick == 0u
            ? voxel::PlantType.OAK_TRUNK
            : voxel::PlantType.OAK2_TRUNK;

        uint tree_seed = voxel::voronoi_hash(px, pz, world_seed, (uint)(i + 2000));

        usz len_before = out.tree.len();
        plant_grow_tree(out, scratch, type, { wx, wy, wz }, tree_seed);

        if (is_home) continue;

        // Forward-compact filter: iterate appended range [len_before, len()),
        // keep entries whose vis-AABB overlaps home's XZ bbox at write
        // index `w`, then truncate. Using an in-place compaction with a
        // single write pointer makes the loop correct for any pattern of
        // pass/fail — the earlier swap-with-last variant could skip
        // re-checking a just-moved entry.
        usz w = len_before;
        usz n = out.tree.len();
        for (usz r = len_before; r < n; r++) {
            voxel::TreeEntry e = out.tree[r];
            bool ov = e.vis_max.x >= home_x0 && e.vis_min.x <= home_x1
                   && e.vis_max.z >= home_z0 && e.vis_min.z <= home_z1;
            if (ov) {
                if (w != r) out.tree.set(w, e);
                w++;
            }
        }
        while (out.tree.len() > w) (void)out.tree.pop();
    }
}

fn void plant_generate_page(
    PageGeometry*  out,
    Page*          page,
    Block*         block,
    uint           world_seed,
    PlantNodeList* scratch)
{
    // Home page + 8 neighbours. Each TreeEntry has its own per-branch
    // vis-AABB; a tree whose canopy straddles a page boundary stamps
    // its far-side branches into this page's SSBO so the shader can
    // paint those voxels too. Without this, canopies get cleanly sliced
    // at page edges.
    int home_px = (int)page.px;
    int home_pz = (int)page.pz;
    for (int dz = -1; dz <= 1; dz++) {
        for (int dx = -1; dx <= 1; dx++) {
            bool is_home = (dx == 0 && dz == 0);
            plant_emit_trees_from(out, page, block, world_seed, scratch,
                                  home_px + dx, home_pz + dz, is_home);
        }
    }
}
