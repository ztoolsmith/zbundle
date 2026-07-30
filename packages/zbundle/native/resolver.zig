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
//! Depends on the stdlib and on `codeframe.zig` — itself stdlib-only, and used
//! for PRESENTATION alone (shortening an over-long value in a message). No
//! zcompiler here (resolving a path is not compiling), no zignapi (no notion of
//! JS): the invariant that matters is untouched.
//!
//! **Disk access goes through `io: std.Io`** (Zig 0.16's I/O interface), never
//! through a hard-coded syscall. Direct consequence: porting zbundle onto a
//! virtual filesystem (a wasm backend, an in-memory cache, a watcher) means
//! supplying a different `Io`, without touching a single line of the resolver.

const std = @import("std");
const codeframe = @import("codeframe.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// The extension table, in TRY ORDER. The order is a **contract** (tested case
/// by case): `./x` must find `x.ts` BEFORE `x.js` — a TS project that compiled
/// an `x.js` next to its `x.ts` must see the source, not the output. Same order
/// as esbuild's `resolveExtensions`, minus `.css`/`.json` (no asset loaders).
pub const EXTENSIONS = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs" };

/// One alias: a specifier PREFIX and what it expands to.
///
/// `to` is expected ABSOLUTE. The TS layer resolves it against the directory of
/// the **config file** — not the cwd — before handing it over: a config is read
/// relative to where it lives, and doing it up there keeps this file free of any
/// notion of "project root".
pub const Alias = struct {
    from: []const u8,
    to: []const u8,
    /// Match the specifier WHOLE instead of as a prefix.
    ///
    /// A tsconfig `paths` entry without a `*` is an EXACT mapping:
    /// `"jquery": ["./vendor/jq.js"]` must map `jquery` and nothing else — as a
    /// prefix it would also swallow `jquery-ui`. Wildcard entries stay prefixes.
    exact: bool = false,
    /// The directory this alias is valid UNDER. Empty = the whole build.
    ///
    /// This is what makes per-file `tsconfig.json` work: a monorepo has one
    /// tsconfig per package, each with its own `paths`, and a module must be
    /// resolved by the one that governs IT — not by whichever happened to be
    /// found first. The build layer stamps each alias with its tsconfig's
    /// directory; resolution then only considers the aliases whose scope
    /// contains the importer.
    scope: []const u8 = "",
};

/// Does the specifier match this alias — whole for an exact entry, by prefix
/// otherwise?
fn aliasMatches(al: Alias, specifier: []const u8) bool {
    return if (al.exact)
        std.mem.eql(u8, specifier, al.from)
    else
        std.mem.startsWith(u8, specifier, al.from);
}

/// Does this alias govern a file sitting in `from_dir`?
///
/// A scope contains a directory when it IS that directory or a prefix of it at a
/// separator boundary — `/p/a` must not capture `/p/ab`.
fn aliasApplies(al: Alias, from_dir: []const u8) bool {
    if (al.scope.len == 0) return true;
    if (std.mem.eql(u8, from_dir, al.scope)) return true;
    return from_dir.len > al.scope.len and
        std.mem.startsWith(u8, from_dir, al.scope) and
        from_dir[al.scope.len] == std.fs.path.sep;
}

/// What the build layer is allowed to change about resolution. The defaults ARE
/// the historical behaviour, so `.{}` resolves exactly as before.
pub const Config = struct {
    /// Try order for an omitted extension. Order is meaning, not preference.
    extensions: []const []const u8 = &EXTENSIONS,
    /// Prefix aliases, applied BEFORE the bare-specifier test.
    alias: []const Alias = &.{},
};

/// Expands the first matching alias, or null.
///
/// **Exact prefix substitution**, deliberately: `'@' -> '/p/src'` turns `'@/x'`
/// into `'/p/src/x'`. No regex, no multiple fallback. The consequence is worth
/// stating: `'@foo'` also matches `'@'` and becomes `'/p/srcfoo'` — which is why
/// an alias key is normally written with its separator (`'@/'`).
///
/// When several aliases match, the LONGEST prefix wins: without that rule `'@'`
/// would shadow `'@scope'` depending on declaration order, and a config's
/// meaning must not depend on key order.
fn applyAlias(a: Allocator, cfg: Config, from_dir: []const u8, specifier: []const u8) Allocator.Error!?[]const u8 {
    var best: ?Alias = null;
    for (cfg.alias) |al| {
        if (!aliasApplies(al, from_dir)) continue;
        if (!aliasMatches(al, specifier)) continue;
        // The NEAREST tsconfig wins first (longest scope), then the most
        // specific prefix. Without the scope tie-break, a root tsconfig would
        // shadow a package's own `paths`.
        const b = best orelse {
            best = al;
            continue;
        };
        if (al.scope.len > b.scope.len or (al.scope.len == b.scope.len and al.from.len > b.from.len)) best = al;
    }
    const hit = best orelse return null;
    // Separate statement: `[]u8` does not coerce into the `?[]const u8` payload
    // of an error union directly.
    const expanded = try std.mem.concat(a, u8, &.{ hit.to, specifier[hit.from.len..] });
    return expanded;
}

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

/// Would this specifier be left to the runtime? Bare AND matched by no alias.
///
/// The graph asks this **before** calling `resolve` (it files externals without
/// touching the disk), so the answer has to account for aliases here too —
/// otherwise `'@/x'` would be filed as an external and the alias would never
/// fire. One rule, one place: `resolve` calls this very function.
pub fn isExternal(cfg: Config, from_dir: []const u8, specifier: []const u8) bool {
    if (!isBare(specifier)) return false;
    for (cfg.alias) |al| {
        if (aliasApplies(al, from_dir) and aliasMatches(al, specifier)) return false;
    }
    return true;
}

/// Resolves `specifier` from `from_dir`.
///
/// Try order (the contract):
///   0. an ALIAS whose prefix matches -> substitute, and the result is NEVER
///      external (see below);
///   1. BARE specifier -> `.external`, stop there (never an error);
///   2. the path AS IS if it carries a known extension;
///   3. otherwise `<path>.ts`, `.tsx`, `.js`, `.jsx`, `.mjs` (in that order);
///   4. then `<path>/index.<ext>` in the SAME order (directory resolution).
///
/// **Aliases run BEFORE the bare test, and that ordering is the whole point.**
/// `'@'` and `'~'` are bare-looking; if the test came first they would leave as
/// externals and the alias would never fire. So an aliased specifier that does
/// not exist on disk is an ERROR, not a silent external — otherwise a typo in an
/// aliased import would sail through and only surface at runtime.
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
    cfg: Config,
    diag: *Diagnostic,
) Error!Resolution {
    if (isExternal(cfg, from_dir, specifier)) return .{ .kind = .external, .path = specifier };
    const spec = (try applyAlias(a, cfg, from_dir, specifier)) orelse specifier;

    const base = try std.fs.path.resolve(a, &.{ from_dir, spec });
    var tried: std.ArrayList([]const u8) = .empty;

    if (hasKnownExtension(base, cfg.extensions)) {
        if (try tryFile(a, io, base, &tried)) |hit| return hit;
    } else {
        for (cfg.extensions) |ext| {
            if (try tryFile(a, io, try std.mem.concat(a, u8, &.{ base, ext }), &tried)) |hit| return hit;
        }
        for (cfg.extensions) |ext| {
            const leaf = try std.mem.concat(a, u8, &.{ "index", ext });
            if (try tryFile(a, io, try std.fs.path.join(a, &.{ base, leaf }), &tried)) |hit| return hit;
        }
    }

    // The ORIGINAL specifier is reported: that is what the user wrote. The
    // attempted paths below already show what the alias expanded it to.
    diag.* = .{ .specifier = specifier, .tried = tried.items };
    return error.NotFound;
}

