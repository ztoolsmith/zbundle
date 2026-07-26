//! Le TREE-SHAKING, moitié « analyse » : découper un module en **unités**
//! (ses statements top-level) et décider, pour chacune, si elle est PURE.
//!
//! Ce fichier ne connaît qu'UN module à la fois — pas le graphe, pas les autres
//! modules, pas le linker. C'est voulu : la pureté est une propriété locale, et
//! ça rend toute cette logique testable sans toucher au disque. Le marquage
//! cross-module (qui a besoin des chaînes d'import) vit dans `linker.zig`.
//!
//! ## La règle de pureté, en une phrase
//!
//!   > **Dans le doute : IMPUR.**
//!
//! Un bundle 5 % plus gros est un bug de moins. Un statement jugé pur à tort
//! disparaît, et avec lui un effet de bord que le programme attendait — c'est
//! exactement le genre de bug qu'on ne trouve qu'en production. Donc : tout ce
//! qui n'est pas manifestement inerte est traité comme une racine.
//!
//! ## Granularité (v0.3) : LE STATEMENT TOP-LEVEL
//!
//! Une déclaration vit ou meurt en entier. `const { a, b } = x` où seul `a` sert
//! garde les deux. Pas de découpe intra-statement, pas d'élimination de
//! propriétés d'objet. C'est le niveau de base de rollup, et c'est déjà
//! l'essentiel du gain (les barrels).

const std = @import("std");
const zc = @import("zcompiler");

const Allocator = std.mem.Allocator;
const Node = zc.Node;
const Binding = zc.semantic.Binding;

/// Une **unité** de tree-shaking : un statement top-level, avec ce qu'il déclare,
/// ce qu'il utilise, et s'il peut être supprimé sans rien changer d'observable.
pub const Unit = struct {
    stmt: *Node,
    /// Les bindings du scope module que ce statement déclare.
    declares: []const *Binding,
    /// Les bindings (module scope) qu'il référence, hors ceux qu'il déclare.
    uses: []const *Binding,
    /// Aucun effet de bord observable à l'évaluation du module.
    pure: bool,
    /// Marqué vivant par la phase de marquage (cf. `linker.zig`).
    alive: bool = false,
};

/// Découpe `program` en unités. `sem` doit être l'analyse DE CE program.
pub fn units(a: Allocator, program: *Node, source: []const u8, sem: *zc.semantic.Semantic) Allocator.Error![]Unit {
    const scope = sem.scopes.items[0]; // le scope module
    var out: std.ArrayList(Unit) = .empty;

    for (program.kind.program.body) |stmt| {
        var declares: std.ArrayList(*Binding) = .empty;
        collectDeclared(a, stmt, source, scope, &declares);

        var declared_set: std.AutoHashMapUnmanaged(*Binding, void) = .empty;
        for (declares.items) |b| try declared_set.put(a, b, {});

        var uses: std.ArrayList(*Binding) = .empty;
        var seen: std.AutoHashMapUnmanaged(*Binding, void) = .empty;
        var c = UseCollector{
            .a = a,
            .sem = sem,
            .scope = scope,
            .declared = &declared_set,
            .seen = &seen,
            .out = &uses,
        };
        _ = zc.walker.walk(stmt, .{ .ctx = &c, .enter = useThunk });

        try out.append(a, .{
            .stmt = stmt,
            .declares = declares.items,
            .uses = uses.items,
            .pure = isPureTopLevel(stmt, source),
        });
    }
    return out.items;
}

