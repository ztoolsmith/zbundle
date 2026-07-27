//! The module GRAPH: from an entry, follow dependencies to the fixed point and
//! return the structure — modules, edges, externals, cycles.
//!
//! **The golden rule**: zbundle never reimplements what zcompiler already does.
//! Reading a file's dependencies is compiler work, so `zcompiler.parseWith` plus
//! `zcompiler.moduleRecords` (a capability ADDED to zcompiler for this purpose).
//! What remains here is what is genuinely bundler work: traversal, deduplication
//! and cycles.

const std = @import("std");
const zc = @import("zcompiler");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A reasonable source file. Beyond that it is not code: we refuse rather than
/// swallow 2 GB into the arena.
const MAX_FILE_BYTES = 32 * 1024 * 1024;

pub const ModuleId = u32;

/// A module = a FILE, identified by its canonical absolute path. Visited exactly
/// once, however many importers it has (that is the diamond test).
pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    /// Derived from the extension (see `resolver.Format`): drives the parse mode.
    format: resolver.Format,
    /// Number of parse diagnostics. Non-blocking: zcompiler recovers from errors
    /// and always returns an AST, so a broken file still contributes the imports
    /// we could read (same philosophy as its error recovery).
    parse_errors: u32,
};

/// The dependency kind, an exact mirror of `zcompiler.ModuleRecordKind`: the
/// boundary renames nothing.
pub const EdgeKind = enum { import, re_export, export_all, export_all_as, dynamic_import };

/// An entry of `with { type: 'json' }`, as zcompiler decodes it. Unused so far
/// (the resolver only knows JS/TS extensions) — this is what will route assets
/// to their loader once package resolution lands.
pub const Attribute = struct { key: []const u8, value: []const u8 };

/// An edge = a dependency declared by `from`.
///
/// `to` is null when the target is EXTERNAL (a bare specifier); `external` then
/// gives the index into `externals`. `is_dynamic` is derived from `kind`:
/// redundant but explicit, it is the piece future code splitting will read.
/// `name`: the export name of an `export * as ns from` (null everywhere else).
/// `attributes`: the `with { … }` clause, empty when absent.
pub const Edge = struct {
    from: ModuleId,
    to: ?ModuleId,
    external: ?u32,
    specifier: []const u8,
    kind: EdgeKind,
    is_dynamic: bool,
    name: ?[]const u8 = null,
    attributes: []const Attribute = &.{},
};

/// A bare specifier, deduplicated, with how many times it is imported.
pub const External = struct { specifier: []const u8, count: u32 };

pub const Stats = struct {
    modules: u32,
    edges: u32,
    externals: u32,
    cycles: u32,
    parse_errors: u32,
    /// Graph build time (disk reads + parsing + traversal).
    build_ms: f64,
};

/// The PARSED module, kept aside for the next stage (the linker). Indexed by
/// `ModuleId`, parallel to `Graph.modules`.
///
/// Separate from `Module` for a dull but good reason: `Module` crosses the N-API
/// boundary (zignapi serializes it into a JS object), and a `*Node` has no JS
/// representation. Pointers therefore stay on the Zig side.
///
/// **The AST is already normalized to plain JS**: TS types erased, JSX lowered
/// to `jsx()/jsxs()`. Everything downstream (records, linking, emission) sees a
/// single language.
pub const Parsed = struct {
    source: []const u8,
    program: *zc.Node,
};

/// The complete result. Everything is allocated in the arena passed to `build`.
pub const Graph = struct {
    entry: ModuleId,
    modules: []const Module,
    edges: []const Edge,
    externals: []const External,
    /// Each cycle = the (sorted) list of modules that reach one another. See
    /// `findCycles` for the exact definition.
    cycles: []const []const ModuleId,
    stats: Stats,
};

/// A `build` failure: the message is already formatted for the user (specifier
/// plus importer plus attempted paths).
pub const BuildError = struct { message: []const u8 = "" };

pub const Error = error{ BuildFailed, OutOfMemory };

