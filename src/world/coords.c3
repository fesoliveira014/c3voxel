module c3voxel::world;

const int PIXELS_PER_PAGE        = 128;
const int PAGES_PER_HOLDER       = 2;
// A block is the unit of heightmap (and road raster) CPU/GPU storage. The
// heightmap covers exactly `PIXELS_PER_PAGE * PAGES_PER_HOLDER * HOLDERS_PER_BLOCK`
// world pixels per axis. If HOLDERS_PER_BLOCK is larger than the heightmap's
// nominal axis pixel count (via BLOCK_HEIGHTMAP_PIXELS), holders at the
// outer ring sample past the edge of their block's heightmap and get
// clamped to a constant — visible as flat terrain on all but the focus
// holder. Keep these two in lockstep.
const int HOLDERS_PER_BLOCK      = 2;
const int VOLUME_PITCH           = 128;
const int ACTIVE_HOLDERS_PER_AXIS = 2;

// World-space integer pixel coordinate. Used for page/holder/block
// bounds in world units (distinct from screen Pixel in core::).
typedef WorldPixel  = inline int;
// World-space metric length. Future physics/collision code will need
// this once the engine leaves pure-rendering territory.
typedef Meter       = inline float;
typedef PageCoord   = inline int;
typedef HolderCoord = inline int;
typedef BlockCoord  = inline int;
