const std = @import("std");

/// Compile l'addon zbundle. Calqué sur le build.zig de zcompiler (mêmes deux
/// cibles, mêmes artefacts) :
///   - natif  → `zig-out/lib/zbundle.node` (lib dynamique ; symboles N-API
///     résolus par Node au chargement) ;
///   - wasm   → `zig-out/lib/zbundle.wasm` (wasm32-freestanding, sans libc).
///
/// L'addon importe DEUX modules : `zignapi` (le pont N-API) et **`zcompiler`**
/// (parser + semantic + AST). zbundle est le premier consommateur externe du
/// module `zcompiler` : il ne réimplémente aucune brique de compilation.
///
/// `link_libc` est décidé ICI selon la cible : le backend N-API a besoin de libc,
/// le backend wasm freestanding le REFUSE (cf. build.zig de zignapi).
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
        wasm.entry = .disabled; // -fno-entry : pas de `main`, juste des exports
        wasm.rdynamic = true; // exporte les symboles marqués `export`
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .lib, "zbundle.wasm");
        b.getInstallStep().dependOn(&install.step);
    } else {
        const addon = b.addLibrary(.{ .name = "zbundle", .linkage = .dynamic, .root_module = mod });
        addon.linker_allow_shlib_undefined = true;
        linkNapiOnWindows(b, addon, target, zignapi_dep);
        const install = b.addInstallFileWithDir(addon.getEmittedBin(), .lib, "zbundle.node");
        b.getInstallStep().dependOn(&install.step);
    }

    // Tests unitaires (logique pure, sans N-API) : `zig build test`. Les deux
    // fichiers cœur ont besoin du module `zcompiler` (graph.zig parse via lui) ;
    // resolver.zig est autonome mais suit le même chemin.
    const test_step = b.step("test", "Lancer les tests Zig (resolver + graph)");
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

/// Windows : résout les symboles N-API contre le `node.exe` hôte. Une DLL Windows
/// ne peut PAS laisser des symboles indéfinis (contrairement à ELF/Mach-O), donc
/// on génère une import lib depuis le `node_api.def` vendored par zignapi (dont
/// `LIBRARY node.exe` lie les imports à l'hôte) via `zig lib /def:`, et on lie
/// l'addon dessus. No-op hors Windows. (Copié tel quel de zcompiler : c'est la
/// recette de l'org.)
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
