const std = @import("std");
const Build = std.Build;
const builtin = @import("builtin");
const sokol = @import("sokol");

const Options = struct {
    mod: *Build.Module,
    dep_sokol: *Build.Dependency,
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_pacman = b.createModule(.{
        .root_source_file = b.path("src/pacman.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    // special case handling for native vs web build
    const opts = Options{ .mod = mod_pacman, .dep_sokol = dep_sokol };
    if (target.result.cpu.arch.isWasm()) {
        try buildWeb(b, opts);
    } else {
        try buildNative(b, opts);
    }

    // Add deploy command for web release build
    try addDeployCommand(b);
}

// this is the regular build for all native platforms, nothing surprising here
fn buildNative(b: *Build, opts: Options) !void {
    const exe = b.addExecutable(.{
        .name = "pacman",
        .root_module = opts.mod,
    });
    const shd = try buildShader(b, opts.dep_sokol);
    exe.step.dependOn(&shd.step);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run pacman").dependOn(&run.step);
}

// for web builds, the Zig code needs to be built into a library and linked with the Emscripten linker
fn buildWeb(b: *Build, opts: Options) !void {
    const lib = b.addStaticLibrary(.{
        .name = "pacman",
        .root_module = opts.mod,
    });
    const shd = try buildShader(b, opts.dep_sokol);
    lib.step.dependOn(&shd.step);

    // create a build step which invokes the Emscripten linker
    const emsdk = opts.dep_sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = opts.mod.resolved_target.?,
        .optimize = opts.mod.optimize.?,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = opts.dep_sokol.path("src/sokol/web/shell.html"),
    });
    // attach Emscripten linker output to default install step
    b.getInstallStep().dependOn(&link_step.step);
    // ...and a special run step to start the web build output via 'emrun'
    const run = sokol.emRunStep(b, .{ .name = "pacman", .emsdk = emsdk });
    run.step.dependOn(&link_step.step);
    b.step("run", "Run pacman").dependOn(&run.step);
}

// compile shader via sokol-shdc
fn buildShader(b: *Build, dep_sokol: *Build.Dependency) !*Build.Step.Run {
    return try sokol.shdc.compile(b, .{
        .dep_shdc = dep_sokol.builder.dependency("shdc", .{}),
        .input = b.path("src/shader.glsl"),
        .output = b.path("src/shader.zig"),
        .slang = .{
            .glsl410 = true,
            .glsl300es = true,
            .hlsl4 = true,
            .metal_macos = true,
            .wgsl = true,
        },
    });
}

// Creates a web release build and copies output files to /dist directory for nginx serving
fn addDeployCommand(b: *Build) !void {
    // Create a new step for deploying
    const deploy_step = b.step("deploy", "Create web release build and copy to /dist directory");

    // Set up wasm32-emscripten target and release optimization
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    const optimize = .ReleaseFast;

    // Set up dependencies with release optimization
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
    });

    const mod_pacman = b.createModule(.{
        .root_source_file = b.path("src/pacman.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
        },
    });

    const lib = b.addStaticLibrary(.{
        .name = "pacman",
        .root_module = mod_pacman,
    });

    const shd = try buildShader(b, dep_sokol);
    lib.step.dependOn(&shd.step);

    // Emscripten linking
    const emsdk = dep_sokol.builder.dependency("emsdk", .{});
    const link_step = try sokol.emLinkStep(b, .{
        .lib_main = lib,
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .use_webgl2 = true,
        .use_emmalloc = true,
        .use_filesystem = false,
        .shell_file_path = dep_sokol.path("src/sokol/web/shell.html"),
    });

    // Create dist directory
    const make_dist_dir = b.addSystemCommand(if (builtin.os.tag == .windows)
        &.{ "cmd", "/c", "if", "not", "exist", "dist", "mkdir", "dist" }
    else
        &.{ "mkdir", "-p", "dist" });
    deploy_step.dependOn(&make_dist_dir.step);

    // Copy web files to dist directory
    const web_files = [_][]const u8{
        "pacman.js",
        "pacman.wasm",
        "pacman.html",
    };

    for (web_files) |file| {
        const source_path = b.fmt("zig-out/web/{s}", .{file});
        const dest_path = b.fmt("../dist/{s}", .{file});

        const copy_file = b.addInstallFile(b.path(source_path), dest_path);
        copy_file.step.dependOn(&link_step.step);
        deploy_step.dependOn(&copy_file.step);
    }
}
