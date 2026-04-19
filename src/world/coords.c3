module c3voxel::world;

const int PIXELS_PER_PAGE        = 128;
const int PAGES_PER_HOLDER       = 2;
const int HOLDERS_PER_BLOCK      = 8;
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
