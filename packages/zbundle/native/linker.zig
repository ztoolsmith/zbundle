//! Le LINKER : N modules → UN fichier de JS exécutable.
//!
//! v0.2. Le graphe (v0.1) disait QUI dépend de QUI ; ici on fusionne. La
//! stratégie est celle de rollup/rolldown — le **scope hoisting** :
//!
//!   > tous les modules sont concaténés dans UN SEUL scope, et les collisions de
//!   > noms sont résolues par RENOMMAGE.
//!
//! Pas de wrappers de fonctions (`__webpack_require__(id)`), pas de registre de
//! modules à l'exécution : la sortie est du JS plat, lisible, que le moteur
//! optimise comme du code écrit à la main. C'est possible parce que zcompiler
//! sait déjà, pour chaque module, quels sont ses bindings top-level, où sont
//! toutes leurs références, et comment réécrire un nom (`synthetic_text`) — le
//! mangler faisait exactement ça, à l'échelle d'UN fichier. Le linker fait la
//! même chose à l'échelle du programme entier.
//!
//! ## La chaîne, de la référence au nom final
//!
//!     référence à `a` dans m.js
//!       → binding local `a` de m (kind = .import_)
//!         → ImportEntry { specifier: './x', imported: 'a' }
//!           → module x, ExportEntry { exported: 'a', … }
//!             → (.local)      le binding local de x → son NOM FINAL
//!             → (.re_export)  on recommence chez la source de x
//!             → (.star_as)    l'objet namespace matérialisé
//!
//! Le tour de force : on n'a **rien à réécrire dans le corps des modules**. Il
//! suffit de poser `new_name` sur le binding importé — puisque toutes ses
//! références passent par lui, `applyRenames` les met toutes à jour d'un coup.
//! Un `import` devient littéralement un **alias de nom**.
//!
//! ## Ce que la v0.2 REFUSE (plutôt que d'émettre un bundle faux)
//!
//! Chaque refus est vérifié et porte un message qui dit quoi faire. Cf. `check`.

