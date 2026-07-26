//! Le GRAPHE de modules : depuis une entry, suivre les dépendances jusqu'au
//! point fixe et rendre la structure — modules, arêtes, externals, cycles.
//!
//! v0.1 s'arrête LÀ. Aucune émission de bundle : on VOIT le graphe, comme le
//! premier tokenizer de zcompiler imprimait ses tokens. Ce qu'on voit
//! maintenant est ce sur quoi tout le reste (ordre d'exécution, tree-shaking,
//! code-splitting, chunks) se construira.
//!
//! **La règle d'or** : zbundle ne réimplémente RIEN de ce que zcompiler sait
//! faire. Lire les dépendances d'un fichier, c'est du travail de compilateur —
//! donc `zcompiler.parseWith` + `zcompiler.moduleRecords` (une capacité AJOUTÉE
//! à zcompiler pour l'occasion). Ici il ne reste que ce qui est vraiment du
//! bundler : la traversée, la déduplication, les cycles.

const std = @import("std");
const zc = @import("zcompiler");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Un fichier source raisonnable. Au-delà, ce n'est pas du code : on refuse
/// plutôt que d'avaler 2 Go dans l'arène.
const MAX_FILE_BYTES = 32 * 1024 * 1024;

pub const ModuleId = u32;

/// Un module = un FICHIER, identifié par son chemin absolu canonique. Visité
/// une seule fois, quel que soit le nombre d'importeurs (c'est le test du
/// diamant).
pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    /// Déduit de l'extension (cf. `resolver.Format`) : pilote le mode de parse.
    format: resolver.Format,
    /// Nombre de diagnostics de parse. Non bloquant : zcompiler récupère des
    /// erreurs et rend toujours un AST, donc un fichier cassé apporte quand
    /// même les imports qu'on a pu lire (même philosophie que l'error recovery).
    parse_errors: u32,
};

/// Le type de dépendance, miroir exact de `zcompiler.ModuleRecordKind` : la
/// frontière ne renomme rien.
pub const EdgeKind = enum { import, re_export, export_all, export_all_as, dynamic_import };

/// Une entrée de `with { type: 'json' }`, telle que zcompiler la décode.
/// Inutilisée par la v0.1 (le resolver ne connaît que les extensions JS/TS) —
/// c'est sur elle que la v0.5 routera les assets vers leur loader.
pub const Attribute = struct { key: []const u8, value: []const u8 };

/// Une arête = une dépendance déclarée par `from`.
///
/// `to` est null quand la cible est EXTERNAL (specifier nu) ; `external` donne
/// alors l'index dans `externals`. `is_dynamic` est dérivé de `kind` : redondant
/// mais explicite, c'est l'info que lira le futur code-splitting.
/// `name` : le nom d'export d'un `export * as ns from` (null partout ailleurs).
/// `attributes` : la clause `with { … }`, vide si absente.
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

/// Un specifier nu, dédupliqué, avec le nombre de fois où il est importé.
pub const External = struct { specifier: []const u8, count: u32 };

pub const Stats = struct {
    modules: u32,
    edges: u32,
    externals: u32,
    cycles: u32,
    parse_errors: u32,
    /// Temps de construction du graphe (lecture disque + parse + traversée).
    build_ms: f64,
};

/// Le module PARSÉ, gardé de côté pour l'étape d'après (le linker). Indexé par
/// `ModuleId`, parallèle à `Graph.modules`.
///
/// Séparé de `Module` pour une raison bête et bonne : `Module` traverse la
/// frontière N-API (zignapi le sérialise en objet JS), et un `*Node` n'a aucune
/// représentation JS. Les pointeurs restent donc du côté Zig.
///
/// **L'AST est déjà normalisé en JS pur** : les types TS effacés, le JSX abaissé
/// en `jsx()/jsxs()`. Tout ce qui vient après (records, linking, émission) ne
/// voit plus qu'un seul langage.
pub const Parsed = struct {
    source: []const u8,
    program: *zc.Node,
};

/// Le résultat complet. Tout est alloué dans l'arène passée à `build`.
pub const Graph = struct {
    entry: ModuleId,
    modules: []const Module,
    edges: []const Edge,
    externals: []const External,
    /// Chaque cycle = la liste (triée) des modules qui s'atteignent
    /// mutuellement. Cf. `findCycles` pour la définition exacte.
    cycles: []const []const ModuleId,
    stats: Stats,
};

