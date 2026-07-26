const std = @import("std");

/// Builds the zbundle addon. Modelled on zcompiler's build.zig (same two
/// targets, same artifacts):
///   - native -> `zig-out/lib/zbundle.node` (dynamic library; N-API symbols
///     resolved by Node at load time);
///   - wasm   -> `zig-out/lib/zbundle.wasm` (wasm32-freestanding, no libc).
///
/// The addon imports TWO modules: `zignapi` (the N-API bridge) and
/// **`zcompiler`** (parser + semantic + AST). zbundle is the first external
/// consumer of the `zcompiler` module: it reimplements no compiler machinery.
///
/// `link_libc` is decided HERE based on the target: the N-API backend needs
/// libc, the freestanding wasm backend REFUSES it (see zignapi's build.zig).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasm = target.result.cpu.arch.isWasm();

    const zignapi_dep = b.dependency("zignapi", .{});
    const zignapi = zignapi_dep.module("zignapi");
    const zcompiler = b.dependency("zcompiler", .{}).module("zcompiler");

    const mod = b.createModule(.{
        .root_source_file = b.path("native/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_wasm,
        .imports = &.{
            .{ .name = "zignapi", .module = zignapi },
            .{ .name = "zcompiler", .module = zcompiler },
        },
    });

    if (is_wasm) {
        const wasm = b.addExecutable(.{ .name = "zbundle", .root_module = mod });
        wasm.entry = .disabled; // -fno-entry: no `main`, only exports
        wasm.rdynamic = true; // export the symbols marked `export`
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .lib, "zbundle.wasm");
        b.getInstallStep().dependOn(&install.step);
    } else {
        const addon = b.addLibrary(.{ .name = "zbundle", .linkage = .dynamic, .root_module = mod });
        addon.linker_allow_shlib_undefined = true;
        linkNapiOnWindows(b, addon, target, zignapi_dep);
        const install = b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "zbundle.node");
        b.getInstallStep().dependOn(&install.step);
    }

    // Unit tests (pure logic, no N-API): `zig build test`. The core files need
    // the `zcompiler` module (graph.zig parses through it); resolver.zig is
    // standalone but follows the same path.
    const test_step = b.step("test", "Run the Zig tests (resolver + graph + shake + linker)");
    for ([_][]const u8{ "native/resolver.zig", "native/graph.zig", "native/shake.zig", "native/linker.zig" }) |root| {
        const tests_mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zcompiler", .module = zcompiler },
            },
        });
        const unit_tests = b.addTest(.{ .root_module = tests_mod });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}

/// Windows: resolves N-API symbols against the host `node.exe`. A Windows DLL
/// CANNOT leave symbols undefined (unlike ELF/Mach-O), so we generate an import
/// library from the `node_api.def` vendored by zignapi (whose `LIBRARY node.exe`
/// binds the imports to the host) via `zig lib /def:`, and link the addon
/// against it. A no-op outside Windows. (Copied verbatim from zcompiler.)
fn linkNapiOnWindows(
    b: *std.Build,
    addon: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    zignapi_dep: *std.Build.Dependency,
) void {
    if (target.result.os.tag != .windows) return;
    const gen = b.addSystemCommand(&.{ b.graph.zig_exe, "lib", "-nologo" });
    gen.addPrefixedFileArg("/def:", zignapi_dep.namedLazyPath("node_api_def"));
    const implib = gen.addPrefixedOutputFileArg("/out:", "node_api.lib");
    gen.addArg(if (target.result.cpu.arch == .aarch64) "/machine:arm64" else "/machine:x64");
    addon.root_module.addObjectFile(implib);
}
