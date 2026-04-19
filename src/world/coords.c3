module c3voxel::world;

const int PIXELS_PER_PAGE   = 128;
const int PAGES_PER_HOLDER  = 2;
const int HOLDERS_PER_BLOCK = 8;
const int VOLUME_PITCH      = 128;

typedef WorldPixel  = inline int;
typedef Meter       = inline float;
typedef PageCoord   = inline int;
typedef HolderCoord = inline int;
typedef BlockCoord  = inline int;
alias   Pixel       = int;
