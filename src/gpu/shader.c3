module c3voxel::gpu;

import std::io;
import std::io::file;
import std::io::path;
import std::os::process;
import std::core::mem::alloc;
import std::time;

import opengl::gl;

import c3voxel::core;

faultdef
    SHADER_FILE_MISSING,
    SHADER_COMPILE_FAILED,
    SHADER_LINK_FAILED,
    SHADER_TOO_MANY_STAGES,
    SHADER_POOL_FULL,
    GLSLC_FAILED;

typedef Shader = inline uint;
const Shader SHADER_INVALID = (Shader)core::HANDLE_INVALID_VALUE;

const usz    MAX_SHADERS        = 64;
const usz    MAX_SHADER_STAGES  = 8;
const String SPV_SUFFIX         = ".spv";
const String SHADER_BUILD_DIR   = "resources/shaders/build";

enum ShaderStageKind : char {
    VERTEX,
    FRAGMENT,
    COMPUTE,
}

struct ShaderStageSpec {
    ShaderStageKind kind;
    String          glsl_path;
}

struct ShaderStage {
    ShaderStageKind kind;
    String          glsl_path;
    String          spv_path;
    time::Time      mtime;
}

fn GLenum stage_to_gl(ShaderStageKind k) @local
{
    switch (k) {
        case ShaderStageKind.VERTEX:   return (GLenum)gl::GL_VERTEX_SHADER;
        case ShaderStageKind.FRAGMENT: return (GLenum)gl::GL_FRAGMENT_SHADER;
        case ShaderStageKind.COMPUTE:  return (GLenum)gl::GL_COMPUTE_SHADER;
    }
}

fn String stage_flag(ShaderStageKind k) @local
{
    switch (k) {
        case ShaderStageKind.VERTEX:   return "vert";
        case ShaderStageKind.FRAGMENT: return "frag";
        case ShaderStageKind.COMPUTE:  return "comp";
    }
}

struct ShaderSlot {
    uint          program;
    char          generation;
    ShaderStage[] stages;
    Allocator     allocator;
}

ShaderSlot[MAX_SHADERS] shader_slots @local;

fn Shader? shader_load(Allocator allocator, ShaderStageSpec[] specs)
{
    if (specs.len > MAX_SHADER_STAGES) return SHADER_TOO_MANY_STAGES~;

    usz slot_idx = MAX_SHADERS;
    for (usz i = 0; i < MAX_SHADERS; i++) {
        if (shader_slots[i].program == 0 && shader_slots[i].stages.len == 0) {
            slot_idx = i;
            break;
        }
    }
    if (slot_idx == MAX_SHADERS) return SHADER_POOL_FULL~;

    ShaderSlot* slot = &shader_slots[slot_idx];
    slot.allocator = allocator;
    slot.program   = 0;
    slot.stages    = alloc::new_array(allocator, ShaderStage, specs.len);

    for (usz i = 0; i < specs.len; i++) {
        slot.stages[i].kind      = specs[i].kind;
        slot.stages[i].glsl_path = specs[i].glsl_path;
        slot.stages[i].spv_path  = string::format(allocator, "%s/%s%s", SHADER_BUILD_DIR, basename_of(specs[i].glsl_path), SPV_SUFFIX);
        slot.stages[i].mtime     = (time::Time)0;
    }

    if (catch err = build_program(slot)) {
        slot_release(slot);
        return err~;
    }

    return (Shader)core::handle_pack((uint)slot_idx, (uint)slot.generation);
}

fn void shader_destroy(Shader s)
{
    ShaderSlot* slot = slot_of(s);
    if (slot == null) return;
    if (slot.program != 0) {
        gl::deleteProgram(slot.program);
        slot.program = 0;
    }
    slot_release(slot);
    slot.generation++;
}

fn uint shader_program(Shader s) @inline
{
    ShaderSlot* slot = slot_of(s);
    return slot == null ? 0 : slot.program;
}

fn bool shader_reload_if_changed(Shader s)
{
    ShaderSlot* slot = slot_of(s);
    if (slot == null || slot.program == 0) return false;

    bool dirty = false;
    foreach (&st : slot.stages) {
        time::Time? cur = file::last_modified(st.glsl_path);
        if (try cur && (long)cur > (long)st.mtime) {
            dirty = true;
            break;
        }
    }
    if (!dirty) return false;

    uint saved = slot.program;
    slot.program = 0;
    if (catch err = build_program(slot)) {
        io::eprintfn("[shader] reload failed: %s", err);
        slot.program = saved;
        return false;
    }
    if (saved != 0) gl::deleteProgram(saved);
    io::printfn("[shader] reloaded");
    return true;
}