const std = @import("std");
const zc = @import("zcompiler");
const graph = @import("graph.zig");
const resolver = @import("resolver.zig");
const shake = @import("shake.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ModuleId = graph.ModuleId;

pub const Error = error{ BundleFailed, OutOfMemory };
pub const BundleError = struct { message: []const u8 = "" };

/// Le format du fichier produit.
pub const Format = enum {
    /// Module ES : les externals restent des `import` en tête, les exports de
    /// l'entry sortent en `export { … }`. Le défaut, et le seul qui compose.
    esm,
    /// Une IIFE : tout est enfermé dans `(() => { … })()`, rien ne fuit dans le
    /// scope global. C'est le format d'un `<script>` ou d'un binaire autonome.
    /// **Exige zéro external** : un `import` est illégal dans une fonction.
    iife,
};

pub const Options = struct { format: Format = .esm };

pub const Stats = struct {
    /// Modules effectivement ÉMIS (après shaking).
    modules: u32,
    /// Nombre d'exports de l'entry (0 en `iife` : une IIFE n'exporte rien).
    entry_exports: u32,
    /// Modules du graphe dont plus rien n'a survécu.
    modules_dropped: u32,
    externals: u32,
    /// Bindings qui ont dû être renommés pour éviter une collision.
    renamed: u32,
    /// Statements top-level gardés / éliminés par le tree-shaking.
    statements_kept: u32,
    statements_dropped: u32,
    input_bytes: u32,
    output_bytes: u32,
    bundle_ms: f64,
};

pub const Bundle = struct {
    code: []const u8,
    stats: Stats,
};

/// Un statement éliminé par le tree-shaking, avec de quoi le retrouver.
/// Sert à `inspect.mjs --dead` : comprendre le shaking à l'œil, et déboguer le
/// jour où quelque chose disparaît à tort.
pub const Dead = struct {
    module: []const u8,
    /// Ligne dans le module d'origine (1-indexée).
    line: u32,
    /// Le code éliminé, tronqué et mis sur une ligne.
    snippet: []const u8,
    /// Pourquoi il est mort.
    reason: []const u8,
};

pub const Report = struct {
    code: []const u8,
    stats: Stats,
    dead: []const Dead,
};

/// Un module, avec tout ce que le linker a appris de lui.
const Mod = struct {
    id: ModuleId,
    path: []const u8,
    source: []const u8,
    program: *zc.Node,
    sem: *zc.semantic.Semantic,
    info: zc.semantic.ModuleInfo,
    /// Les statements top-level, découpés en unités de tree-shaking (v0.3).
    units: []shake.Unit = &.{},
    /// Le nom final du binding fabriqué pour `export default <expression>`.
    default_name: ?[]const u8 = null,
    /// Nom final de l'objet namespace de CE module, s'il en faut un.
    namespace_name: ?[]const u8 = null,
};

/// Un import d'external, après dédup. Deux modules qui importent `react` ne
/// produisent qu'UNE ligne d'import en tête du bundle.
const ExternalImport = struct {
    specifier: []const u8,
    /// nom importé chez l'external ("default" / "*" / un nom) → nom final local
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
};

const Linker = struct {
    a: Allocator,
    err: *BundleError,
    g: graph.Graph,
    mods: []Mod,
    /// Ordre d'ÉMISSION (post-ordre DFS depuis l'entry) : dépendances d'abord.
    order: std.ArrayList(ModuleId) = .empty,
    /// Tous les noms déjà pris dans le scope du bundle.
    used: std.StringHashMapUnmanaged(void) = .empty,
    externals: std.ArrayList(ExternalImport) = .empty,
    by_specifier: std.StringHashMapUnmanaged(u32) = .empty,
    renamed: u32 = 0,

    // --- état du marquage (v0.3) ---
    /// Les bindings atteignables depuis les racines.
    live: std.AutoHashMapUnmanaged(*zc.semantic.Binding, void) = .empty,
    /// File du point fixe.
    queue: std.ArrayList(BindingRef) = .empty,
    /// Par module : binding → index de l'unité qui le déclare.
    decl_unit: []std.AutoHashMapUnmanaged(*zc.semantic.Binding, u32) = &.{},
    /// Par module : binding d'import → son `ImportEntry` (pour suivre la chaîne).
    import_of: []std.AutoHashMapUnmanaged(*zc.semantic.Binding, zc.semantic.ImportEntry) = &.{},
    /// Statistiques de shaking.
    units_total: u32 = 0,
    units_alive: u32 = 0,
    opts: Options = .{},
    entry_exports: u32 = 0,

    fn fail(self: *Linker, comptime fmt: []const u8, args: anytype) Error {
        self.err.message = std.fmt.allocPrint(self.a, fmt, args) catch "bundle failed";
        return error.BundleFailed;
    }

    /// Le module cible d'un specifier depuis `from`, ou null s'il est external.
    fn targetOf(self: *Linker, from: ModuleId, specifier: []const u8) ?ModuleId {
        for (self.g.edges) |e| {
            if (e.from == from and std.mem.eql(u8, e.specifier, specifier)) return e.to;
        }
        return null;
    }

    fn isExternal(self: *Linker, from: ModuleId, specifier: []const u8) bool {
        for (self.g.edges) |e| {
            if (e.from == from and std.mem.eql(u8, e.specifier, specifier)) return e.to == null;
        }
        return false;
    }

    // ---- 1. l'ordre d'émission ----

    /// Post-ordre DFS depuis l'entry : un module est émis APRÈS toutes ses
    /// dépendances. Itératif (une vraie base de code a des chaînes de centaines
    /// de modules — cf. le Tarjan de graph.zig, même raison).
    ///
    /// **Les cycles** : une arête qui revient sur un module déjà en cours de
    /// visite est simplement ignorée, donc les membres d'un cycle sortent dans
    /// l'ordre de première visite. C'est l'approximation de rollup. Elle est
    /// FAUSSE pour les TDZ inter-cycle pathologiques (un module qui LIT au
    /// top-level une `const` d'un module du même cycle émis après lui) — assumé
    /// et documenté : le vrai code n'y vit pas, et rollup ne fait pas mieux.
    fn computeOrder(self: *Linker) Error!void {
        const n = self.mods.len;
        const State = enum { white, gray, black };
        const state = try self.a.alloc(State, n);
        @memset(state, .white);

        // Arêtes sortantes (index dans g.edges) par module, dans l'ordre source.
        const deps = try self.outgoing();

        const Frame = struct { m: ModuleId, i: usize };
        var stack: std.ArrayList(Frame) = .empty;
        try stack.append(self.a, .{ .m = self.g.entry, .i = 0 });
        state[self.g.entry] = .gray;

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.i < deps[top.m].len) {
                const to = deps[top.m][top.i];
                top.i += 1;
                if (state[to] == .white) {
                    state[to] = .gray;
                    try stack.append(self.a, .{ .m = to, .i = 0 });
                }
                continue; // .gray = arête de retour (cycle) ; .black = déjà émis
            }
            state[top.m] = .black;
            try self.order.append(self.a, top.m);
            _ = stack.pop();
        }

        // Un module inatteignable depuis l'entry ne devrait pas exister (le
        // graphe part de l'entry), mais on ne perd rien en silence.
        for (0..n) |i| if (state[i] != .black) {
            try self.order.append(self.a, @intCast(i));
        };
    }

    /// Pour chaque module, ses dépendances INTERNES, dans l'ordre source, sans
    /// doublon (le diamant ne visite `d` qu'une fois).
    fn outgoing(self: *Linker) Error![]const []const ModuleId {
        const out = try self.a.alloc([]ModuleId, self.mods.len);
        for (out, 0..) |*slot, m| {
            var list: std.ArrayList(ModuleId) = .empty;
            var seen: std.AutoHashMapUnmanaged(ModuleId, void) = .empty;
            for (self.g.edges) |e| {
                if (e.from != m) continue;
                const to = e.to orelse continue;
                if ((try seen.getOrPut(self.a, to)).found_existing) continue;
                try list.append(self.a, to);
            }
            slot.* = list.items;
        }
        return @ptrCast(out);
    }

    // ---- 2. les refus (avant tout travail : un message clair, pas un faux bundle) ----

    fn check(self: *Linker) Error!void {
        for (self.mods) |m| {
            const rel = self.display(m.path);
            if (m.info.has_top_level_await) {
                return self.fail(
                    "top-level await n'est pas supporte en v0.2 ({s})\n" ++
                        "  Le scope hoisting concatene les modules dans un seul scope : un `await`\n" ++
                        "  top-level rendrait le bundle entier asynchrone. Deplacez-le dans une\n" ++
                        "  fonction async, ou attendez la v0.3.",
                    .{rel},
                );
            }
            if (m.info.has_import_meta) {
                return self.fail(
                    "import.meta n'est pas supporte en v0.2 ({s})\n" ++
                        "  Sa valeur depend de l'URL du module, qui n'existe plus une fois les\n" ++
                        "  modules fusionnes en un seul fichier.",
                    .{rel},
                );
            }
        }
        // `import()` vers un module INTERNE : ce serait un chunk séparé.
        for (self.g.edges) |e| {
            if (!e.is_dynamic) continue;
            const to = e.to orelse continue; // dynamique vers un external : OK, réémis tel quel
            return self.fail(
                "import() dynamique vers un module interne non supporte en v0.2 : '{s}'\n" ++
                    "  ({s} -> {s})\n" ++
                    "  Un import dynamique interne demande un CHUNK separe : c'est le\n" ++
                    "  code-splitting, prevu en v0.5. Rendez l'import statique, ou marquez la\n" ++
                    "  cible comme externe.",
                .{ e.specifier, self.display(self.mods[e.from].path), self.display(self.mods[to].path) },
            );
        }
    }

    /// LE cas où le scope hoisting ne peut PAS reproduire la sémantique ESM.
    ///
    /// Un **live binding** (`export let n` réassigné) marche naturellement quand
    /// il est importé nommément : après fusion, l'importeur référence LA MÊME
    /// variable, donc il voit les mises à jour. Vérifié — c'est gratuit.
    ///
    /// Mais un **objet namespace** (`import * as ns`) est matérialisé une fois,
    /// à la construction : `{ n: n }` fige la VALEUR. En ESM natif, `ns.n` reste
    /// vivant. Là, et seulement là, le bundle mentirait — donc on refuse.
    ///
    /// (Se lance APRÈS `linkImports`, quand on sait quels namespaces existent.)
    fn checkNamespaceSnapshots(self: *Linker) Error!void {
        for (self.mods) |m| {
            if (m.namespace_name == null) continue;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            if (try self.findAssigned(m.id, &seen, 0)) |b| {
                return self.fail(
                    "live binding expose via un objet namespace : `{s}` dans {s}\n" ++
                        "  `{s}` est REASSIGNE apres son initialisation, et son module est importe\n" ++
                        "  avec `import * as ns` (ou re-exporte en `export * as ns`). L'objet\n" ++
                        "  namespace est construit UNE fois : il figerait la valeur, alors qu'en\n" ++
                        "  ESM `ns.{s}` reste vivant.\n" ++
                        "  Importez le nom directement (`import {{ {s} }} from …`) — la, le scope\n" ++
                        "  hoisting preserve le live binding — ou exportez une fonction accesseur.",
                    .{ b.name, self.display(m.path), b.name, b.name, b.name },
                );
            }
        }
    }

    /// Le premier binding RÉASSIGNÉ atteignable parmi les exports d'un module
    /// (les siens et ceux de ses `export *`).
    fn findAssigned(
        self: *Linker,
        mod: ModuleId,
        seen: *std.StringHashMapUnmanaged(void),
        depth: u32,
    ) Error!?*zc.semantic.Binding {
        if (depth > 32) return null;
        const m = &self.mods[mod];
        for (m.info.exports) |e| {
            switch (e.kind) {
                .local => if (e.binding) |b| {
                    if (b.assigned) return b;
                },
                .re_export => {
                    if (self.isExternal(mod, e.specifier)) continue;
                    const to = self.targetOf(mod, e.specifier) orelse continue;
                    if (try self.findAssigned(to, seen, depth + 1)) |b| return b;
                },
                else => {},
            }
        }
        for (m.info.star_exports) |spec| {
            if (self.isExternal(mod, spec)) continue;
            const to = self.targetOf(mod, spec) orelse continue;
            if ((try seen.getOrPut(self.a, spec)).found_existing) continue;
            if (try self.findAssigned(to, seen, depth + 1)) |b| return b;
        }
        return null;
    }

    // ---- 3. l'attribution des noms ----

    /// Un nom libre dans le scope du bundle. `base` s'il est disponible, sinon
    /// `base$1`, `base$2`… (la convention rollup — lisible, et `$` est légal).
    fn unique(self: *Linker, base: []const u8) Error![]const u8 {
        if (!self.used.contains(base)) {
            try self.used.put(self.a, base, {});
            return base;
        }
        var n: u32 = 1;
        while (true) : (n += 1) {
            const cand = try std.fmt.allocPrint(self.a, "{s}${d}", .{ base, n });
            if (!self.used.contains(cand)) {
                try self.used.put(self.a, cand, {});
                self.renamed += 1;
                return cand;
            }
        }
    }

    /// Réserve les noms intouchables : mots réservés + tous les noms NON RÉSOLUS
    /// de tous les modules (les globals — `console`, `process`, `Math`…). Sans
    /// ça, un binding local pourrait être renommé en `console` et capturer le
    /// global. Même garde-fou que le mangler, à l'échelle du bundle.
    fn reserveNames(self: *Linker) Error!void {
        for (RESERVED) |kw| try self.used.put(self.a, kw, {});
        for (self.mods) |m| {
            var it = m.sem.unresolved.keyIterator();
            while (it.next()) |name| try self.used.put(self.a, name.*, {});
        }
    }

    /// Donne son nom final à chaque binding top-level de chaque module, dans
    /// l'ordre d'émission (les premiers gardent leur nom : le bundle reste
    /// lisible, et l'entry — la partie qu'on lit le plus — est nommée en dernier
    /// donc peut être suffixée ; c'est le compromis de rollup).
    ///
    /// Les bindings d'IMPORT sont sautés : ce sont des alias, ils recevront le
    /// nom de leur source à l'étape de résolution.
    fn assignNames(self: *Linker) Error!void {
        for (self.order.items) |id| {
            const m = &self.mods[id];
            var list: std.ArrayList(*zc.semantic.Binding) = .empty;
            var it = m.info.module_scope.bindings.valueIterator();
            while (it.next()) |b| try list.append(self.a, b.*);
            // Ordre de déclaration : déterminisme (une map n'a pas d'ordre).
            std.mem.sort(*zc.semantic.Binding, list.items, {}, byDecl);
            for (list.items) |b| {
                if (b.kind == .import_) continue; // alias : résolu plus tard
                // Un binding MORT ne consomme pas de nom : sinon un `helper`
                // éliminé forcerait le `helper` vivant d'un autre module à
                // devenir `helper$1`, pour rien.
                if (!self.live.contains(b)) continue;
                const final = try self.unique(b.name);
                if (!std.mem.eql(u8, final, b.name)) b.new_name = final;
            }
            // `export default <expression>` : pas de binding, on en fabrique un.
            for (m.info.exports) |e| {
                if (e.kind != .default_expr) continue;
                if (!self.defaultAlive(m.id)) continue;
                m.default_name = try self.unique(try std.fmt.allocPrint(self.a, "{s}_default", .{self.stem(m.path)}));
            }
        }
    }

    /// Le nom final d'un binding : son `new_name` s'il a été renommé, sinon le sien.
    fn finalOf(_: *Linker, b: *zc.semantic.Binding) []const u8 {
        return b.currentName();
    }

    /// L'unité `export default <expr>` de ce module a-t-elle survécu ?
    fn defaultAlive(self: *Linker, mod: ModuleId) bool {
        for (self.mods[mod].units) |u| {
            if (u.stmt.kind == .export_default_declaration and u.alive) return true;
        }
        return false;
    }

    // ---- 3bis. LE MARQUAGE (v0.3) : qu'est-ce qui est ATTEIGNABLE ? ----

    /// Marque tout ce qui est vivant, par point fixe. Ce qui reste mort ne sera
    /// jamais émis.
    ///
    /// **Les racines** (deux familles, et seulement deux) :
    ///   1. **Tout statement top-level IMPUR de tout module du graphe.** Un
    ///      module présent dans le graphe SERA évalué à l'exécution (ESM évalue
    ///      chaque module importé) : ses effets de bord doivent survivre, même
    ///      si personne n'utilise ce qu'il exporte. C'est ce qui fait marcher
    ///      `import './polyfill'`.
    ///   2. **Les exports de l'ENTRY.** C'est le contrat du bundle avec
    ///      l'extérieur.
    ///
    /// **La propagation** : une unité vivante rend vivants les bindings qu'elle
    /// utilise → chaque binding vivant rend vivante l'unité qui le déclare → et
    /// on recommence. Le corps d'une fonction vivante tire donc ce qu'il touche,
    /// transitivement. Worklist explicite, pas de récursion : lodash, c'est 172
    /// modules et des milliers d'unités.
    ///
    /// **Les chaînes d'import** sont traversées par `resolveTarget` : importer
    /// `a` de `x` ne marque QUE le binding `a` de `x`, pas tout `x`. C'est
    /// précisément le gain du tree-shaking sur les barrels.
    fn mark(self: *Linker) Error!void {
        // Index : quel binding est déclaré par quelle unité (par module).
        self.decl_unit = try self.a.alloc(std.AutoHashMapUnmanaged(*zc.semantic.Binding, u32), self.mods.len);
        self.import_of = try self.a.alloc(std.AutoHashMapUnmanaged(*zc.semantic.Binding, zc.semantic.ImportEntry), self.mods.len);
        for (self.mods, 0..) |*m, i| {
            self.decl_unit[i] = .empty;
            self.import_of[i] = .empty;
            for (m.units, 0..) |u, ui| {
                for (u.declares) |b| try self.decl_unit[i].put(self.a, b, @intCast(ui));
            }
            for (m.info.imports) |imp| {
                if (imp.binding) |b| try self.import_of[i].put(self.a, b, imp);
            }
        }

        // Racine 1 : les effets de bord de chaque module du graphe.
        for (self.mods, 0..) |*m, i| {
            for (m.units, 0..) |u, ui| {
                if (!u.pure) try self.markUnit(@intCast(i), @intCast(ui));
            }
        }
        // Racine 2 : ce que l'entry expose au monde.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        try self.exportNames(self.g.entry, &names, &seen, 0);
        for (names.items) |name| {
            if (try self.resolveTarget(self.g.entry, name, 0)) |t| try self.markTarget(t);
        }

        try self.drain();
    }

    /// Rend une unité vivante et met ses dépendances en file.
    fn markUnit(self: *Linker, mod: ModuleId, idx: u32) Error!void {
        const u = &self.mods[mod].units[idx];
        if (u.alive) return;
        u.alive = true;
        for (u.uses) |b| try self.queue.append(self.a, .{ .mod = mod, .b = b });
    }

    fn markTarget(self: *Linker, t: Target) Error!void {
        switch (t) {
            .binding => |x| try self.queue.append(self.a, .{ .mod = x.mod, .b = x.b }),
            .default_expr => |mod| try self.markDefaultUnit(mod),
            .namespace => |mod| try self.markNamespace(mod, 0),
            // Un external vivant : on note qu'il faudra l'importer (cf. `emit`).
            .external => |x| _ = try self.externalName(x.specifier, x.imported, x.kind),
        }
    }

    /// `export default <expression>` n'a pas de binding : on marque directement
    /// le statement qui le porte.
    fn markDefaultUnit(self: *Linker, mod: ModuleId) Error!void {
        for (self.mods[mod].units, 0..) |u, ui| {
            if (u.stmt.kind == .export_default_declaration) try self.markUnit(mod, @intCast(ui));
        }
    }

    /// Un objet namespace expose TOUT : il rend vivant chaque export du module.
    /// C'est le prix d'un `import * as ns` — et la raison pour laquelle il vaut
    /// mieux importer les noms un par un quand on veut du shaking.
    fn markNamespace(self: *Linker, mod: ModuleId, depth: u32) Error!void {
        if (depth > 32) return;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        try self.exportNames(mod, &names, &seen, 0);
        for (names.items) |name| {
            if (try self.resolveTarget(mod, name, 0)) |t| {
                // Pas de `markTarget` récursif sur un namespace imbriqué : on
                // passe par la file pour les bindings, et on borne la profondeur.
                switch (t) {
                    .namespace => |inner| if (inner != mod) try self.markNamespace(inner, depth + 1),
                    else => try self.markTarget(t),
                }
            }
        }
    }

    /// Vide la file jusqu'au point fixe.
    fn drain(self: *Linker) Error!void {
        while (self.queue.pop()) |ref| {
            const gop = try self.live.getOrPut(self.a, ref.b);
            if (gop.found_existing) continue;

            // Un binding d'IMPORT est un alias : ce qui vit, c'est sa source.
            if (self.import_of[ref.mod].get(ref.b)) |imp| {
                if (self.isExternal(ref.mod, imp.specifier)) {
                    _ = try self.externalName(imp.specifier, imp.imported, imp.kind);
                    continue;
                }
                const to = self.targetOf(ref.mod, imp.specifier) orelse continue;
                switch (imp.kind) {
                    .namespace => try self.markNamespace(to, 0),
                    .default => if (try self.resolveTarget(to, "default", 0)) |t| try self.markTarget(t),
                    .named => if (try self.resolveTarget(to, imp.imported, 0)) |t| try self.markTarget(t),
                }
                continue;
            }
            // Un binding normal : l'unité qui le déclare doit vivre.
            if (self.decl_unit[ref.mod].get(ref.b)) |ui| try self.markUnit(ref.mod, ui);
        }
    }

    /// Tous les noms exportés par un module (les siens + ceux traversés par
    /// `export *`).
    fn exportNames(
        self: *Linker,
        mod: ModuleId,
        out: *std.ArrayList([]const u8),
        seen: *std.StringHashMapUnmanaged(void),
        depth: u32,
    ) Error!void {
        if (depth > 32) return;
        const m = &self.mods[mod];
        for (m.info.exports) |e| {
            if ((try seen.getOrPut(self.a, e.exported)).found_existing) continue;
            try out.append(self.a, e.exported);
        }
        for (m.info.star_exports) |spec| {
            if (self.isExternal(mod, spec)) continue;
            const to = self.targetOf(mod, spec) orelse continue;
            try self.exportNames(to, out, seen, depth + 1);
        }
    }

    /// Un module a-t-il au moins une unité vivante ? Sinon il disparaît du
    /// bundle — en-tête compris.
    fn moduleAlive(self: *Linker, mod: ModuleId) bool {
        for (self.mods[mod].units) |u| {
            if (u.alive) return true;
        }
        return false;
    }

    // ---- 4. la résolution des imports (LE cœur) ----

    /// Ce que désigne VRAIMENT un nom exporté, une fois la chaîne suivie.
    ///
    /// Structurel, pas textuel : le marquage (v0.3) a besoin de savoir QUEL
    /// binding vit, bien avant que les noms finaux n'existent. `nameOf` en tire
    /// le texte au moment de l'émission.
    const Target = union(enum) {
        /// Un binding réel, dans un module donné.
        binding: struct { mod: ModuleId, b: *zc.semantic.Binding },
        /// Le `const <mod>_default = …` fabriqué pour un `export default <expr>`.
        default_expr: ModuleId,
        /// L'objet namespace d'un module.
        namespace: ModuleId,
        /// Un nom venu d'un external : la clé (specifier, imported, kind).
        external: struct { specifier: []const u8, imported: []const u8, kind: zc.semantic.ImportKind },
    };

    /// Suit la chaîne d'exports de `mod` pour `name`. `null` = pas exporté.
    fn resolveTarget(self: *Linker, mod: ModuleId, name: []const u8, depth: u32) Error!?Target {
        if (depth > 32) return self.fail("chaine de re-export trop profonde pour '{s}'", .{name});
        const m = &self.mods[mod];
        for (m.info.exports) |e| {
            if (!std.mem.eql(u8, e.exported, name)) continue;
            switch (e.kind) {
                .local => return Target{ .binding = .{ .mod = mod, .b = e.binding orelse return null } },
                .default_expr => return Target{ .default_expr = mod },
                .re_export => {
                    if (self.isExternal(mod, e.specifier)) {
                        return Target{ .external = .{ .specifier = e.specifier, .imported = e.imported, .kind = .named } };
                    }
                    const to = self.targetOf(mod, e.specifier) orelse return null;
                    return self.resolveTarget(to, e.imported, depth + 1);
                },
                .star_as => {
                    const to = self.targetOf(mod, e.specifier) orelse return null;
                    return Target{ .namespace = to };
                },
            }
        }
        // `export * from './x'` : le nom vient peut-être d'une des sources.
        for (m.info.star_exports) |spec| {
            if (self.isExternal(mod, spec)) continue; // impossible à énumérer
            const to = self.targetOf(mod, spec) orelse continue;
            if (try self.resolveTarget(to, name, depth + 1)) |hit| return hit;
        }
        return null;
    }

    /// Le nom final d'une cible. N'est appelé qu'à l'émission, quand tous les
    /// noms sont attribués.
    fn nameOf(self: *Linker, t: Target) Error![]const u8 {
        return switch (t) {
            .binding => |x| self.finalOf(x.b),
            .default_expr => |mod| self.mods[mod].default_name.?,
            .namespace => |mod| self.mods[mod].namespace_name.?,
            .external => |x| self.externalName(x.specifier, x.imported, x.kind),
        };
    }

    /// Le nom final, dans le bundle, de `name` tel qu'exporté par `mod`.
    fn resolveExport(self: *Linker, mod: ModuleId, name: []const u8, depth: u32) Error!?[]const u8 {
        const t = (try self.resolveTarget(mod, name, depth)) orelse return null;
        return try self.nameOf(t);
    }

    /// Tous les noms exportés d'un module (les siens + ceux de ses `export *`),
    /// avec leur nom final. Sert à matérialiser un objet namespace.
    fn collectExports(
        self: *Linker,
        mod: ModuleId,
        out: *std.ArrayList(NamePair),
        seen: *std.StringHashMapUnmanaged(void),
        depth: u32,
    ) Error!void {
        if (depth > 32) return;
        const m = &self.mods[mod];
        for (m.info.exports) |e| {
            if ((try seen.getOrPut(self.a, e.exported)).found_existing) continue;
            const final = (try self.resolveExport(mod, e.exported, 0)) orelse continue;
            try out.append(self.a, .{ .exported = e.exported, .final = final });
        }
        for (m.info.star_exports) |spec| {
            if (self.isExternal(mod, spec)) continue;
            const to = self.targetOf(mod, spec) orelse continue;
            try self.collectExports(to, out, seen, depth + 1);
        }
    }

    /// Résout chaque import : le binding local reçoit le nom FINAL de sa source.
    /// C'est tout le linking — après ça, plus aucun `import` n'a de raison d'être.
    fn linkImports(self: *Linker) Error!void {
        // Les namespaces d'abord : un `import * as ns` doit avoir son nom avant
        // qu'un autre module ne le référence.
        // PAS de filtre `moduleAlive` ici : un barrel PUR (que des re-exports)
        // n'a aucune unité vivante — il n'émet rien — mais ses déclarations
        // pilotent quand même la RÉSOLUTION. Le filtrage se fait sur les
        // bindings (`live`) et sur `namespaceNeeded`, pas sur le module.
        for (self.order.items) |id| {
            for (self.mods[id].info.imports) |imp| {
                if (imp.kind != .namespace) continue;
                // Un import mort ne matérialise rien (v0.3).
                if (imp.binding) |b| if (!self.live.contains(b)) continue;
                if (self.isExternal(id, imp.specifier)) continue;
                const to = self.targetOf(id, imp.specifier) orelse continue;
                try self.ensureNamespace(to);
            }
            // `export * as ns from './x'` matérialise aussi le namespace de x.
            for (self.mods[id].info.exports) |e| {
                if (e.kind != .star_as) continue;
                if (self.isExternal(id, e.specifier)) continue;
                const to = self.targetOf(id, e.specifier) orelse continue;
                if (!self.namespaceNeeded(id, e.exported)) continue;
                try self.ensureNamespace(to);
            }
        }

        for (self.order.items) |id| {
            const m = &self.mods[id];
            for (m.info.imports) |imp| {
                const b = imp.binding orelse continue;
                if (!self.live.contains(b)) continue; // import mort : rien à lier
                const final = try self.resolveImport(id, imp);
                // LE geste du linker : le binding importé devient un ALIAS du nom
                // source. Toutes ses références suivent (via `applyRenames`).
                if (!std.mem.eql(u8, final, b.name)) b.new_name = final;
            }
        }
    }

    fn resolveImport(self: *Linker, from: ModuleId, imp: zc.semantic.ImportEntry) Error![]const u8 {
        if (self.isExternal(from, imp.specifier)) {
            return self.externalName(imp.specifier, imp.imported, imp.kind);
        }
        const to = self.targetOf(from, imp.specifier) orelse
            return self.fail("dependance non resolue '{s}' depuis {s}", .{ imp.specifier, self.display(self.mods[from].path) });
        switch (imp.kind) {
            .namespace => return self.mods[to].namespace_name.?,
            .default => return (try self.resolveExport(to, "default", 0)) orelse
                self.fail("{s} n'a pas d'export par defaut (importe par {s})", .{ self.display(self.mods[to].path), self.display(self.mods[from].path) }),
            .named => return (try self.resolveExport(to, imp.imported, 0)) orelse
                self.fail("{s} n'exporte pas '{s}' (importe par {s})", .{ self.display(self.mods[to].path), imp.imported, self.display(self.mods[from].path) }),
        }
    }

    /// Un `export * as ns from './x'` de `mod` est-il réellement consommé ?
    /// (Soit parce que `mod` est l'entry — c'est un export public —, soit parce
    /// qu'un module vivant importe ce nom.)
    fn namespaceNeeded(self: *Linker, mod: ModuleId, exported: []const u8) bool {
        if (mod == self.g.entry) return true;
        for (self.mods, 0..) |*other, oi| {
            if (!self.moduleAlive(@intCast(oi))) continue;
            for (other.info.imports) |imp| {
                const b = imp.binding orelse continue;
                if (!self.live.contains(b)) continue;
                if (imp.kind == .namespace) {
                    if (self.targetOf(@intCast(oi), imp.specifier) == mod) return true;
                } else if (imp.kind == .named and std.mem.eql(u8, imp.imported, exported)) {
                    if (self.targetOf(@intCast(oi), imp.specifier) == mod) return true;
                }
            }
        }
        return false;
    }

    fn ensureNamespace(self: *Linker, mod: ModuleId) Error!void {
        if (self.mods[mod].namespace_name != null) return;
        self.mods[mod].namespace_name = try self.unique(
            try std.fmt.allocPrint(self.a, "{s}_ns", .{self.stem(self.mods[mod].path)}),
        );
    }

    /// Le nom local d'un nom importé depuis un external, dédupliqué : deux
    /// modules qui importent `useState` de `react` partagent le même.
    fn externalName(self: *Linker, specifier: []const u8, imported: []const u8, kind: zc.semantic.ImportKind) Error![]const u8 {
        const key = switch (kind) {
            .default => "default",
            .namespace => "*",
            .named => imported,
        };
        const gop = try self.by_specifier.getOrPut(self.a, specifier);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.externals.items.len);
            try self.externals.append(self.a, .{ .specifier = specifier });
        }
        const ext = &self.externals.items[gop.value_ptr.*];
        if (ext.names.get(key)) |existing| return existing;
        const base = switch (kind) {
            .default => try identifierFrom(self.a, specifier),
            .namespace => try std.fmt.allocPrint(self.a, "{s}_ns", .{try identifierFrom(self.a, specifier)}),
            .named => imported,
        };
        const final = try self.unique(base);
        try ext.names.put(self.a, key, final);
        return final;
    }

    // ---- 5. l'émission ----

    fn emit(self: *Linker, out: *std.ArrayList(u8)) Error!void {
        const iife = self.opts.format == .iife;
        try out.appendSlice(self.a, if (iife)
            "// Genere par zbundle — IIFE, un seul fichier.\n"
        else
            "// Genere par zbundle — format ESM, un seul fichier.\n");

        // Une IIFE ne peut PAS porter d'`import` : un module externe n'a nulle
        // part où aller. On le dit, plutôt que d'émettre du JS invalide.
        if (iife and self.externals.items.len > 0) {
            return self.fail(
                "--format iife est incompatible avec des imports externes ({d})\n" ++
                    "  Le premier : '{s}'. Une IIFE enferme tout dans une fonction, or un\n" ++
                    "  `import` n'est legal qu'au top-level d'un module.\n" ++
                    "  Utilisez --format esm, ou rendez ces dependances internes.",
                .{ self.externals.items.len, self.externals.items[0].specifier },
            );
        }

        // Les externals EN TÊTE, dédupliqués et fusionnés.
        for (self.externals.items) |ext| try self.emitExternalImport(ext, out);
        if (self.externals.items.len > 0) try out.append(self.a, '\n');

        if (iife) try out.appendSlice(self.a, "(() => {\n");

        for (self.order.items) |id| {
            const m = &self.mods[id];
            // Un module dont aucune unité n'a survécu disparaît ENTIÈREMENT,
            // en-tête compris : il n'a plus rien à dire.
            if (!self.moduleAlive(id)) continue;
            try out.appendSlice(self.a, try std.fmt.allocPrint(
                self.a,
                "// \u{2500}\u{2500} {s} \u{2500}\u{2500}\n",
                .{self.display(m.path)},
            ));
            try self.emitModuleBody(m, out);
            if (m.namespace_name) |ns| try self.emitNamespace(id, ns, out);
            try out.append(self.a, '\n');
        }

        if (iife) {
            // Une IIFE n'exporte rien : on compte quand même ce qu'on perd, pour
            // que l'appelant puisse le signaler.
            self.entry_exports = try self.countEntryExports();
            try out.appendSlice(self.a, "})();\n");
            return;
        }
        self.entry_exports = try self.emitEntryExports(out);
    }

    fn countEntryExports(self: *Linker) Error!u32 {
        var pairs: std.ArrayList(NamePair) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectExports(self.g.entry, &pairs, &seen, 0);
        return @intCast(pairs.items.len);
    }

    fn emitExternalImport(self: *Linker, ext: ExternalImport, out: *std.ArrayList(u8)) Error!void {
        var default_name: ?[]const u8 = null;
        var ns_name: ?[]const u8 = null;
        var named: std.ArrayList(NamePair) = .empty;
        var it = ext.names.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.eql(u8, key, "default")) default_name = e.value_ptr.*
            else if (std.mem.eql(u8, key, "*")) ns_name = e.value_ptr.*
            else try named.append(self.a, .{ .exported = key, .final = e.value_ptr.* });
        }
        std.mem.sort(NamePair, named.items, {}, byExported); // déterminisme

        // `import * as ns` ne se mélange pas aux autres clauses : ligne à part.
        if (ns_name) |ns| {
            try out.appendSlice(self.a, try std.fmt.allocPrint(
                self.a,
                "import * as {s} from {f};\n",
                .{ ns, Quoted{ .s = ext.specifier } },
            ));
        }
        if (default_name == null and named.items.len == 0) {
            if (ns_name == null) {
                try out.appendSlice(self.a, try std.fmt.allocPrint(
                    self.a,
                    "import {f};\n",
                    .{Quoted{ .s = ext.specifier }},
                ));
            }
            return;
        }
        try out.appendSlice(self.a, "import ");
        if (default_name) |d| try out.appendSlice(self.a, d);
        if (named.items.len > 0) {
            if (default_name != null) try out.appendSlice(self.a, ", ");
            try out.appendSlice(self.a, "{ ");
            for (named.items, 0..) |p, i| {
                if (i != 0) try out.appendSlice(self.a, ", ");
                if (std.mem.eql(u8, p.exported, p.final)) {
                    try out.appendSlice(self.a, p.final);
                } else {
                    try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, "{s} as {s}", .{ p.exported, p.final }));
                }
            }
            try out.appendSlice(self.a, " }");
        }
        try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, " from {f};\n", .{Quoted{ .s = ext.specifier }}));
    }

    /// Le corps d'un module : chaque statement top-level, les déclarations de
    /// module en moins. Le PRINTER de zcompiler fait le rendu — l'AST porte déjà
    /// les noms finaux (`applyRenames` est passé), donc il n'y a rien à réécrire.
    fn emitModuleBody(self: *Linker, m: *Mod, out: *std.ArrayList(u8)) Error!void {
        for (m.units) |unit| {
            if (!unit.alive) continue; // le SWEEP : le code mort n'est pas émis
            try self.emitStatement(m, unit.stmt, out);
        }
    }

    fn emitStatement(self: *Linker, m: *Mod, stmt: *zc.Node, out: *std.ArrayList(u8)) Error!void {
        switch (stmt.kind) {
            // Les imports DISPARAISSENT : ce n'étaient que des alias de noms.
            .import_declaration => {},
            // `export * from` / `export * as ns from` : rien à émettre (la table
            // d'exports et l'objet namespace s'en chargent).
            .export_all_declaration => {},
            .export_named_declaration => |e| {
                // `export const x = 1` -> `const x = 1` (on perd le mot-clé).
                if (e.declaration) |decl| try self.printStmt(m, decl, out);
                // `export { a }` / `export { a } from './x'` : rien (table).
            },
            .export_default_declaration => {
                // `export default foo` (un binding) : rien à émettre.
                // `export default <expr>` : on lie l'expression au nom fabriqué.
                for (m.info.exports) |e| {
                    if (e.kind != .default_expr) continue;
                    try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, "const {s} = ", .{m.default_name.?}));
                    zc.printer.printExpression(e.value.?, m.source, out, self.a) catch
                        return self.fail("impossible d'imprimer l'export default de {s}", .{self.display(m.path)});
                    try out.appendSlice(self.a, ";\n");
                }
            },
            else => try self.printStmt(m, stmt, out),
        }
    }

    fn printStmt(self: *Linker, m: *Mod, stmt: *zc.Node, out: *std.ArrayList(u8)) Error!void {
        zc.printer.printStatement(stmt, m.source, out, self.a) catch
            return self.fail("impossible d'imprimer un statement de {s}", .{self.display(m.path)});
    }

    /// L'objet namespace : la SEULE matérialisation du linking. `import * as ns`
    /// veut un vrai objet à l'exécution, on le construit à partir des noms finaux.
    fn emitNamespace(self: *Linker, id: ModuleId, name: []const u8, out: *std.ArrayList(u8)) Error!void {
        var pairs: std.ArrayList(NamePair) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectExports(id, &pairs, &seen, 0);
        std.mem.sort(NamePair, pairs.items, {}, byExported);

        try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, "const {s} = {{", .{name}));
        for (pairs.items, 0..) |p, i| {
            if (i != 0) try out.appendSlice(self.a, ",");
            try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, " {s}: {s}", .{ p.exported, p.final }));
        }
        try out.appendSlice(self.a, if (pairs.items.len == 0) "};\n" else " };\n");
    }

    /// Les exports de l'ENTRY : les seuls survivants du bundle.
    fn emitEntryExports(self: *Linker, out: *std.ArrayList(u8)) Error!u32 {
        var pairs: std.ArrayList(NamePair) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectExports(self.g.entry, &pairs, &seen, 0);
        if (pairs.items.len == 0) return 0;
        std.mem.sort(NamePair, pairs.items, {}, byExported);

        try out.appendSlice(self.a, "export {");
        for (pairs.items, 0..) |p, i| {
            if (i != 0) try out.appendSlice(self.a, ",");
            if (std.mem.eql(u8, p.exported, p.final)) {
                try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, " {s}", .{p.final}));
            } else {
                try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, " {s} as {s}", .{ p.final, p.exported }));
            }
        }
        try out.appendSlice(self.a, " };\n");
        return @intCast(pairs.items.len);
    }

    // ---- utilitaires ----

    /// Le chemin relatif au dossier de l'entry — lisible dans les en-têtes et
    /// les messages d'erreur (un chemin absolu de 120 caractères ne l'est pas).
    fn display(self: *Linker, path: []const u8) []const u8 {
        const root = std.fs.path.dirname(self.mods[self.g.entry].path) orelse return path;
        if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep) {
            return path[root.len + 1 ..];
        }
        return path;
    }

    /// Le nom de fichier sans extension, nettoyé pour servir d'identifiant JS.
    fn stem(self: *Linker, path: []const u8) []const u8 {
        const base = std.fs.path.basename(path);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        return identifierFrom(self.a, base[0..dot]) catch "mod";
    }
};

