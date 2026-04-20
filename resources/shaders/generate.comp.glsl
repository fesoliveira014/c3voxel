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

const float VOLUME_PITCH = 128.0;
const float MAX_HEIGHT   = 128.0;
const int   MATERIAL_COUNT = 17;

vec4 material_color(int id) {
    // Mirror of MATERIAL_DEBUG_PALETTE. M8 replaces with a palette LUT texture.
    if (id == 0)  return vec4(0.0, 0.0, 0.0, 0.0);           // NULL
    if (id == 1)  return vec4(0.95, 0.80, 0.10, 1.0);        // GOLD
    if (id == 2)  return vec4(0.55, 0.40, 0.25, 1.0);        // DIRT
    if (id == 3)  return vec4(0.45, 0.45, 0.48, 1.0);        // STONE
    if (id == 4)  return vec4(0.30, 0.60, 0.25, 1.0);        // GRASS
    if (id == 5)  return vec4(0.90, 0.85, 0.55, 1.0);        // SAND
    if (id == 6)  return vec4(0.70, 0.70, 0.65, 1.0);        // MORTAR
    if (id == 7)  return vec4(0.50, 0.32, 0.18, 1.0);        // WOOD
    if (id == 8)  return vec4(0.65, 0.30, 0.22, 1.0);        // BRICK
    if (id == 9)  return vec4(0.45, 0.35, 0.30, 1.0);        // SHINGLE
    if (id == 10) return vec4(0.90, 0.88, 0.82, 1.0);        // PLASTER
    if (id == 11) return vec4(1.00, 0.00, 1.00, 1.0);        // DEBUG
    if (id == 12) return vec4(0.20, 0.40, 0.70, 0.6);        // WATER
    if (id == 13) return vec4(0.75, 0.75, 0.80, 1.0);        // METAL
    if (id == 14) return vec4(0.85, 0.95, 1.00, 0.4);        // GLASS
    if (id == 15) return vec4(0.35, 0.25, 0.18, 1.0);        // EARTH
    return vec4(0.28, 0.20, 0.15, 1.0);                       // BARK
}

vec4 terrain_color(float h01, float voxel_y, float surface_y)
{
    if (voxel_y > surface_y) return vec4(0.0);
    vec3 col;
    if (h01 < 0.30)       col = vec3(0.45, 0.45, 0.48);
    else if (h01 < 0.70)  col = vec3(0.55, 0.40, 0.25);
    else                  col = vec3(0.30, 0.60, 0.25);
    float shade = clamp(1.0 - (surface_y - voxel_y) / MAX_HEIGHT, 0.4, 1.0);
    return vec4(col * shade, 1.0);
}

float voronoi_grad(vec3 w)
{
    float min1 = 1e30;
    float min2 = 1e30;
    for (int i = 0; i < 27; i++) {
        float d = distance(w, voro[i].xyz);
        if (d < min1)      { min2 = min1; min1 = d; }
        else if (d < min2) { min2 = d; }
    }
    float denom = min1 + min2;
    if (denom <= 0.0001) return 1.0;
    return 1.0 - (min1 * 2.0) / denom;
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

vec4 eval_geom(vec3 w, GeomEntry e)
{
    if (!superellipsoid_inside(w, e)) return vec4(0.0);
    vec4 col = material_color(int(e.mat.x));
    return col;
}

vec4 eval_tree(vec3 w, TreeEntry e)
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
        // Degenerate chord — skip branch test; leaf sphere still counts.
        if (sph > 0.0 && distance(w, p2) < sph) return material_color(leaf_mat_id);
        return vec4(0.0);
    }
    float t        = clamp(dot(w - p0, chord) / chord_sq, 0.0, 1.0);
    float omt      = 1.0 - t;
    vec3  on_bezier = omt * omt * p0 + 2.0 * omt * t * p1 + t * t * p2;
    float d_branch  = distance(w, on_bezier);
    float thickness = mix(beg_t, end_t, t);

    if (d_branch < thickness) {
        return material_color(int(e.mat.x));
    }
    if (sph > 0.0 && distance(w, p2) < sph) {
        return material_color(leaf_mat_id);
    }
    return vec4(0.0);
}