/// What `build` returns: the graph (serializable) plus the ASTs (Zig side).
pub const Built = struct { graph: Graph, parsed: []const Parsed };

/// Builds the graph from `entry` (a path, relative to the cwd or absolute).
///
/// **Breadth-first** traversal (FIFO queue): every discovered module gets an id
/// in discovery order, is read and parsed ONCE, and its records become edges.
/// Since ids are assigned on discovery and the queue is FIFO, edges come out
/// grouped by ascending `from` — deterministic output.
///
/// A relative specifier that does not resolve FAILS the build (`err.message`
/// holds the attempted paths). A bare specifier never fails: it becomes an
/// external.
///
/// `cfg` is what the build layer is allowed to change about resolution (the
/// extension table, the aliases). `.{}` = the historical behaviour, so every
/// existing caller and test keeps its exact meaning.
pub fn build(a: Allocator, io: Io, entry: []const u8, cfg: resolver.Config, err: *BuildError) Error!Built {
    const t0 = Io.Clock.awake.now(io).nanoseconds;

    var b = Builder{ .a = a, .io = io, .cfg = cfg, .err = err };
    // The entry is made ABSOLUTE first: `std.fs.path.resolve` is purely lexical
    // in Zig 0.16 (it does not know the cwd), so without this a relative entry
    // would stay relative in error messages.
    const abs_entry = try absolute(a, io, entry);
    const entry_dir = std.fs.path.dirname(abs_entry) orelse ".";
    const entry_name = try std.mem.concat(a, u8, &.{ "./", std.fs.path.basename(abs_entry) });
    const entry_id = try b.resolveAndIntern(entry_dir, entry_name, "");

    // FIFO queue: `cursor` advances, `modules` grows behind it.
    var cursor: usize = 0;
    while (cursor < b.modules.items.len) : (cursor += 1) {
        try b.scan(@intCast(cursor));
    }

    const cycles = try findCycles(a, b.modules.items.len, b.edges.items);
    const t1 = Io.Clock.awake.now(io).nanoseconds;

    return .{
        .graph = .{
            .entry = entry_id,
            .modules = b.modules.items,
            .edges = b.edges.items,
            .externals = b.externals.items,
            .cycles = cycles,
            .stats = .{
                .modules = @intCast(b.modules.items.len),
                .edges = @intCast(b.edges.items.len),
                .externals = @intCast(b.externals.items.len),
                .cycles = @intCast(cycles.len),
                .parse_errors = b.parse_errors,
                .build_ms = @as(f64, @floatFromInt(t1 - t0)) / std.time.ns_per_ms,
            },
        },
        .parsed = b.parsed.items,
    };
}

/// `path` as is when absolute, otherwise prefixed with the process cwd. Does not
/// touch the disk for the file itself (the resolver does that right after).
fn absolute(a: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = std.process.currentPathAlloc(io, a) catch return path;
    return std.fs.path.resolve(a, &.{ cwd, path });
}