const NamePair = struct { exported: []const u8, final: []const u8 };

/// Un binding, situé dans son module (un `*Binding` seul ne dit pas d'où il vient).
const BindingRef = struct { mod: ModuleId, b: *zc.semantic.Binding };

fn byExported(_: void, x: NamePair, y: NamePair) bool {
    return std.mem.order(u8, x.exported, y.exported) == .lt;
}

fn byDecl(_: void, x: *zc.semantic.Binding, y: *zc.semantic.Binding) bool {
    return x.decl_start < y.decl_start;
}

/// Transforme un texte quelconque en identifiant JS valide (`node:fs/promises`
/// → `node_fs_promises`, `@scope/pkg` → `scope_pkg`).
fn identifierFrom(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
            try out.append(a, c);
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '_') {
            try out.append(a, '_');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    if (out.items.len == 0 or std.ascii.isDigit(out.items[0])) try out.insert(a, 0, '_');
    return out.items;
}

/// La ligne (1-indexée) d'un offset dans un source.
fn lineOf(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    const end = @min(offset, source.len);
    for (source[0..end]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// Le code d'un statement, sur une ligne, tronqué — de quoi le reconnaître.
fn snippetOf(a: Allocator, source: []const u8, stmt: *zc.Node) Allocator.Error![]const u8 {
    const raw = source[@min(stmt.start, source.len)..@min(stmt.end, source.len)];
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (raw) |c| {
        if (out.items.len >= 68) {
            try out.appendSlice(a, "…");
            break;
        }
        if (std.ascii.isWhitespace(c)) {
            if (!space and out.items.len > 0) try out.append(a, ' ');
            space = true;
        } else {
            try out.append(a, c);
            space = false;
        }
    }
    return out.items;
}

/// Pourquoi ce statement est mort.
fn reasonOf(a: Allocator, u: shake.Unit, whole_module: bool) Allocator.Error![]const u8 {
    if (whole_module) return "module entierement elimine (rien d'atteignable)";
    if (u.declares.len == 0) return "statement pur, aucun effet observable";
    var names: std.ArrayList(u8) = .empty;
    for (u.declares, 0..) |b, i| {
        if (i != 0) try names.appendSlice(a, ", ");
        try names.appendSlice(a, b.name);
    }
    return std.fmt.allocPrint(a, "aucune reference vivante vers {s}", .{names.items});
}

/// Une string JS entre guillemets simples (les specifiers n'en contiennent pas
/// en pratique ; on échappe quand même).
const Quoted = struct {
    s: []const u8,
    pub fn format(self: Quoted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('\'');
        for (self.s) |c| {
            if (c == '\'' or c == '\\') try writer.writeByte('\\');
            try writer.writeByte(c);
        }
        try writer.writeByte('\'');
    }
};

const RESERVED = [_][]const u8{
    "break",      "case",    "catch",     "class",   "const",     "continue",
    "debugger",   "default", "delete",    "do",      "else",      "enum",
    "export",     "extends", "false",     "finally", "for",       "function",
    "if",         "import",  "in",        "instanceof", "new",    "null",
    "return",     "super",   "switch",    "this",    "throw",     "true",
    "try",        "typeof",  "var",       "void",    "while",     "with",
    "yield",      "let",     "static",    "await",   "async",     "implements",
    "interface",  "package", "private",   "protected", "public",  "arguments",
    "eval",       "undefined",
};

/// Bundle `entry` en UN fichier de JS exécutable (format ESM).
pub fn bundle(a: Allocator, io: Io, entry: []const u8, err: *BundleError) Error!Bundle {
    const r = try bundleReport(a, io, entry, err, false, .{});
    return .{ .code = r.code, .stats = r.stats };
}

/// Idem, mais collecte aussi ce que le tree-shaking a éliminé (si `with_dead`),
/// et accepte les options (le format de sortie).
pub fn bundleReport(a: Allocator, io: Io, entry: []const u8, err: *BundleError, with_dead: bool, opts: Options) Error!Report {
    const t0 = Io.Clock.awake.now(io).nanoseconds;

    var gerr: graph.BuildError = .{};
    const built = graph.build(a, io, entry, &gerr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BuildFailed => {
            err.message = gerr.message;
            return error.BundleFailed;
        },
    };

    // Analyse de chaque module : scopes/bindings (le renommage) + table
    // imports/exports (le linking). Les deux viennent de zcompiler.
    const mods = try a.alloc(Mod, built.graph.modules.len);
    var input_bytes: u32 = 0;
    for (built.graph.modules, built.parsed, 0..) |gm, p, i| {
        const sem = zc.semantic.analyze(a, p.program, p.source);
        mods[i] = .{
            .id = @intCast(i),
            .path = gm.path,
            .source = p.source,
            .program = p.program,
            .sem = sem,
            .info = zc.semantic.moduleInfo(a, p.program, p.source, sem),
            .units = try shake.units(a, p.program, p.source, sem),
        };
        input_bytes += @intCast(p.source.len);
    }

    var l = Linker{ .a = a, .err = err, .g = built.graph, .mods = mods, .opts = opts };
    try l.computeOrder();
    try l.check();
    // MARK avant tout nommage : un binding mort ne doit pas consommer un nom
    // (sinon un `helper` éliminé pousserait un `helper` vivant en `helper$1`).
    try l.mark();
    try l.reserveNames();
    try l.assignNames();
    try l.linkImports();
    try l.checkNamespaceSnapshots();

    // Les noms finaux descendent sur l'AST : une seule passe par module, et
    // toutes les références (locales ET importées) sont à jour.
    for (mods) |m| zc.mangler.applyRenames(m.sem);

    var out: std.ArrayList(u8) = .empty;
    try l.emit(&out);

    // Comptage du shaking (après coup : les unités portent leur verdict).
    var kept: u32 = 0;
    var dropped: u32 = 0;
    var emitted_mods: u32 = 0;
    for (mods, 0..) |m, i| {
        var any = false;
        for (m.units) |u| {
            if (u.alive) {
                kept += 1;
                any = true;
            } else dropped += 1;
        }
        _ = i;
        if (any) emitted_mods += 1;
    }

    // Ce qui est mort, pour qui veut le lire (`inspect.mjs --dead`).
    var dead: std.ArrayList(Dead) = .empty;
    if (with_dead) {
        for (mods, 0..) |m, mi| {
            const whole = !l.moduleAlive(@intCast(mi));
            for (m.units) |u| {
                if (u.alive) continue;
                // Les déclarations de module n'émettent rien de toute façon :
                // les lister comme « éliminées » serait du bruit.
                switch (u.stmt.kind) {
                    .import_declaration, .export_all_declaration => continue,
                    .export_named_declaration => |e| if (e.declaration == null) continue,
                    else => {},
                }
                try dead.append(a, .{
                    .module = l.display(m.path),
                    .line = lineOf(m.source, u.stmt.start),
                    .snippet = try snippetOf(a, m.source, u.stmt),
                    .reason = try reasonOf(a, u, whole),
                });
            }
        }
    }

    const t1 = Io.Clock.awake.now(io).nanoseconds;
    return .{
        .code = out.items,
        .dead = dead.items,
        .stats = .{
            .modules = emitted_mods,
            .entry_exports = l.entry_exports,
            .modules_dropped = @intCast(mods.len - emitted_mods),
            .externals = @intCast(l.externals.items.len),
            .renamed = l.renamed,
            .statements_kept = kept,
            .statements_dropped = dropped,
            .input_bytes = input_bytes,
            .output_bytes = @intCast(out.items.len),
            .bundle_ms = @as(f64, @floatFromInt(t1 - t0)) / std.time.ns_per_ms,
        },
    };
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
        // En deux temps : sinon l'arène est copiée dans le slot de retour avant
        // que `.root` n'alloue dedans (fuite — cf. la même note dans graph.zig).
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
    fn bundleOf(self: *Sandbox, entry: []const u8) ![]const u8 {
        var err: BundleError = .{};
        const full = try std.fs.path.join(self.a(), &.{ self.root, entry });
        const b = bundle(self.a(), io, full, &err) catch |e| {
            std.debug.print("\nbundle a echoue: {s}\n", .{err.message});
            return e;
        };
        return b.code;
    }
    /// Le message d'erreur d'un bundle qui DOIT échouer.
    fn refusal(self: *Sandbox, entry: []const u8) ![]const u8 {
        var err: BundleError = .{};
        const full = try std.fs.path.join(self.a(), &.{ self.root, entry });
        if (bundle(self.a(), io, full, &err)) |_| {
            return error.ShouldHaveFailed;
        } else |_| {
            return err.message;
        }
    }
};

/// L'index de la première occurrence de `needle` (pour comparer des ORDRES).
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

test "ordre topologique : les dependances AVANT les dependants" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; export const a = b + 1;");
    try s.write("b.js", "import { c } from './c.js'; export const b = c + 1;");
    try s.write("c.js", "export const c = 1;");
    const code = try s.bundleOf("a.js");
    const ic = indexOf(code, "const c = 1").?;
    const ib = indexOf(code, "const b = ").?;
    const ia = indexOf(code, "const a = ").?;
    try std.testing.expect(ic < ib);
    try std.testing.expect(ib < ia);
}

test "ordre topologique : le diamant emet le module partage UNE fois" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; import { c } from './c.js'; export const a = b + c;");
    try s.write("b.js", "import { d } from './d.js'; export const b = d;");
    try s.write("c.js", "import { d } from './d.js'; export const c = d;");
    try s.write("d.js", "export const d = 1;");
    const code = try s.bundleOf("a.js");
    // Une seule declaration de `d`, et elle precede ses deux consommateurs.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "const d = 1"));
    const id = indexOf(code, "const d = 1").?;
    try std.testing.expect(id < indexOf(code, "const b = ").?);
    try std.testing.expect(id < indexOf(code, "const c = ").?);
}

