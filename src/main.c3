module c3voxel;

import std::io;
import std::math;

import glfw;

import c3voxel::core;
import c3voxel::platform;
import c3voxel::gpu;
import c3voxel::voxel;
import c3voxel::world;
import c3voxel::game;
import c3voxel::render;

const ulong RELOAD_CHECK_INTERVAL = 30;
const float PAN_SENSITIVITY       = 1.5f;

fn int main(String[] args)
{
    // --- CLI args -------------------------------------------------------
    // `--flat-terrain` or `-f`: skip fbm2 heightmap, render on a
    // perfectly flat plane at FLAT_TERRAIN_H01 * MAX_HEIGHT. Handy for
    // debugging shadows/lighting where rolling terrain obscures the
    // ground contribution. Must be applied before any block generation.
    bool flat_terrain = false;
    for (usz i = 1; i < args.len; i++) {
        if (args[i] == "--flat-terrain" || args[i] == "-f") {
            flat_terrain = true;
        } else if (args[i] == "--help" || args[i] == "-h") {
            io::printfn("Usage: c3voxel [--flat-terrain|-f] [--help|-h]");
            io::printfn("  --flat-terrain, -f  Skip fbm2; render on a flat plane.");
            return 0;
        }
    }
    world::terrain_set_flat(flat_terrain);
    if (flat_terrain) io::printfn("[world] flat terrain mode enabled");

    platform::Window win;
    if (catch err = win.init(platform::window_config_default())) {
        io::eprintfn("Failed to open window: %s", err);
        return 1;
    }
    defer win.destroy();

    if (catch err = gpu::gpu_init((gpu::LoadFn)&glfw::getProcAddress)) {
        io::eprintfn("Failed to initialize GPU: %s", err);
        return 1;
    }

    io::printfn("Renderer: %s", gpu::renderer_string());
    io::printfn("OpenGL version: %s", gpu::version_string());

    gpu::Timer timer;
    timer.init();
    defer timer.destroy();

    gpu::Commands cmd;
    cmd.init();
    cmd.timer = &timer;
    defer cmd.destroy();

    voxel::GenerateContext gen;
    if (catch err = gen.init(mem)) {
        io::eprintfn("Failed to load generate shader: %s", err);
        return 1;
    }
    defer gen.destroy();

    voxel::RayMarchContext rm;
    if (catch err = rm.init(mem)) {
        io::eprintfn("Failed to load raymarch shader: %s", err);
        return 1;
    }
    defer rm.destroy();

    render::DeferredContext deferred;
    if (catch err = deferred.init(mem, win.fb_width, win.fb_height)) {
        io::eprintfn("Failed to load deferred shader: %s", err);
        return 1;
    }
    defer deferred.destroy();

    render::AoContext ao;
    if (catch err = ao.init(mem, win.fb_width, win.fb_height)) {
        io::eprintfn("Failed to load ao shader: %s", err);
        return 1;
    }
    defer ao.destroy();

    render::LightingContext lighting;
    if (catch err = lighting.init(mem, win.fb_width, win.fb_height)) {
        io::eprintfn("Failed to load lighting shader: %s", err);
        return 1;
    }
    defer lighting.destroy();

    render::PresentContext present;
    if (catch err = present.init(mem)) {
        io::eprintfn("Failed to load present shader: %s", err);
        return 1;
    }
    defer present.destroy();

    voxel::VolumeRing ring;
    ring.init();
    defer ring.destroy();

    world::BlockPool  block_pool;
    world::HolderPool holder_pool;
    world::PagePool   page_pool;
    block_pool.init(mem);
    holder_pool.init(mem);
    page_pool.init(mem);
    defer { block_pool.destroy(); holder_pool.destroy(); page_pool.destroy(); }

    world::GpuPool pool;
    pool.init();

    world::DirtyQueue dirty;
    dirty.init(mem);
    defer dirty.free();

    core::Vec3 pan_target = { 0.0f, 0.0f, 0.0f };
    float      zoom_scale = 1.0f;
    bool       f12_prev   = false;
    bool       lb_prev    = false;       // [ previous frame
    bool       rb_prev    = false;       // ] previous frame
    bool       p_prev     = false;       // P previous frame

    game::TimeOfDay tod;
    tod.init();

    world::PlantNodeList plant_scratch;
    plant_scratch.init(mem, 64);
    defer plant_scratch.free();

    platform::FrameClock clock;
    clock.init();

    while (!win.should_close()) {
        clock.tick();

        platform::MouseState mouse;
        platform::input_poll(&mouse, &win);

        if (win.key_down(glfw::KEY_ESCAPE)) win.request_close();

        bool f12_now = win.key_down(glfw::KEY_F12);
        if (f12_now && !f12_prev) timer.dump();
        f12_prev = f12_now;

        // Time-of-day controls (edge-detected so auto-repeat doesn't spam):
        //   [  step sun back     (disables auto-advance)
        //   ]  step sun forward  (disables auto-advance)
        //   P  toggle auto-advance
        bool lb_now = win.key_down(glfw::KEY_LEFT_BRACKET);
        bool rb_now = win.key_down(glfw::KEY_RIGHT_BRACKET);
        bool p_now  = win.key_down(glfw::KEY_P);
        if (lb_now && !lb_prev) tod.step(-1);
        if (rb_now && !rb_prev) tod.step(+1);
        if (p_now  && !p_prev)  tod.toggle_auto();
        lb_prev = lb_now;
        rb_prev = rb_now;
        p_prev  = p_now;

        tod.update((core::Seconds)(float)clock.dt);

        if (mouse.left_down) {
            // Iso-aware grab-and-pull: convert (dx, dy) in GLFW window
            // pixels (y-down) to a world-ground delta, then shift
            // pan_target by its negative so the point under the cursor
            // tracks the mouse. The XZ basis is:
            //   sx  = zoom * (wx - wz)
            //   sy  = zoom * (ISO_TILT * (wx + wz))   (y-up; dy flips)
            // so (s, u) = (dx / zoom, -dy / (zoom * ISO_TILT)) inverts to
            //   dwx = (u + s)/2,  dwz = (u - s)/2.
            float s   = (float)mouse.dx / zoom_scale;
            float u   = -(float)mouse.dy / (zoom_scale * game::ISO_TILT);
            float dwx = (u + s) * 0.5f;
            float dwz = (u - s) * 0.5f;
            pan_target.x -= dwx * PAN_SENSITIVITY;
            pan_target.z -= dwz * PAN_SENSITIVITY;
        }

        if (mouse.scroll_steps != 0) {
            if (mouse.scroll_steps > 0) {
                zoom_scale *= 1.4f;
            } else {
                zoom_scale *= 0.714f;   // 1/1.4
            }
            if (zoom_scale < 0.25f) zoom_scale = 0.25f;
            if (zoom_scale > 16.0f) zoom_scale = 16.0f;
        }

        if (clock.frame % RELOAD_CHECK_INTERVAL == 0) {
            gpu::shader_reload_if_changed(deferred.shader);
            gpu::shader_reload_if_changed(gen.shader);
            gpu::shader_reload_if_changed(gen.normal_shader);
            gpu::shader_reload_if_changed(rm.shader);
            gpu::shader_reload_if_changed(ao.shader);
            gpu::shader_reload_if_changed(lighting.shader);
            gpu::shader_reload_if_changed(present.shader);
        }

        if (clock.frame > 0 && clock.frame % 60 == 0) {
            io::printfn("frame %d  dt=%.2f ms  pool alive=%d dirty=%d pan=(%.1f, %.1f) zoom=%.2f",
                        clock.frame, clock.dt * 1000.0,
                        alive_slot_count(&pool), (int)dirty.len(),
                        pan_target.x, pan_target.z, zoom_scale);
        }

        timer.begin_frame();
        cmd.time_push("frame");

        cmd.time_push("stream");
        world::streaming_update(&pool, &block_pool, &holder_pool, &page_pool, &dirty,
                                pan_target, zoom_scale, win.fb_width, win.fb_height);
        cmd.time_pop();

        cmd.time_push("generate");
        drain_dirty(&cmd, &gen, &rm, &ring,
                    &block_pool, &holder_pool, &page_pool, &pool, &dirty,
                    &plant_scratch, pan_target, world::MAX_REGEN_PER_FRAME);
        cmd.time_pop();

        cmd.begin_frame();

        core::Vec4[world::POOL_SIZE] screen_min;
        core::Vec4[world::POOL_SIZE] screen_max;
        uint alive_mask = 0;
        for (int i = 0; i < world::POOL_SIZE; i++) {
            if ((uint)pool.slots[i].owner == core::HANDLE_INVALID_VALUE) {
                screen_min[i] = { 0.0f, 0.0f, 0.0f, 0.0f };
                screen_max[i] = { 0.0f, 0.0f, 0.0f, 0.0f };
                continue;
            }
            world::Holder* h = holder_pool.get(pool.slots[i].owner);
            if (h == null) continue;
            compute_holder_screen_rect(h, pan_target, zoom_scale,
                                       win.fb_width, win.fb_height,
                                       &screen_min[i], &screen_max[i]);
            alive_mask |= ((uint)1 << i);
        }

        // Deferred pass: build the screen G-buffer (normal / height / mat_id
        // packed into RGBA8) at window resolution.
        cmd.time_push("deferred");
        if (catch err = deferred.resize(win.fb_width, win.fb_height)) {
            io::eprintfn("Failed to resize G-buffer: %s", err);
        }
        deferred.dispatch(&cmd, &pool, &holder_pool,
                          screen_min[..], screen_max[..], alive_mask,
                          win.fb_width, win.fb_height);
        cmd.time_pop();

        // AO pass: VQ-style height-based SSAO (24 taps low tier) written
        // to an R8 target. Sampled by the lighting pass at binding 2.
        cmd.time_push("ao");
        if (catch err = ao.resize(win.fb_width, win.fb_height)) {
            io::eprintfn("Failed to resize AO FBO: %s", err);
        }
        ao.dispatch(&cmd, deferred.gbuffer_texture(), win.fb_width, win.fb_height);
        cmd.time_pop();

        // Lighting pass: palette-lookup albedo + single directional light
        // with shadow march and AO, writes the lit color into
        // lighting.result_fbo at window resolution.
        cmd.time_push("lighting");
        if (catch err = lighting.resize(win.fb_width, win.fb_height)) {
            io::eprintfn("Failed to resize lit FBO: %s", err);
        }
        core::Vec3 sun_dir = game::sun_direction_for(tod.t);
        render::LightingUniforms lighting_uniforms = {
            .sun_dir          = { sun_dir.x, sun_dir.y, sun_dir.z, 0.0f },
            .sun_color        = game::sun_color_for(tod.t),
            .ambient_color    = game::ambient_color_for(tod.t),
            .resolution       = { win.fb_width, win.fb_height, 0, 0 },
            .pan_target       = { pan_target.x, pan_target.y, pan_target.z, zoom_scale },
            .time_of_day      = tod.t,
            .shadow_step      = 1.0f,
            .shadow_max_steps = 64,
            .ao_quality_high  = 0,
        };
        lighting.dispatch(&cmd, deferred.gbuffer_texture(), ao.result_texture(), &lighting_uniforms);
        cmd.time_pop();

        // Present pass: gamma-correct the lit color onto fbo 0.
        cmd.time_push("present");
        present.dispatch(&cmd, lighting.result_texture(), win.fb_width, win.fb_height);
        cmd.time_pop();

        cmd.end_frame();
        cmd.time_pop();
        timer.end_frame();
        timer.resolve_prev();
        win.poll();
        win.swap();
    }

    return 0;
}