const Builder = struct {
    a: Allocator,
    io: Io,
    /// The resolution knobs, carried down to every `resolver.resolve` call.
    cfg: resolver.Config,
    err: *BuildError,
    modules: std.ArrayList(Module) = .empty,
    /// Parallel to `modules`: each one's normalized AST, kept for the linker.
    parsed: std.ArrayList(Parsed) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    externals: std.ArrayList(External) = .empty,
    /// canonical path -> id. THE table that guarantees "one file = one module".
    by_path: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// bare specifier -> index into `externals`.
    by_specifier: std.StringHashMapUnmanaged(u32) = .empty,
    parse_errors: u32 = 0,

    /// Resolves `specifier` from `from_dir` and returns the module id (creating
    /// it if new). `error.BuildFailed` if a relative specifier does not resolve.
    fn resolveAndIntern(self: *Builder, from_dir: []const u8, specifier: []const u8, importer: []const u8) Error!ModuleId {
        var diag: resolver.Diagnostic = .{};
        const r = resolver.resolve(self.a, self.io, from_dir, specifier, self.cfg, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound => {
                self.err.message = try resolver.formatError(self.a, diag, importer);
                return error.BuildFailed;
            },
        };
        std.debug.assert(r.kind == .file); // the caller filtered out externals
        return self.intern(r.path);
    }

    /// The id of `path` (canonical), creating it if needed. This is where — and
    /// nowhere else — deduplication happens.
    fn intern(self: *Builder, path: []const u8) Error!ModuleId {
        const gop = try self.by_path.getOrPut(self.a, path);
        if (gop.found_existing) return gop.value_ptr.*;
        const id: ModuleId = @intCast(self.modules.items.len);
        gop.value_ptr.* = id;
        try self.modules.append(self.a, .{
            .id = id,
            .path = path,
            .format = resolver.formatOf(path),
            .parse_errors = 0,
        });
        try self.parsed.append(self.a, .{ .source = "", .program = undefined }); // filled in by `scan`
        return id;
    }

    fn internExternal(self: *Builder, specifier: []const u8) Error!u32 {
        const gop = try self.by_specifier.getOrPut(self.a, specifier);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.externals.items.len);
            try self.externals.append(self.a, .{ .specifier = specifier, .count = 0 });
        }
        self.externals.items[gop.value_ptr.*].count += 1;
        return gop.value_ptr.*;
    }

    /// Reads and parses module `id`, **normalizes it to plain JS**, and turns its
    /// module records into edges.
    /// **All JS understanding lives in zcompiler**: here we only route paths.
    fn scan(self: *Builder, id: ModuleId) Error!void {
        const mod = self.modules.items[id];
        const src = resolver.readFile(self.a, self.io, mod.path, MAX_FILE_BYTES) catch |e| {
            self.err.message = try std.fmt.allocPrint(self.a, "cannot read {s}: {s}", .{ mod.path, @errorName(e) });
            return error.BuildFailed;
        };

        const f = mod.format.flags();
        const parsed = try zc.parseWith(self.a, src, f.jsx, f.ts);
        self.modules.items[id].parse_errors = @intCast(parsed.errors.len);
        self.parse_errors += @intCast(parsed.errors.len);

        // NORMALIZE TO PLAIN JS right away — before records, before anything.
        // TS types are erased, JSX is lowered to `jsx()/jsxs()`. Two reasons:
        //   1. the linker and the emitter only ever see ONE language;
        //   2. more importantly, `jsxTransform` **ADDS an import**
        //      (`react/jsx-runtime`). Doing it AFTER record extraction would make
        //      that dependency invisible to the graph — the bundle would
        //      reference `jsx` without importing it.
        // The order (strip THEN jsx) is the one zcompiler's own harness uses.
        if (f.ts) zc.transformer.stripTypes(parsed.program, src, self.a);
        if (f.jsx) _ = zc.jsx_transform.transform(parsed.program, src, self.a, .{});
        self.parsed.items[id] = .{ .source = src, .program = parsed.program };

        const dir = std.fs.path.dirname(mod.path) orelse ".";
        for (zc.moduleRecords(self.a, parsed.program, src)) |rec| {
            // `import type { T } from './t'` is erased on emission: it is not a
            // runtime dependency, so not an edge. (After `stripTypes` there
            // should be none left; the guard costs nothing.)
            if (rec.type_only) continue;
            try self.addEdge(id, dir, mod.path, rec);
        }
    }

    fn addEdge(self: *Builder, from: ModuleId, dir: []const u8, importer: []const u8, rec: zc.ModuleRecord) Error!void {
        const kind = kindOf(rec.kind);
        var edge: Edge = .{
            .from = from,
            .to = null,
            .external = null,
            .specifier = rec.specifier,
            .kind = kind,
            .is_dynamic = kind == .dynamic_import,
            .name = rec.name,
            .attributes = @ptrCast(rec.attributes),
        };
        if (resolver.isExternal(self.cfg, rec.specifier)) {
            edge.external = try self.internExternal(rec.specifier);
        } else {
            edge.to = try self.resolveAndIntern(dir, rec.specifier, importer);
        }
        try self.edges.append(self.a, edge);
    }
};