test "un cycle ne fait pas boucler et emet chaque module une fois" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; export function a() { return b(); }");
    try s.write("b.js", "import { a } from './a.js'; export function b() { return 1; } export const usesA = () => a;");
    const code = try s.bundleOf("a.js");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "function a()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "function b()"));
}

test "table de renommage : collision -> name$1, pas de collision -> nom garde" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "const shared = 'A'; export const fromA = () => shared; export const unique = 1;");
    try s.write("b.js", "const shared = 'B'; export const fromB = () => shared;");
    try s.write("m.js", "import { fromA, unique } from './a.js'; import { fromB } from './b.js'; console.log(fromA(), fromB(), unique);");
    const code = try s.bundleOf("m.js");
    // Le premier emis garde son nom, le second est suffixe.
    try std.testing.expect(indexOf(code, "const shared = 'A'") != null);
    try std.testing.expect(indexOf(code, "const shared$1 = 'B'") != null);
    // Un nom sans collision n'est JAMAIS touche (lisibilite du bundle).
    try std.testing.expect(indexOf(code, "const unique = 1") != null);
    try std.testing.expect(indexOf(code, "unique$1") == null);
}

test "les references suivent le renommage (l'import est un ALIAS)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dep.js", "export const value = 42;");
    try s.write("m.js", "const value = 'local'; export const both = () => value;");
    try s.write("main.js", "import { value } from './dep.js'; import { both } from './m.js'; console.log(value, both());");
    const code = try s.bundleOf("main.js");
    // `value` (dep) garde son nom, `value` (m) est renomme, et l'usage dans `m`
    // pointe bien sur le renomme.
    try std.testing.expect(indexOf(code, "const value = 42") != null);
    try std.testing.expect(indexOf(code, "const value$1 = 'local'") != null);
    try std.testing.expect(indexOf(code, "() => value$1") != null);
    // Aucun `import` interne ne survit.
    try std.testing.expect(indexOf(code, "from './dep.js'") == null);
}

