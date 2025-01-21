const std = @import("std");
const Scanner = @import("zig-wayland").Scanner;
const buildpkg = @import("ghostty").buildpkg;

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // We don't use env vars but ghostty requires them
    var env = try std.process.getEnvMap(b.allocator);
    errdefer env.deinit();

    const config: buildpkg.Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = .browser,
        .env = env,
    };
    const resources = try buildpkg.GhosttyResources.init(b, &config);

    const exe = b.addExecutable(.{
        .name = "wraith",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    resources.install();

    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
    });

    const ghostty_mod = ghostty.module("ghostty");

    exe.root_module.addImport("ghostty", ghostty_mod);

    const xkbcommon = b.dependency("zig-xkbcommon", .{}).module("xkbcommon");
    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_seat", 5);

    scanner.generate("wl_data_device_manager", 3);

    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);

    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.generate("wp_cursor_shape_manager_v1", 1);

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.generate("xdg_wm_base", 1);

    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");

    exe.linkSystemLibrary("wayland-egl");
    exe.linkSystemLibrary("EGL");

    exe.root_module.addImport("xkbcommon", xkbcommon);
    exe.root_module.addImport("xev", libxev);
    exe.linkSystemLibrary("xkbcommon");
    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
