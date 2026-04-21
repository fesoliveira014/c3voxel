#version 460

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(binding = 0, rgba8) uniform restrict writeonly image3D volume;
layout(binding = 1)        uniform sampler2D heightmap;

layout(std140, binding = 2) uniform U {
    vec4  world_min;
    vec4  world_max;
    vec4  block_origin;
    vec4  block_extent;
    float time;
    float _pad_time_0;
    float _pad_time_1;
    float _pad_time_2;
    ivec4 entry_counts;   // x = num_geom, y = num_tree, z = num_line
};

struct GeomEntry {
    vec4 vis_min;
    vec4 vis_max;
    vec4 bounds_min;
    vec4 bounds_max;
    vec4 corner_dis;
    vec4 power_vals;
    vec4 power_vals_2;
    vec4 thick_vals;
    vec4 center_point;
    vec4 mat;              // material_id, normal_id, modifier, _pad
};

struct TreeEntry {
    vec4 vis_min;
    vec4 vis_max;
    vec4 p0;
    vec4 p1;
    vec4 p2;
    vec4 power_vals;
    vec4 power_vals_2;
    vec4 thick_vals;
    vec4 center_point;
    vec4 mat;
};

struct LineEntry {
    vec4 vis_min;
    vec4 vis_max;
    vec4 origin;
    vec4 tangent;
    vec4 bitangent;
    vec4 normal;
    vec4 rad0;
    vec4 rad1;
    vec4 center_point;
    vec4 mat;
};

layout(std430, binding = 3) readonly buffer GeomEntries { GeomEntry geom[]; };
layout(std430, binding = 4) readonly buffer TreeEntries { TreeEntry tree[]; };
layout(std430, binding = 5) readonly buffer LineEntries { LineEntry line[]; };

layout(std140, binding = 6) uniform VoronoiU {
    vec4 voro[27];
};

layout(binding = 7) uniform usampler2D road_raster;
layout(binding = 8) uniform usampler2D building_interior;

const float VOLUME_PITCH = 128.0;
const float MAX_HEIGHT   = 128.0;
const int   MATERIAL_COUNT = 17;

// Material ids (mirrors c3voxel::voxel::Material). M8 packs the id into the
// volume's .b channel; the palette LUT turns it into color at the lighting
// pass. No more baked RGB in the volume.
const int MAT_NULL  = 0;
const int MAT_DIRT  = 2;
const int MAT_STONE = 3;
const int MAT_GRASS = 4;

// Packs the M8 volume value: (.rg=0 placeholder for normal, .b=mat/255, .a=opacity).
vec4 pack_voxel(int material_id, bool opaque)
{
    return vec4(0.0, 0.0, float(material_id) / 255.0, opaque ? 1.0 : 0.0);
}

// Terrain layer: decides the winning material_id from h01 bands.
//   h01 < 0.30  -> STONE
//   h01 < 0.70  -> DIRT
//   else        -> GRASS
// Voxels above the surface return an air packet.
vec4 terrain_packed(float h01, float voxel_y, float surface_y)
{
    if (voxel_y > surface_y) return pack_voxel(MAT_NULL, false);
    int mat_id;
    if (h01 < 0.30)      mat_id = MAT_STONE;
    else if (h01 < 0.70) mat_id = MAT_DIRT;
    else                 mat_id = MAT_GRASS;
    return pack_voxel(mat_id, true);
}

bool aabb_contains(vec3 w, vec3 bmin, vec3 bmax) {
    return all(greaterThanEqual(w, bmin)) && all(lessThanEqual(w, bmax));
}

// Superellipsoid inside-test (simplified for M7.1 smoke: treat as
// symmetric exponents on all three axes, using power_vals.x as p).
bool superellipsoid_inside(vec3 w, GeomEntry e)
{
    vec3 center = e.center_point.xyz;
    vec3 half_extent = (e.bounds_max.xyz - e.bounds_min.xyz) * 0.5;
    if (any(lessThanEqual(half_extent, vec3(0.0)))) return false;
    vec3 d = abs(w - center) / half_extent;
    float p = max(e.power_vals.x, 1.0);
    float v = pow(d.x, p) + pow(d.y, p) + pow(d.z, p);
    return v <= 1.0;
}