test "la chaine de re-export se resout jusqu'au binding d'origine" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("deep.js", "export const original = 'deep';");
    try s.write("mid.js", "export { original as renamed } from './deep.js';");
    try s.write("top.js", "export { renamed as final } from './mid.js';");
    try s.write("main.js", "import { final } from './top.js'; console.log(final);");
    const code = try s.bundleOf("main.js");
    // Trois niveaux d'alias : il ne reste QUE le binding d'origine.
    try std.testing.expect(indexOf(code, "const original = 'deep'") != null);
    try std.testing.expect(indexOf(code, "console.log(original)") != null);
    try std.testing.expect(indexOf(code, "renamed") == null);
    try std.testing.expect(indexOf(code, "final") == null);
}

test "export * from : le nom traverse et se resout" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("src.js", "export const via_star = 7;");
    try s.write("barrel.js", "export * from './src.js';");
    try s.write("main.js", "import { via_star } from './barrel.js'; console.log(via_star);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "const via_star = 7") != null);
    try std.testing.expect(indexOf(code, "console.log(via_star)") != null);
}

test "namespace : materialise en objet, avec les noms FINAUX" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("m.js", "export const x = 1; export const y = 2;");
    try s.write("main.js", "const x = 'collision'; import * as ns from './m.js'; console.log(ns.x, ns.y, x);");
    const code = try s.bundleOf("main.js");
    // L'objet existe, et pointe sur les noms finaux (pas les noms d'origine).
    try std.testing.expect(indexOf(code, "const m_ns = {") != null);
    try std.testing.expect(indexOf(code, "x: x") != null);
    try std.testing.expect(indexOf(code, "y: y") != null);
    // Le nom local `ns` a disparu au profit du nom final de l'objet.
    try std.testing.expect(indexOf(code, "console.log(m_ns.x, m_ns.y, x$1)") != null);
}

