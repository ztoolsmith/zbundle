//! The RESOLVER: `(fromDir, specifier)` -> a canonical absolute path, or
//! "external", or an error that says exactly what was tried.
//!
//! Scope: **RELATIVE specifiers only** (`./x`, `../y/z`) and absolute paths. A
//! BARE specifier (`react`, `lodash/merge`, `node:fs`) is NOT an error: it is
//! marked **external** and the graph moves on. That is esbuild's `--external`
//! behaviour, and it is honest: `node_modules` resolution (the `exports` field,
//! conditions, `main`/`module`, self-references, hoisting...) is a project of
//! its own, planned for later.
//!
//! Depends on NOTHING but the stdlib: no zcompiler here (resolving a path is not
//! compiling), no zignapi (no notion of JS).
//!
//! **Disk access goes through `io: std.Io`** (Zig 0.16's I/O interface), never
//! through a hard-coded syscall. Direct consequence: porting zbundle onto a
//! virtual filesystem (a wasm backend, an in-memory cache, a watcher) means
//! supplying a different `Io`, without touching a single line of the resolver.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// The extension table, in TRY ORDER. The order is a **contract** (tested case
/// by case): `./x` must find `x.ts` BEFORE `x.js` — a TS project that compiled
/// an `x.js` next to its `x.ts` must see the source, not the output. Same order
/// as esbuild's `resolveExtensions`, minus `.css`/`.json` (no asset loaders).
pub const EXTENSIONS = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs" };

/// A module's format, derived from its EXTENSION (like esbuild/oxc — and like
/// zcompiler's own harness). Drives the parse mode.
pub const Format = enum {
    js,
    jsx,
    ts,
    tsx,

    /// The two flags `zcompiler.parseWith(arena, src, jsx, ts)` expects.
    pub fn flags(self: Format) struct { jsx: bool, ts: bool } {
        return switch (self) {
            .js => .{ .jsx = false, .ts = false },
            .jsx => .{ .jsx = true, .ts = false },
            .ts => .{ .jsx = false, .ts = true },
            .tsx => .{ .jsx = true, .ts = true },
        };
    }
};

/// `.ts` -> ts, `.tsx` -> ts+jsx, `.jsx` -> jsx, `.js`/`.mjs` (and the rest) -> js.
pub fn formatOf(path: []const u8) Format {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".ts")) return .ts;
    if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
    if (std.mem.eql(u8, ext, ".jsx")) return .jsx;
    return .js;
}

pub const Kind = enum {
    /// A file found on disk. `path` = its CANONICAL ABSOLUTE path.
    file,
    /// A bare specifier, left to the runtime. `path` = the specifier as written.
    external,
};

pub const Resolution = struct { kind: Kind, path: []const u8 };

pub const Error = error{ NotFound, OutOfMemory };

/// What was tried when it failed. Filled in by `resolve` on `error.NotFound`
/// (left empty otherwise). `tried` is in exact attempt order: this is THE
/// message that saves the user time.
pub const Diagnostic = struct {
    specifier: []const u8 = "",
    tried: []const []const u8 = &.{},
};

/// A BARE specifier = anything neither relative (`./`, `../`) nor absolute.
/// Covers `react`, `@scope/pkg`, `lodash/merge`, `node:fs`, `#alias` (import
/// maps) — all external for now.
pub fn isBare(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (std.mem.startsWith(u8, specifier, "./")) return false;
    if (std.mem.startsWith(u8, specifier, "../")) return false;
    if (std.mem.eql(u8, specifier, ".") or std.mem.eql(u8, specifier, "..")) return false;
    return !std.fs.path.isAbsolute(specifier);
}

