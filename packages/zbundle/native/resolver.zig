//! Le RESOLVER : `(fromDir, specifier)` → un chemin absolu canonique, ou
//! « external », ou une erreur qui dit exactement ce qui a été essayé.
//!
//! Périmètre v0.1 — **les specifiers RELATIFS seulement** (`./x`, `../y/z`) et
//! les chemins absolus. Un specifier NU (`react`, `lodash/merge`, `node:fs`)
//! n'est PAS une erreur : il est marqué **external** et le graphe continue.
//! C'est le comportement `--external` d'esbuild, et c'est honnête : la
//! résolution `node_modules` (le champ `exports`, les conditions, `main`/
//! `module`, les self-references, le hoisting…) est un chantier à elle seule
//! — c'est la v0.5.
//!
//! Ne dépend de RIEN d'autre que la stdlib : pas de zcompiler ici (résoudre un
//! chemin n'est pas compiler), pas de zignapi (aucune notion de JS).
//!
//! **L'accès disque passe par `io: std.Io`** (l'interface d'I/O de Zig 0.16),
//! jamais par un appel système en dur. Conséquence directe : porter zbundle sur
//! un FS virtuel (le backend wasm, un cache mémoire, un watcher) = fournir un
//! autre `Io`, sans toucher une ligne du resolver.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;

/// La table d'extensions, dans l'ORDRE D'ESSAI. L'ordre est un **contrat**
/// (testé cas par cas) : `./x` doit trouver `x.ts` AVANT `x.js` — un projet TS
/// qui a compilé un `x.js` à côté de son `x.ts` doit voir la source, pas la
/// sortie. Même ordre que le `resolveExtensions` d'esbuild, sans `.css`/`.json`
/// (pas de loaders d'assets en v0.1).
pub const EXTENSIONS = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs" };

/// Le format d'un module, déduit de son EXTENSION (comme esbuild/oxc — c'est
/// aussi ce que fait le harnais de zcompiler). Pilote le mode de parse.
pub const Format = enum {
    js,
    jsx,
    ts,
    tsx,

    /// Les deux flags que `zcompiler.parseWith(arena, src, jsx, ts)` attend.
    pub fn flags(self: Format) struct { jsx: bool, ts: bool } {
        return switch (self) {
            .js => .{ .jsx = false, .ts = false },
            .jsx => .{ .jsx = true, .ts = false },
            .ts => .{ .jsx = false, .ts = true },
            .tsx => .{ .jsx = true, .ts = true },
        };
    }
};

/// `.ts` → ts, `.tsx` → ts+jsx, `.jsx` → jsx, `.js`/`.mjs` (et le reste) → js.
pub fn formatOf(path: []const u8) Format {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".ts")) return .ts;
    if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
    if (std.mem.eql(u8, ext, ".jsx")) return .jsx;
    return .js;
}

pub const Kind = enum {
    /// Un fichier trouvé sur le disque. `path` = son chemin ABSOLU CANONIQUE.
    file,
    /// Un specifier nu, laissé au runtime. `path` = le specifier tel quel.
    external,
};

pub const Resolution = struct { kind: Kind, path: []const u8 };

pub const Error = error{ NotFound, OutOfMemory };

/// Ce qu'on a essayé quand ça a échoué. Rempli par `resolve` sur `error.NotFound`
/// (et laissé vide sinon). `tried` est dans l'ordre exact des tentatives : c'est
/// LE message qui fait gagner du temps à l'utilisateur.
pub const Diagnostic = struct {
    specifier: []const u8 = "",
    tried: []const []const u8 = &.{},
};

/// Un specifier NU = tout ce qui n'est ni relatif (`./`, `../`) ni absolu.
/// Couvre `react`, `@scope/pkg`, `lodash/merge`, `node:fs`, `#alias` (imports
/// map) — tous externals en v0.1.
pub fn isBare(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (std.mem.startsWith(u8, specifier, "./")) return false;
    if (std.mem.startsWith(u8, specifier, "../")) return false;
    if (std.mem.eql(u8, specifier, ".") or std.mem.eql(u8, specifier, "..")) return false;
    return !std.fs.path.isAbsolute(specifier);
}

/// Résout `specifier` depuis `from_dir`.
///
/// L'ordre d'essai (le contrat de la v0.1, cf. la table du CLAUDE.md) :
///   1. specifier NU → `.external`, on s'arrête là (jamais d'erreur) ;
///   2. le chemin TEL QUEL s'il porte une extension connue ;
///   3. sinon `<chemin>.ts`, `.tsx`, `.js`, `.jsx`, `.mjs` (dans cet ordre) ;
///   4. puis `<chemin>/index.<ext>` dans le MÊME ordre (résolution de dossier).
///
/// Le chemin rendu est **canonique** (`realPath` : liens symboliques suivis,
/// casse corrigée sur un FS insensible comme macOS). C'est ce qui garantit
/// qu'un même fichier atteint par deux chemins différents soit UN seul module
/// dans le graphe.
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

/// Note le candidat dans `tried` et renvoie la résolution s'il existe.
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

/// Le chemin canonique de `path` s'il désigne un FICHIER existant. Un dossier
/// est un échec (`./dir` doit tomber dans la branche `index.<ext>`, pas
/// « résoudre » vers le dossier lui-même).
fn canonical(a: Allocator, io: Io, path: []const u8) ![]const u8 {
    const st = try Dir.cwd().statFile(io, path, .{});
    if (st.kind != .file) return error.IsDir;
    return Dir.cwd().realPathFileAlloc(io, path, a);
}