test "export default : expression nommee vs binding existant" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("expr.js", "export default function () { return 1; }");
    try s.write("bound.js", "const named = 2; export default named;");
    try s.write("main.js", "import e from './expr.js'; import b from './bound.js'; console.log(e(), b);");
    const code = try s.bundleOf("main.js");
    // L'expression recoit un nom fabrique...
    try std.testing.expect(indexOf(code, "const expr_default = function") != null);
    // ...mais un binding existant n'a PAS de const intermediaire inutile.
    try std.testing.expect(indexOf(code, "const named = 2") != null);
    try std.testing.expect(indexOf(code, "bound_default") == null);
    try std.testing.expect(indexOf(code, "console.log(expr_default(), named)") != null);
}

test "externals : hoistes en tete, dedupliques et fusionnes" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { join } from 'node:path'; export const ja = join;");
    try s.write("main.js",
        \\import { join, basename } from 'node:path';
        \\import { ja } from './a.js';
        \\import fs from 'node:fs';
        \\console.log(join, basename, ja, fs);
    );
    const code = try s.bundleOf("main.js");
    // UNE seule ligne pour node:path, avec les deux noms fusionnes.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "from 'node:path'"));
    try std.testing.expect(indexOf(code, "import { basename, join } from 'node:path';") != null);
    try std.testing.expect(indexOf(code, "import node_fs from 'node:fs';") != null);
    // Les imports sont AVANT le premier module.
    try std.testing.expect(indexOf(code, "from 'node:path'").? < indexOf(code, "\u{2500}\u{2500} a.js").?);
}