/// The zcompiler -> zbundle boundary: an exhaustive `switch`, so that the day
/// zcompiler adds a `kind` (import attributes, `require`...), the compiler forces
/// us to decide here.
fn kindOf(k: zc.ModuleRecordKind) EdgeKind {
    return switch (k) {
        .import => .import,
        .re_export => .re_export,
        .export_all => .export_all,
        // Added by zcompiler 0.2.0. The exhaustive `switch` REFUSED to compile
        // until this case was handled — exactly the role it was given: making it
        // impossible to silently ignore a new compiler capability. A full-fledged
        // edge (the target module really is a dependency); what differs is what
        // the emitter will make of it.
        .export_all_as => .export_all_as,
        .dynamic_import => .dynamic_import,
    };
}

// ---- cycles ----

/// The graph's cycles, via **Tarjan** (strongly connected components),
/// iterative — a real project has chains of hundreds of modules, and a recursive
/// DFS would eventually blow the stack.
///
/// Definition used: a cycle = an SCC of size > 1 (its modules all reach one
/// another), or a module that imports itself. Every loop in the graph is
/// contained in exactly one SCC — so the list is complete, without duplicates or
/// combinatorial blow-up (enumerating every cyclic path would be exponential).
///
/// **A cycle is NOT an error**: ESM cycles are legal and real code has them. The
/// bundler will have to handle them (execution order, live bindings); the graph
/// must already see them.
fn findCycles(a: Allocator, n_modules: usize, edges: []const Edge) Allocator.Error![]const []const ModuleId {
    if (n_modules == 0) return &.{};
    const adj = try adjacency(a, n_modules, edges);

    const UNVISITED = std.math.maxInt(u32);
    const index = try a.alloc(u32, n_modules);
    const lowlink = try a.alloc(u32, n_modules);
    const on_stack = try a.alloc(bool, n_modules);
    @memset(index, UNVISITED);
    @memset(lowlink, 0);
    @memset(on_stack, false);

    var next_index: u32 = 0;
    var scc_stack: std.ArrayList(ModuleId) = .empty;
    var out: std.ArrayList([]const ModuleId) = .empty;

    // Explicit DFS stack: (module, position in its adjacency list).
    const Frame = struct { v: ModuleId, i: usize };
    var stack: std.ArrayList(Frame) = .empty;

    for (0..n_modules) |root| {
        if (index[root] != UNVISITED) continue;
        try stack.append(a, .{ .v = @intCast(root), .i = 0 });
        index[root] = next_index;
        lowlink[root] = next_index;
        next_index += 1;
        try scc_stack.append(a, @intCast(root));
        on_stack[root] = true;

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const v = top.v;
            if (top.i < adj[v].len) {
                const w = adj[v][top.i];
                top.i += 1;
                if (index[w] == UNVISITED) {
                    index[w] = next_index;
                    lowlink[w] = next_index;
                    next_index += 1;
                    try scc_stack.append(a, w);
                    on_stack[w] = true;
                    try stack.append(a, .{ .v = w, .i = 0 });
                } else if (on_stack[w]) {
                    lowlink[v] = @min(lowlink[v], index[w]);
                }
                continue;
            }
            // v is finished: propagate its lowlink to the parent, and close the
            // SCC if v is its root.
            _ = stack.pop();
            if (stack.items.len > 0) {
                const parent = stack.items[stack.items.len - 1].v;
                lowlink[parent] = @min(lowlink[parent], lowlink[v]);
            }
            if (lowlink[v] != index[v]) continue;

            var comp: std.ArrayList(ModuleId) = .empty;
            while (true) {
                const w = scc_stack.pop().?;
                on_stack[w] = false;
                try comp.append(a, w);
                if (w == v) break;
            }
            if (comp.items.len > 1 or hasSelfLoop(adj[v], v)) {
                std.mem.sort(ModuleId, comp.items, {}, std.sort.asc(ModuleId));
                try out.append(a, comp.items);
            }
        }
    }

    // Stable order for tests and diffs: by smallest member.
    std.mem.sort([]const ModuleId, out.items, {}, cycleLess);
    return out.items;
}

