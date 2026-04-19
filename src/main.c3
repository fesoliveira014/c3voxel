module c3voxel;

import std::io;

import glfw;

import c3voxel::core;
import c3voxel::platform;
import c3voxel::gpu;
import c3voxel::voxel;
import c3voxel::world;
import c3voxel::render;

const ulong RELOAD_CHECK_INTERVAL = 30;

fn int main(String[] args)
{
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

    gpu::Commands cmd;
    cmd.init();
    defer cmd.destroy();

    voxel::GenerateContext gen;
    if (catch err = gen.init(mem)) {
        io::eprintfn("Failed to load generate shader: %s", err);
        return 1;
    }
    defer gen.destroy();

    voxel::JumpFloodContext jfa;
    if (catch err = jfa.init(mem)) {
        io::eprintfn("Failed to load JFA shaders: %s", err);
        return 1;
    }
    defer jfa.destroy();

    voxel::RayMarchContext rm;
    if (catch err = rm.init(mem, win.fb_width, win.fb_height)) {
        io::eprintfn("Failed to load raymarch shader: %s", err);
        return 1;
    }
    defer rm.destroy();

    render::CompositeContext composite;
    if (catch err = composite.init(mem)) {
        io::eprintfn("Failed to load composite shader: %s", err);
        return 1;
    }
    defer composite.destroy();

    voxel::VolumeRing ring;
    ring.init();
    defer ring.destroy();

    voxel::DistanceField df;
    df.init();
    defer df.destroy();

    world::BlockPool  block_pool;
    world::HolderPool holder_pool;
    world::PagePool   page_pool;
    block_pool.init(mem);
    holder_pool.init(mem);
    page_pool.init(mem);
    defer { block_pool.destroy(); holder_pool.destroy(); page_pool.destroy(); }

    world::BlockId block_id = block_pool.get_or_create(0, 0);
    world::Block*  block    = block_pool.get(block_id);
    world::generate_heightmap_cpu(mem, block, 1337u);

    world::HolderId[4] holder_ids;
    world::PageId[16]  page_ids;
    int page_cursor = 0;

    for (world::HolderCoord hz = 0; hz < (world::HolderCoord)world::ACTIVE_HOLDERS_PER_AXIS; hz++) {
        for (world::HolderCoord hx = 0; hx < (world::HolderCoord)world::ACTIVE_HOLDERS_PER_AXIS; hx++) {
            world::HolderId? hid_opt = holder_pool.get_or_create(hx, hz, block_id);
            if (catch err = hid_opt) {
                io::eprintfn("Failed to create holder: %s", err);
                return 1;
            }
            world::HolderId hid = hid_opt;
            block_pool.retain(block_id);
            int hi = (int)hz * world::ACTIVE_HOLDERS_PER_AXIS + (int)hx;
            holder_ids[hi] = hid;
            world::Holder* holder = holder_pool.get(hid);

            for (world::PageCoord lz = 0; lz < (world::PageCoord)world::PAGES_PER_HOLDER; lz++) {
                for (world::PageCoord lx = 0; lx < (world::PageCoord)world::PAGES_PER_HOLDER; lx++) {
                    world::PageCoord px = (world::PageCoord)((int)hx * world::PAGES_PER_HOLDER + (int)lx);
                    world::PageCoord pz = (world::PageCoord)((int)hz * world::PAGES_PER_HOLDER + (int)lz);
                    world::PageId pid = page_pool.get_or_create(px, pz);
                    world::Page* page = page_pool.get(pid);

                    float x0 = (float)(int)px * (float)world::PIXELS_PER_PAGE;
                    float z0 = (float)(int)pz * (float)world::PIXELS_PER_PAGE;
                    page.world_min = { x0, 0.0f, z0, 0.0f };
                    page.world_max = { x0 + (float)world::PIXELS_PER_PAGE, (float)world::VOLUME_PITCH, z0 + (float)world::PIXELS_PER_PAGE, 0.0f };

                    int ph_slot = (int)lz * world::PAGES_PER_HOLDER + (int)lx;
                    holder.pages[ph_slot] = pid;
                    page_ids[page_cursor++] = pid;
                }
            }
        }
    }

    float block_extent = (float)world::BLOCK_HEIGHTMAP_PIXELS;
    core::Vec4 block_origin = { 0.0f, 0.0f, 0.0f, 0.0f };
    core::Vec4 block_extent_v = { block_extent, (float)world::VOLUME_PITCH, block_extent, 0.0f };

    for (int hi = 0; hi < 4; hi++) {
        world::Holder* holder = holder_pool.get(holder_ids[hi]);
        for (int lz = 0; lz < world::PAGES_PER_HOLDER; lz++) {
            for (int lx = 0; lx < world::PAGES_PER_HOLDER; lx++) {
                int ph_slot = lz * world::PAGES_PER_HOLDER + lx;
                world::PageId pid = holder.pages[ph_slot];
                world::Page* page = page_pool.get(pid);

                int slot = ring.next();
                gen.dispatch_page(&cmd, &ring, slot, page, block.heightmap, block_origin, block_extent_v, (core::Seconds)0.0f);

                voxel::Volume tmp_vol = { .tex = ring.slot(slot) };
                jfa.build(&cmd, &tmp_vol, &df);

                core::IVec2 write_offset = { lx * world::PIXELS_PER_PAGE, lz * world::PIXELS_PER_PAGE };
                rm.dispatch_into(&cmd, &ring, slot, &df, page, &holder.fbo_layer0, write_offset);
            }
        }
    }

    platform::FrameClock clock;
    clock.init();

    while (!win.should_close()) {
        clock.tick();

        if (win.key_down(glfw::KEY_ESCAPE)) win.request_close();
        if (clock.frame % RELOAD_CHECK_INTERVAL == 0) {
            gpu::shader_reload_if_changed(composite.shader);
            gpu::shader_reload_if_changed(gen.shader);
            gpu::shader_reload_if_changed(jfa.init_shader);
            gpu::shader_reload_if_changed(jfa.step_shader);
            gpu::shader_reload_if_changed(rm.shader);
        }

        if (clock.frame > 0 && clock.frame % 60 == 0) {
            io::printfn("frame %d  dt=%.2f ms", clock.frame, clock.dt * 1000.0);
        }

        world::Holder*[4] holders = {
            holder_pool.get(holder_ids[0]),
            holder_pool.get(holder_ids[1]),
            holder_pool.get(holder_ids[2]),
            holder_pool.get(holder_ids[3]),
        };

        float half_w = (float)win.fb_width * 0.5f;
        float half_h = (float)win.fb_height * 0.5f;
        core::Vec4[4] screen_min = {
            { 0.0f,   0.0f,   0.0f, 0.0f },
            { half_w, 0.0f,   0.0f, 0.0f },
            { 0.0f,   half_h, 0.0f, 0.0f },
            { half_w, half_h, 0.0f, 0.0f },
        };
        core::Vec4[4] screen_max = {
            { half_w,             half_h,             0.0f, 0.0f },
            { (float)win.fb_width, half_h,             0.0f, 0.0f },
            { half_w,             (float)win.fb_height, 0.0f, 0.0f },
            { (float)win.fb_width, (float)win.fb_height, 0.0f, 0.0f },
        };

        cmd.begin_frame();
        cmd.bind_default_framebuffer();
        cmd.set_viewport(0, 0, win.fb_width, win.fb_height);
        cmd.clear(0.02, 0.02, 0.04, 1.0);
        composite.dispatch(&cmd, holders[..], screen_min[..], screen_max[..], win.fb_width, win.fb_height);
        cmd.end_frame();

        win.poll();
        win.swap();
    }

    return 0;
}