// eval_* return a (material_id, opaque) pair encoded in ivec2; material 0 = air.
ivec2 eval_geom(vec3 w, GeomEntry e)
{
    if (!superellipsoid_inside(w, e)) return ivec2(MAT_NULL, 0);
    return ivec2(int(e.mat.x), 1);
}

ivec2 eval_tree(vec3 w, TreeEntry e)
{
    vec3 p0 = e.p0.xyz;
    vec3 p1 = e.p1.xyz;
    vec3 p2 = e.p2.xyz;
    float beg_t       = e.thick_vals.x;
    float end_t       = e.thick_vals.y;
    float sph         = e.thick_vals.z;
    int   leaf_mat_id = int(e.thick_vals.w);

    // VQ tangent-line approximation: project onto the P0->P2 chord to estimate t,
    // evaluate the Bezier at that t, use Euclidean distance.
    vec3  chord    = p2 - p0;
    float chord_sq = dot(chord, chord);
    if (chord_sq < 1e-4) {
        if (sph > 0.0 && distance(w, p2) < sph) return ivec2(leaf_mat_id, 1);
        return ivec2(MAT_NULL, 0);
    }
    float t        = clamp(dot(w - p0, chord) / chord_sq, 0.0, 1.0);
    float omt      = 1.0 - t;
    vec3  on_bezier = omt * omt * p0 + 2.0 * omt * t * p1 + t * t * p2;
    float d_branch  = distance(w, on_bezier);
    float thickness = mix(beg_t, end_t, t);

    if (d_branch < thickness) {
        return ivec2(int(e.mat.x), 1);
    }
    if (sph > 0.0 && distance(w, p2) < sph) {
        return ivec2(leaf_mat_id, 1);
    }
    return ivec2(MAT_NULL, 0);
}

ivec2 eval_line(vec3 w, LineEntry e) { return ivec2(11, 1); }     // DEBUG magenta stub

