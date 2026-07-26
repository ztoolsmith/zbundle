//! TREE-SHAKING, the "analysis" half: cutting a module into **units** (its
//! top-level statements) and deciding, for each one, whether it is PURE.
//!
//! This file only ever knows ONE module at a time — not the graph, not the other
//! modules, not the linker. That is deliberate: purity is a local property, and
//! it makes all of this logic testable without touching the disk. Cross-module
//! marking (which needs import chains) lives in `linker.zig`.
//!
//! ## The purity rule, in one sentence
//!
//!   > **When in doubt: IMPURE.**
//!
//! A bundle 5 % larger is one bug fewer. A statement wrongly judged pure
//! disappears, and with it a side effect the program expected — exactly the kind
//! of bug you only find in production. So: anything not manifestly inert is
//! treated as a root.
//!
//! ## Granularity: THE TOP-LEVEL STATEMENT
//!
//! A declaration lives or dies as a whole. `const { a, b } = x` where only `a` is
//! used keeps both. No intra-statement splitting, no object-property
//! elimination. That is rollup's baseline, and it is already where most of the
//! gain is (barrels).

const std = @import("std");
const zc = @import("zcompiler");

const Allocator = std.mem.Allocator;
const Node = zc.Node;
const Binding = zc.semantic.Binding;

/// A tree-shaking **unit**: a top-level statement, with what it declares, what it
/// uses, and whether it can be removed without changing anything observable.
pub const Unit = struct {
    stmt: *Node,
    /// The module-scope bindings this statement declares.
    declares: []const *Binding,
    /// The module-scope bindings it references, excluding those it declares.
    uses: []const *Binding,
    /// No side effect observable when the module is evaluated.
    pure: bool,
    /// Marked live by the mark phase (see `linker.zig`).
    alive: bool = false,
};