/// L'erreur d'un `build` : le message est déjà formaté pour l'utilisateur
/// (specifier + demandeur + chemins essayés).
pub const BuildError = struct { message: []const u8 = "" };

pub const Error = error{ BuildFailed, OutOfMemory };

/// Ce que rend `build` : le graphe (sérialisable) + les ASTs (côté Zig).
pub const Built = struct { graph: Graph, parsed: []const Parsed };

/// Construit le graphe depuis `entry` (un chemin, relatif au cwd ou absolu).
///
/// Traversée en **largeur** (file FIFO) : chaque module découvert reçoit un id
/// dans l'ordre de découverte, est lu+parsé UNE fois, et ses records deviennent
/// des arêtes. Les ids étant attribués à la découverte et la file étant FIFO,
/// les arêtes sortent groupées par `from` croissant — sortie déterministe.
///
/// Un specifier relatif qui ne résout pas fait ÉCHOUER le build (`err.message`
/// contient les chemins essayés). Un specifier nu ne fait jamais échouer :
/// il devient un external.
pub fn build(a: Allocator, io: Io, entry: []const u8, err: *BuildError) Error!Built {
    const t0 = Io.Clock.awake.now(io).nanoseconds;

    var b = Builder{ .a = a, .io = io, .err = err };
    // L'entry est rendue ABSOLUE avant tout : `std.fs.path.resolve` est purement
    // lexical en Zig 0.16 (il ne connaît pas le cwd), donc sans ça une entry
    // relative resterait relative dans les messages d'erreur.
    const abs_entry = try absolute(a, io, entry);
    const entry_dir = std.fs.path.dirname(abs_entry) orelse ".";
    const entry_name = try std.mem.concat(a, u8, &.{ "./", std.fs.path.basename(abs_entry) });
    const entry_id = try b.resolveAndIntern(entry_dir, entry_name, "");

    // File FIFO : `cursor` avance, `modules` s'allonge derrière lui.
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

/// `path` tel quel s'il est absolu, sinon préfixé du cwd du process. Ne touche
/// pas au disque pour le fichier lui-même (le resolver s'en charge juste après).
fn absolute(a: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = std.process.currentPathAlloc(io, a) catch return path;
    return std.fs.path.resolve(a, &.{ cwd, path });
}

const Builder = struct {
    a: Allocator,
    io: Io,
    err: *BuildError,
    modules: std.ArrayList(Module) = .empty,
    /// Parallèle à `modules` : l'AST normalisé de chacun, gardé pour le linker.
    parsed: std.ArrayList(Parsed) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    externals: std.ArrayList(External) = .empty,
    /// chemin canonique -> id. LA table qui garantit « un fichier = un module ».
    by_path: std.StringHashMapUnmanaged(ModuleId) = .empty,
    /// specifier nu -> index dans `externals`.
    by_specifier: std.StringHashMapUnmanaged(u32) = .empty,
    parse_errors: u32 = 0,

    /// Résout `specifier` depuis `from_dir` et renvoie l'id du module (créé s'il
    /// est nouveau). `error.BuildFailed` si un relatif ne résout pas.
    fn resolveAndIntern(self: *Builder, from_dir: []const u8, specifier: []const u8, importer: []const u8) Error!ModuleId {
        var diag: resolver.Diagnostic = .{};
        const r = resolver.resolve(self.a, self.io, from_dir, specifier, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound => {
                self.err.message = try resolver.formatError(self.a, diag, importer);
                return error.BuildFailed;
            },
        };
        std.debug.assert(r.kind == .file); // l'appelant a filtré les externals
        return self.intern(r.path);
    }

    /// L'id de `path` (canonique), en le créant au besoin. C'est ici, et nulle
    /// part ailleurs, que la déduplication se joue.
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
        try self.parsed.append(self.a, .{ .source = "", .program = undefined }); // rempli par `scan`
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

    /// Lit + parse le module `id`, le **normalise en JS pur**, et transforme ses
    /// module records en arêtes.
    /// **Toute la compréhension du JS est chez zcompiler** : ici on ne fait que
    /// router des chemins.
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

        // NORMALISATION EN JS PUR, tout de suite — avant les records, avant tout.
        // Les types TS s'effacent, le JSX s'abaisse en `jsx()/jsxs()`. Deux raisons :
        //   1. le linker et l'émetteur ne voient qu'UN seul langage ;
        //   2. surtout, `jsxTransform` **AJOUTE un import** (`react/jsx-runtime`).
        //      Le faire APRÈS l'extraction des records rendrait cette dépendance
        //      invisible au graphe — le bundle référencerait `jsx` sans l'importer.
        // L'ordre (strip PUIS jsx) est celui du harnais de zcompiler.
        if (f.ts) zc.transformer.stripTypes(parsed.program, src, self.a);
        if (f.jsx) _ = zc.jsx_transform.transform(parsed.program, src, self.a, .{});
        self.parsed.items[id] = .{ .source = src, .program = parsed.program };

        const dir = std.fs.path.dirname(mod.path) orelse ".";
        for (zc.moduleRecords(self.a, parsed.program, src)) |rec| {
            // `import type { T } from './t'` est effacé à l'émission : ce n'est
            // pas une dépendance runtime, donc pas une arête. (Après `stripTypes`
            // il n'en reste normalement plus ; la garde coûte zéro.)
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
        if (resolver.isBare(rec.specifier)) {
            edge.external = try self.internExternal(rec.specifier);
        } else {
            edge.to = try self.resolveAndIntern(dir, rec.specifier, importer);
        }
        try self.edges.append(self.a, edge);
    }
};

/// La frontière zcompiler → zbundle : un `switch` exhaustif, pour qu'un jour où
/// zcompiler ajoutera un `kind` (les import attributes, `require`…), le
/// compilateur nous force à décider ici.
fn kindOf(k: zc.ModuleRecordKind) EdgeKind {
    return switch (k) {
        .import => .import,
        .re_export => .re_export,
        .export_all => .export_all,
        // Ajouté par zcompiler 0.2.0. Le `switch` exhaustif a REFUSÉ de compiler
        // tant que ce cas n'était pas traité — c'est exactement le rôle qu'on lui
        // avait donné : rendre impossible d'ignorer en silence une capacité neuve
        // du compilateur. Une arête à part entière (le module cible est bien une
        // dépendance) ; ce qui change, c'est ce que le futur émetteur en fera.
        .export_all_as => .export_all_as,
        .dynamic_import => .dynamic_import,
    };
}

// ---- cycles ----

/// Les cycles du graphe, via **Tarjan** (composantes fortement connexes),
/// itératif — un vrai projet a des chaînes de plusieurs centaines de modules,
/// une DFS récursive finirait par déborder la pile.
///
/// Définition retenue : un cycle = une SCC de taille > 1 (ses modules
/// s'atteignent tous mutuellement), ou un module qui s'importe lui-même. Toute
/// boucle du graphe est contenue dans exactement une SCC — donc la liste est
/// complète, sans doublon ni explosion combinatoire (énumérer tous les chemins
/// cycliques serait exponentiel).
///
/// **Un cycle n'est PAS une erreur** : les cycles ESM sont légaux et le vrai
/// code en a. Le bundler devra les gérer (ordre d'exécution, bindings vivants) ;
/// le graphe doit déjà les voir.
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

    // Pile de DFS explicite : (module, position dans sa liste d'adjacence).
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
            // v est fini : remonte son lowlink au parent, et ferme la SCC si
            // v en est la racine.
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

    // Ordre stable pour les tests et les diffs : par plus petit membre.
    std.mem.sort([]const ModuleId, out.items, {}, cycleLess);
    return out.items;
}