/// Les bindings du scope module déclarés par un statement top-level.
fn collectDeclared(
    a: Allocator,
    stmt: *Node,
    source: []const u8,
    scope: *zc.semantic.Scope,
    out: *std.ArrayList(*Binding),
) void {
    switch (stmt.kind) {
        .variable_declaration => |d| for (d.declarations) |v| {
            patternNames(a, v.kind.variable_declarator.id, source, scope, out);
        },
        .function_declaration => |f| if (f.id) |id| push(a, scope, id.litText(source), out),
        .class_declaration => |c| if (c.id) |id| push(a, scope, id.litText(source), out),
        .ts_enum => |e| push(a, scope, e.id.litText(source), out),
        .ts_namespace => |n| push(a, scope, n.id.litText(source), out),
        // `export const x = 1` : c'est la déclaration interne qui lie.
        .export_named_declaration => |e| if (e.declaration) |d| collectDeclared(a, d, source, scope, out),
        // `import … from` : les specifiers lient des noms locaux (des alias).
        .import_declaration => |d| for (d.specifiers) |s| switch (s.kind) {
            .import_default_specifier => |x| push(a, scope, x.local.litText(source), out),
            .import_namespace_specifier => |x| push(a, scope, x.local.litText(source), out),
            .import_specifier => |x| push(a, scope, x.local.litText(source), out),
            else => {},
        },
        else => {},
    }
}

fn push(a: Allocator, scope: *zc.semantic.Scope, name: []const u8, out: *std.ArrayList(*Binding)) void {
    if (scope.bindings.get(name)) |b| out.append(a, b) catch {};
}

fn patternNames(
    a: Allocator,
    node: *Node,
    source: []const u8,
    scope: *zc.semantic.Scope,
    out: *std.ArrayList(*Binding),
) void {
    switch (node.kind) {
        .identifier => push(a, scope, node.litText(source), out),
        .array_pattern => |x| for (x.elements) |el| {
            if (el) |e| patternNames(a, e, source, scope, out);
        },
        .object_pattern => |o| for (o.properties) |p| switch (p.kind) {
            .rest_element => |r| patternNames(a, r.argument, source, scope, out),
            .property => |pr| patternNames(a, pr.value, source, scope, out),
            else => {},
        },
        .assignment_pattern => |x| patternNames(a, x.left, source, scope, out),
        .rest_element => |r| patternNames(a, r.argument, source, scope, out),
        .ts_typed => |t| patternNames(a, t.binding, source, scope, out),
        else => {},
    }
}

const UseCollector = struct {
    a: Allocator,
    sem: *zc.semantic.Semantic,
    scope: *zc.semantic.Scope,
    declared: *std.AutoHashMapUnmanaged(*Binding, void),
    seen: *std.AutoHashMapUnmanaged(*Binding, void),
    out: *std.ArrayList(*Binding),

    fn enter(self: *UseCollector, node: *Node) ?*Node {
        // `node_binding` associe CHAQUE nœud identifiant (déclaration ou
        // référence) à son binding : c'est la table que le mangler utilise pour
        // renommer, et elle sert ici à savoir qui touche quoi.
        const b = self.sem.node_binding.get(node) orelse return null;
        if (self.declared.contains(b)) return null; // se déclarer n'est pas s'utiliser
        if (!isModuleScope(self.scope, b)) return null; // un local de fonction : hors sujet
        if ((self.seen.getOrPut(self.a, b) catch return null).found_existing) return null;
        self.out.append(self.a, b) catch {};
        return null;
    }
};

fn useThunk(ctx: *anyopaque, node: *Node) ?*Node {
    const c: *UseCollector = @ptrCast(@alignCast(ctx));
    return c.enter(node);
}

fn isModuleScope(scope: *zc.semantic.Scope, b: *Binding) bool {
    var it = scope.bindings.valueIterator();
    while (it.next()) |x| if (x.* == b) return true;
    return false;
}

// ---- la pureté ----

