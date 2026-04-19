# Procedural Generation Algorithms

This document describes the procedural generation algorithms in VoxelQuest: how the world gets built from a handful of seeds, heightmaps, and grammar rules. These algorithms run in layers, each producing input for the next: terrain macrostructure → road networks → building layout → individual geometry → material variation → per-voxel evaluation on GPU.

The algorithms are notable for what they don't do. Nothing gets meshed. No textures are baked. No chunks are serialized. Everything is re-derived from seed parameters every time a page is visited, which is why the streaming architecture can afford to throw away volume textures between frames.

---

## 1. Terrain: Simplex Noise Plus Heightmap Stitching

Terrain is the foundation that everything else sits on. VoxelQuest builds it in two steps: low-frequency macrostructure via multi-octave simplex noise, then micro-detail by sampling supplied heightmap images.

### Multi-octave simplex

The CPU-side noise library (`f00240_simplex.h`) is a standard Perlin-style simplex implementation in 2D, 3D, and 4D. The workhorse is `simplexNoise(octaves, persistence, scale, x, y, z)`:

```cpp
float simplexNoise(float octaves, float persistence, float scale, float x, float y, float z) {
    float total = 0;
    float frequency = scale;
    float amplitude = 1;
    float maxAmplitude = 0;

    for (int i = 0; i < octaves; i++) {
        total += simplexRawNoise(x*frequency, y*frequency, z*frequency) * amplitude;
        frequency *= 2;
        maxAmplitude += amplitude;
        amplitude *= persistence;
    }
    return total / maxAmplitude;
}
```

Each octave doubles frequency and multiplies amplitude by persistence (usually 0.5). Summing them produces fractal terrain — broad mountains at the low octaves, fine wrinkles at the high ones. The final division by `maxAmplitude` normalizes to `[-1, 1]`.

### Heightmap stitching

Raw simplex alone produces generic rolling terrain. To get biome-scale variation — specific mountain ranges, coastlines, deserts — VoxelQuest uses simplex output as a *blend weight* between pre-drawn heightmap textures. The mixing happens in `TerrainMix.c`:

```glsl
uniform sampler2D Texture0; // simplexFBO — the noise mask
uniform sampler2D Texture1; // imageHM0  — first heightmap pack (3 channels)
uniform sampler2D Texture2; // imageHM2  — second heightmap pack

void main() {
    vec4 tex0 = texture2D(Texture0, (TexCoord0.xy + paramArrMap[8].xy));
    vec4 tex1 = texture2D(Texture1, (TexCoord0.xy + paramArrMap[9].xy) * mapSampScale);
    vec4 tex2 = texture2D(Texture2, (TexCoord0.xy + paramArrMap[10].xy) * mapSampScale);

    float[6] vals = { tex1.r, tex1.g, tex1.b, tex2.r, tex2.g, tex2.b };
    float[6] sv;
    for (int i = 0; i < 6; i++) {
        sv[i] = vals[int(paramArrMap[i].x)];   // indirection lets art team pick channels
    }

    float v0 = sv[0] * tex0.r;    // simplex RGB acts as blend weights
    float v1 = sv[1] * tex0.g;
    float v2 = sv[2] * tex0.b;

    float h = pow(max(max(v0, v1), v2), 0.4);
    h = pow(h, 1.5);
    gl_FragData[0] = vec4(clamp(h, 0.0, 1.0), 0.0, 0.0, 0.0);
}
```

The simplex texture is generated as RGB via three independent calls with offset Z coordinates, which produces a smooth partitioning of the world into three zones. Those zones pick between six heightmap channels. The `max` reduction means the dominant zone wins in each region with smooth transitions at the borders.

### Recursive detail sampling

For a voxel query at world position `p`, the heightmap value comes from a second pass (`TopoShader.c`) that samples the stitched map at multiple frequencies:

```glsl
// Pseudocode of the topo shader
float h = 0.0;
for (int i = 0; i < NUM_OCTAVES; i++) {
    h += sample_heightmap(p.xy * mapFreqs[i]) * mapAmps[i];
}
```