fn cycleLess(_: void, x: []const ModuleId, y: []const ModuleId) bool {
    return x[0] < y[0];
}

fn hasSelfLoop(neighbors: []const ModuleId, v: ModuleId) bool {
    return std.mem.indexOfScalar(ModuleId, neighbors, v) != null;
}

/// Adjacency lists (external edges are ignored: an external is a leaf, it cannot
/// close a cycle).
fn adjacency(a: Allocator, n_modules: usize, edges: []const Edge) Allocator.Error![]const []const ModuleId {
    const counts = try a.alloc(u32, n_modules);
    @memset(counts, 0);
    for (edges) |e| {
        if (e.to) |to| {
            _ = to;
            counts[e.from] += 1;
        }
    }
    const adj = try a.alloc([]ModuleId, n_modules);
    for (adj, counts) |*slot, c| slot.* = try a.alloc(ModuleId, c);
    const filled = try a.alloc(u32, n_modules);
    @memset(filled, 0);
    for (edges) |e| {
        if (e.to) |to| {
            adj[e.from][filled[e.from]] = to;
            filled[e.from] += 1;
        }
    }
    return @ptrCast(adj);
}

// ---- debug printer ----

/// The readable indented tree: the entry as root, one level per depth, externals
/// marked, cycles reported. The counterpart of zcompiler's `printTree` — a graph
/// you cannot READ is a graph you cannot debug.
///
/// Paths are shown relative to the entry's directory. An already-visited module
/// is not expanded again (otherwise a diamond would duplicate and a cycle would
/// loop): it is marked, with `(cycle)` when the module is an ancestor on the
/// current branch.
pub fn printTree(a: Allocator, g: Graph, out: *std.ArrayList(u8)) Allocator.Error!void {
    const root_dir = std.fs.path.dirname(g.modules[g.entry].path) orelse ".";
    const adj = try edgeIndex(a, g);

    const seen = try a.alloc(bool, g.modules.len);
    @memset(seen, false);
    var path_stack: std.ArrayList(ModuleId) = .empty;
    try walk(a, g, adj, g.entry, 0, root_dir, seen, &path_stack, out);

    if (g.cycles.len > 0) {
        try out.appendSlice(a, "\ncycles:\n");
        for (g.cycles) |cyc| {
            try out.appendSlice(a, "  ");
            for (cyc, 0..) |m, i| {
                if (i > 0) try out.appendSlice(a, " <-> ");
                try out.appendSlice(a, try display(a, root_dir, g.modules[m].path));
            }
            try out.append(a, '\n');
        }
    }
    try out.appendSlice(a, try std.fmt.allocPrint(
        a,
        "\n{d} modules, {d} edges, {d} externals, {d} cycles, {d} parse errors in {d:.2} ms\n",
        .{ g.stats.modules, g.stats.edges, g.stats.externals, g.stats.cycles, g.stats.parse_errors, g.stats.build_ms },
    ));
}

fn walk(
    a: Allocator,
    g: Graph,
    adj: []const []const u32,
    id: ModuleId,
    depth: usize,
    root_dir: []const u8,
    seen: []bool,
    path_stack: *std.ArrayList(ModuleId),
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    try indent(a, out, depth);
    try out.appendSlice(a, try display(a, root_dir, g.modules[id].path));
    if (g.modules[id].parse_errors > 0) {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "  [{d} parse errors]", .{g.modules[id].parse_errors}));
    }
    if (seen[id]) {
        const cyclic = std.mem.indexOfScalar(ModuleId, path_stack.items, id) != null;
        try out.appendSlice(a, if (cyclic) "  (cycle)\n" else "  (deja visite)\n");
        return;
    }
    try out.append(a, '\n');
    seen[id] = true;
    try path_stack.append(a, id);
    defer _ = path_stack.pop();

    for (adj[id]) |ei| {
        const e = g.edges[ei];
        if (e.to) |to| {
            if (e.is_dynamic) {
                // An `import()` is a BOUNDARY (the future chunk split point): it
                // shows up in the tree, even though it is currently followed like
                // any other edge.
                try indent(a, out, depth + 1);
                try out.appendSlice(a, "(dynamic)\n");
            }
            try walk(a, g, adj, to, depth + 1, root_dir, seen, path_stack, out);
        } else {
            try indent(a, out, depth + 1);
            const tag = if (e.is_dynamic) "  (external, dynamic)\n" else "  (external)\n";
            try out.appendSlice(a, e.specifier);
            try out.appendSlice(a, tag);
        }
    }
}