/// Records the candidate in `tried` and returns the resolution if it exists.
fn tryFile(a: Allocator, io: Io, cand: []const u8, tried: *std.ArrayList([]const u8)) Error!?Resolution {
    try tried.append(a, cand);
    const real = canonical(a, io, cand) catch return null;
    return .{ .kind = .file, .path = real };
}

fn hasKnownExtension(path: []const u8, extensions: []const []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (extensions) |known| {
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
    const short = struct {
        fn f(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
            return codeframe.ellipsize(alloc, text, codeframe.VALUE_LIMIT);
        }
    }.f;

    var out: std.ArrayList(u8) = .empty;
    // Every value is bounded: the specifier appears once and each attempted path
    // repeats it, so an over-long one would be printed a dozen times over.
    try out.appendSlice(a, try std.fmt.allocPrint(a, "cannot resolve '{s}'", .{try short(a, diag.specifier)}));
    if (importer.len > 0) try out.appendSlice(a, try std.fmt.allocPrint(a, " from {s}", .{try short(a, importer)}));
    if (diag.tried.len > 0) {
        try out.appendSlice(a, "\n  tried:");
        for (diag.tried) |t| try out.appendSlice(a, try std.fmt.allocPrint(a, "\n    {s}", .{try short(a, t)}));
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
        return self.relCfg(specifier, .{});
    }
    /// Same, with an explicit resolution config (aliases, custom table).
    fn relCfg(self: *Sandbox, specifier: []const u8, cfg: Config) ![]const u8 {
        return self.relFrom(self.root, specifier, cfg);
    }
    /// Same, resolving from an arbitrary directory (scoped aliases need this).
    fn relFrom(self: *Sandbox, from_dir: []const u8, specifier: []const u8, cfg: Config) ![]const u8 {
        var diag: Diagnostic = .{};
        const r = try resolve(self.a(), io, from_dir, specifier, cfg, &diag);
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
        const r = try resolve(s.a(), Sandbox.io, s.root, spec, .{}, &diag);
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
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./missing", .{}, &diag));
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
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./dir", .{}, &diag));
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

// ---- aliases and a custom extension table (the build layer's two knobs) ----

/// An absolute alias target, built inside the sandbox.
fn aliasTo(s: *Sandbox, sub: []const u8) ![]const u8 {
    return std.fs.path.join(s.a(), &.{ s.root, sub });
}

test "alias: the prefix is substituted" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("src/utils.ts", "");
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = try aliasTo(&s, "src") }} };
    try std.testing.expectEqualStrings("src/utils.ts", try s.relCfg("@/utils", cfg));
}