This lets macro-scale terrain (stitched at world scale) be refined with micro-scale noise (sampled at 10×, 100× frequency) without storing that detail anywhere. It's the same fractal trick as simplex itself, applied on top of the heightmap.

### Sea level by histogram

The planet's sea level isn't hardcoded — it's chosen after terrain generation to make a target fraction of the world water. The engine histograms heights across the map, then picks the height at which (say) 65% of the planet is below. This means continents and oceans emerge from whatever noise parameters were used, rather than needing to be calibrated by hand.

---

## 2. Road Networks: Two Algorithms on the Same FBO

Roads are drawn as pixel trails onto a shared "world FBO" that multiple channels write to (`blockChannel`, `btChannel`, `pathChannel`, `hmChannel`). The algorithms don't know about each other — they just write their own channel and read others' as needed.

### City interiors: recursive backtracking maze

Within each city, VoxelQuest runs a classic maze-generation algorithm (recursive backtracking on a grid) over the city's pixel footprint. From `f00380_gameworld.hpp`:

```cpp
btStack[0] = fbow2->getIndex(provinceX[i], provinceY[i]);
btStackInd = 0;

while (btStackInd > -1) {
    curInd = btStack[btStackInd];
    // look at 4 neighbors in randomized order
    do {
        curDir = (startDir + count) % 4;
        testX = curX + dirModX[curDir];
        testY = curY + dirModY[curDir];
        testPix = fbow2->getPixelAtIndex(testInd, btChannel);

        if ((testPix & visFlag) == 0 && (testPix3 != 0)) {
            // unvisited and inside city — prefer smallest height delta
            delta = abs(fbow->getPixelAtIndex(curInd, hmChannel) -
                        fbow->getPixelAtIndex(testInd, hmChannel));
            if (delta < bestDelta) {
                bestDelta = delta; bestDir = curDir; bestInd = testInd;
            }
        }
        count++;
    } while (count < 4);

    if (notFound) { btStackInd--; }           // dead end, back up
    else {
        // knock down the wall between curInd and bestInd
        fbow2->andPixelAtIndex(curInd, btChannel, dirFlags[bestDir]);
        fbow2->andPixelAtIndex(bestInd, btChannel, dirFlagsOp[bestDir]);
        btStackInd++;
        btStack[btStackInd] = bestInd;
    }
}
```

The neat twist: when choosing which unvisited neighbor to dig toward, the algorithm prefers the one with the smallest terrain height delta. This produces roads that follow contours instead of climbing cliffs — something a pure maze wouldn't give you. You still get maze-like cul-de-sacs (which read as winding alleys), but main paths naturally find the flat routes.

Over this maze-level network, a second pass overlays major thoroughfares at fixed intervals (`blockSizeInLots`), giving you a city with both main roads and organic back streets.

### Inter-city roads: midpoint displacement with weighted paths

Connecting cities is done by a recursive midpoint displacement algorithm that chooses the cheapest path between two points:

```cpp
float bestPath(float x1, float y1, float x2, float y2, int generation,
               int roadIndex, bool doSet, bool isOcean) {
    float mpx = (x1 + x2) / 2.0;
    float mpy = (y1 + y2) / 2.0;
    float dis = quickDis(x1, y1, x2, y2);
    float rad = dis / 2.0;

    if (rad < 2.0f || generation > 1024) {
        // Base case: draw a Manhattan-distance line into pathChannel
        if (doSet) {
            while (ibx != ix2) { curFBO2->setPixelAtWrapped(ibx, iby, pathChannel, 255); ... }
        }
        return 0.0f;
    }

    // Try numTries random midpoint offsets, pick lowest-cost
    float bestDelta = FLT_MAX;
    for (int i = 0; i < numTries; i++) {
        mpxTemp = mpx + (fGenRand() * dis - rad) / 2.0f;
        mpyTemp = mpy + (fGenRand() * dis - rad) / 2.0f;

        delta = weighPath(x1, y1, mpxTemp, mpyTemp, rad/2.0f, doSet, isOcean)
              + weighPath(mpxTemp, mpyTemp, x2, y2, rad/2.0f, doSet, isOcean);

        if (delta < bestDelta) {
            bestDelta = delta;
            bestX = mpxTemp; bestY = mpyTemp;
        }
    }

    // Recurse into both halves around the chosen midpoint
    bestPath(x1, y1, bestX, bestY, generation+1, roadIndex, doSet, isOcean);
    bestPath(bestX, bestY, x2, y2, generation+1, roadIndex, doSet, isOcean);
}
```