/// Un statement top-level peut-il disparaître sans rien changer d'observable ?
///
/// PURS : les déclarations de fonction/classe (le corps n'est pas évalué), les
/// `const/let/var` dont TOUS les initialiseurs sont purs, les déclarations de
/// module (`import`, `export`), les types TS (déjà effacés à ce stade).
///
/// IMPURS (donc racines) : tout le reste. Notamment tout appel (`f()`, `new X()`,
/// une IIFE, un tagged template), toute mutation (`x.y = …`, `x++`), et tout
/// accès membre (`obj.prop` peut déclencher un **getter**).
pub fn isPureTopLevel(stmt: *Node, source: []const u8) bool {
    return switch (stmt.kind) {
        // Une fonction déclarée n'exécute rien tant qu'on ne l'appelle pas.
        .function_declaration => true,
        .class_declaration => |c| isPureClass(c, source),
        .variable_declaration => |d| {
            for (d.declarations) |v| {
                const init = v.kind.variable_declarator.init orelse continue;
                if (!isPureExpr(init, source)) return false;
            }
            return true;
        },
        // Déclarations de module : elles ne calculent rien par elles-mêmes.
        // (Le module CIBLE, lui, a ses propres unités impures — c'est là que
        // vivent ses effets de bord.)
        .import_declaration, .export_all_declaration => true,
        .export_named_declaration => |e| if (e.declaration) |d| isPureTopLevel(d, source) else true,
        .export_default_declaration => |d| isPureExpr(d.declaration, source),
        // TS : effacé avant d'arriver ici (le graphe normalise en JS pur), mais
        // par sécurité, un type ne s'évalue pas.
        .ts_type_alias, .ts_interface => true,
        // DANS LE DOUTE : IMPUR. Un `console.log(…)`, un `f()`, un `x.y = 1`,
        // une boucle, un `if`, un `throw` — tout ça s'exécute à l'import.
        else => false,
    };
}

/// Une expression peut-elle être évaluée sans effet observable ?
pub fn isPureExpr(node: *Node, source: []const u8) bool {
    return switch (node.kind) {
        // Littéraux et identifiants : lire une variable est inerte.
        .number_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regex_literal,
        .identifier,
        .this_expression,
        => true,
        // Une fonction n'exécute son corps qu'à l'appel.
        .function_expression, .arrow_function => true,
        .class_expression => |c| isPureClass(c, source),
        .array_expression => |x| {
            for (x.elements) |el| if (el) |e| {
                if (!isPureExpr(e, source)) return false;
            };
            return true;
        },
        .object_expression => |o| {
            for (o.properties) |p| if (!isPureProperty(p, source)) return false;
            return true;
        },
        .spread_element => |s| isPureExpr(s.argument, source),
        .template_literal => |t| {
            for (t.expressions) |e| if (!isPureExpr(e, source)) return false;
            return true;
        },
        .sequence_expression => |s| {
            for (s.expressions) |e| if (!isPureExpr(e, source)) return false;
            return true;
        },
        .binary_expression => |b| isPureExpr(b.left, source) and isPureExpr(b.right, source),
        .conditional_expression => |c| isPureExpr(c.@"test", source) and
            isPureExpr(c.consequent, source) and isPureExpr(c.alternate, source),
        // `typeof x`, `!x`, `-x`, `void x` : inertes. `delete x.y` : une MUTATION.
        .unary_expression => |u| u.operator != .delete_ and isPureExpr(u.operand, source),
        // Un APPEL peut tout faire — sauf s'il porte l'annotation `/* @__PURE__ */`.
        .call_expression, .new_expression => hasPureAnnotation(source, node.start),
        // `x.y` : `y` peut être un GETTER, donc un appel déguisé. Conservateur.
        // (Rollup fait le même choix hors « known globals ».)
        .member_expression => false,
        // Mutations, appels déguisés, attente : impurs par nature.
        .assignment_expression,
        .update_expression,
        .await_expression,
        .yield_expression,
        .tagged_template_expression,
        => false,
        else => false, // dans le doute
    };
}

fn isPureProperty(p: *Node, source: []const u8) bool {
    return switch (p.kind) {
        .property => |pr| {
            // Une clé calculée s'évalue : `{ [f()]: 1 }` n'est pas pur.
            if (pr.computed and !isPureExpr(pr.key, source)) return false;
            return isPureExpr(pr.value, source);
        },
        .spread_element => |s| isPureExpr(s.argument, source),
        // Un getter/setter défini ici ne s'exécute pas à la construction.
        .method_definition => true,
        else => false,
    };
}