/// Cuts `program` into units. `sem` must be the analysis OF THAT program.
pub fn units(a: Allocator, program: *Node, source: []const u8, sem: *zc.semantic.Semantic) Allocator.Error![]Unit {
    const scope = sem.scopes.items[0]; // the module scope
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

/// The module-scope bindings declared by a top-level statement.
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
        // `export const x = 1`: the inner declaration is what binds.
        .export_named_declaration => |e| if (e.declaration) |d| collectDeclared(a, d, source, scope, out),
        // `import … from`: specifiers bind local names (aliases).
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
        // `node_binding` maps EVERY identifier node (declaration or reference)
        // to its binding: it is the table the mangler uses to rename, and here it
        // tells us who touches what.
        const b = self.sem.node_binding.get(node) orelse return null;
        if (self.declared.contains(b)) return null; // declaring is not using
        if (!isModuleScope(self.scope, b)) return null; // a function local: not our concern
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

// ---- purity ----

/// Can a top-level statement disappear without changing anything observable?
///
/// PURE: function/class declarations (the body is not evaluated), `const/let/var`
/// whose initializers are ALL pure, module declarations (`import`, `export`), TS
/// types (already erased by this point).
///
/// IMPURE (hence roots): everything else. Notably any call (`f()`, `new X()`, an
/// IIFE, a tagged template), any mutation (`x.y = …`, `x++`), and any member
/// access (`obj.prop` may trigger a **getter**).
pub fn isPureTopLevel(stmt: *Node, source: []const u8) bool {
    return switch (stmt.kind) {
        // A declared function runs nothing until it is called.
        .function_declaration => true,
        .class_declaration => |c| isPureClass(c, source),
        .variable_declaration => |d| {
            for (d.declarations) |v| {
                const init = v.kind.variable_declarator.init orelse continue;
                if (!isPureExpr(init, source)) return false;
            }
            return true;
        },
        // Module declarations: they compute nothing by themselves. (The TARGET
        // module has its own impure units — that is where its side effects live.)
        .import_declaration, .export_all_declaration => true,
        .export_named_declaration => |e| if (e.declaration) |d| isPureTopLevel(d, source) else true,
        .export_default_declaration => |d| isPureExpr(d.declaration, source),
        // TS: erased before reaching here (the graph normalizes to plain JS), but
        // for safety: a type does not evaluate.
        .ts_type_alias, .ts_interface => true,
        // WHEN IN DOUBT: IMPURE. A `console.log(…)`, an `f()`, an `x.y = 1`, a
        // loop, an `if`, a `throw` — all of it runs on import.
        else => false,
    };
}

/// Can an expression be evaluated without an observable effect?
pub fn isPureExpr(node: *Node, source: []const u8) bool {
    return switch (node.kind) {
        // Literals and identifiers: reading a variable is inert.
        .number_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regex_literal,
        .identifier,
        .this_expression,
        => true,
        // A function only runs its body when called.
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
        // `typeof x`, `!x`, `-x`, `void x`: inert. `delete x.y`: a MUTATION.
        .unary_expression => |u| u.operator != .delete_ and isPureExpr(u.operand, source),
        // A CALL can do anything — unless it carries the `/* @__PURE__ */` annotation.
        .call_expression, .new_expression => hasPureAnnotation(source, node.start),
        // `x.y`: `y` may be a GETTER, so a disguised call. Conservative.
        // (Rollup makes the same choice outside its "known globals".)
        .member_expression => false,
        // Mutations, disguised calls, awaiting: impure by nature.
        .assignment_expression,
        .update_expression,
        .await_expression,
        .yield_expression,
        .tagged_template_expression,
        => false,
        else => false, // when in doubt
    };
}

fn isPureProperty(p: *Node, source: []const u8) bool {
    return switch (p.kind) {
        .property => |pr| {
            // A computed key evaluates: `{ [f()]: 1 }` is not pure.
            if (pr.computed and !isPureExpr(pr.key, source)) return false;
            return isPureExpr(pr.value, source);
        },
        .spread_element => |s| isPureExpr(s.argument, source),
        // A getter/setter defined here does not run at construction time.
        .method_definition => true,
        else => false,
    };
}

/// A class is pure if its evaluation (not its instantiation) is inert: a
/// superclass that evaluates without effect, and no impure static field — static
/// fields ARE executed when the class is defined.
fn isPureClass(c: zc.ast.Node.Class, source: []const u8) bool {
    if (c.superclass) |s| {
        // `extends Base` (an identifier): inert. `extends getBase()`: not.
        if (!isPureExpr(s, source)) return false;
    }
    if (c.body.kind != .class_body) return true;
    for (c.body.kind.class_body.members) |m| switch (m.kind) {
        .property_definition => |p| {
            if (!p.static) continue; // an instance field evaluates at `new`, not here
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
/// This is the rollup/terser convention: it promises a call has no effect, and
/// is therefore removable when unused. zcompiler's lexer **discards comments** —
/// but the annotation is POSITIONAL, and nodes carry their exact span: we re-read
/// the source right before the call. Nothing to add to the compiler, and zero
/// cost when there is no annotation (we only walk back over whitespace).
pub fn hasPureAnnotation(source: []const u8, start: u32) bool {
    var i: usize = start;
    // Walk back over whitespace.
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    // The comment must end right there.
    if (i < 2 or !std.mem.eql(u8, source[i - 2 .. i], "*/")) return false;
    const open = std.mem.lastIndexOf(u8, source[0 .. i - 2], "/*") orelse return false;
    const inside = source[open + 2 .. i - 2];
    return std.mem.indexOf(u8, inside, "@__PURE__") != null or
        std.mem.indexOf(u8, inside, "#__PURE__") != null;
}

// ------------------------------------------------------------------ tests

/// Analyses a source and returns its units (arena freed by the caller).
const Probe = struct {
    arena: std.heap.ArenaAllocator,
    list: []Unit,
    src: []const u8,

    fn deinit(self: *Probe) void {
        self.arena.deinit();
    }
    /// The unit that declares `name`.
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
    // In two steps: otherwise the arena is copied into the return slot before
    // `units` allocates into it (a leak).
    const list = try units(a, program, src, sem);
    return .{ .arena = arena, .list = list, .src = src };
}

fn expectPure(gpa: Allocator, src: []const u8, want: bool) !void {
    var p = try probe(gpa, src);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.list.len);
    if (p.list[0].pure != want) {
        std.debug.print("\nunexpected purity for: {s}\n  expected {}, got {}\n", .{ src, want, p.list[0].pure });
        return error.WrongPurity;
    }
}

test "pure: declarations that evaluate nothing" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "function f() { console.log('bruyant'); }", true); // the body is not evaluated
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

test "impure: any call, any mutation — WHEN IN DOUBT, IMPURE" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "console.log('hello');", false);
    try expectPure(gpa, "const x = compute();", false);
    try expectPure(gpa, "const x = new Thing();", false);
    try expectPure(gpa, "(function () { boot(); })();", false); // IIFE
    try expectPure(gpa, "const t = tag`template`;", false);
    try expectPure(gpa, "globalThis.patched = true;", false);
    try expectPure(gpa, "counter++;", false);
    try expectPure(gpa, "const x = { [compute()]: 1 };", false); // impure computed key
    try expectPure(gpa, "const x = [1, compute()];", false);
    try expectPure(gpa, "const d = delete obj.prop;", false); // mutation
    try expectPure(gpa, "if (flag) { run(); }", false);
    try expectPure(gpa, "for (const x of xs) { run(x); }", false);
    try expectPure(gpa, "throw new Error('boom');", false);
    try expectPure(gpa, "const t = `x${compute()}y`;", false);
}

