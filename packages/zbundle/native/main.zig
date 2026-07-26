//! Pont N-API : expose le resolver + le graphe à Node.js via zignapi.
//!
//! Trivial par construction, et c'est le but. Les composites de zignapi v1
//! sérialisent la structure du graphe toute seule (structs → objets, slices →
//! tableaux, `?u32` → `number | null`, enums → leur nom) : aucune glue à écrire,
//! aucune « struct vue » à maintenir. Les types de `graph.zig` SONT la forme JS
//! — c'est la 3ᵉ fois que l'org le vérifie (zcompiler, hello-world, zbundle).
//!
//! Chaque fonction : demander l'allocateur d'appel, faire le travail, retourner
//! une valeur Zig. zignapi convertit puis libère.

const std = @import("std");
const zignapi = @import("zignapi");
const graph = @import("graph.zig");
const linker = @import("linker.zig");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;

/// La version de zbundle (miroir du `package.json`). Une **constante de module**
/// — zignapi enregistre les valeurs non-fonction telles quelles.
pub const VERSION = "0.3.0";

/// L'`Io` d'un appel (Zig 0.16 : tout accès disque passe par cette interface).
/// La variante mono-thread ne démarre aucun worker et n'alloue rien : c'est
/// exactement ce qu'il faut à un build synchrone. Sa durée de vie = l'appel.
fn blockingIo(t: *std.Io.Threaded) std.Io {
    t.* = .init_single_threaded;
    return t.io();
}

// ---- graph : la structure complète ----

/// graph(entryPath) -> { entry, modules, edges, externals, cycles, stats }.
///
/// Un specifier relatif introuvable lève une exception JS dont le message liste
/// les chemins essayés. Un specifier nu ne lève jamais : il est external.
fn graphImpl(a: Allocator, entry: []const u8) !graph.Graph {
    var t: std.Io.Threaded = undefined;
    var err: graph.BuildError = .{};
    const built = graph.build(a, blockingIo(&t), entry, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BuildFailed => return zignapi.fail(err.message),
    };
    return built.graph;
}

// ---- graphPrint : le même graphe, en arbre lisible ----

/// graphPrint(entryPath) -> string. L'entry en racine, un niveau par
/// profondeur, les externals marqués, les cycles listés, les stats en pied.
fn graphPrint(a: Allocator, entry: []const u8) ![]const u8 {
    const g = try graphImpl(a, entry);
    var out: std.ArrayList(u8) = .empty;
    try graph.printTree(a, g, &out);
    return out.items;
}

// ---- resolve : le resolver seul (une résolution, sans graphe) ----

/// resolve(fromDir, specifier) -> { kind: "file" | "external", path }.
/// `path` est absolu et canonique pour un fichier, le specifier tel quel pour
/// un external. Introuvable -> exception avec les chemins essayés.
fn resolveImpl(a: Allocator, from_dir: []const u8, specifier: []const u8) !resolver.Resolution {
    var t: std.Io.Threaded = undefined;
    var diag: resolver.Diagnostic = .{};
    return resolver.resolve(a, blockingIo(&t), from_dir, specifier, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.NotFound => return zignapi.fail(try resolver.formatError(a, diag, "")),
    };
}

// ---- bundle : LE livrable de la v0.2 ----

/// bundle(entryPath) -> string : UN fichier de JS exécutable (format ESM).
///
/// Les refus de la v0.2 (top-level await, `import()` interne, live binding
/// mutable, `import.meta`) lèvent une exception JS dont le message dit quoi
/// faire — jamais un bundle silencieusement faux.
fn bundleImpl(a: Allocator, entry: []const u8) ![]const u8 {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    const b = linker.bundle(a, blockingIo(&t), entry, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
    return b.code;
}

/// bundleStats(entryPath) -> { code, stats } : le bundle ET ses mesures.
fn bundleStats(a: Allocator, entry: []const u8) !linker.Bundle {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    return linker.bundle(a, blockingIo(&t), entry, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
}

/// bundleReport(entryPath) -> { code, stats, dead } : le bundle ET la liste de
/// ce que le tree-shaking a éliminé (module, ligne, extrait, raison).
fn bundleReport(a: Allocator, entry: []const u8) !linker.Report {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    return linker.bundleReport(a, blockingIo(&t), entry, &err, true) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
}

/// bundlePrint(entryPath) -> string : le bundle précédé de ses stats en
/// commentaire. Le pendant de `graphPrint` — fait pour l'œil humain.
fn bundlePrint(a: Allocator, entry: []const u8) ![]const u8 {
    const b = try bundleStats(a, entry);
    const s = b.stats;
    const ratio = if (s.input_bytes > 0)
        100.0 * @as(f64, @floatFromInt(s.output_bytes)) / @as(f64, @floatFromInt(s.input_bytes))
    else
        0.0;
    return std.fmt.allocPrint(a,
        \\// {d} modules emis ({d} elimines), {d} externals, {d} bindings renommes
        \\// tree-shaking : {d} statements gardes, {d} elimines
        \\// {d} -> {d} octets ({d:.0} %) en {d:.2} ms
        \\{s}
    , .{
        s.modules,          s.modules_dropped,   s.externals, s.renamed,
        s.statements_kept,  s.statements_dropped,
        s.input_bytes,      s.output_bytes,      ratio,       s.bundle_ms,
        b.code,
    });
}

comptime {
    zignapi.register(.{
        .graph = graphImpl,
        .graphPrint = graphPrint,
        .resolve = resolveImpl,
        .bundle = bundleImpl,
        .bundleStats = bundleStats,
        .bundlePrint = bundlePrint,
        .bundleReport = bundleReport,
        .VERSION = VERSION,
    });
}