test "alias: a non-matching specifier is untouched (stays external)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = try aliasTo(&s, "src") }} };
    // `react` does not start with `@`: the alias never fires, the bare rule does.
    try std.testing.expectEqualStrings("react", try s.relCfg("react", cfg));
}

test "alias: it runs BEFORE the external test" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("src/x.ts", "");
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = try aliasTo(&s, "src") }} };
    // `@/x` IS bare-looking. Without alias-first it would leave as an external
    // and never touch the disk — this is the ordering guarantee, pinned.
    const got = try s.relCfg("@/x", cfg);
    try std.testing.expectEqualStrings("src/x.ts", got);
    // …and the same specifier WITHOUT the alias config is indeed external.
    try std.testing.expectEqualStrings("@/x", try s.rel("@/x"));
}

test "alias: an aliased specifier that is missing is an ERROR, never an external" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = try aliasTo(&s, "src") }} };
    var diag: Diagnostic = .{};
    try std.testing.expectError(
        error.NotFound,
        resolve(s.a(), Sandbox.io, s.root, "@/nope", cfg, &diag),
    );
    // The message quotes what the USER wrote, not the expansion.
    try std.testing.expectEqualStrings("@/nope", diag.specifier);
    try std.testing.expect(diag.tried.len > 0);
}

test "alias: the longest prefix wins, whatever the declaration order" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("short/a.ts", "");
    try s.write("long/a.ts", "");
    const short: Alias = .{ .from = "@", .to = try aliasTo(&s, "short") };
    const long: Alias = .{ .from = "@lib", .to = try aliasTo(&s, "long") };
    // Both orders must give the same answer: a config's meaning does not depend
    // on key order.
    try std.testing.expectEqualStrings("long/a.ts", try s.relCfg("@lib/a", .{ .alias = &.{ short, long } }));
    try std.testing.expectEqualStrings("long/a.ts", try s.relCfg("@lib/a", .{ .alias = &.{ long, short } }));
}

test "custom extension table: order and membership both obey it" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.ts", "");
    try s.write("x.js", "");
    // Reversed table: `.js` must now win over `.ts`.
    const cfg: Config = .{ .extensions = &.{ ".js", ".ts" } };
    try std.testing.expectEqualStrings("x.js", try s.relCfg("./x", cfg));
}

test "custom extension table: an extension outside the table is not 'known'" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.mts", "");
    // `.mts` is absent from the default table, so `./x.mts` is treated as a
    // path WITHOUT a known extension -> `./x.mts.ts`, `.tsx`… all miss.
    var diag: Diagnostic = .{};
    try std.testing.expectError(
        error.NotFound,
        resolve(s.a(), Sandbox.io, s.root, "./x.mts", .{}, &diag),
    );
    // Add it to the table and the very same specifier resolves.
    try std.testing.expectEqualStrings("x.mts", try s.relCfg("./x.mts", .{ .extensions = &.{".mts"} }));
}

test "custom extension table: index resolution follows it too" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/index.mjs", "");
    try std.testing.expectEqualStrings("dir/index.mjs", try s.relCfg("./dir", .{ .extensions = &.{".mjs"} }));
}