test "les exports de l'ENTRY sont les seuls survivants" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("hidden.js", "export const internal = 1;");
    try s.write("main.js", "import { internal } from './hidden.js'; export const visible = internal + 1;");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "export { visible };") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "export {"));
}

test "refus : top-level await, import.meta, import() interne, namespace live" {
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("main.js", "const x = await Promise.resolve(1); console.log(x);");
        try std.testing.expect(indexOf(try s.refusal("main.js"), "top-level await") != null);
    }
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("main.js", "console.log(import.meta.url);");
        try std.testing.expect(indexOf(try s.refusal("main.js"), "import.meta") != null);
    }
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("lazy.js", "export const v = 1;");
        try s.write("main.js", "export const f = () => import('./lazy.js');");
        try std.testing.expect(indexOf(try s.refusal("main.js"), "code-splitting") != null);
    }
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("c.js", "export let n = 0; export function bump() { n += 1; }");
        try s.write("main.js", "import * as ns from './c.js'; ns.bump(); console.log(ns.n);");
        const msg = try s.refusal("main.js");
        try std.testing.expect(indexOf(msg, "objet namespace") != null);
    }
}

test "live binding importe NOMMEMENT : accepte (le hoisting le gere)" {
    // Le pendant du refus precedent : sans namespace, la reassignation est
    // visible chez l'importeur puisque c'est LA MEME variable apres fusion.
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("c.js", "export let n = 0; export function bump() { n += 1; }");
    try s.write("main.js", "import { n, bump } from './c.js'; bump(); console.log(n);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "let n = 0") != null);
    try std.testing.expect(indexOf(code, "console.log(n)") != null);
}

test "un import() vers un EXTERNAL reste tel quel (pas un chunk)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export const load = () => import('node:fs');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "import('node:fs')") != null);
}

// ---- tree-shaking (v0.3) ----

test "shaking : un import de 1 nom sur 3 ne tire QUE lui" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js",
        \\export const kept = () => 'vivant';
        \\export const dead1 = () => 'mort1';
        \\export const dead2 = () => 'mort2';
    );
    try s.write("main.js", "import { kept } from './lib.js'; console.log(kept());");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "kept") != null);
    try std.testing.expect(indexOf(code, "dead1") == null);
    try std.testing.expect(indexOf(code, "dead2") == null);
}

test "shaking : un module dont rien ne survit disparait, en-tete comprise" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("used.js", "export const used = 1;");
    try s.write("unused.js", "export const unused = 2;");
    try s.write("barrel.js", "export { used } from './used.js'; export { unused } from './unused.js';");
    try s.write("main.js", "import { used } from './barrel.js'; console.log(used);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "unused.js") == null); // meme l'en-tete
    try std.testing.expect(indexOf(code, "const unused") == null);
    try std.testing.expect(indexOf(code, "const used = 1") != null);
}

test "shaking : un effet de bord top-level SURVIT sans etre importe" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("polyfill.js",
        \\globalThis.PATCHED = true;
        \\export const neverUsed = () => 'mort';
    );
    try s.write("main.js", "import './polyfill.js'; console.log(globalThis.PATCHED);");
    const code = try s.bundleOf("main.js");
    // L'effet est une RACINE : il vit meme si rien n'est importe du module.
    try std.testing.expect(indexOf(code, "globalThis.PATCHED = true") != null);
    // Mais la fonction pure et inutilisee du meme module meurt.
    try std.testing.expect(indexOf(code, "neverUsed") == null);
}

test "shaking : le corps d'une fonction vivante tire ce qu'il touche" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("deep.js", "export const deep = () => 'profond';");
    try s.write("mid.js", "import { deep } from './deep.js'; export const mid = () => deep() + '!';");
    try s.write("main.js", "import { mid } from './mid.js'; console.log(mid());");
    const code = try s.bundleOf("main.js");
    // La chaine transitive entiere survit.
    try std.testing.expect(indexOf(code, "'profond'") != null);
    try std.testing.expect(indexOf(code, "const mid") != null);
}