fn int alive_slot_count(world::GpuPool* pool)
{
    int n = 0;
    for (int i = 0; i < world::POOL_SIZE; i++) {
        if ((uint)pool.slots[i].owner != core::HANDLE_INVALID_VALUE) n++;
    }
    return n;
}

fn void compute_holder_screen_rect(world::Holder* h, core::Vec3 pan_target, float zoom,
                                   int fb_w, int fb_h,
                                   core::Vec4* out_min, core::Vec4* out_max)
{
    float wx0 = (float)(int)h.hx * (float)world::HOLDER_WORLD_EXTENT;
    float wz0 = (float)(int)h.hz * (float)world::HOLDER_WORLD_EXTENT;
    float wx1 = wx0 + (float)world::HOLDER_WORLD_EXTENT;
    float wz1 = wz0 + (float)world::HOLDER_WORLD_EXTENT;
    float wy0 = 0.0f;
    float wy1 = (float)world::VOLUME_PITCH;

    core::Vec3[8] corners = {
        game::world_xz_to_screen(pan_target, zoom, wx0, wy0, wz0),
        game::world_xz_to_screen(pan_target, zoom, wx1, wy0, wz0),
        game::world_xz_to_screen(pan_target, zoom, wx0, wy0, wz1),
        game::world_xz_to_screen(pan_target, zoom, wx1, wy0, wz1),
        game::world_xz_to_screen(pan_target, zoom, wx0, wy1, wz0),
        game::world_xz_to_screen(pan_target, zoom, wx1, wy1, wz0),
        game::world_xz_to_screen(pan_target, zoom, wx0, wy1, wz1),
        game::world_xz_to_screen(pan_target, zoom, wx1, wy1, wz1),
    };

    float min_x = corners[0].x;
    float max_x = corners[0].x;
    float min_y = corners[0].y;
    float max_y = corners[0].y;
    for (int i = 1; i < 8; i++) {
        if (corners[i].x < min_x) min_x = corners[i].x;
        if (corners[i].x > max_x) max_x = corners[i].x;
        if (corners[i].y < min_y) min_y = corners[i].y;
        if (corners[i].y > max_y) max_y = corners[i].y;
    }

    float half_w = (float)fb_w * 0.5f;
    float half_h = (float)fb_h * 0.5f;
    *out_min = { min_x + half_w, min_y + half_h, 0.0f, 0.0f };
    *out_max = { max_x + half_w, max_y + half_h, 0.0f, 0.0f };
}