// ---- scoped aliases: one tsconfig per package, each governing its own files ----

test "alias scope: only files UNDER the scope see the alias" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("pkg/src/x.ts", "");
    const pkg = try std.fs.path.join(s.a(), &.{ s.root, "pkg" });
    const target = try std.fs.path.join(s.a(), &.{ s.root, "pkg/src" });
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = target, .scope = pkg }} };

    // A file inside pkg/ resolves through it…
    try std.testing.expectEqualStrings("pkg/src/x.ts", try s.relFrom(pkg, "@/x.ts", cfg));
    // …a file OUTSIDE does not: the alias is not its business, so `@/x.ts` is
    // just a bare specifier again.
    try std.testing.expectEqualStrings("@/x.ts", try s.relFrom(s.root, "@/x.ts", cfg));
}

test "alias scope: the NEAREST tsconfig wins over an outer one" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("outer/x.ts", "");
    try s.write("pkg/inner/x.ts", "");
    const root = s.root;
    const pkg = try std.fs.path.join(s.a(), &.{ s.root, "pkg" });
    const outer = try std.fs.path.join(s.a(), &.{ s.root, "outer" });
    const inner = try std.fs.path.join(s.a(), &.{ s.root, "pkg/inner" });
    // Same key `@/`, two scopes: the root one and the package one.
    const cfg: Config = .{ .alias = &.{
        .{ .from = "@", .to = outer, .scope = root },
        .{ .from = "@", .to = inner, .scope = pkg },
    } };
    // From inside the package, ITS mapping applies…
    try std.testing.expectEqualStrings("pkg/inner/x.ts", try s.relFrom(pkg, "@/x.ts", cfg));
    // …and elsewhere the outer one still does.
    try std.testing.expectEqualStrings("outer/x.ts", try s.relFrom(root, "@/x.ts", cfg));
}

test "alias scope: a prefix is not a parent (/p/a must not capture /p/ab)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a/t.ts", "");
    try s.write("ab/other.ts", "");
    const a_dir = try std.fs.path.join(s.a(), &.{ s.root, "a" });
    const ab_dir = try std.fs.path.join(s.a(), &.{ s.root, "ab" });
    const cfg: Config = .{ .alias = &.{.{ .from = "#", .to = a_dir, .scope = a_dir }} };
    // `ab` starts with `a` as a STRING but is not inside it: the scope must be
    // compared at a separator boundary.
    try std.testing.expectEqualStrings("#/t.ts", try s.relFrom(ab_dir, "#/t.ts", cfg));
    try std.testing.expectEqualStrings("a/t.ts", try s.relFrom(a_dir, "#/t.ts", cfg));
}

test "alias scope: an unscoped alias still applies everywhere" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("deep/nested/x.ts", "");
    const target = try std.fs.path.join(s.a(), &.{ s.root, "deep/nested" });
    const from = try std.fs.path.join(s.a(), &.{ s.root, "deep" });
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = target }} };
    try std.testing.expectEqualStrings("deep/nested/x.ts", try s.relFrom(from, "@/x.ts", cfg));
}

test "alias scope: isExternal agrees with resolve, per directory" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    const pkg = try std.fs.path.join(s.a(), &.{ s.root, "pkg" });
    const cfg: Config = .{ .alias = &.{.{ .from = "@", .to = pkg, .scope = pkg }} };
    // The graph asks isExternal BEFORE touching the disk: it must give the same
    // answer resolve would, scope included.
    try std.testing.expect(!isExternal(cfg, pkg, "@/x.ts"));
    try std.testing.expect(isExternal(cfg, s.root, "@/x.ts"));
    try std.testing.expect(isExternal(cfg, pkg, "react"));
}

test "alias exact: a whole-specifier mapping does not swallow its neighbours" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("vendor/jq.js", "");
    const target = try std.fs.path.join(s.a(), &.{ s.root, "vendor/jq.js" });
    const cfg: Config = .{ .alias = &.{.{ .from = "jquery", .to = target, .exact = true }} };
    try std.testing.expectEqualStrings("vendor/jq.js", try s.relCfg("jquery", cfg));
    // `jquery-ui` is a DIFFERENT package: an exact mapping must leave it alone.
    try std.testing.expectEqualStrings("jquery-ui", try s.relCfg("jquery-ui", cfg));
    try std.testing.expect(isExternal(cfg, s.root, "jquery-ui"));
    try std.testing.expect(!isExternal(cfg, s.root, "jquery"));
}
