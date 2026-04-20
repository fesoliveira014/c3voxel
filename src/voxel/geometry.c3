module c3voxel::voxel;

import c3voxel::core;

// 4096 entries × (tree | geom | line) SSBO. Post-M7.4 cross-page tree
// emit folds canopy branches from the 3×3 page neighbourhood into each
// page's tree SSBO; for a page with corner trees near 4 holders, ~9
// source pages × 5–8 trees × ~60 branches per tree tops out around 2–3k
// entries before the shader truncates at the cap. With 1024 the tail of
// the list was silently dropped and canopies appeared sliced at holder
// corners.
const int MAX_ENTRIES_PER_PAGE = 4096;

// Material reference carried by every entry. 16 B, std430 / std140-compatible.
struct MaterialParams @packed {
    float material_id;    // Material cast to float for GPU use
    float normal_id;       // reserved (M8 lighting)
    float modifier;         // reserved (per-entry shading variant)
    float _pad;
}
$assert(MaterialParams.sizeof == 16);

// Superellipsoid / bounded-shape entry. Mirrors VQ's E_GP_* slot layout.
// Since all fields are Vec4 / 16-B struct, std430 packs identically to std140.
//
// Fields not read by the M7.1 smoke evaluator (corner_dis, power_vals_2,
// thick_vals) are reserved to mirror VQ's layout; the smoke generator zeroes
// them. M7.4 consumers fill them in without a struct churn.
struct GeomEntry @packed @align(16) {
    core::Vec4     vis_min;          // visibility AABB (skip entry if voxel outside)
    core::Vec4     vis_max;
    core::Vec4     bounds_min;        // superellipsoid fit AABB
    core::Vec4     bounds_max;
    core::Vec4     corner_dis;         // reserved (VQ E_GP_CORNERDISINPIXELS)
    core::Vec4     power_vals;         // superellipsoid exponents p (x), q (y)
    core::Vec4     power_vals_2;        // reserved
    core::Vec4     thick_vals;          // reserved
    core::Vec4     center_point;
    MaterialParams mat;
}
$assert(GeomEntry.sizeof % 16 == 0);

// Bezier-branch entry. Geometry is P0/P1/P2 with begin/end thickness + leaf sphere.
// Defined now so M7.2's Bezier evaluator has a stable struct. Not yet emitted.
struct TreeEntry @packed @align(16) {
    core::Vec4     vis_min;
    core::Vec4     vis_max;
    core::Vec4     p0;
    core::Vec4     p1;
    core::Vec4     p2;
    core::Vec4     power_vals;
    core::Vec4     power_vals_2;
    core::Vec4     thick_vals;          // begThickness (x), endThickness (y), sphereRad (z)
    core::Vec4     center_point;
    MaterialParams mat;
}
$assert(TreeEntry.sizeof % 16 == 0);

// Line-geometry entry (lanterns, thin walls). Matches VQ's E_AP_*.
struct LineEntry @packed @align(16) {
    core::Vec4     vis_min;
    core::Vec4     vis_max;
    core::Vec4     origin;
    core::Vec4     tangent;
    core::Vec4     bitangent;
    core::Vec4     normal;
    core::Vec4     rad0;
    core::Vec4     rad1;
    core::Vec4     center_point;
    MaterialParams mat;
}
$assert(LineEntry.sizeof % 16 == 0);