The `weighPath` function penalizes:
- Steep terrain (summed height gradient along the proposed segment)
- Water crossings (unless `isOcean=true`, in which case water is rewarded)

By recursively picking the lowest-cost midpoint, the algorithm naturally routes around mountains and along rivers. The 20-ish random tries per level is enough for the chosen path to be good without being optimal — which is desirable, since optimal routes look suspiciously straight.

**Shipping routes use the same algorithm** with `isOcean=true`, producing trade routes that hug coastlines and thread between islands.

### Junction merging

When a recursive call is deep (`generation < 8`, meaning this is a significant junction), the algorithm checks whether any existing road endpoint is within a merge distance (`min(400, rad)`). If so, the new path snaps to the existing endpoint instead of creating a parallel road a few pixels away:

```cpp
if (curDis < min(400.0f, rad)) {
    baseCoord = bestCoord;   // snap to existing junction
    baseCoord.index = roadIndex;
}
roadCoords.push_back(baseCoord);
```

This is what makes the road network look intentional rather than like a bunch of independent paths that happen to run near each other.

---

## 3. Buildings: Grammar on a 3D Node Grid

Buildings are the most elaborate part of the generator. Each `GameBlock` owns a 3D grid of `BuildingNode` structs (`f00026_enums.h`):

```cpp
struct BuildingCon {
    int conType;              // E_CT_ROAD, E_CT_WING, E_CT_DOORWAY, etc.
    unsigned int nodeFlags;   // BC_FLAG_INSIDE | BC_FLAG_WING_BEG | BC_FLAG_WING_END
    float wingMult;           // thickness/width multiplier for this segment
    float wallRadInMeters;
    int heightDelta;
    int direction;            // -1, 0, +1 for surface normal orientation
};

struct BuildingNode {
    BuildingCon con[TOT_NODE_VALS];  // 6 directions × 2 layers = 12 connections
    int mazeIndex;
    int id;
    int visited;
    float powerValU, powerValV;
    bool nearTerrain, nearAir;
};
```

Each node has up to 12 connections (6 axis directions × 2 logical layers — foundation and superstructure). The building is "the set of all non-null `BuildingCon` entries in the grid." Geometry comes later by walking this graph.

### Phased generation

Building generation proceeds in discrete phases (`E_BG_*` enum), each doing one thing, each reading the results of the previous:

```
E_BG_ROADS_AND_BUILDINGS   → drop foundation cells under roads and wings
E_BG_BASEMENTS             → (commented out; would dig underground rooms)
E_BG_WING_TIPS             → flag nodes at wing endpoints for dormer treatment
E_BG_DOORS                 → identify WINDOWFRAME vs DOORWAY by adjacent roads
E_BG_FILL_TERRAIN          → carve out terrain inside rooms
```

The outer loop walks all nodes at all Z levels for each phase:

```cpp
for (n = 0; n < E_BG_LENGTH; n++) {
    incVal = (n == E_BG_DOORS) ? 1 : 2;
    for (ktemp = 0; ktemp < terDataBufPitchZ; ktemp++) {
        // Fill terrain runs top-down; others bottom-up
        k = (n == E_BG_FILL_TERRAIN) ? (terDataBufPitchZ - 1 - ktemp) : ktemp;
        for (j = 0; ...) for (i = 0; ...) {
            curInd = getNodeIndex(i, j, k, 0);
            for (m = 0; m < 6; m += incVal) {
                conType = buildingData[curInd].con[m].conType;
                switch (n) { /* per-phase logic */ }
            }
        }
    }
}
```

### Phase detail: ROADS_AND_BUILDINGS