/// Une classe est pure si son évaluation (pas son instanciation) est inerte :
/// une superclasse qui s'évalue sans effet, et aucun champ statique impur —
/// les champs statiques, eux, SONT exécutés à la définition de la classe.
fn isPureClass(c: zc.ast.Node.Class, source: []const u8) bool {
    if (c.superclass) |s| {
        // `extends Base` (un identifiant) : inerte. `extends getBase()` : non.
        if (!isPureExpr(s, source)) return false;
    }
    if (c.body.kind != .class_body) return true;
    for (c.body.kind.class_body.members) |m| switch (m.kind) {
        .property_definition => |p| {
            if (!p.static) continue; // un champ d'instance s'évalue à `new`, pas ici
            if (p.computed and !isPureExpr(p.key, source)) return false;
            if (p.value) |v| if (!isPureExpr(v, source)) return false;
        },
        .method_definition => |mm| {
            if (mm.computed and !isPureExpr(mm.key, source)) return false;
        },
        else => {},
    };
    return true;
}

/// L'annotation `/* @__PURE__ */` (ou `/* #__PURE__ */`) juste avant `start`.
///
/// C'est la convention rollup/terser : elle promet qu'un appel n'a pas d'effet,
/// donc qu'il est supprimable s'il n'est pas utilisé. Le lexer de zcompiler
/// **jette les commentaires** — mais l'annotation est POSITIONNELLE, et les
/// nœuds portent leur span exact : on relit le source juste avant l'appel. Rien
/// à ajouter au compilateur, et zéro coût quand il n'y a pas d'annotation (on
/// ne recule que sur des blancs).
pub fn hasPureAnnotation(source: []const u8, start: u32) bool {
    var i: usize = start;
    // Reculer sur les blancs.
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    // Le commentaire doit se terminer juste là.
    if (i < 2 or !std.mem.eql(u8, source[i - 2 .. i], "*/")) return false;
    const open = std.mem.lastIndexOf(u8, source[0 .. i - 2], "/*") orelse return false;
    const inside = source[open + 2 .. i - 2];
    return std.mem.indexOf(u8, inside, "@__PURE__") != null or
        std.mem.indexOf(u8, inside, "#__PURE__") != null;
}

// ------------------------------------------------------------------ tests

/// Analyse un source et rend ses unités (arène libérée par l'appelant).
const Probe = struct {
    arena: std.heap.ArenaAllocator,
    list: []Unit,
    src: []const u8,

    fn deinit(self: *Probe) void {
        self.arena.deinit();
    }
    /// L'unité qui déclare `name`.
    fn declaring(self: *Probe, name: []const u8) ?Unit {
        for (self.list) |u| {
            for (u.declares) |b| if (std.mem.eql(u8, b.name, name)) return u;
        }
        return null;
    }
};

fn probe(gpa: Allocator, src: []const u8) !Probe {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const program = (try zc.parser.parse(a, src)).program;
    const sem = zc.semantic.analyze(a, program, src);
    // En deux temps : sinon l'arène est copiée dans le slot de retour avant que
    // `units` n'alloue dedans (fuite).
    const list = try units(a, program, src, sem);
    return .{ .arena = arena, .list = list, .src = src };
}

fn expectPure(gpa: Allocator, src: []const u8, want: bool) !void {
    var p = try probe(gpa, src);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.list.len);
    if (p.list[0].pure != want) {
        std.debug.print("\npureté inattendue pour: {s}\n  attendu {}, obtenu {}\n", .{ src, want, p.list[0].pure });
        return error.WrongPurity;
    }
}

test "pur : les declarations qui n'evaluent rien" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "function f() { console.log('bruyant'); }", true); // le corps n'est pas evalue
    try expectPure(gpa, "class C { m() { alert(1); } }", true);
    try expectPure(gpa, "const x = 1;", true);
    try expectPure(gpa, "const s = 'a' + 'b';", true);
    try expectPure(gpa, "let f = () => sideEffect();", true); // arrow non appelee
    try expectPure(gpa, "var o = { a: 1, b: [2, 3], c: { d: 4 } };", true);
    try expectPure(gpa, "const t = `x${1 + 2}y`;", true);
    try expectPure(gpa, "const a = b;", true);
    try expectPure(gpa, "const n = -1, m = !flag, t2 = typeof x;", true);
    try expectPure(gpa, "const c = cond ? 1 : 2;", true);
    try expectPure(gpa, "import { x } from './m';", true);
    try expectPure(gpa, "export const e = 1;", true);
}