vec4 eval_line(vec3 w, LineEntry e) { return vec4(1.0, 0.0, 1.0, 1.0); }     // M7.4 stub

void main()
{
    ivec3 voxel = ivec3(gl_GlobalInvocationID);
    vec3  uvw   = (vec3(voxel) + 0.5) / vec3(VOLUME_PITCH);
    vec3  world = mix(world_min.xyz, world_max.xyz, uvw);

    // 1. Terrain base.
    vec2  hm_uv = (world.xz - block_origin.xz) / block_extent.xz;
    float h01   = texture(heightmap, hm_uv).r;
    float h_w   = h01 * MAX_HEIGHT;
    vec4  result = terrain_color(h01, world.y, h_w);

    // 1b. Road override: if this voxel is the surface voxel at (world.xz) AND
    // the block's road raster has ROAD_BIT set here, paint it with DIRT (id 2).
    uint road_flags = texture(road_raster, hm_uv).r;
    if ((road_flags & 1u) != 0u && int(floor(world.y)) == int(floor(h_w))) {
        result = material_color(3);   // STONE — distinct from DIRT-banded terrain
    }

    // 2. Trees: iterate all entries with branch-priority-over-leaf precedence.
    // Nearest-match on center_point doesn't work for trees because child
    // leaf-sphere centers often sit closer to trunk voxels than the trunk
    // entry itself, hiding trunks behind leaves. Iterate + test each shape.
    vec4 tree_color = vec4(0.0);
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
                tree_color = material_color(leaf_mat_id);
            }
            continue;
        }
        float t        = clamp(dot(world - p0, chord) / chord_sq, 0.0, 1.0);
        float omt      = 1.0 - t;
        vec3  on_bezier = omt * omt * p0 + 2.0 * omt * t * p1 + t * t * p2;
        float d_branch  = distance(world, on_bezier);
        float thickness = mix(beg_t, end_t, t);

        if (d_branch < thickness) {
            tree_color = material_color(int(e.mat.x));
            tree_branch_hit = true;
            break;    // branch wins; stop scanning
        }
        if (!tree_branch_hit && sph > 0.0 && distance(world, p2) < sph) {
            tree_color = material_color(leaf_mat_id);
            // keep scanning — later entry's branch may still override
        }
    }

    // 3. Geometry (buildings): nearest-match across GeomEntry.
    float best_dis  = 1e30;
    int   best_geom = -1;
    for (int i = 0; i < entry_counts.x; i++) {
        GeomEntry e = geom[i];
        if (!aabb_contains(world, e.vis_min.xyz, e.vis_max.xyz)) continue;
        // VQ uses XZ-plane distance (not 3D): a tall wall's center_point sits
        // near its Y-midpoint, so a voxel high in the wall wouldn't "belong"
        // to it under 3D distance — a shorter neighbouring wall would win. XZ
        // distance avoids this and matches the procedural-generation-vq.md §6.3
        // snippet (`testDisXY = distance(worldPos.xy, centerPt.xy)`).
        float d = distance(world.xz, e.center_point.xz);
        if (d < best_dis) { best_dis = d; best_geom = i; }
    }
    vec4 geom_color = vec4(0.0);
    if (best_geom >= 0) {
        geom_color = eval_geom(world, geom[best_geom]);
    }

    // 4. Composite: geometry wins over trees (buildings occlude); trees over
    // terrain. Voronoi modulation applies to whichever entry painted.
    bool hit = false;
    if (geom_color.a > 0.0) {
        result = geom_color;
        hit = true;
    } else if (tree_color.a > 0.0) {
        result = tree_color;
        hit = true;
    }
    if (hit) {
        float g = voronoi_grad(world);
        result.rgb *= mix(0.85, 1.00, g);
    }

    imageStore(volume, voxel, result);
}