test "the getter trap: a member access is IMPURE (potential getter)" {
    const gpa = std.testing.allocator;
    // `obj.prop` may trigger an arbitrary getter: we cannot know.
    try expectPure(gpa, "const config = obj.prop;", false);
    try expectPure(gpa, "const deep = a.b.c;", false);
    try expectPure(gpa, "export default obj.prop;", false);
}

test "classes: superclass and static fields decide" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "class A extends Base {}", true); // reading an identifier
    try expectPure(gpa, "class A extends getBase() {}", false); // a call
    try expectPure(gpa, "class A { static x = 1; }", true);
    try expectPure(gpa, "class A { static x = compute(); }", false); // runs when the class is defined
    try expectPure(gpa, "class A { x = compute(); }", true); // an INSTANCE field: at `new`, not here
    try expectPure(gpa, "class A { static m() { boot(); } }", true); // method never called
}

test "/* @__PURE__ */ makes a call removable" {
    const gpa = std.testing.allocator;
    try expectPure(gpa, "const x = /* @__PURE__ */ compute();", true);
    try expectPure(gpa, "const x = /* #__PURE__ */ compute();", true); // the other spelling
    try expectPure(gpa, "const x = /*@__PURE__*/ compute();", true); // without spaces
    try expectPure(gpa, "const x = /* @__PURE__ */\n  compute();", true); // newline
    // An arbitrary comment promises nothing.
    try expectPure(gpa, "const x = /* juste un commentaire */ compute();", false);
    // The annotation only applies to the call it PRECEDES.
    try expectPure(gpa, "const x = /* @__PURE__ */ a(), y = b();", false);
}

test "declares: the names bound by each statement" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "const { a, b: [c] } = obj; function f() {} class K {} import d from './m';");
    defer p.deinit();
    for ([_][]const u8{ "a", "c", "f", "K", "d" }) |name| {
        if (p.declaring(name) == null) {
            std.debug.print("\nundeclared binding: {s}\n", .{name});
            return error.MissingDeclaration;
        }
    }
    // `const { a, b: [c] }` is ONE unit declaring TWO bindings: granularity is
    // the statement, so both live or die together.
    try std.testing.expectEqual(@as(usize, 2), p.declaring("a").?.declares.len);
}

test "uses: references to module scope, not to locals" {
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

test "uses: declaring is not using (no self-liveness)" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "const x = 1;");
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 0), p.list[0].uses.len);
}

test "uses: recursion does not create a false dependency" {
    const gpa = std.testing.allocator;
    var p = try probe(gpa, "function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }");
    defer p.deinit();
    // `fact` references itself: it DECLARES that name, so it is not a `use`.
    try std.testing.expectEqual(@as(usize, 0), p.declaring("fact").?.uses.len);
}