test "impur : tout appel, toute mutation — DANS LE DOUTE, IMPUR" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "console.log('hello');", false);
    try expectPure(gpa, "const x = compute();", false);
    try expectPure(gpa, "const x = new Thing();", false);
    try expectPure(gpa, "(function () { boot(); })();", false); // IIFE
    try expectPure(gpa, "const t = tag`template`;", false);
    try expectPure(gpa, "globalThis.patched = true;", false);
    try expectPure(gpa, "counter++;", false);
    try expectPure(gpa, "const x = { [compute()]: 1 };", false); // cle calculee impure
    try expectPure(gpa, "const x = [1, compute()];", false);
    try expectPure(gpa, "const d = delete obj.prop;", false); // mutation
    try expectPure(gpa, "if (flag) { run(); }", false);
    try expectPure(gpa, "for (const x of xs) { run(x); }", false);
    try expectPure(gpa, "throw new Error('boom');", false);
    try expectPure(gpa, "const t = `x${compute()}y`;", false);
}

test "le piege du getter : un acces membre est IMPUR (getter potentiel)" {
    const gpa = std.testing.allocator;
    // `obj.prop` peut declencher un getter arbitraire : on ne peut pas savoir.
    try expectPure(gpa, "const config = obj.prop;", false);
    try expectPure(gpa, "const deep = a.b.c;", false);
    try expectPure(gpa, "export default obj.prop;", false);
}

test "classes : superclasse et champs statiques decident" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "class A extends Base {}", true); // lire un identifiant
    try expectPure(gpa, "class A extends getBase() {}", false); // un appel
    try expectPure(gpa, "class A { static x = 1; }", true);
    try expectPure(gpa, "class A { static x = compute(); }", false); // execute a la definition
    try expectPure(gpa, "class A { x = compute(); }", true); // champ d'INSTANCE : a `new`, pas ici
    try expectPure(gpa, "class A { static m() { boot(); } }", true); // methode non appelee
}

test "/* @__PURE__ */ rend un appel supprimable" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "const x = /* @__PURE__ */ compute();", true);
    try expectPure(gpa, "const x = /* #__PURE__ */ compute();", true); // l'autre orthographe
    try expectPure(gpa, "const x = /*@__PURE__*/ compute();", true); // sans espaces
    try expectPure(gpa, "const x = /* @__PURE__ */\n  compute();", true); // saut de ligne
    // Un commentaire quelconque ne promet rien.
    try expectPure(gpa, "const x = /* juste un commentaire */ compute();", false);
    // L'annotation ne vaut que pour l'appel qu'elle PRECEDE.
    try expectPure(gpa, "const x = /* @__PURE__ */ a(), y = b();", false);
}

test "declares : les noms lies par chaque statement" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "const { a, b: [c] } = obj; function f() {} class K {} import d from './m';");
    defer p.deinit();
    for ([_][]const u8{ "a", "c", "f", "K", "d" }) |name| {
        if (p.declaring(name) == null) {
            std.debug.print("\nbinding non declare: {s}\n", .{name});
            return error.MissingDeclaration;
        }
    }
    // `const { a, b: [c] }` est UNE unite qui declare DEUX bindings : la
    // granularite v0.3 est le statement, les deux vivent ou meurent ensemble.
    try std.testing.expectEqual(@as(usize, 2), p.declaring("a").?.declares.len);
}

test "uses : les references vers le scope module, pas les locaux" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa,
        \\const dep = 1;
        \\function user() { const local = 2; return dep + local; }
    );
    defer p.deinit();
    const u = p.declaring("user").?;
    try std.testing.expectEqual(@as(usize, 1), u.uses.len);
    try std.testing.expectEqualStrings("dep", u.uses[0].name);
}

test "uses : se declarer n'est pas s'utiliser (pas d'auto-vie)" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "const x = 1;");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.list[0].uses.len);
}

test "uses : la recursion ne cree pas de fausse dependance" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }");
    defer p.deinit();
    // `fact` se reference lui-meme : il DECLARE ce nom, donc ce n'est pas un `use`.
    try std.testing.expectEqual(@as(usize, 0), p.declaring("fact").?.uses.len);
}