fn cycleLess(_: void, x: []const ModuleId, y: []const ModuleId) bool {
    return x[0] < y[0];
}

fn hasSelfLoop(neighbors: []const ModuleId, v: ModuleId) bool {
    return std.mem.indexOfScalar(ModuleId, neighbors, v) != null;
}

/// Listes d'adjacence (les arêtes externals sont ignorées : un external est une
/// feuille, il ne peut pas fermer un cycle).
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

/// L'arbre indenté, lisible : l'entry en racine, un niveau par profondeur, les
/// externals marqués, les cycles signalés. Le pendant du `printTree` de
/// zcompiler — un graphe qu'on ne peut pas LIRE ne se débogue pas.
///
/// Les chemins sont affichés relativement au dossier de l'entry. Un module déjà
/// visité n'est pas redéveloppé (sinon un diamant doublerait, un cycle
/// boucherait) : il est marqué, avec `(cycle)` si le module est un ancêtre dans
/// la branche courante.
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
                // Un `import()` est une FRONTIÈRE (le futur point de découpe en
                // chunks) : il se voit dans l'arbre, même si la v0.1 le suit
                // comme une arête normale.
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

/// Chemin relatif à `root_dir` quand c'est possible (lisible), absolu sinon.
fn display(a: Allocator, root_dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (path.len > root_dir.len + 1 and std.mem.startsWith(u8, path, root_dir) and
        path[root_dir.len] == std.fs.path.sep)
    {
        return try std.mem.concat(a, u8, &.{ "./", path[root_dir.len + 1 ..] });
    }
    return path;
}