fn indent(a: Allocator, out: *std.ArrayList(u8), depth: usize) Allocator.Error!void {
    for (0..depth) |_| try out.appendSlice(a, "  ");
}

/// Path relative to `root_dir` when possible (readable), absolute otherwise.
fn display(a: Allocator, root_dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (path.len > root_dir.len + 1 and std.mem.startsWith(u8, path, root_dir) and
        path[root_dir.len] == std.fs.path.sep)
    {
        return try std.mem.concat(a, u8, &.{ "./", path[root_dir.len + 1 ..] });
    }
    return path;
}

/// For each module, the INDICES of its outgoing edges (in source order).
fn edgeIndex(a: Allocator, g: Graph) Allocator.Error![]const []const u32 {
    const counts = try a.alloc(u32, g.modules.len);
    @memset(counts, 0);
    for (g.edges) |e| counts[e.from] += 1;
    const adj = try a.alloc([]u32, g.modules.len);
    for (adj, counts) |*slot, c| slot.* = try a.alloc(u32, c);
    const filled = try a.alloc(u32, g.modules.len);
    @memset(filled, 0);
    for (g.edges, 0..) |e, i| {
        adj[e.from][filled[e.from]] = @intCast(i);
        filled[e.from] += 1;
    }
    return @ptrCast(adj);
}

// ------------------------------------------------------------------ tests

const Sandbox = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    const io = std.testing.io;

    fn init(gpa: Allocator) !Sandbox {
        var tmp = std.testing.tmpDir(.{});
        var arena = std.heap.ArenaAllocator.init(gpa);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        // In TWO steps: in a `return .{ .arena = arena, .root = try
        // arena.allocator()… }`, the arena is copied into the return slot BEFORE
        // `.root` allocates — the allocation would land in the local copy, never
        // freed (a real leak, caught by the test runner).
        const root = try arena.allocator().dupe(u8, buf[0..n]);
        return .{ .tmp = tmp, .arena = arena, .root = root };
    }
    fn deinit(self: *Sandbox) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn a(self: *Sandbox) Allocator {
        return self.arena.allocator();
    }
    fn write(self: *Sandbox, sub_path: []const u8, contents: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |dir| try self.tmp.dir.createDirPath(io, dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = contents });
    }
    fn graph(self: *Sandbox, entry: []const u8) !Graph {
        return self.graphCfg(entry, .{});
    }
    /// Same, with explicit resolution knobs (aliases, custom table).
    fn graphCfg(self: *Sandbox, entry: []const u8, cfg: resolver.Config) !Graph {
        var err: BuildError = .{};
        const full = try std.fs.path.join(self.a(), &.{ self.root, entry });
        const built = build(self.a(), io, full, cfg, &err) catch |e| {
            std.debug.print("build failed: {s}\n", .{err.message});
            return e;
        };
        return built.graph;
    }
    /// The module whose path ends with `suffix` (readable assertions).
    fn find(self: *Sandbox, g: Graph, suffix: []const u8) !ModuleId {
        _ = self;
        for (g.modules) |m| {
            if (std.mem.endsWith(u8, m.path, suffix)) return m.id;
        }
        return error.ModuleNotInGraph;
    }
};

test "simple chain a -> b -> c" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js';");
    try s.write("b.js", "import './c.js';");
    try s.write("c.js", "export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 3), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 2), g.stats.edges);
    try std.testing.expectEqual(@as(u32, 0), g.stats.cycles);
    try std.testing.expectEqual(@as(ModuleId, 0), g.entry);
}

