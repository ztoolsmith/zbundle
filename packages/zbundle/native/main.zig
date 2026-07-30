//! N-API bridge: exposes the resolver, the graph and the bundler to Node.js
//! through zignapi.
//!
//! Trivial by construction, and that is the point. zignapi's composites
//! serialize these structures on their own (structs -> objects, slices ->
//! arrays, `?u32` -> `number | null`, enums -> their name): no glue to write, no
//! "view struct" to maintain. The types in `graph.zig` and `linker.zig` ARE the
//! JS shape.
//!
//! Every function: ask for the call allocator, do the work, return a Zig value.
//! zignapi converts, then frees.

const std = @import("std");
const zignapi = @import("zignapi");
const graph = @import("graph.zig");
const linker = @import("linker.zig");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;

/// zbundle's version (mirrors `package.json`). A **module constant** — zignapi
/// registers non-function values as they are.
pub const VERSION = "0.4.4";

/// The `Io` for one call (Zig 0.16: all disk access goes through this
/// interface). The single-threaded variant starts no worker and allocates
/// nothing: exactly right for a synchronous build. Its lifetime = the call.
fn blockingIo(t: *std.Io.Threaded) std.Io {
    t.* = .init_single_threaded;
    return t.io();
}

// ---- graph: the full structure ----

/// graph(entryPath) -> { entry, modules, edges, externals, cycles, stats }.
///
/// A relative specifier that cannot be found throws a JS exception whose message
/// lists the attempted paths. A bare specifier never throws: it is external.
fn graphImpl(a: Allocator, entry: []const u8) !graph.Graph {
    var t: std.Io.Threaded = undefined;
    var err: graph.BuildError = .{};
    // `.{}` = the default resolution. ONE crossing was specified, and it is
    // `bundleWith`; `graph`/`resolve` stay the raw, unconfigured probes.
    const built = graph.build(a, blockingIo(&t), entry, .{}, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BuildFailed => return zignapi.fail(err.message),
    };
    return built.graph;
}

/// graphWith(entryPath, { resolve, jsxImportSource }) -> the same graph as
/// `graph`, but resolved with the build's own knobs.
///
/// The config layer needs this to find every module BEFORE it can know which
/// `tsconfig.json` governs each of them — the discovery pass. `graph` keeps its
/// one-argument shape: it is the raw probe, and every existing caller of it
/// stays valid.
fn graphWith(a: Allocator, entry: []const u8, opts: JsOptions) !graph.Graph {
    var t: std.Io.Threaded = undefined;
    var err: graph.BuildError = .{};
    const built = graph.build(a, blockingIo(&t), entry, .{
        .resolve = opts.resolve,
        .jsx_import_source = opts.jsx_import_source,
    }, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BuildFailed => return zignapi.fail(err.message),
    };
    return built.graph;
}

// ---- graphPrint: the same graph, as a readable tree ----

/// graphPrint(entryPath) -> string. The entry as root, one level per depth,
/// externals marked, cycles listed, statistics at the bottom.
fn graphPrint(a: Allocator, entry: []const u8) ![]const u8 {
    const g = try graphImpl(a, entry);
    var out: std.ArrayList(u8) = .empty;
    try graph.printTree(a, g, &out);
    return out.items;
}

// ---- resolve: the resolver alone (one resolution, no graph) ----

/// resolve(fromDir, specifier) -> { kind: "file" | "external", path }.
/// `path` is absolute and canonical for a file, the specifier as written for an
/// external. Not found -> an exception with the attempted paths.
fn resolveImpl(a: Allocator, from_dir: []const u8, specifier: []const u8) !resolver.Resolution {
    var t: std.Io.Threaded = undefined;
    var diag: resolver.Diagnostic = .{};
    return resolver.resolve(a, blockingIo(&t), from_dir, specifier, .{}, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.NotFound => return zignapi.fail(try resolver.formatError(a, diag, "")),
    };
}

// ---- bundle: the main deliverable ----