The first phase walks the 2D `mapData[]` layer (which was populated from the road-generation FBO) and extrudes foundations and walls:

```cpp
case E_BG_ROADS_AND_BUILDINGS:
    if (m < 4) {  // horizontal directions only
        testInd  = getMapNodeIndex(i, j, 0);
        testInd2 = getMapNodeIndex(i + dirModX[m], j + dirModY[m], 0);

        curBT    = mapData[testInd].connectionProps[m];   // E_CT_ROAD, WING, MAINHALL
        testVal  = mapData[testInd].adjustedHeight;
        testVal2 = mapData[testInd2].adjustedHeight;

        switch (curBT) {
            case E_CT_ROAD:
            case E_CT_MAINHALL:
            case E_CT_WING:
                if (testVal == (k+1)) {   // at ground level for this column
                    connectNodes(
                        i, j, k,
                        i + dirModX[m], j + dirModY[m], k + dirModZ[m],
                        E_CT_FOUNDATION, -1,
                        testVal2 - testVal,   // stair-step if heights differ
                        0,
                        wallRadInMeters + 1.0f
                    );
                }
                break;
        }
    }
    break;
```

Where a road pixel meets the terrain surface, foundation connections go in. Where a building footprint (wing/mainhall) exists, the wall framework extends upward.

### Phase detail: DOORS and windows

Later phases refine by looking at neighbors. Windows vs doors are identified by checking whether a wing connection is *adjacent to a road*:

```cpp
curBT = E_CT_WINDOWFRAME;   // default
testInd = getNodeIndex(i + dirModX[m], j + dirModY[m], k, 0);
if (testInd > -1) {
    if (ctClasses[buildingData[testInd].con[m].conType] == E_CTC_ROAD) {
        curBT = E_CT_DOORWAY;   // upgrade window → doorway because it faces a road
    }
}

connectNodes(i, j, k, i+dirModX[m], j+dirModY[m], k+dirModZ[m], curBT, ...);
```

And lanterns are placed automatically on the interior side of every window frame:

```cpp
if (curDir == 1 && curBT == E_CT_WINDOWFRAME) {
    nodeFlags |= BC_FLAG_INSIDE;
    connectNodes(i, j, k, i+dirModX[m], j+dirModY[m], k+dirModZ[m],
                 E_CT_LANTERN, -1, 0, curDir, -1.0f, nodeFlags);
}
```

This is the kind of detail that would be prohibitive to hand-place but emerges naturally from the node-graph representation.

### Wing propagation

For long runs along a wing, the endpoints need marking so geometry can taper them (thinner at tip, thicker at center). `applyWingValues()` walks axis-aligned runs and sets `BC_FLAG_WING_BEG` / `BC_FLAG_WING_END` flags on the two endpoints:

```cpp
void applyWingValues(int _x1,_y1,_z1, _x2,_y2,_z2, int cnum, bool isWingBeg, bool isWingEnd, float multiplier) {
    // swap so x1<x2 etc.
    if (x1 > x2) std::swap(x1, x2);
    if (y1 > y2) std::swap(y1, y2);

    int baseDir = 0;
    if ((x1 == x2) && (y1 == y2)) baseDir = 4;   // vertical run
    else if (x1 == x2) baseDir = 2;              // N/S run
    else if (y1 == y2) baseDir = 0;              // E/W run

    finalInd1 = baseDir + cnum * MAX_NODE_DIRS;
    finalInd2 = baseDir + 1 + cnum * MAX_NODE_DIRS;

    buildingData[ind1].con[finalInd1].nodeFlags |= (isWingBeg ? BC_FLAG_WING_BEG : 0)
                                                 | (isWingEnd ? BC_FLAG_WING_END : 0);
    buildingData[ind1].con[finalInd1].wingMult = multiplier;
    // ... mirror on the other endpoint, swapping flags
}
```

### Height consistency iteration

Building heights are computed from the underlying terrain, but neighbors need to match or look stepped. The algorithm iterates until stable or it hits 16 passes:

```cpp
do {
    notFound = false;
    for each mapNode (i, j) {
        m = mapData[curInd].adjustedHeight;
        for each neighbor direction {
            p = max(p, mapData[testInd].adjustedHeight);
        }
        if (p - m > 1) {
            mapData[curInd].adjustedHeight = p - 1;
            notFound = true;    // raised, so need another pass
        }
        if (newSeaLev > mapData[curInd].adjustedHeight) {
            mapData[curInd].adjustedHeight = max(..., newSeaLev);
            notFound = true;
        }
    }
    counter++;
} while (notFound && (counter < 16));
```

This smoothing pass is what prevents buildings from having one-node cliffs between adjacent rooms. The sea level check also ensures waterfront buildings don't have floors below water.

---

## 4. Trees: L-System With Quadratic Béziers

Trees are generated by a recursive grammar (`f00341_gameplant.hpp`). Each plant type is defined by a `PlantRules` struct:

```cpp
struct PlantRules {
    float numChildren[2];          // {min, max} children per node
    float divergenceAngleV[2];     // {min, max} angle from parent tangent
    float begThickness;            // thickness at root (scaled to pixelsPerMeter)
    float endThickness;            // thickness at tip
    float curLength[MAX_PLANT_GEN];// length per generation level
    float sphereGen;               // which generation gets leaf spheres (-1 = none)
    float sphereRad;               // leaf sphere radius
    float numGenerations;          // recursion depth
    float angleUniformityU;        // 0 = fully random spacing, 1 = perfectly regular
    float isInit;
};
```

Six variants are defined: `OAK_TRUNK`, `OAK_ROOTS`, `OAK2_TRUNK`, `OAK2_ROOTS`, `BARE_OAK_TRUNK`, `BARE_OAK_ROOTS`. Trunk and roots are generated independently, with roots getting more generations and narrower divergence angles. For example:

```cpp
pr = &(allPlantRules[E_PT_OAK_TRUNK]);
pr->numChildren[0]      = 2.0f;    // 2-5 children per branch
pr->numChildren[1]      = 5.0f;
pr->divergenceAngleV[0] = pi/3.0f; // 60° ±
pr->divergenceAngleV[1] = pi/6.0f;
pr->begThickness        = 1.0f;
pr->endThickness        = 0.4f;
pr->sphereGen           = 2.0f;    // generation 2 gets leaves
pr->sphereRad           = 6.0f;    // 6-meter leaf blobs
pr->numGenerations      = 2.0f;
pr->angleUniformityU    = 0.75f;
pr->curLength[0] = 6.0f;
pr->curLength[1] = 8.0f;
// ...

pr = &(allPlantRules[E_PT_OAK_ROOTS]);
pr->numChildren[0]      = 2.0f;
pr->divergenceAngleV[0] = pi/8.0f; // 22.5° — roots spread shallower than branches
pr->endThickness        = 0.0f;    // taper to a point underground
pr->sphereGen           = -1.0f;   // no leaves
pr->numGenerations      = 4.0f;    // more generations — fine root network
// ...
```

### Recursive branching

The trunk and root nodes are built from the origin outward by `applyRules()`:

```cpp
void applyRules(PlantRules* rules, GamePlantNode* curParent, int curGen, int maxGen,
                float totLength, float maxLength) {
    float twoPi = 6.283185307f;
    float curLength = rules->curLength[curGen];

    for (int i = 0; i < curParent->numChildren; i++) {
        float fi = ((float)i) / curParent->numChildren;
        GamePlantNode* curChild = &(curParent->children[i]);

        // Children inherit parent's endpoint as their startpoint
        curChild->begPoint.setFXYZRef(&(curParent->endPoint));
        curChild->endPoint.setFXYZRef(&(curParent->endPoint));

        // Distribute children around the parent's tangent direction
        // fi*twoPi spaces them evenly; jitter proportional to (1-angleUniformityU)
        axisRotationInstance.doRotation(
            &tempv0,
            &(curParent->baseShoot),
            &(curParent->tangent),
            fi * twoPi + (fGenRand() - 0.5f) * twoPi * (1.0f - rules->angleUniformityU) / fNumChildren
        );
        curChild->endPoint.addXYZRef(&tempv0, curLength);
        curChild->updateTangent(gv(rules->divergenceAngleV));

        // Thickness interpolates linearly from trunk base to tip along total length
        curLerp = totLength / maxLength;
        curChild->begThickness = mix(rules->begThickness, rules->endThickness, curLerp);
        curLerp = (totLength + curLength) / maxLength;
        curChild->endThickness = mix(rules->begThickness, rules->endThickness, curLerp);

        // Leaves: only children at sphereGen depth get sphere blobs
        if (rules->sphereGen == (float)curGen) {
            curChild->sphereRad = rules->sphereRad * singleton->pixelsPerMeter;
        }

        if (curGen < maxGen) {
            applyRules(rules, curChild, curGen + 1, maxGen,
                       totLength + curLength, maxLength);
        }
    }
}
```