test "diamond: the shared module is visited ONCE (4 modules, not 5)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js'; import './c.js';");
    try s.write("b.js", "import './d.js';");
    try s.write("c.js", "import './d.js';");
    try s.write("d.js", "export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 4), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 4), g.stats.edges); // both edges to d still exist
    try std.testing.expectEqual(@as(u32, 0), g.stats.cycles);
    // Both edges point at the SAME id.
    const d = try s.find(g, "d.js");
    var to_d: u32 = 0;
    for (g.edges) |e| {
        if (e.to) |t| {
            if (t == d) to_d += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), to_d);
}

test "cycle a -> b -> a: detected, listed, not an error, no infinite loop" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js';");
    try s.write("b.js", "import './a.js';");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 1), g.stats.cycles);
    try std.testing.expectEqual(@as(usize, 2), g.cycles[0].len);
}

test "self-import (a -> a): a one-module cycle" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './a.js'; export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 1), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 1), g.stats.cycles);
    try std.testing.expectEqual(@as(usize, 1), g.cycles[0].len);
}

test "a re-export IS a dependency" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "export { x } from './b.js'; export * from './c.js';");
    try s.write("b.js", "export const x = 1;");
    try s.write("c.js", "export const y = 2;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 3), g.stats.modules);
    try std.testing.expectEqual(EdgeKind.re_export, g.edges[0].kind);
    try std.testing.expectEqual(EdgeKind.export_all, g.edges[1].kind);
}

test "bare specifier -> external, and the graph carries on" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import 'react'; import './b.js'; import 'react';");
    try s.write("b.js", "import 'lodash';");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 2), g.stats.externals); // react dedupe
    try std.testing.expectEqualStrings("react", g.externals[0].specifier);
    try std.testing.expectEqual(@as(u32, 2), g.externals[0].count);
}

test "dynamic import(): edge marked is_dynamic" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "const f = () => import('./b.js');");
    try s.write("b.js", "export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules);
    try std.testing.expect(g.edges[0].is_dynamic);
    try std.testing.expectEqual(EdgeKind.dynamic_import, g.edges[0].kind);
}

test "mixed .ts / .js / .jsx / .tsx: each file parsed in its own mode" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.tsx", "import { B } from './b'; const x: number = 1; export const A = () => <B x={x} />;");
    try s.write("b.jsx", "import './c'; export const B = (p) => <i>{p.x}</i>;");
    try s.write("c.ts", "import './d.js'; export type T = string; export const c: T = 'c';");
    try s.write("d.js", "export const d = 1;");
    const g = try s.graph("a.tsx");
    try std.testing.expectEqual(@as(u32, 4), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 0), g.stats.parse_errors);
    try std.testing.expectEqual(resolver.Format.tsx, g.modules[g.entry].format);
}

test "import type: erased on emission, so NOT an edge" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.ts", "import type { T } from './types'; import { v } from './v';");
    try s.write("types.ts", "export type T = string;");
    try s.write("v.ts", "export const v = 1;");
    const g = try s.graph("a.ts");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules); // types.ts absent
    try std.testing.expectEqual(@as(u32, 1), g.stats.edges);
}

test "relative not found: error with the attempted paths" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './missing';");
    var err: BuildError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "a.js" });
    try std.testing.expectError(error.BuildFailed, build(s.a(), Sandbox.io, full, .{}, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.message, "cannot resolve './missing'") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "a.js") != null); // the importer
    try std.testing.expect(std.mem.indexOf(u8, err.message, "missing.ts") != null); // the attempts
}

test "broken code: the graph is still built (error recovery)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js'; let x = ; import './c.js';");
    try s.write("b.js", "");
    try s.write("c.js", "");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 3), g.stats.modules);
    try std.testing.expect(g.stats.parse_errors > 0);
}

test "printTree: readable tree, externals and cycles marked" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js'; import 'react';");
    try s.write("b.js", "import './a.js';");
    const g = try s.graph("a.js");
    var out: std.ArrayList(u8) = .empty;
    try printTree(s.a(), g, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "./a.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "react  (external)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(cycle)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "cycles:") != null);
}