/// bundle(entryPath) -> string: ONE executable JS file (ESM format).
///
/// The refusals (top-level await, internal `import()`, a live binding exposed
/// through a namespace, `import.meta`) throw a JS exception whose message says
/// what to do — never a silently wrong bundle.
fn bundleImpl(a: Allocator, entry: []const u8) ![]const u8 {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    const b = linker.bundle(a, blockingIo(&t), entry, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
    return b.code;
}

/// bundleStats(entryPath) -> { code, stats }: the bundle AND its measurements.
fn bundleStats(a: Allocator, entry: []const u8) !linker.Bundle {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    return linker.bundle(a, blockingIo(&t), entry, &err) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
}

/// bundleReport(entryPath) -> { code, stats, dead }: the bundle AND the list of
/// what tree-shaking eliminated (module, line, snippet, reason).
fn bundleReport(a: Allocator, entry: []const u8) !linker.Report {
    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    return linker.bundleReport(a, blockingIo(&t), entry, &err, true, .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
}

/// The options as written in JS:
/// `{ format: 'esm' | 'iife', dead, minify, resolve: { alias, extensions } }`.
///
/// `resolve` is **`resolver.Config` itself**, not a mirror of it: zignapi
/// converts the JS object field by field, recursively (an array of
/// `{ from, to }` becomes `[]Alias`, an array of strings becomes
/// `[]const []const u8`). This is the file's founding principle applied to an
/// input rather than an output — the Zig type IS the JS shape, so there is no
/// second definition to keep in sync.
///
/// **One crossing, at the start of the build.** The TS layer has already done
/// its job by then: keys validated, aliases made absolute against the config
/// file's directory, reserved options refused. What arrives here is settled.
const JsOptions = struct {
    format: []const u8 = "esm",
    dead: bool = false,
    /// Shorten cross-module names. NOT a full minifier: the printer still emits
    /// readable, indented JS. Compact output would need a compact mode in
    /// zcompiler's printer — that belongs downstairs, not here.
    minify: bool = false,
    resolve: resolver.Config = .{},
    /// `jsxImportSource` — `"react"` -> `react/jsx-runtime`, `"preact"` ->
    /// `preact/jsx-runtime`. Read from the tsconfig, overridable by the config.
    jsx_import_source: []const u8 = "react",
    /// Return the position of every emitted node, for a source map.
    sourcemap: bool = false,
};

/// bundleWith(entryPath, { format, dead, minify, resolve }) -> { code, stats, dead }.
/// The CLI's entry point: a single call for everything it can do.
fn bundleWith(a: Allocator, entry: []const u8, opts: JsOptions) !linker.Report {
    const format: linker.Format = if (std.mem.eql(u8, opts.format, "iife"))
        .iife
    else if (std.mem.eql(u8, opts.format, "esm"))
        .esm
    else
        return zignapi.fail(try std.fmt.allocPrint(
            a,
            "unknown format '{s}' (expected: esm, iife)",
            .{opts.format},
        ));

    var t: std.Io.Threaded = undefined;
    var err: linker.BundleError = .{};
    const options: linker.Options = .{
        .format = format,
        .minify = opts.minify,
        .resolve = opts.resolve,
        .jsx_import_source = opts.jsx_import_source,
        .sourcemap = opts.sourcemap,
    };
    return linker.bundleReport(a, blockingIo(&t), entry, &err, opts.dead, options) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BundleFailed => return zignapi.fail(err.message),
    };
}

/// bundlePrint(entryPath) -> string: the bundle preceded by its statistics as a
/// comment. The counterpart of `graphPrint` — made for human eyes.
fn bundlePrint(a: Allocator, entry: []const u8) ![]const u8 {
    const b = try bundleStats(a, entry);
    const s = b.stats;
    const ratio = if (s.input_bytes > 0)
        100.0 * @as(f64, @floatFromInt(s.output_bytes)) / @as(f64, @floatFromInt(s.input_bytes))
    else
        0.0;
    return std.fmt.allocPrint(a,
        \\// {d} modules emitted ({d} eliminated), {d} externals, {d} bindings renamed
        \\// tree-shaking: {d} statements kept, {d} eliminated
        \\// {d} -> {d} bytes ({d:.0} %) in {d:.2} ms
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
        .graphWith = graphWith,
        .graphPrint = graphPrint,
        .resolve = resolveImpl,
        .bundle = bundleImpl,
        .bundleStats = bundleStats,
        .bundlePrint = bundlePrint,
        .bundleReport = bundleReport,
        .bundleWith = bundleWith,
        .VERSION = VERSION,
    });
}