Key observations:
- **`fi*twoPi` gives even angular spacing** around the parent's tangent. The random jitter term adds chaos proportional to `(1 - angleUniformityU)` — OAK_TRUNK uses 0.75 so branches are mostly regular but not mechanically so.
- **Thickness lerps globally**, not per-branch. A child halfway up the tree gets roughly half the total taper, regardless of which parent it stems from.
- **Leaves are tied to a specific generation**, not the terminal branches. Setting `sphereGen = 2` means "all generation-2 branches sprout a leaf ball." Leaves above or below that depth get no sphere.

### Per-branch geometry on GPU

The recursion produces a tree of `GamePlantNode` objects, each holding `begPoint`, `endPoint`, `midThickness`, and optional `sphereRad`. These get flattened into `GameGeom` entries:

```cpp
gameGeom.push_back(new GameGeom());
gameGeom.back()->initTree(
    E_CT_TREE, localGeomCounter, singleton->geomCounter,
    &tempVec,    // P0: parent midpoint (start of bezier)
    &tempVec2,   // P1: current midpoint (control point)
    &tempVec3,   // P2: current begPoint (end — this is where curves bend)
    begThickness * scale,
    endThickness * scale,
    curPlantNode->sphereRad * scale,
    &matParams
);
```

The three points define a **quadratic Bézier curve**. The GPU evaluates each branch by computing the point-to-curve distance using a tangent-line approximation:

```glsl
// In GenerateVolume.c, per voxel
for (int i = 0; i < numTreeEntries; i++) {
    baseInd = i * paramsPerEntry;
    p0 = paramArr[baseInd + E_TP_P0];
    p1 = paramArr[baseInd + E_TP_P1];
    p2 = paramArr[baseInd + E_TP_P2];

    // Quadratic bezier: B(t) = (1-t)²P0 + 2(1-t)t·P1 + t²·P2
    // Point-to-bezier is nonlinear; approximate via tangent line
    vec4 dres = pointSegDistance(worldPosInPixels, p0, p2);   // approx to chord first
    vec3 tangentPos = evaluateBezier(t, p0, p1, p2);           // refine at best-t
    float curDis = distance(worldPosInPixels, tangentPos);

    // Thickness at t lerps between begThickness and endThickness
    float curThickness = mix(begThickness, endThickness, dres.w);

    if (curDis < curThickness) { /* this voxel is inside the branch */ }

    // Plus leaf sphere check at endpoint
    if (sphereRad > 0.0 && distance(worldPosInPixels, p2) < sphereRad) { /* leaf */ }
}
```

The Bézier approximation is fast and good enough — trees render with a natural curved look rather than straight connected segments.

---

## 5. Voronoi for Stone and Brick Patterns

Stone walls, cobblestone roads, and brick patterns share a single cell-pattern mechanism: 3D Voronoi diagrams. But instead of computing Voronoi from arbitrary seeds, VoxelQuest uses a **fixed 3×3×3 grid of perturbed points** per page:

```glsl
uniform vec4 voroArr[27];   // 27 seed positions, one per 3×3×3 cell
```

The seeds are precomputed on the CPU at page generation time. Each seed is a grid center perturbed by a small random offset, deterministically seeded from the page coordinate so it's stable across regenerations.