test "shaking : un cycle mort disparait sans faire boucler le marquage" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; export const a = () => b();");
    try s.write("b.js", "import { a } from './a.js'; export const b = () => a();");
    try s.write("main.js", "import './a.js'; console.log('rien du cycle');");
    const code = try s.bundleOf("main.js");
    // Rien du cycle n'est utilise : tout meurt, et le point fixe termine.
    try std.testing.expect(indexOf(code, "const a = ") == null);
    try std.testing.expect(indexOf(code, "const b = ") == null);
    try std.testing.expect(indexOf(code, "rien du cycle") != null);
}

test "shaking : un binding MORT ne consomme pas de nom" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dead.js", "export const helper = () => 'mort';");
    try s.write("live.js", "const helper = () => 'vivant'; export const use = () => helper();");
    try s.write("main.js", "import './dead.js'; import { use } from './live.js'; console.log(use());");
    const code = try s.bundleOf("main.js");
    // Le `helper` mort a disparu, donc le vivant garde son nom : pas de `helper$1`.
    try std.testing.expect(indexOf(code, "helper$1") == null);
    try std.testing.expect(indexOf(code, "const helper = () => 'vivant'") != null);
}

test "shaking : un external dont plus rien ne survit disparait de l'en-tete" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dead.js", "import { join } from 'node:path'; export const j = () => join('a');");
    // NB : le message ne doit pas contenir le specifier, sinon on s'auto-piege.
    try s.write("main.js", "import './dead.js'; console.log('rien a importer');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "node:path") == null);
    try std.testing.expect(indexOf(code, "import ") == null); // aucun en-tete d'import
}

test "shaking : un import side-effect nu garde ses effets, meme sans binding" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("css.js", "globalThis.STYLED = 1;");
    try s.write("main.js", "import './css.js'; console.log(globalThis.STYLED);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "globalThis.STYLED = 1") != null);
}

test "shaking : les exports de l'ENTRY sont des racines" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const exposed = 1; export const hidden = 2;");
    try s.write("main.js", "export { exposed } from './lib.js';");
    const code = try s.bundleOf("main.js");
    // `exposed` est le contrat du bundle : il vit. `hidden` non.
    try std.testing.expect(indexOf(code, "const exposed = 1") != null);
    try std.testing.expect(indexOf(code, "hidden") == null);
}

test "shaking : un namespace rend TOUT vivant (le prix d'import * as)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("m.js", "export const a = 1; export const b = 2; export const c = 3;");
    try s.write("main.js", "import * as ns from './m.js'; console.log(ns.a);");
    const code = try s.bundleOf("main.js");
    // L'objet namespace expose tout : impossible de savoir ce qui sera lu.
    try std.testing.expect(indexOf(code, "const a = 1") != null);
    try std.testing.expect(indexOf(code, "const b = 2") != null);
    try std.testing.expect(indexOf(code, "const c = 3") != null);
}

test "shaking : les stats comptent ce qui est garde et ce qui tombe" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const a = 1; export const b = 2; export const c = 3;");
    try s.write("main.js", "import { a } from './lib.js'; console.log(a);");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    const b = try bundle(s.a(), Sandbox.io, full, &err);
    try std.testing.expect(b.stats.statements_dropped >= 2); // b et c
    try std.testing.expect(b.stats.statements_kept >= 2); // a et le console.log
    try std.testing.expectEqual(@as(u32, 0), b.stats.modules_dropped);
}

test "shaking : le rapport dit CE QUI est mort et POURQUOI" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const kept = 1;\nexport const dropped = 2;");
    try s.write("main.js", "import { kept } from './lib.js'; console.log(kept);");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    const r = try bundleReport(s.a(), Sandbox.io, full, &err, true, .{});
    try std.testing.expectEqual(@as(usize, 1), r.dead.len);
    try std.testing.expect(std.mem.endsWith(u8, r.dead[0].module, "lib.js"));
    try std.testing.expectEqual(@as(u32, 2), r.dead[0].line);
    try std.testing.expect(indexOf(r.dead[0].snippet, "dropped") != null);
    try std.testing.expect(indexOf(r.dead[0].reason, "aucune reference vivante") != null);
}

test "format iife : tout enferme dans une fonction, rien n'exporte" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const greet = () => 'salut';");
    try s.write("main.js", "import { greet } from './lib.js'; console.log(greet()); export const x = 1;");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    const r = try bundleReport(s.a(), Sandbox.io, full, &err, false, .{ .format = .iife });
    try std.testing.expect(indexOf(r.code, "(() => {") != null);
    try std.testing.expect(std.mem.endsWith(u8, r.code, "})();\n"));
    // Une IIFE n'exporte rien — mais on COMPTE ce qu'on perd, pour le signaler.
    try std.testing.expect(indexOf(r.code, "export {") == null);
    try std.testing.expectEqual(@as(u32, 1), r.stats.entry_exports);
}

test "format iife : refus clair si le bundle a des externals" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "import { join } from 'node:path'; console.log(join('a', 'b'));");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    try std.testing.expectError(
        error.BundleFailed,
        bundleReport(s.a(), Sandbox.io, full, &err, false, .{ .format = .iife }),
    );
    try std.testing.expect(indexOf(err.message, "incompatible avec des imports externes") != null);
    try std.testing.expect(indexOf(err.message, "--format esm") != null); // dit quoi faire
}

test "format esm reste le defaut, inchange" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export const x = 1;");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "(() => {") == null);
    try std.testing.expect(indexOf(code, "export { x };") != null);
}

// ---- les racines-export de l'entry : LES QUATRE FORMES ----
// Ces tests ne corrigent aucun bug (les quatre formes marchaient) : ils
// VERROUILLENT le cas limite « exporte + zero reference interne », qui est
// exactement celui qu'un marquage naif (iterer les references au lieu des
// exports) casserait sans que rien d'autre ne s'en apercoive.

test "racine-export : export <declaration> inline, zero reference" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export function jamaisUtilisee(x) { return x; }\nconsole.log('ok');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "function jamaisUtilisee") != null);
    try std.testing.expect(indexOf(code, "export { jamaisUtilisee };") != null);
}

test "racine-export : export { a, b as c } (specifiers), zero reference" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js",
        \\function a() { return 1; }
        \\function b() { return 2; }
        \\export { a, b as renomme };
        \\console.log('ok');
    );
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "function a()") != null);
    try std.testing.expect(indexOf(code, "function b()") != null);
    try std.testing.expect(indexOf(code, "export { a, b as renomme };") != null);
}

test "racine-export : export default (expression ET binding)" {
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("main.js", "export default function () { return 1; }\nconsole.log('ok');");
        const code = try s.bundleOf("main.js");
        try std.testing.expect(indexOf(code, "_default = function") != null);
        try std.testing.expect(indexOf(code, "as default };") != null);
    }
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("main.js", "const val = 42;\nexport default val;\nconsole.log('ok');");
        const code = try s.bundleOf("main.js");
        try std.testing.expect(indexOf(code, "const val = 42") != null);
        try std.testing.expect(indexOf(code, "export { val as default };") != null);
    }
}

test "racine-export : re-export — la racine est dans le module CIBLE" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dep.js", "export const cible = 1; export const inutile = 2;");
    try s.write("main.js", "export { cible } from './dep.js';\nconsole.log('ok');");
    const code = try s.bundleOf("main.js");
    // Le binding vit dans dep.js : c'est LUI que la racine doit atteindre.
    try std.testing.expect(indexOf(code, "const cible = 1") != null);
    try std.testing.expect(indexOf(code, "export { cible };") != null);
    // …sans tirer le reste du module cible.
    try std.testing.expect(indexOf(code, "inutile") == null);
}

test "racine-export : export * et export * as ns" {
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("dep.js", "export const viaStar = 1;");
        try s.write("main.js", "export * from './dep.js';\nconsole.log('ok');");
        const code = try s.bundleOf("main.js");
        try std.testing.expect(indexOf(code, "const viaStar = 1") != null);
        try std.testing.expect(indexOf(code, "export { viaStar };") != null);
    }
    {
        var s = try Sandbox.init(std.testing.allocator);
        defer s.deinit();
        try s.write("dep.js", "export const a = 1; export const b = 2;");
        try s.write("main.js", "export * as ns from './dep.js';\nconsole.log('ok');");
        const code = try s.bundleOf("main.js");
        // Le namespace est materialise, et exporte sous son nom public.
        try std.testing.expect(indexOf(code, "const dep_ns = {") != null);
        try std.testing.expect(indexOf(code, "as ns };") != null);
    }
}

test "racine-export : exporte survit, jumeau NON exporte meurt (pas de sur-marquage)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js",
        \\export function publique(x) { return x; }
        \\function privee(x) { return x; }
        \\console.log('ok');
    );
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "function publique") != null);
    try std.testing.expect(indexOf(code, "privee") == null);
}