fn usz pick_next_dirty(world::DirtyQueue* dirty, world::HolderPool* holders, core::Vec3 pan_target, uint current_frame) @local
{
    usz best_idx  = 0;
    float best_d  = 1e30f;
    int   best_age = 0;
    for (usz i = 0; i < dirty.len(); i++) {
        world::DirtyEntry e = (*dirty)[i];
        world::Holder* h = holders.get(e.id);
        if (h == null) continue;
        int age = (int)(current_frame - e.enqueue_frame);
        float d = world::holder_distance_sq(h, pan_target);
        float effective_d = d;
        if (age >= world::FRAME_STARVATION_CAP) effective_d = 0.0f;
        if (effective_d < best_d || (effective_d == best_d && age > best_age)) {
            best_d   = effective_d;
            best_idx = i;
            best_age = age;
        }
    }
    return best_idx;
}

fn void drain_dirty(
    gpu::Commands*           cmd,
    voxel::GenerateContext*  gen,
    voxel::RayMarchContext*  rm,
    voxel::VolumeRing*       ring,
    world::BlockPool*        blocks,
    world::HolderPool*       holders,
    world::PagePool*         pages,
    world::GpuPool*          pool,
    world::DirtyQueue*       dirty,
    world::PlantNodeList*    plant_scratch,
    core::Vec3               pan_target,
    int                      budget)
{
    int done = 0;
    while (done < budget && dirty.len() > 0) {
        usz idx = pick_next_dirty(dirty, holders, pan_target, pool.current_frame);
        world::DirtyEntry entry = (*dirty)[idx];
        dirty.remove_at(idx);
        world::Holder* holder = holders.get(entry.id);
        if (holder == null) continue;
        world::Block* block = blocks.get(holder.block_id);
        if (block == null) continue;

        if (block.heightmap_dirty) {
            world::generate_heightmap_cpu(mem, block, 1337u);
            world::generate_roads_for_block(mem, block, 1337u);
            world::buildings_generate_for_block(block, mem, 1337u);
        }

        float block_origin_x = (float)(int)block.cx * (float)world::BLOCK_HEIGHTMAP_PIXELS;
        float block_origin_z = (float)(int)block.cz * (float)world::BLOCK_HEIGHTMAP_PIXELS;
        core::Vec4 block_origin = { block_origin_x, 0.0f, block_origin_z, 0.0f };
        core::Vec4 block_extent = { (float)world::BLOCK_HEIGHTMAP_PIXELS, (float)world::VOLUME_PITCH, (float)world::BLOCK_HEIGHTMAP_PIXELS, 0.0f };

        gpu::Texture3D[4] page_vols = {
            gpu::TEXTURE3D_INVALID, gpu::TEXTURE3D_INVALID,
            gpu::TEXTURE3D_INVALID, gpu::TEXTURE3D_INVALID,
        };
        gpu::Texture3D[4] page_norms = {
            gpu::TEXTURE3D_INVALID, gpu::TEXTURE3D_INVALID,
            gpu::TEXTURE3D_INVALID, gpu::TEXTURE3D_INVALID,
        };
        world::Page*[4] page_ptrs = { null, null, null, null };
        core::IVec4 valid_mask = { 0, 0, 0, 0 };

        for (int lz = 0; lz < world::PAGES_PER_HOLDER; lz++) {
            for (int lx = 0; lx < world::PAGES_PER_HOLDER; lx++) {
                int ph = lz * world::PAGES_PER_HOLDER + lx;
                world::Page* page = pages.get(holder.pages[ph]);
                if (page == null) continue;
                world::geometry_generate_page(&page.geometry, page, block, plant_scratch);
                int slot = ring.next();
                gen.dispatch_page(cmd, ring, slot, page, block.heightmap, block.road_texture, block.building_interior_tex, block_origin, block_extent, (core::Seconds)0.0f);
                page_vols[ph]  = ring.slot(slot);
                page_norms[ph] = ring.normal_slot(slot);
                page_ptrs[ph]  = page;
                valid_mask.x |= (1 << ph);
            }
        }

        if (valid_mask.x != 0) {
            rm.dispatch_holder(cmd, page_vols, page_norms, holder, page_ptrs, &holder.fbo_layer0, valid_mask);
        }
        done++;
    }
}