At evaluation time, the shader finds the two nearest seed points and computes a gradient:

```glsl
vec3 voroPos;
float voroId, voroGrad;

float minDis1 = 99999.0, minDis2 = 99999.0;
vec3 bestPos = vec3(0.0);

for (int i = 0; i < 27; i++) {
    vec3 seed = voroArr[i].xyz;
    float d = distance(worldPosInPixels.xyz, seed);
    if (d < minDis1) {
        minDis2 = minDis1;
        minDis1 = d;
        bestPos = seed;
    } else if (d < minDis2) {
        minDis2 = d;
    }
}

voroGrad = 1.0 - minDis1 * 2.0 / (minDis1 + minDis2);  // 0 at edge, 1 at cell center
voroPos = bestPos;
voroId = randf3(bestPos);   // stable per-cell ID
```

- **`voroGrad`** is 1 at the cell center, 0 at the cell boundary — use as a gentle gradient inside each stone, or as a mortar mask near 0.
- **`voroId`** is a stable per-cell pseudo-random, used to vary color or orientation from stone to stone without breaking the pattern.

Only 27 seeds per page sounds sparse, but at 128-voxel pages it works out to ~40 voxels per cell on average — about the size of a brick or cobblestone. For finer patterns (mortar lines, grain), regular trig functions on local coordinates fill in the detail.

---

## 6. Materials: The `paramArr` System

Every piece of procedural geometry (building wall, tree branch, lantern post) gets serialized into a shared parameter array and uploaded to the GPU once per page. The GPU then iterates that array per voxel to decide what, if anything, that voxel should look like.

### Material IDs

The material ID space is flat `float`-valued:

```glsl
const float TEX_NULL     = 0.0;
const float TEX_GOLD     = 1.0;
const float TEX_DIRT     = 8.0;
const float TEX_STONE    = 10.0;
const float TEX_GRASS    = 12.0;
const float TEX_SAND     = 14.0;
const float TEX_MORTAR   = 16.0;
const float TEX_WOOD     = 18.0;
const float TEX_BRICK    = 20.0;
const float TEX_SHINGLE  = 22.0;
const float TEX_PLASTER  = 28.0;
const float TEX_DEBUG    = 30.0;
const float TEX_WATER    = 32.0;
const float TEX_METAL    = 33.0;
const float TEX_GLASS    = 35.0;
const float TEX_EARTH    = 36.0;
const float TEX_BARK     = 42.0;
```

Even values are solid materials; odd values (21, 23, 29...) are "variant" slots used during material layering (e.g., mortar between bricks).

### Parameter layout

`paramArr` holds up to 256 `vec3` entries, with `paramsPerEntry` stride (currently 10). Buildings use one entry layout, trees another, lanterns a third. The indexing enum:

```glsl
// General geometry (buildings, walls)
const int E_GP_VISMININPIXELST   = 0;
const int E_GP_VISMAXINPIXELST   = 1;
const int E_GP_BOUNDSMININPIXELST= 2;
const int E_GP_BOUNDSMAXINPIXELST= 3;
const int E_GP_CORNERDISINPIXELS = 4;
const int E_GP_POWERVALS         = 5;   // superellipsoid exponents
const int E_GP_POWERVALS2        = 6;
const int E_GP_THICKVALS         = 7;
const int E_GP_CENTERPOINT       = 8;
const int E_GP_MATPARAMS         = 9;   // material_id, normal_id, modifier

// Trees (P0/P1/P2 instead of bounds)
const int E_TP_P0 = 2, E_TP_P1 = 3, E_TP_P2 = 4;
const int E_TP_POWERVALS = 5, E_TP_POWERVALS2 = 6, E_TP_THICKVALS = 7;

// Lanterns/line geometry (tangent/bitangent/normal frame)
const int E_AP_ORG = 2, E_AP_TAN = 3, E_AP_BIT = 4, E_AP_NOR = 5;
const int E_AP_RAD0 = 6, E_AP_RAD1 = 7;
```

### Per-voxel evaluation