void main()
{
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3  uvw   = (vec3(voxel) + 0.5) / vec3(VOLUME_PITCH);
    vec3  world = mix(world_min.xyz, world_max.xyz, uvw);

    // 1. Terrain base.
    vec2  hm_uv = (world.xz - block_origin.xz) / block_extent.xz;
    float h01   = texture(heightmap, hm_uv).r;
    float h_w   = h01 * MAX_HEIGHT;
    vec4  result = terrain_packed(h01, world.y, h_w);

    // 1b. Road override: if this voxel is the surface voxel at (world.xz) AND
    // the block's road raster has ROAD_BIT set here, paint it STONE (id 3).
    uint road_flags = texture(road_raster, hm_uv).r;
    if ((road_flags & 1u) != 0u && int(floor(world.y)) == int(floor(h_w))) {
        result = pack_voxel(MAT_STONE, true);
    }

    // 2. Trees: iterate all entries with branch-priority-over-leaf precedence.
    // See pre-M8 generate.comp.glsl for the rationale behind the branch-vs-leaf
    // scan: nearest-match on center_point paints leaves over trunks, so we walk
    // every tree entry per voxel and let branches override previously-set leaf
    // hits.
    int  tree_mat   = MAT_NULL;
    bool tree_opaque = false;
    bool tree_branch_hit = false;
    for (int i = 0; i < entry_counts.y; i++) {
        TreeEntry e = tree[i];
        if (!aabb_contains(world, e.vis_min.xyz, e.vis_max.xyz)) continue;
        vec3 p0 = e.p0.xyz;
        vec3 p1 = e.p1.xyz;
        vec3 p2 = e.p2.xyz;
        float beg_t       = e.thick_vals.x;
        float end_t       = e.thick_vals.y;
        float sph         = e.thick_vals.z;
        int   leaf_mat_id = int(e.thick_vals.w);

        vec3  chord    = p2 - p0;
        float chord_sq = dot(chord, chord);
        if (chord_sq < 1e-4) {
            // Degenerate Bezier (p0 ≈ p2): the branch-distance projection
            // blows up to 0 or 1 uniformly, painting the whole vis-AABB as
            // "inside branch" and producing stray wood blobs. Skip the
            // branch test; still allow the leaf sphere.
            if (sph > 0.0 && distance(world, p2) < sph) {
                tree_mat    = leaf_mat_id;
                tree_opaque = true;
            }
            continue;
        }
        float t        = clamp(dot(world - p0, chord) / chord_sq, 0.0, 1.0);
        float omt      = 1.0 - t;
        vec3  on_bezier = omt * omt * p0 + 2.0 * omt * t * p1 + t * t * p2;
        float d_branch  = distance(world, on_bezier);
        float thickness = mix(beg_t, end_t, t);

        if (d_branch < thickness) {
            tree_mat        = int(e.mat.x);
            tree_opaque     = true;
            tree_branch_hit = true;
            break;    // branch wins; stop scanning
        }
        if (!tree_branch_hit && sph > 0.0 && distance(world, p2) < sph) {
            tree_mat    = leaf_mat_id;
            tree_opaque = true;
            // keep scanning — later entry's branch may still override
        }
    }

    // 3. Geometry (buildings): UNION across GeomEntry, matching section 2's
    // tree loop. Evaluating only the nearest-by-xz entry (the prior scheme)
    // left Swiss-cheese gaps at overlapping entry boundaries: the k-level
    // seams of stacked wall superellipsoids (p=4, half_y=4) false-negate
    // at off-centre columns where d.x⁴ + d.y⁴ > 1, and so do the matching
    // neighbour wall / roof slabs that SHOULD backfill those voxels. With
    // nearest-only, the single "winner" entry says air, and the adjacent
    // overlapping entry is never consulted — ground shadows from walls
    // disappeared because col_top's upward scan hit those gaps and halted
    // well below the actual column top. Union fixes this: any entry whose
    // superellipsoid accepts the voxel makes it opaque. First-wins order
    // preserves the implicit material precedence from building_emit_to_page
    // (roof slab pushed before walls → SHINGLE beats PLASTER at shared y).
    int  geom_mat    = MAT_NULL;
    bool geom_opaque = false;
    for (int i = 0; i < entry_counts.x; i++) {
        GeomEntry e = geom[i];
        if (!aabb_contains(world, e.vis_min.xyz, e.vis_max.xyz)) continue;
        ivec2 g = eval_geom(world, e);
        if (g.y != 0) {
            geom_mat    = g.x;
            geom_opaque = true;
            break;
        }
    }

    // 4. Composite: geometry wins over trees (buildings occlude); trees over
    // terrain. Volume stores (0, 0, material_id/255, opacity) — normals come
    // from a separate central-difference pass in M8.
    if (geom_opaque) {
        result = pack_voxel(geom_mat, true);
    } else if (tree_opaque) {
        result = pack_voxel(tree_mat, true);
    }

    // M7.4 FILL_TERRAIN: DISABLED (quick-diagnostic) — the interior carve was
    // overwriting wall voxels with vec4(0). The fill_terrain mask sets bits
    // for Y levels [adj_h+1, adj_h+3] over the full 8x8 tile footprint, while
    // walls are emitted at tile-Y levels {adj_h, adj_h+1, adj_h+2}. The
    // overlap erases the top two thirds of every wall (and with tile-texel
    // rounding at boundaries, sometimes the bottom level too), making
    // buildings invisible. Leaving this off for M7.4 until fill_terrain is
    // redesigned in M8 to properly exclude the wall footprint.
    // TODO(M8): re-enable with a corrected mask that carves only the room
    // interior volume, not the wall cells.
    // uint interior_mask = texture(building_interior, hm_uv).r;
    // int  y_tile = int(floor(world.y / 8.0));
    // if (y_tile >= 0 && y_tile < 16 && (interior_mask & (1u << uint(y_tile))) != 0u) {
    //     result = vec4(0.0);
    // }

    imageStore(volume, voxel, result);
}
