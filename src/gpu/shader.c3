module c3voxel::gpu;

import std::io;
import std::io::file;
import std::os::process;
import std::core::mem::alloc;
import std::time;

import opengl::gl;

faultdef
    SHADER_FILE_MISSING,
    SHADER_COMPILE_FAILED,
    SHADER_LINK_FAILED,
    SHADER_TOO_MANY_STAGES,
    GLSLC_FAILED;

const usz MAX_SHADER_STAGES = 8;
const String SPV_SUFFIX = ".spv";

struct ShaderStageSpec {
    GLenum stage;
    String flag;
    String glsl_path;
}

struct ShaderStage {
    GLenum     stage;
    String     flag;
    String     glsl_path;
    String     spv_path;
    time::Time mtime;
}

struct Shader {
    uint          program;
    ShaderStage[] stages;
    Allocator     allocator;
}

fn void? Shader.init(&self, Allocator allocator, ShaderStageSpec[] specs)
{
    if (specs.len > MAX_SHADER_STAGES) return SHADER_TOO_MANY_STAGES~;

    self.allocator = allocator;
    self.program   = 0;
    self.stages    = alloc::new_array(allocator, ShaderStage, specs.len);

    for (usz i = 0; i < specs.len; i++) {
        self.stages[i].stage     = specs[i].stage;
        self.stages[i].flag      = specs[i].flag;
        self.stages[i].glsl_path = specs[i].glsl_path;
        self.stages[i].spv_path  = string::format(allocator, "%s%s", specs[i].glsl_path, SPV_SUFFIX);
        self.stages[i].mtime     = (time::Time)0;
    }

    if (catch err = build_program(self)) {
        self.destroy();
        return err~;
    }
}

fn void Shader.destroy(&self)
{
    if (self.program != 0) {
        gl::deleteProgram(self.program);
        self.program = 0;
    }
    if (self.stages.len != 0) {
        foreach (s : self.stages) {
            if (s.spv_path.len != 0) alloc::free(self.allocator, s.spv_path.ptr);
        }
        alloc::free(self.allocator, self.stages.ptr);
        self.stages = {};
    }
}

fn void Shader.bind(&self) @inline
{
    gl::useProgram(self.program);
}

fn bool Shader.reload_if_changed(&self)
{
    bool dirty = false;
    foreach (&s : self.stages) {
        time::Time? cur = file::last_modified(s.glsl_path);
        if (try t = cur) {
            if ((long)t > (long)s.mtime) {
                dirty = true;
                break;
            }
        }
    }
    if (!dirty) return false;

    uint saved = self.program;
    self.program = 0;
    if (catch err = build_program(self)) {
        io::eprintfn("[shader] reload failed: %s", err);
        self.program = saved;
        return false;
    }
    if (saved != 0) gl::deleteProgram(saved);
    io::printfn("[shader] reloaded");
    return true;
}

fn void? build_program(Shader* self) @private
{
    uint[MAX_SHADER_STAGES] shader_ids;
    usz n = self.stages.len;

    for (usz i = 0; i < n; i++) {
        shader_ids[i] = compile_stage(&self.stages[i])!;
    }

    uint program = gl::createProgram();
    for (usz i = 0; i < n; i++) gl::attachShader(program, shader_ids[i]);
    gl::linkProgram(program);

    int linked;
    gl::getProgramiv(program, gl::GL_LINK_STATUS, &linked);
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

    self.program = program;
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

    uint shader = gl::createShader(s.stage);
    gl::shaderBinary(1, &shader, gl::GL_SHADER_BINARY_FORMAT_SPIR_V, spv.ptr, (int)spv.len);
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
    gl::getShaderiv(shader, gl::GL_COMPILE_STATUS, &compiled);
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
    String stage_flag = string::tformat("-fshader-stage=%s", s.flag);
    String[6] argv = { "glslc", "--target-env=opengl", stage_flag, s.glsl_path, "-o", s.spv_path };
    int? code = process::run(argv[..]);
    if (catch err = code) {
        io::eprintfn("[shader] glslc spawn failed: %s", err);
        return GLSLC_FAILED~;
    }
    if (code != 0) {
        io::eprintfn("[shader] glslc exit %d on %s", code, s.glsl_path);
        return GLSLC_FAILED~;
    }
}