The GPU loop for each voxel scans all entries looking for the closest one whose material matches the current pass:

```glsl
for (int i = 0; i < numEntries; i++) {
    baseInd = i * paramsPerEntry;
    matParams = paramArr[baseInd + E_GP_MATPARAMS];

    if (matParams.x == curMat) {  // only consider entries of this pass's material
        visMin    = paramArr[baseInd + E_GP_VISMININPIXELST] + 1.0;
        visMax    = paramArr[baseInd + E_GP_VISMAXINPIXELST];
        centerPt  = paramArr[baseInd + E_GP_CENTERPOINT];

        if (all(lessThanEqual(worldPos, visMax)) && all(greaterThan(worldPos, visMin))) {
            testDisXY = distance(worldPos.xy, centerPt.xy);
            if (testDisXY < bestDisXY) {
                nextBestDisXY = bestDisXY;
                bestDisXY     = testDisXY;
                bestInd       = i;
            }
        }
    }
}
```

Then the winning entry's actual shape is evaluated — superellipsoid, Bézier, etc. The "best and second-best" tracking is used for corner detection and wing-junction effects, where the distance *between* nearby entries matters (a T-junction between two walls should know about both walls to figure out if it's a corner).

### Superellipsoid evaluation

Buildings use the **superellipsoid** shape family:

$$\left(\left|\frac{x}{a}\right|^p + \left|\frac{y}{b}\right|^p\right)^{q/p} + \left|\frac{z}{c}\right|^q = 1$$

With exponents `powerVals.x = p` and `powerVals.y = q` controlling corner softness. `p = q = 2` is a sphere; high values (6, 8) make near-cube shapes with slightly rounded corners. The GPU evaluates it as:

```glsl
tempVec = absDis / coefMin;
resMin  = 1.0 / pow(dot(pow(tempVec.xy, powerVals.xx), oneVec.xy), 1.0 / powerVals.x);
tempVec = absDis / coefMax;
resMax  = 1.0 / pow(dot(pow(tempVec.xy, powerVals.xx), oneVec.xy), 1.0 / powerVals.x);
resXY   = clamp((1.0 - resMin) / (resMax - resMin), 0.0, 1.0);
```

The dual-radius evaluation produces a smooth ramp between "definitely inside" and "definitely outside," which the downstream pass uses for anti-aliasing and material blending.

---

## 7. The Whole Picture

Stacking these algorithms gives a five-layer generator running as follows:

1. **Seed selection** (CPU, once per world): province centers, seed RNG state.
2. **Terrain macrostructure** (CPU + simplex FBO): multi-octave simplex + heightmap stitching → world-scale heightmap.
3. **Road network** (CPU, FBO channels):
   - Inter-city: recursive midpoint displacement with terrain-weighted cost
   - Intra-city: recursive backtrack maze with height-preference tiebreaker
   - Shipping routes: same midpoint algorithm with inverted water cost
4. **Building skeleton** (CPU, per-block, 3D node grid): phased generation distributing foundations, walls, wings, doors, lanterns.
5. **Geometry emission** (CPU, per-page): for each visible page, gather building geometry (superellipsoid params) + tree Béziers + lantern lines + voronoi seeds into `paramArr`, upload to GPU.
6. **Voxel evaluation** (GPU, compute shader per voxel): iterate `paramArr`, find the nearest matching entry, evaluate the superellipsoid/Bézier, apply material variation from voronoi, write RGBA to the volume.

Every layer produces parameters for the next. Nothing is stored as voxels, nothing is stored as meshes — the world exists as a few hundred kilobytes of heightmaps, seeds, and grammar rules. The voxels only come into existence on the GPU, for the ~1 second between a page being scheduled for rendering and its 2D output sprite being cached.

This is also why the data-oriented design of the C3 port matters so much: the procedural generator is essentially a massive fan-out from a handful of tiny structures (`PlantRules`, `BuildingNode`, `MapNode`) to millions of evaluations per frame. Pointer chasing anywhere in that path would be catastrophic. Everything needs to be contiguous arrays, indexed by integer, hot in cache.