/// Lit un fichier source. Vit ici (et pas dans graph.zig) parce que c'est l'autre
/// moitié du même contrat : le resolver est le SEUL point de contact avec le
/// disque. `max_bytes` borne la lecture (un fichier source n'est pas un blob).
pub fn readFile(a: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, a, .limited(max_bytes));
}

/// Le message d'erreur complet : le specifier, le demandeur, et TOUS les chemins
/// essayés dans l'ordre. `importer` peut être vide (résolution isolée).
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

/// Un dossier temporaire réel : le resolver touche le disque, donc les tests
/// aussi (un faux FS mentirait sur la casse et les liens symboliques).
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
    /// Résout depuis la racine du sandbox et renvoie le chemin RELATIF trouvé
    /// (comparaisons lisibles, indépendantes du chemin du tmpdir). Le résultat
    /// étant canonique, il commence forcément par `root` + un séparateur.
    fn rel(self: *Sandbox, specifier: []const u8) ![]const u8 {
        var diag: Diagnostic = .{};
        const r = try resolve(self.a(), io, self.root, specifier, &diag);
        if (r.kind == .external) return r.path;
        try std.testing.expect(std.mem.startsWith(u8, r.path, self.root));
        return r.path[self.root.len + 1 ..];
    }
};

test "l'ordre de la table : .ts gagne sur .js" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.js", "");
    try s.write("x.ts", "");
    try std.testing.expectEqualStrings("x.ts", try s.rel("./x"));
}

test "l'ordre de la table, cas par cas (.ts > .tsx > .js > .jsx > .mjs)" {
    // Chaque paire : le gagnant attendu, puis un fichier de rang inférieur.
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

test "extension omise : le seul candidat présent gagne" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("only.mjs", "");
    try std.testing.expectEqualStrings("only.mjs", try s.rel("./only"));
}

test "extension explicite : le chemin tel quel" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("x.ts", "");
    try s.write("x.js", "");
    try std.testing.expectEqualStrings("x.js", try s.rel("./x.js"));
}

test "résolution de dossier : ./dir -> dir/index.ts" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/index.js", "");
    try s.write("dir/index.ts", "");
    const want = try std.fs.path.join(s.a(), &.{ "dir", "index.ts" });
    try std.testing.expectEqualStrings(want, try s.rel("./dir"));
}

test "un fichier voisin gagne sur le dossier du même nom" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/index.ts", "");
    try s.write("dir.ts", "");
    try std.testing.expectEqualStrings("dir.ts", try s.rel("./dir"));
}

test "`..` et `.` sont normalisés (un seul chemin canonique)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("sub/deep/mod.ts", "");
    const a = try s.rel("./sub/deep/mod.ts");
    const b = try s.rel("./sub/./deep/../deep/mod.ts");
    try std.testing.expectEqualStrings(a, b);
}

test "specifier nu -> external (jamais une erreur)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    for ([_][]const u8{ "react", "@scope/pkg", "lodash/merge", "node:fs" }) |spec| {
        var diag: Diagnostic = .{};
        const r = try resolve(s.a(), Sandbox.io, s.root, spec, &diag);
        try std.testing.expectEqual(Kind.external, r.kind);
        try std.testing.expectEqualStrings(spec, r.path);
    }
}

test "isBare : la frontière relatif / nu" {
    try std.testing.expect(isBare("react"));
    try std.testing.expect(isBare("@a/b"));
    try std.testing.expect(!isBare("./a"));
    try std.testing.expect(!isBare("../a"));
    try std.testing.expect(!isBare("/abs/a"));
    try std.testing.expect(!isBare("."));
}

test "introuvable : l'erreur liste TOUS les chemins essayés, dans l'ordre" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./missing", &diag));
    // 5 extensions + 5 index.<ext> = 10 candidats, dans l'ordre de la table.
    try std.testing.expectEqual(@as(usize, 10), diag.tried.len);
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[0], "missing.ts"));
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[4], "missing.mjs"));
    const idx_ts = try std.fs.path.join(s.a(), &.{ "missing", "index.ts" });
    try std.testing.expect(std.mem.endsWith(u8, diag.tried[5], idx_ts));
    const msg = try formatError(s.a(), diag, "/app/entry.ts");
    try std.testing.expect(std.mem.startsWith(u8, msg, "cannot resolve './missing' from /app/entry.ts"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "tried:") != null);
}

test "un dossier ne résout pas vers lui-même (sans index)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dir/other.ts", "");
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.NotFound, resolve(s.a(), Sandbox.io, s.root, "./dir", &diag));
}

test "formatOf : l'extension décide du mode de parse" {
    try std.testing.expectEqual(Format.ts, formatOf("/a/b.ts"));
    try std.testing.expectEqual(Format.tsx, formatOf("/a/b.tsx"));
    try std.testing.expectEqual(Format.jsx, formatOf("/a/b.jsx"));
    try std.testing.expectEqual(Format.js, formatOf("/a/b.js"));
    try std.testing.expectEqual(Format.js, formatOf("/a/b.mjs"));
    try std.testing.expect(Format.tsx.flags().jsx and Format.tsx.flags().ts);
    try std.testing.expect(!Format.js.flags().jsx and !Format.js.flags().ts);
}