/// Resolves `specifier` from `from_dir`.
///
/// Try order (the contract):
///   1. BARE specifier -> `.external`, stop there (never an error);
///   2. the path AS IS if it carries a known extension;
///   3. otherwise `<path>.ts`, `.tsx`, `.js`, `.jsx`, `.mjs` (in that order);
///   4. then `<path>/index.<ext>` in the SAME order (directory resolution).
///
/// The returned path is **canonical** (`realPath`: symlinks followed, case
/// corrected on a case-insensitive filesystem such as macOS). That is what
/// guarantees that one file reached by two different paths is ONE module in the
/// graph.
pub fn resolve(
    a: Allocator,
    io: Io,
    from_dir: []const u8,
    specifier: []const u8,
    diag: *Diagnostic,
) Error!Resolution {
    if (isBare(specifier)) return .{ .kind = .external, .path = specifier };

    const base = try std.fs.path.resolve(a, &.{ from_dir, specifier });
    var tried: std.ArrayList([]const u8) = .empty;

    if (hasKnownExtension(base)) {
        if (try tryFile(a, io, base, &tried)) |hit| return hit;
    } else {
        for (EXTENSIONS) |ext| {
            if (try tryFile(a, io, try std.mem.concat(a, u8, &.{ base, ext }), &tried)) |hit| return hit;
        }
        for (EXTENSIONS) |ext| {
            const leaf = try std.mem.concat(a, u8, &.{ "index", ext });
            if (try tryFile(a, io, try std.fs.path.join(a, &.{ base, leaf }), &tried)) |hit| return hit;
        }
    }

    diag.* = .{ .specifier = specifier, .tried = tried.items };
    return error.NotFound;
}

/// Records the candidate in `tried` and returns the resolution if it exists.
fn tryFile(a: Allocator, io: Io, cand: []const u8, tried: *std.ArrayList([]const u8)) Error!?Resolution {
    try tried.append(a, cand);
    const real = canonical(a, io, cand) catch return null;
    return .{ .kind = .file, .path = real };
}

fn hasKnownExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (EXTENSIONS) |known| {
        if (std.mem.eql(u8, ext, known)) return true;
    }
    return false;
}

/// The canonical path of `path` if it names an existing FILE. A directory is a
/// failure (`./dir` must fall through to the `index.<ext>` branch, not "resolve"
/// to the directory itself).
fn canonical(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    const st = try Dir.cwd().statFile(io, path, .{});
    if (st.kind != .file) return error.IsDir;
    return Dir.cwd().realPathFileAlloc(io, path, a);
}

/// Reads a source file. Lives here (rather than in graph.zig) because it is the
/// other half of the same contract: the resolver is the ONLY point of contact
/// with the disk. `max_bytes` bounds the read (a source file is not a blob).
pub fn readFile(a: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
}

/// The full error message: the specifier, the importer, and ALL attempted paths
/// in order. `importer` may be empty (standalone resolution).
pub fn formatError(a: Allocator, diag: Diagnostic, importer: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "cannot resolve '{s}'", .{diag.specifier}));
    if (importer.len > 0) try out.appendSlice(a, try std.fmt.allocPrint(a, " from {s}", .{importer}));
    if (diag.tried.len > 0) {
        try out.appendSlice(a, "\n  tried:");
        for (diag.tried) |t| try out.appendSlice(a, try std.fmt.allocPrint(a, "\n    {s}", .{t}));
    }
    return out.items;
}

// ------------------------------------------------------------------ tests

/// A real temporary directory: the resolver touches the disk, so the tests do
/// too (a fake filesystem would lie about case and symlinks).
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
    /// Resolves from the sandbox root and returns the RELATIVE path found
    /// (readable comparisons, independent of the tmpdir path). The result being
    /// canonical, it necessarily starts with `root` plus a separator.
    fn rel(self: *Sandbox, specifier: []const u8) ![]const u8 {
        var diag: Diagnostic = .{};
        const r = try resolve(self.a(), io, self.root, specifier, &diag);
        if (r.kind == .external) return r.path;
        try std.testing.expect(std.mem.startsWith(u8, r.path, self.root));
        return r.path[self.root.len + 1 ..];
    }
};

test "table order: .ts wins over .js" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.js", "");
    try s.write("x.ts", "");
    try std.testing.expectEqualStrings("x.ts", try s.rel("./x"));
}