/// Pour chaque module, les INDEX de ses arêtes sortantes (dans l'ordre source).
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
        // En DEUX temps : dans un `return .{ .arena = arena, .root = try
        // arena.allocator()… }`, l'arène est copiée dans le slot de retour AVANT
        // que `.root` n'alloue — l'allocation partirait dans la copie locale,
        // jamais libérée (fuite réelle, attrapée par le test runner).
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
        var err: BuildError = .{};
        const full = try std.fs.path.join(self.a(), &.{ self.root, entry });
        const built = build(self.a(), io, full, &err) catch |e| {
            std.debug.print("build failed: {s}\n", .{err.message});
            return e;
        };
        return built.graph;
    }
    /// Le module dont le chemin se termine par `suffix` (assertions lisibles).
    fn find(self: *Sandbox, g: Graph, suffix: []const u8) !ModuleId {
        _ = self;
        for (g.modules) |m| {
            if (std.mem.endsWith(u8, m.path, suffix)) return m.id;
        }
        return error.ModuleNotInGraph;
    }
};

test "chaine simple a -> b -> c" {
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

test "diamant : le module partage est visite UNE fois (4 modules, pas 5)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js'; import './c.js';");
    try s.write("b.js", "import './d.js';");
    try s.write("c.js", "import './d.js';");
    try s.write("d.js", "export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 4), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 4), g.stats.edges); // les 2 aretes vers d existent
    try std.testing.expectEqual(@as(u32, 0), g.stats.cycles);
    // Les deux aretes pointent vers le MEME id.
    const d = try s.find(g, "d.js");
    var to_d: u32 = 0;
    for (g.edges) |e| {
        if (e.to) |t| {
            if (t == d) to_d += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), to_d);
}

test "cycle a -> b -> a : detecte, liste, pas une erreur, pas de boucle infinie" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js';");
    try s.write("b.js", "import './a.js';");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 1), g.stats.cycles);
    try std.testing.expectEqual(@as(usize, 2), g.cycles[0].len);
}

test "auto-import (a -> a) : un cycle d'un seul module" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './a.js'; export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 1), g.stats.modules);
    try std.testing.expectEqual(@as(u32, 1), g.stats.cycles);
    try std.testing.expectEqual(@as(usize, 1), g.cycles[0].len);
}

test "un re-export EST une dependance" {
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

test "specifier nu -> external, et le graphe continue" {
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

test "import() dynamique : arete marquee is_dynamic" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "const f = () => import('./b.js');");
    try s.write("b.js", "export const x = 1;");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules);
    try std.testing.expect(g.edges[0].is_dynamic);
    try std.testing.expectEqual(EdgeKind.dynamic_import, g.edges[0].kind);
}

test "mixte .ts / .js / .jsx / .tsx : chaque fichier parse dans son mode" {
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

test "import type : efface a l'emission, donc PAS une arete" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.ts", "import type { T } from './types'; import { v } from './v';");
    try s.write("types.ts", "export type T = string;");
    try s.write("v.ts", "export const v = 1;");
    const g = try s.graph("a.ts");
    try std.testing.expectEqual(@as(u32, 2), g.stats.modules); // types.ts absent
    try std.testing.expectEqual(@as(u32, 1), g.stats.edges);
}

test "relatif introuvable : erreur avec les chemins essayes" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './missing';");
    var err: BuildError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "a.js" });
    try std.testing.expectError(error.BuildFailed, build(s.a(), Sandbox.io, full, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.message, "cannot resolve './missing'") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "a.js") != null); // le demandeur
    try std.testing.expect(std.mem.indexOf(u8, err.message, "missing.ts") != null); // les essais
}

test "code casse : le graphe se construit quand meme (error recovery)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import './b.js'; let x = ; import './c.js';");
    try s.write("b.js", "");
    try s.write("c.js", "");
    const g = try s.graph("a.js");
    try std.testing.expectEqual(@as(u32, 3), g.stats.modules);
    try std.testing.expect(g.stats.parse_errors > 0);
}

test "printTree : arbre lisible, externals et cycles marques" {
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