fn ShaderSlot* slot_of(Shader s) @local
{
    uint h = (uint)s;
    if (h == core::HANDLE_INVALID_VALUE) return null;
    uint idx = core::handle_index(h);
    uint gen = core::handle_gen(h);
    if (idx >= MAX_SHADERS) return null;
    ShaderSlot* slot = &shader_slots[idx];
    if (slot.program == 0) return null;
    if ((uint)slot.generation != gen) return null;
    return slot;
}

fn void slot_release(ShaderSlot* slot) @local
{
    if (slot.stages.len != 0) {
        foreach (st : slot.stages) {
            if (st.spv_path.len != 0) alloc::free(slot.allocator, st.spv_path.ptr);
        }
        alloc::free(slot.allocator, slot.stages.ptr);
        slot.stages = {};
    }
    slot.program = 0;
}

fn void? build_program(ShaderSlot* slot) @private
{
    uint[MAX_SHADER_STAGES] shader_ids;
    usz n = slot.stages.len;

    for (usz i = 0; i < n; i++) {
        shader_ids[i] = compile_stage(&slot.stages[i])!;
    }

    uint program = gl::createProgram();
    for (usz i = 0; i < n; i++) gl::attachShader(program, shader_ids[i]);
    gl::linkProgram(program);

    int linked;
    gl::getProgramiv(program, (GLenum)gl::GL_LINK_STATUS, &linked);
    if (!linked) {
        char[2048] log;
        gl::getProgramInfoLog(program, log.len, null, &log);
        io::eprintfn("[shader] link error:\n%s", (ZString)&log);
        for (usz i = 0; i < n; i++) gl::deleteShader(shader_ids[i]);
        gl::deleteProgram(program);
        return SHADER_LINK_FAILED~;
    }

    for (usz i = 0; i < n; i++) {
        gl::detachShader(program, shader_ids[i]);
        gl::deleteShader(shader_ids[i]);
    }

    slot.program = program;
}

fn uint? compile_stage(ShaderStage* s) @private
{
    if (!file::is_file(s.glsl_path)) {
        io::eprintfn("[shader] missing glsl: %s", s.glsl_path);
        return SHADER_FILE_MISSING~;
    }

    bool need_build = true;
    if (file::is_file(s.spv_path)) {
        time::Time? glsl_m = file::last_modified(s.glsl_path);
        time::Time? spv_m  = file::last_modified(s.spv_path);
        if (try glsl_m && try spv_m) need_build = (long)glsl_m > (long)spv_m;
    }
    if (need_build) run_glslc(s)!;

    char[] spv = file::load_temp(s.spv_path)!;

    uint shader = gl::createShader(stage_to_gl(s.kind));
    gl::shaderBinary(1, &shader, (GLenum)gl::GL_SHADER_BINARY_FORMAT_SPIR_V, spv.ptr, (int)spv.len);
    if (gl::specializeShader != null) {
        gl::specializeShader(shader, (char*)"main", 0, null, null);
    } else if (gl::specializeShaderARB != null) {
        gl::specializeShaderARB(shader, (char*)"main", 0, null, null);
    } else {
        io::eprintfn("[shader] ARB_gl_spirv unavailable");
        gl::deleteShader(shader);
        return SHADER_COMPILE_FAILED~;
    }

    int compiled;
    gl::getShaderiv(shader, (GLenum)gl::GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char[2048] log;
        gl::getShaderInfoLog(shader, log.len, null, &log);
        io::eprintfn("[shader] specialize error (%s):\n%s", s.glsl_path, (ZString)&log);
        gl::deleteShader(shader);
        return SHADER_COMPILE_FAILED~;
    }

    if (try t = file::last_modified(s.glsl_path)) s.mtime = t;
    return shader;
}

fn void? run_glslc(ShaderStage* s) @private
{
    if (catch err = path::mkdir(SHADER_BUILD_DIR, recursive: true)) {
        // non-fatal: mkdir of an existing dir reports as a fault on some
        // platforms, and run_glslc surfaces the real error next.
        (void)err;
    }

    String flag_arg = string::tformat("-fshader-stage=%s", stage_flag(s.kind));
    String[6] argv = { "glslc", "--target-env=opengl", flag_arg, s.glsl_path, "-o", s.spv_path };
    int? code = process::run(argv[..], process::SpawnOptions.INHERIT_STDIO);
    if (catch err = code) {
        io::eprintfn("[shader] glslc spawn failed: %s", err);
        return GLSLC_FAILED~;
    }
    if (code != 0) {
        io::eprintfn("[shader] glslc exit %d on %s", code, s.glsl_path);
        return GLSLC_FAILED~;
    }
}

fn String basename_of(String p) @local
{
    usz i = p.len;
    while (i > 0 && p[i - 1] != '/' && p[i - 1] != '\\') i--;
    return p[i..];
}