test "table order, case by case (.ts > .tsx > .js > .jsx > .mjs)" {
    // Each pair: the expected winner, then a lower-ranked file.
    const pairs = [_][2][]const u8{
        .{ "a.ts", "a.tsx" },
        .{ "b.tsx", "b.js" },
        .{ "c.js", "c.jsx" },
        .{ "d.jsx", "d.mjs" },
    };
    for (pairs) |p| {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write(p[0], "");
        try s.write(p[1], "");
        const spec = try std.mem.concat(s.a(), u8, &.{ "./", p[0][0..1] });
        try std.testing.expectEqualStrings(p[0], try s.rel(spec));
    }
}

test "omitted extension: the only present candidate wins" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("only.mjs", "");
    try std.testing.expectEqualStrings("only.mjs", try s.rel("./only"));
}

test "explicit extension: the path as is" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.ts", "");
    try s.write("x.js", "");
    try std.testing.expectEqualStrings("x.js", try s.rel("./x.js"));
}

test "directory resolution: ./dir -> dir/index.ts" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/index.js", "");
    try s.write("dir/index.ts", "");
    const want = try std.fs.path.join(s.a(), &.{ "dir", "index.ts" });
    try std.testing.expectEqualStrings(want, try s.rel("./dir"));
}

test "a sibling file wins over a directory of the same name" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/index.ts", "");
    try s.write("dir.ts", "");
    try std.testing.expectEqualStrings("dir.ts", try s.rel("./dir"));
}

test "`..` and `.` are normalized (a single canonical path)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("sub/deep/mod.ts", "");
    const a = try s.rel("./sub/deep/mod.ts");
    const b = try s.rel("./sub/./deep/../deep/mod.ts");
    try std.testing.expectEqualStrings(a, b);
}

test "bare specifier -> external (never an error)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    for ([_][]const u8{ "react", "@scope/pkg", "lodash/merge", "node:fs" }) |spec| {
        var diag: Diagnostic = .{};
        const r = try resolve(s.a(), Sandbox.io, s.root, spec, &diag);
        try std.testing.expectEqual(Kind.external, r.kind);
        try std.testing.expectEqualStrings(spec, r.path);
    }
}

test "isBare: the relative / bare boundary" {
    try std.testing.expect(isBare("react"));
    try std.testing.expect(isBare("@a/b"));
    try std.testing.expect(!isBare("./a"));
    try std.testing.expect(!isBare("../a"));
    try std.testing.expect(!isBare("/abs/a"));
    try std.testing.expect(!isBare("."));
}

test "not found: the error lists ALL attempted paths, in order" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./missing", &diag));
    // 5 extensions + 5 index.<ext> = 10 candidates, in table order.
    try std.testing.expectEqual(@as(usize, 10), diag.tried.len);
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[0], "missing.ts"));
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[4], "missing.mjs"));
    const idx_ts = try std.fs.path.join(s.a(), &.{ "missing", "index.ts" });
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[5], idx_ts));
    const msg = try formatError(s.a(), diag, "/app/entry.ts");
    try std.testing.expect(std.mem.startsWith(u8, msg, "cannot resolve './missing' from /app/entry.ts"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "tried:") != null);
}

test "a directory does not resolve to itself (without an index)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/other.ts", "");
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./dir", &diag));
}

test "formatOf: the extension decides the parse mode" {
    try std.testing.expectEqual(Format.ts, formatOf("/a/b.ts"));
    try std.testing.expectEqual(Format.tsx, formatOf("/a/b.tsx"));
    try std.testing.expectEqual(Format.jsx, formatOf("/a/b.jsx"));
    try std.testing.expectEqual(Format.js, formatOf("/a/b.js"));
    try std.testing.expectEqual(Format.js, formatOf("/a/b.mjs"));
    try std.testing.expect(Format.tsx.flags().jsx and Format.tsx.flags().ts);
    try std.testing.expect(!Format.js.flags().jsx and !Format.js.flags().ts);
}
