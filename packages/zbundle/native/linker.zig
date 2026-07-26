//! The LINKER: N modules -> ONE executable JS file.
//!
//! The graph said WHO depends on WHOM; here we merge. The strategy is
//! rollup/rolldown's — **scope hoisting**:
//!
//!   > every module is concatenated into a SINGLE scope, and name collisions are
//!   > resolved by RENAMING.
//!
//! No function wrappers (`__webpack_require__(id)`), no runtime module registry:
//! the output is flat, readable JS that the engine optimizes like hand-written
//! code. This is possible because zcompiler already knows, for each module, its
//! top-level bindings, where all their references are, and how to rewrite a name
//! (`synthetic_text`) — the mangler did exactly that at the scale of ONE file.
//! The linker does the same thing at the scale of the whole program.
//!
//! ## The chain, from reference to final name
//!
//!     reference to `a` in m.js
//!       → binding local `a` de m (kind = .import_)
//!         → ImportEntry { specifier: './x', imported: 'a' }
//!           → module x, ExportEntry { exported: 'a', … }
//!             -> (.local)      x's local binding -> its FINAL NAME
//!             -> (.re_export)  start again at x's source
//!             -> (.star_as)    the materialized namespace object
//!
//! The neat part: there is **nothing to rewrite inside module bodies**. It is
//! enough to set `new_name` on the imported binding — since all its references
//! go through it, `applyRenames` updates them all at once. An `import` literally
//! becomes a **name alias**.
//!
//! ## What the linker REFUSES (rather than emit a wrong bundle)
//!
//! Every refusal is verified and carries a message that says what to do. See
//! `check`.

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

/// The format of the produced file.
pub const Format = enum {
    /// ES module: externals stay as `import`s at the top, the entry's exports
    /// come out as `export { … }`. The default, and the only composable one.
    esm,
    /// An IIFE: everything is wrapped in `(() => { … })()`, nothing leaks into
    /// the global scope. The format for a `<script>` or a standalone artifact.
    /// **Requires zero externals**: an `import` is illegal inside a function.
    iife,
};

pub const Options = struct { format: Format = .esm };

pub const Stats = struct {
    /// Modules actually EMITTED (after shaking).
    modules: u32,
    /// Number of entry exports (0 in `iife`: an IIFE exports nothing).
    entry_exports: u32,
    /// Graph modules of which nothing survived.
    modules_dropped: u32,
    externals: u32,
    /// Bindings that had to be renamed to avoid a collision.
    renamed: u32,
    /// Top-level statements kept / eliminated by tree-shaking.
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

/// A statement eliminated by tree-shaking, with enough to find it again.
/// Used by `inspect.mjs --dead`: understanding the shaking by eye, and debugging
/// the day something disappears wrongly.
pub const Dead = struct {
    module: []const u8,
    /// Line in the original module (1-indexed).
    line: u32,
    /// The eliminated code, truncated onto a single line.
    snippet: []const u8,
    /// Why it died.
    reason: []const u8,
};

pub const Report = struct {
    code: []const u8,
    stats: Stats,
    dead: []const Dead,
};

/// A module, with everything the linker learned about it.
const Mod = struct {
    id: ModuleId,
    path: []const u8,
    source: []const u8,
    program: *zc.Node,
    sem: *zc.semantic.Semantic,
    info: zc.semantic.ModuleInfo,
    /// The top-level statements, cut into tree-shaking units.
    units: []shake.Unit = &.{},
    /// The final name of the binding synthesized for `export default <expression>`.
    default_name: ?[]const u8 = null,
    /// Final name of THIS module's namespace object, if one is needed.
    namespace_name: ?[]const u8 = null,
};

/// An external import, after deduplication. Two modules importing `react`
/// produce only ONE import line at the top of the bundle.
const ExternalImport = struct {
    specifier: []const u8,
    /// name imported from the external ("default" / "*" / a name) -> local final name
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
};

const Linker = struct {
    a: Allocator,
    err: *BundleError,
    g: graph.Graph,
    mods: []Mod,
    /// EMISSION order (post-order DFS from the entry): dependencies first.
    order: std.ArrayList(ModuleId) = .empty,
    /// Every name already taken in the bundle's scope.
    used: std.StringHashMapUnmanaged(void) = .empty,
    externals: std.ArrayList(ExternalImport) = .empty,
    by_specifier: std.StringHashMapUnmanaged(u32) = .empty,
    renamed: u32 = 0,

    // --- mark-phase state ---
    /// The bindings reachable from the roots.
    live: std.AutoHashMapUnmanaged(*zc.semantic.Binding, void) = .empty,
    /// Fixed-point work queue.
    queue: std.ArrayList(BindingRef) = .empty,
    /// Per module: binding -> index of the unit that declares it.
    decl_unit: []std.AutoHashMapUnmanaged(*zc.semantic.Binding, u32) = &.{},
    /// Per module: import binding -> its `ImportEntry` (to follow the chain).
    import_of: []std.AutoHashMapUnmanaged(*zc.semantic.Binding, zc.semantic.ImportEntry) = &.{},
    /// Shaking statistics.
    units_total: u32 = 0,
    units_alive: u32 = 0,
    opts: Options = .{},
    entry_exports: u32 = 0,

    fn fail(self: *Linker, comptime fmt: []const u8, args: anytype) Error {
        self.err.message = std.fmt.allocPrint(self.a, fmt, args) catch "bundle failed";
        return error.BundleFailed;
    }

    /// The target module of a specifier from `from`, or null when external.
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

    // ---- 1. emission order ----

    /// Post-order DFS from the entry: a module is emitted AFTER all of its
    /// dependencies. Iterative (a real codebase has chains of hundreds of
    /// modules — same reason as graph.zig's Tarjan).
    ///
    /// **Cycles**: an edge returning to a module currently being visited is
    /// simply ignored, so cycle members come out in first-visit order. That is
    /// rollup's approximation. It is WRONG for pathological inter-cycle TDZ
    /// cases (a module that READS at top level a `const` from a module of the
    /// same cycle emitted after it) — accepted and documented: real code does
    /// not live there, and rollup does no better.
    fn computeOrder(self: *Linker) Error!void {
        const n = self.mods.len;
        const State = enum { white, gray, black };
        const state = try self.a.alloc(State, n);
        @memset(state, .white);

        // Outgoing edges (indices into g.edges) per module, in source order.
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
                continue; // .gray = back edge (cycle); .black = already emitted
            }
            state[top.m] = .black;
            try self.order.append(self.a, top.m);
            _ = stack.pop();
        }

        // A module unreachable from the entry should not exist (the graph starts
        // at the entry), but we never lose anything silently.
        for (0..n) |i| if (state[i] != .black) {
            try self.order.append(self.a, @intCast(i));
        };
    }

    /// For each module, its INTERNAL dependencies, in source order, without
    /// duplicates (the diamond visits `d` only once).
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

    // ---- 2. refusals (before any work: a clear message, not a wrong bundle) ----

    fn check(self: *Linker) Error!void {
        for (self.mods) |m| {
            const rel = self.display(m.path);
            if (m.info.has_top_level_await) {
                return self.fail(
                    "top-level await is not supported ({s})\n" ++
                        "  Scope hoisting merges every module into a single scope: a top-level\n" ++
                        "  `await` would make the whole bundle asynchronous. Move it inside an\n" ++
                        "  async function.",
                    .{rel},
                );
            }
            if (m.info.has_import_meta) {
                return self.fail(
                    "import.meta is not supported ({s})\n" ++
                        "  Its value depends on the module URL, which no longer exists once the\n" ++
                        "  modules are merged into a single file.",
                    .{rel},
                );
            }
        }
        // `import()` of an INTERNAL module: that would be a separate chunk.
        for (self.g.edges) |e| {
            if (!e.is_dynamic) continue;
            const to = e.to orelse continue; // dynamic toward an external: fine, re-emitted as is
            return self.fail(
                "dynamic import() of an internal module is not supported: '{s}'\n" ++
                    "  ({s} -> {s})\n" ++
                    "  An internal dynamic import needs a separate CHUNK: that is\n" ++
                    "  code-splitting, planned for later. Make the import static, or mark the\n" ++
                    "  target as external.",
                .{ e.specifier, self.display(self.mods[e.from].path), self.display(self.mods[to].path) },
            );
        }
    }

    /// THE case where scope hoisting CANNOT reproduce ESM semantics.
    ///
    /// A **live binding** (a reassigned `export let n`) works naturally when
    /// imported by name: after merging, the importer references THE SAME
    /// variable, so it sees the updates. Verified — and free.
    ///
    /// But a **namespace object** (`import * as ns`) is materialized once, at
    /// construction: `{ n: n }` freezes the VALUE. In native ESM, `ns.n` stays
    /// live. There, and only there, the bundle would lie — so we refuse.
    ///
    /// (Runs AFTER `linkImports`, once we know which namespaces exist.)
    fn checkNamespaceSnapshots(self: *Linker) Error!void {
        for (self.mods) |m| {
            if (m.namespace_name == null) continue;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            if (try self.findAssigned(m.id, &seen, 0)) |b| {
                return self.fail(
                    "live binding exposed through a namespace object: `{s}` in {s}\n" ++
                        "  `{s}` is REASSIGNED after initialization, and its module is imported\n" ++
                        "  with `import * as ns` (or re-exported as `export * as ns`). The\n" ++
                        "  namespace object is built ONCE: it would freeze the value, whereas in\n" ++
                        "  ESM `ns.{s}` stays live.\n" ++
                        "  Import the name directly (`import {{ {s} }} from …`) — there, scope\n" ++
                        "  hoisting preserves the live binding — or export an accessor function.",
                    .{ b.name, self.display(m.path), b.name, b.name, b.name },
                );
            }
        }
    }

    /// The first REASSIGNED binding reachable among a module's exports (its own
    /// and those of its `export *`).
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

    // ---- 3. name assignment ----

    /// A free name in the bundle's scope. `base` when available, otherwise
    /// `base$1`, `base$2`… (rollup's convention — readable, and `$` is legal).
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

    /// Reserves untouchable names: reserved words plus every UNRESOLVED name
    /// from every module (the globals — `console`, `process`, `Math`…). Without
    /// this, a local binding could be renamed to `console` and capture the
    /// global. Same guard as the mangler, at bundle scale.
    fn reserveNames(self: *Linker) Error!void {
        for (RESERVED) |kw| try self.used.put(self.a, kw, {});
        for (self.mods) |m| {
            var it = m.sem.unresolved.keyIterator();
            while (it.next()) |name| try self.used.put(self.a, name.*, {});
        }
    }

    /// Gives its final name to every top-level binding of every module, in
    /// emission order (the first ones keep their name: the bundle stays readable,
    /// and the entry — the part read most — is named last so it may get a suffix;
    /// that is rollup's trade-off).
    ///
    /// IMPORT bindings are skipped: they are aliases, and will receive their
    /// source's name during the resolution step.
    fn assignNames(self: *Linker) Error!void {
        for (self.order.items) |id| {
            const m = &self.mods[id];
            var list: std.ArrayList(*zc.semantic.Binding) = .empty;
            var it = m.info.module_scope.bindings.valueIterator();
            while (it.next()) |b| try list.append(self.a, b.*);
            // Declaration order: determinism (a map has no order).
            std.mem.sort(*zc.semantic.Binding, list.items, {}, byDecl);
            for (list.items) |b| {
                if (b.kind == .import_) continue; // alias: resolved later
                // A DEAD binding does not consume a name: otherwise an
                // eliminated `helper` would push another module's live `helper`
                // to `helper$1`, for nothing.
                if (!self.live.contains(b)) continue;
                const final = try self.unique(b.name);
                if (!std.mem.eql(u8, final, b.name)) b.new_name = final;
            }
            // `export default <expression>`: no binding, so we synthesize one.
            for (m.info.exports) |e| {
                if (e.kind != .default_expr) continue;
                if (!self.defaultAlive(m.id)) continue;
                m.default_name = try self.unique(try std.fmt.allocPrint(self.a, "{s}_default", .{self.stem(m.path)}));
            }
        }
    }

    /// A binding's final name: its `new_name` if renamed, otherwise its own.
    fn finalOf(_: *Linker, b: *zc.semantic.Binding) []const u8 {
        return b.currentName();
    }

    /// Did this module's `export default <expr>` unit survive?
    fn defaultAlive(self: *Linker, mod: ModuleId) bool {
        for (self.mods[mod].units) |u| {
            if (u.stmt.kind == .export_default_declaration and u.alive) return true;
        }
        return false;
    }

    // ---- 3b. THE MARK PHASE: what is REACHABLE? ----

    /// Marks everything that is live, by fixed point. Whatever stays dead is
    /// never emitted.
    ///
    /// **Les racines** (deux familles, et seulement deux) :
    ///   1. **Every IMPURE top-level statement of every module in the graph.** A
    ///      module present in the graph WILL be evaluated at runtime (ESM
    ///      evaluates each imported module): its side effects must survive, even
    ///      if nobody uses what it exports. That is what makes
    ///      `import './polyfill'` work.
    ///   2. **The ENTRY's exports.** That is the bundle's contract with the
    ///      outside world.
    ///
    /// **Propagation**: a live unit makes the bindings it uses live -> each live
    /// binding makes the unit declaring it live -> and around again. The body of
    /// a live function therefore pulls in what it touches, transitively.
    /// Explicit worklist, no recursion: lodash is 172 modules and thousands of
    /// units.
    ///
    /// **Import chains** are traversed by `resolveTarget`: importing `a` from
    /// `x` marks ONLY `x`'s `a` binding, not all of `x`. That is precisely where
    /// tree-shaking pays off on barrels.
    fn mark(self: *Linker) Error!void {
        // Index: which binding is declared by which unit (per module).
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

        // Root 1: the side effects of every module in the graph.
        for (self.mods, 0..) |*m, i| {
            for (m.units, 0..) |u, ui| {
                if (!u.pure) try self.markUnit(@intCast(i), @intCast(ui));
            }
        }
        // Root 2: what the entry exposes to the world.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        try self.exportNames(self.g.entry, &names, &seen, 0);
        for (names.items) |name| {
            if (try self.resolveTarget(self.g.entry, name, 0)) |t| try self.markTarget(t);
        }

        try self.drain();
    }

    /// Makes a unit live and queues its dependencies.
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
            // A live external: record that it will need importing (see `emit`).
            .external => |x| _ = try self.externalName(x.specifier, x.imported, x.kind),
        }
    }

    /// `export default <expression>` has no binding: we mark the statement
    /// carrying it directly.
    fn markDefaultUnit(self: *Linker, mod: ModuleId) Error!void {
        for (self.mods[mod].units, 0..) |u, ui| {
            if (u.stmt.kind == .export_default_declaration) try self.markUnit(mod, @intCast(ui));
        }
    }

    /// A namespace object exposes EVERYTHING: it makes every export of the
    /// module live. That is the price of an `import * as ns` — and the reason to
    /// import names one by one when you want shaking.
    fn markNamespace(self: *Linker, mod: ModuleId, depth: u32) Error!void {
        if (depth > 32) return;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        try self.exportNames(mod, &names, &seen, 0);
        for (names.items) |name| {
            if (try self.resolveTarget(mod, name, 0)) |t| {
                // No recursive `markTarget` on a nested namespace: bindings go
                // through the queue, and depth is bounded.
                switch (t) {
                    .namespace => |inner| if (inner != mod) try self.markNamespace(inner, depth + 1),
                    else => try self.markTarget(t),
                }
            }
        }
    }

    /// Drains the queue to the fixed point.
    fn drain(self: *Linker) Error!void {
        while (self.queue.pop()) |ref| {
            const gop = try self.live.getOrPut(self.a, ref.b);
            if (gop.found_existing) continue;

            // An IMPORT binding is an alias: what lives is its source.
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
            // A normal binding: the unit declaring it must live.
            if (self.decl_unit[ref.mod].get(ref.b)) |ui| try self.markUnit(ref.mod, ui);
        }
    }

    /// Every name exported by a module (its own plus those traversed through
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

    /// Does a module have at least one live unit? Otherwise it vanishes from the
    /// bundle — header comment included.
    fn moduleAlive(self: *Linker, mod: ModuleId) bool {
        for (self.mods[mod].units) |u| {
            if (u.alive) return true;
        }
        return false;
    }

    // ---- 4. import resolution (THE core) ----

    /// What an exported name REALLY designates, once the chain is followed.
    ///
    /// Structural, not textual: the mark phase needs to know WHICH binding is
    /// live, long before final names exist. `nameOf` derives the text from it at
    /// emission time.
    const Target = union(enum) {
        /// A real binding, in a given module.
        binding: struct { mod: ModuleId, b: *zc.semantic.Binding },
        /// The `const <mod>_default = …` synthesized for an `export default <expr>`.
        default_expr: ModuleId,
        /// A module's namespace object.
        namespace: ModuleId,
        /// A name coming from an external: the key (specifier, imported, kind).
        external: struct { specifier: []const u8, imported: []const u8, kind: zc.semantic.ImportKind },
    };

    /// Follows `mod`'s export chain for `name`. `null` = not exported.
    fn resolveTarget(self: *Linker, mod: ModuleId, name: []const u8, depth: u32) Error!?Target {
        if (depth > 32) return self.fail("re-export chain too deep for '{s}'", .{name});
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
        // `export * from './x'`: the name may come from one of the sources.
        for (m.info.star_exports) |spec| {
            if (self.isExternal(mod, spec)) continue; // impossible to enumerate
            const to = self.targetOf(mod, spec) orelse continue;
            if (try self.resolveTarget(to, name, depth + 1)) |hit| return hit;
        }
        return null;
    }

    /// A target's final name. Only called at emission, once all names are
    /// assigned.
    fn nameOf(self: *Linker, t: Target) Error![]const u8 {
        return switch (t) {
            .binding => |x| self.finalOf(x.b),
            .default_expr => |mod| self.mods[mod].default_name.?,
            .namespace => |mod| self.mods[mod].namespace_name.?,
            .external => |x| self.externalName(x.specifier, x.imported, x.kind),
        };
    }

    /// The final name, in the bundle, of `name` as exported by `mod`.
    fn resolveExport(self: *Linker, mod: ModuleId, name: []const u8, depth: u32) Error!?[]const u8 {
        const t = (try self.resolveTarget(mod, name, depth)) orelse return null;
        return try self.nameOf(t);
    }

    /// Every exported name of a module (its own plus those of its `export *`),
    /// with their final name. Used to materialize a namespace object.
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

    /// Resolves each import: the local binding receives its source's FINAL name.
    /// That is the whole of linking — after this, no `import` has any reason to
    /// exist.
    fn linkImports(self: *Linker) Error!void {
        // Namespaces first: an `import * as ns` must have its name before any
        // other module references it.
        // NO `moduleAlive` filter here: a PURE barrel (nothing but re-exports)
        // has no live unit — it emits nothing — yet its declarations still drive
        // RESOLUTION. Filtering happens on bindings (`live`) and on
        // `namespaceNeeded`, not on the module.
        for (self.order.items) |id| {
            for (self.mods[id].info.imports) |imp| {
                if (imp.kind != .namespace) continue;
                // A dead import materializes nothing.
                if (imp.binding) |b| if (!self.live.contains(b)) continue;
                if (self.isExternal(id, imp.specifier)) continue;
                const to = self.targetOf(id, imp.specifier) orelse continue;
                try self.ensureNamespace(to);
            }
            // `export * as ns from './x'` also materializes x's namespace.
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
                if (!self.live.contains(b)) continue; // dead import: nothing to link
                const final = try self.resolveImport(id, imp);
                // THE linker's move: the imported binding becomes an ALIAS of the
                // source name. All its references follow (via `applyRenames`).
                if (!std.mem.eql(u8, final, b.name)) b.new_name = final;
            }
        }
    }

    fn resolveImport(self: *Linker, from: ModuleId, imp: zc.semantic.ImportEntry) Error![]const u8 {
        if (self.isExternal(from, imp.specifier)) {
            return self.externalName(imp.specifier, imp.imported, imp.kind);
        }
        const to = self.targetOf(from, imp.specifier) orelse
            return self.fail("unresolved dependency '{s}' from {s}", .{ imp.specifier, self.display(self.mods[from].path) });
        switch (imp.kind) {
            .namespace => return self.mods[to].namespace_name.?,
            .default => return (try self.resolveExport(to, "default", 0)) orelse
                self.fail("{s} has no default export (imported by {s})", .{ self.display(self.mods[to].path), self.display(self.mods[from].path) }),
            .named => return (try self.resolveExport(to, imp.imported, 0)) orelse
                self.fail("{s} does not export '{s}' (imported by {s})", .{ self.display(self.mods[to].path), imp.imported, self.display(self.mods[from].path) }),
        }
    }

    /// Is a `export * as ns from './x'` of `mod` actually consumed? (Either
    /// because `mod` is the entry — it is then a public export — or because a
    /// live module imports that name.)
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

    /// The local name of a name imported from an external, deduplicated: two
    /// modules importing `useState` from `react` share the same one.
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

    // ---- 5. emission ----

    fn emit(self: *Linker, out: *std.ArrayList(u8)) Error!void {
        const iife = self.opts.format == .iife;
        try out.appendSlice(self.a, if (iife)
            "// Generated by zbundle — IIFE, single file.\n"
        else
            "// Generated by zbundle — ESM, single file.\n");

        // An IIFE CANNOT carry an `import`: an external module has nowhere to
        // go. We say so, rather than emit invalid JS.
        if (iife and self.externals.items.len > 0) {
            return self.fail(
                "--format iife is incompatible with external imports ({d})\n" ++
                    "  The first one: '{s}'. An IIFE wraps everything in a function, and an\n" ++
                    "  `import` is only legal at a module's top level.\n" ++
                    "  Use --format esm, or make those dependencies internal.",
                .{ self.externals.items.len, self.externals.items[0].specifier },
            );
        }

        // Externals AT THE TOP, deduplicated and merged.
        for (self.externals.items) |ext| try self.emitExternalImport(ext, out);
        if (self.externals.items.len > 0) try out.append(self.a, '\n');

        if (iife) try out.appendSlice(self.a, "(() => {\n");

        for (self.order.items) |id| {
            const m = &self.mods[id];
            // A module of which no unit survived disappears ENTIRELY, header
            // comment included: it has nothing left to say.
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
            // An IIFE exports nothing: we still count what is lost, so the
            // caller can report it.
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
        std.mem.sort(NamePair, named.items, {}, byExported); // determinism

        // `import * as ns` does not mix with other clauses: its own line.
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

    /// A module's body: every top-level statement, minus the module
    /// declarations. zcompiler's PRINTER does the rendering — the AST already
    /// carries the final names (`applyRenames` has run), so nothing to rewrite.
    fn emitModuleBody(self: *Linker, m: *Mod, out: *std.ArrayList(u8)) Error!void {
        for (m.units) |unit| {
            if (!unit.alive) continue; // the SWEEP: dead code is not emitted
            try self.emitStatement(m, unit.stmt, out);
        }
    }

    fn emitStatement(self: *Linker, m: *Mod, stmt: *zc.Node, out: *std.ArrayList(u8)) Error!void {
        switch (stmt.kind) {
            // Imports VANISH: they were only name aliases.
            .import_declaration => {},
            // `export * from` / `export * as ns from`: nothing to emit (the
            // export table and the namespace object handle it).
            .export_all_declaration => {},
            .export_named_declaration => |e| {
                // `export const x = 1` -> `const x = 1` (the keyword is dropped).
                if (e.declaration) |decl| try self.printStmt(m, decl, out);
                // `export { a }` / `export { a } from './x'`: nothing (table).
            },
            .export_default_declaration => {
                // `export default foo` (a binding): nothing to emit.
                // `export default <expr>`: bind the expression to the synthesized name.
                for (m.info.exports) |e| {
                    if (e.kind != .default_expr) continue;
                    try out.appendSlice(self.a, try std.fmt.allocPrint(self.a, "const {s} = ", .{m.default_name.?}));
                    zc.printer.printExpression(e.value.?, m.source, out, self.a) catch
                        return self.fail("cannot print the default export of {s}", .{self.display(m.path)});
                    try out.appendSlice(self.a, ";\n");
                }
            },
            else => try self.printStmt(m, stmt, out),
        }
    }

    fn printStmt(self: *Linker, m: *Mod, stmt: *zc.Node, out: *std.ArrayList(u8)) Error!void {
        zc.printer.printStatement(stmt, m.source, out, self.a) catch
            return self.fail("cannot print a statement of {s}", .{self.display(m.path)});
    }

    /// The namespace object: the ONLY materialization in linking.
    /// `import * as ns` wants a real object at runtime, so we build it from the
    /// final names.
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

    /// The ENTRY's exports: the bundle's only survivors.
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

    // ---- utilities ----

    /// The path relative to the entry's directory — readable in headers and
    /// error messages (a 120-character absolute path is not).
    fn display(self: *Linker, path: []const u8) []const u8 {
        const root = std.fs.path.dirname(self.mods[self.g.entry].path) orelse return path;
        if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep) {
            return path[root.len + 1 ..];
        }
        return path;
    }

    /// The file name without extension, cleaned up to serve as a JS identifier.
    fn stem(self: *Linker, path: []const u8) []const u8 {
        const base = std.fs.path.basename(path);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        return identifierFrom(self.a, base[0..dot]) catch "mod";
    }
};

const NamePair = struct { exported: []const u8, final: []const u8 };

/// A binding, located in its module (a bare `*Binding` does not say where it came from).
const BindingRef = struct { mod: ModuleId, b: *zc.semantic.Binding };

fn byExported(_: void, x: NamePair, y: NamePair) bool {
    return std.mem.order(u8, x.exported, y.exported) == .lt;
}

fn byDecl(_: void, x: *zc.semantic.Binding, y: *zc.semantic.Binding) bool {
    return x.decl_start < y.decl_start;
}

/// Turns arbitrary text into a valid JS identifier (`node:fs/promises` ->
/// `node_fs_promises`, `@scope/pkg` -> `scope_pkg`).
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

/// The (1-indexed) line of an offset in a source.
fn lineOf(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    const end = @min(offset, source.len);
    for (source[0..end]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// A statement's code, on one line, truncated — enough to recognize it.
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

/// Why this statement died.
fn reasonOf(a: Allocator, u: shake.Unit, whole_module: bool) Allocator.Error![]const u8 {
    if (whole_module) return "whole module eliminated (nothing reachable)";
    if (u.declares.len == 0) return "pure statement, no observable effect";
    var names: std.ArrayList(u8) = .empty;
    for (u.declares, 0..) |b, i| {
        if (i != 0) try names.appendSlice(a, ", ");
        try names.appendSlice(a, b.name);
    }
    return std.fmt.allocPrint(a, "no live reference to {s}", .{names.items});
}

/// A single-quoted JS string (specifiers do not contain quotes in practice; we
/// escape anyway).
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

/// Bundles `entry` into ONE executable JS file (ESM format).
pub fn bundle(a: Allocator, io: Io, entry: []const u8, err: *BundleError) Error!Bundle {
    const r = try bundleReport(a, io, entry, err, false, .{});
    return .{ .code = r.code, .stats = r.stats };
}

/// Same, but also collects what tree-shaking eliminated (when `with_dead`), and
/// accepts options (the output format).
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

    // Analysis of each module: scopes/bindings (renaming) plus the
    // imports/exports table (linking). Both come from zcompiler.
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
    // MARK before any naming: a dead binding must not consume a name (otherwise
    // an eliminated `helper` would push a live `helper` to `helper$1`).
    try l.mark();
    try l.reserveNames();
    try l.assignNames();
    try l.linkImports();
    try l.checkNamespaceSnapshots();

    // Final names are written onto the AST: a single pass per module, and every
    // reference (local AND imported) is up to date.
    for (mods) |m| zc.mangler.applyRenames(m.sem);

    var out: std.ArrayList(u8) = .empty;
    try l.emit(&out);

    // Shaking counts (after the fact: units carry their verdict).
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

    // What died, for whoever wants to read it (`inspect.mjs --dead`).
    var dead: std.ArrayList(Dead) = .empty;
    if (with_dead) {
        for (mods, 0..) |m, mi| {
            const whole = !l.moduleAlive(@intCast(mi));
            for (m.units) |u| {
                if (u.alive) continue;
                // Module declarations emit nothing anyway: listing them as
                // "eliminated" would be noise.
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
        // In two steps: otherwise the arena is copied into the return slot before
        // `.root` allocates into it (a leak — same note as in graph.zig).
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
    /// The error message of a bundle that MUST fail.
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

/// The index of the first occurrence of `needle` (to compare ORDERINGS).
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

test "topological order: dependencies BEFORE dependents" {
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

test "topological order: the diamond emits the shared module ONCE" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; import { c } from './c.js'; export const a = b + c;");
    try s.write("b.js", "import { d } from './d.js'; export const b = d;");
    try s.write("c.js", "import { d } from './d.js'; export const c = d;");
    try s.write("d.js", "export const d = 1;");
    const code = try s.bundleOf("a.js");
    // A single declaration of `d`, and it precedes both consumers.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "const d = 1"));
    const id = indexOf(code, "const d = 1").?;
    try std.testing.expect(id < indexOf(code, "const b = ").?);
    try std.testing.expect(id < indexOf(code, "const c = ").?);
}

test "a cycle does not loop and emits each module once" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; export function a() { return b(); }");
    try s.write("b.js", "import { a } from './a.js'; export function b() { return 1; } export const usesA = () => a;");
    const code = try s.bundleOf("a.js");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "function a()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "function b()"));
}

test "rename table: collision -> name$1, no collision -> name kept" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "const shared = 'A'; export const fromA = () => shared; export const unique = 1;");
    try s.write("b.js", "const shared = 'B'; export const fromB = () => shared;");
    try s.write("m.js", "import { fromA, unique } from './a.js'; import { fromB } from './b.js'; console.log(fromA(), fromB(), unique);");
    const code = try s.bundleOf("m.js");
    // The first emitted keeps its name, the second gets a suffix.
    try std.testing.expect(indexOf(code, "const shared = 'A'") != null);
    try std.testing.expect(indexOf(code, "const shared$1 = 'B'") != null);
    // A name without collision is NEVER touched (bundle readability).
    try std.testing.expect(indexOf(code, "const unique = 1") != null);
    try std.testing.expect(indexOf(code, "unique$1") == null);
}

test "references follow the renaming (an import is an ALIAS)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dep.js", "export const value = 42;");
    try s.write("m.js", "const value = 'local'; export const both = () => value;");
    try s.write("main.js", "import { value } from './dep.js'; import { both } from './m.js'; console.log(value, both());");
    const code = try s.bundleOf("main.js");
    // `value` (dep) keeps its name, `value` (m) is renamed, and the use inside
    // `m` points at the renamed one.
    try std.testing.expect(indexOf(code, "const value = 42") != null);
    try std.testing.expect(indexOf(code, "const value$1 = 'local'") != null);
    try std.testing.expect(indexOf(code, "() => value$1") != null);
    // No internal `import` survives.
    try std.testing.expect(indexOf(code, "from './dep.js'") == null);
}

test "the re-export chain resolves down to the originating binding" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("deep.js", "export const original = 'deep';");
    try s.write("mid.js", "export { original as renamed } from './deep.js';");
    try s.write("top.js", "export { renamed as final } from './mid.js';");
    try s.write("main.js", "import { final } from './top.js'; console.log(final);");
    const code = try s.bundleOf("main.js");
    // Three levels of aliasing: ONLY the originating binding remains.
    try std.testing.expect(indexOf(code, "const original = 'deep'") != null);
    try std.testing.expect(indexOf(code, "console.log(original)") != null);
    try std.testing.expect(indexOf(code, "renamed") == null);
    try std.testing.expect(indexOf(code, "final") == null);
}

test "export * from: the name passes through and resolves" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("src.js", "export const via_star = 7;");
    try s.write("barrel.js", "export * from './src.js';");
    try s.write("main.js", "import { via_star } from './barrel.js'; console.log(via_star);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "const via_star = 7") != null);
    try std.testing.expect(indexOf(code, "console.log(via_star)") != null);
}

test "namespace: materialized as an object, with the FINAL names" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("m.js", "export const x = 1; export const y = 2;");
    try s.write("main.js", "const x = 'collision'; import * as ns from './m.js'; console.log(ns.x, ns.y, x);");
    const code = try s.bundleOf("main.js");
    // The object exists, and points at the final names (not the original ones).
    try std.testing.expect(indexOf(code, "const m_ns = {") != null);
    try std.testing.expect(indexOf(code, "x: x") != null);
    try std.testing.expect(indexOf(code, "y: y") != null);
    // The local name `ns` is gone, replaced by the object's final name.
    try std.testing.expect(indexOf(code, "console.log(m_ns.x, m_ns.y, x$1)") != null);
}

test "export default: named expression vs existing binding" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("expr.js", "export default function () { return 1; }");
    try s.write("bound.js", "const named = 2; export default named;");
    try s.write("main.js", "import e from './expr.js'; import b from './bound.js'; console.log(e(), b);");
    const code = try s.bundleOf("main.js");
    // The expression gets a synthesized name...
    try std.testing.expect(indexOf(code, "const expr_default = function") != null);
    // ...but an existing binding gets NO useless intermediate const.
    try std.testing.expect(indexOf(code, "const named = 2") != null);
    try std.testing.expect(indexOf(code, "bound_default") == null);
    try std.testing.expect(indexOf(code, "console.log(expr_default(), named)") != null);
}

test "externals: hoisted to the top, deduplicated and merged" {
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
    // A SINGLE line for node:path, with both names merged.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "from 'node:path'"));
    try std.testing.expect(indexOf(code, "import { basename, join } from 'node:path';") != null);
    try std.testing.expect(indexOf(code, "import node_fs from 'node:fs';") != null);
    // Imports come BEFORE the first module.
    try std.testing.expect(indexOf(code, "from 'node:path'").? < indexOf(code, "\u{2500}\u{2500} a.js").?);
}

test "the ENTRY's exports are the only survivors" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("hidden.js", "export const internal = 1;");
    try s.write("main.js", "import { internal } from './hidden.js'; export const visible = internal + 1;");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "export { visible };") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "export {"));
}

test "refusals: top-level await, import.meta, internal import(), live namespace" {
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
        try std.testing.expect(indexOf(msg, "namespace object") != null);
    }
}

test "live binding imported BY NAME: accepted (hoisting handles it)" {
    // The counterpart of the previous refusal: without a namespace, the
    // reassignment is visible to the importer since it is THE SAME variable
    // after merging.
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("c.js", "export let n = 0; export function bump() { n += 1; }");
    try s.write("main.js", "import { n, bump } from './c.js'; bump(); console.log(n);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "let n = 0") != null);
    try std.testing.expect(indexOf(code, "console.log(n)") != null);
}

test "an import() of an EXTERNAL stays as is (not a chunk)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export const load = () => import('node:fs');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "import('node:fs')") != null);
}

// ---- tree-shaking ----

test "shaking: importing 1 name out of 3 pulls in ONLY that one" {
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

test "shaking: a module of which nothing survives disappears, header included" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("used.js", "export const used = 1;");
    try s.write("unused.js", "export const unused = 2;");
    try s.write("barrel.js", "export { used } from './used.js'; export { unused } from './unused.js';");
    try s.write("main.js", "import { used } from './barrel.js'; console.log(used);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "unused.js") == null); // even the header
    try std.testing.expect(indexOf(code, "const unused") == null);
    try std.testing.expect(indexOf(code, "const used = 1") != null);
}

test "shaking: a top-level side effect SURVIVES without being imported" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("polyfill.js",
        \\globalThis.PATCHED = true;
        \\export const neverUsed = () => 'mort';
    );
    try s.write("main.js", "import './polyfill.js'; console.log(globalThis.PATCHED);");
    const code = try s.bundleOf("main.js");
    // The effect is a ROOT: it lives even if nothing is imported from the module.
    try std.testing.expect(indexOf(code, "globalThis.PATCHED = true") != null);
    // But the pure, unused function of the same module dies.
    try std.testing.expect(indexOf(code, "neverUsed") == null);
}

test "shaking: the body of a live function pulls in what it touches" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("deep.js", "export const deep = () => 'profond';");
    try s.write("mid.js", "import { deep } from './deep.js'; export const mid = () => deep() + '!';");
    try s.write("main.js", "import { mid } from './mid.js'; console.log(mid());");
    const code = try s.bundleOf("main.js");
    // The whole transitive chain survives.
    try std.testing.expect(indexOf(code, "'profond'") != null);
    try std.testing.expect(indexOf(code, "const mid") != null);
}

test "shaking: a dead cycle disappears without looping the mark phase" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("a.js", "import { b } from './b.js'; export const a = () => b();");
    try s.write("b.js", "import { a } from './a.js'; export const b = () => a();");
    try s.write("main.js", "import './a.js'; console.log('rien du cycle');");
    const code = try s.bundleOf("main.js");
    // Nothing of the cycle is used: it all dies, and the fixed point terminates.
    try std.testing.expect(indexOf(code, "const a = ") == null);
    try std.testing.expect(indexOf(code, "const b = ") == null);
    try std.testing.expect(indexOf(code, "rien du cycle") != null);
}

test "shaking: a DEAD binding does not consume a name" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dead.js", "export const helper = () => 'mort';");
    try s.write("live.js", "const helper = () => 'vivant'; export const use = () => helper();");
    try s.write("main.js", "import './dead.js'; import { use } from './live.js'; console.log(use());");
    const code = try s.bundleOf("main.js");
    // The dead `helper` is gone, so the live one keeps its name: no `helper$1`.
    try std.testing.expect(indexOf(code, "helper$1") == null);
    try std.testing.expect(indexOf(code, "const helper = () => 'vivant'") != null);
}

test "shaking: an external of which nothing survives leaves the header" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dead.js", "import { join } from 'node:path'; export const j = () => join('a');");
    // NB: the message must not contain the specifier, or we trap ourselves.
    try s.write("main.js", "import './dead.js'; console.log('rien a importer');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "node:path") == null);
    try std.testing.expect(indexOf(code, "import ") == null); // no import header at all
}

test "shaking: a bare side-effect import keeps its effects, even without bindings" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("css.js", "globalThis.STYLED = 1;");
    try s.write("main.js", "import './css.js'; console.log(globalThis.STYLED);");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "globalThis.STYLED = 1") != null);
}

test "shaking: the ENTRY's exports are roots" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const exposed = 1; export const hidden = 2;");
    try s.write("main.js", "export { exposed } from './lib.js';");
    const code = try s.bundleOf("main.js");
    // `exposed` is the bundle's contract: it lives. `hidden` does not.
    try std.testing.expect(indexOf(code, "const exposed = 1") != null);
    try std.testing.expect(indexOf(code, "hidden") == null);
}

test "shaking: a namespace makes EVERYTHING live (the price of import * as)" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("m.js", "export const a = 1; export const b = 2; export const c = 3;");
    try s.write("main.js", "import * as ns from './m.js'; console.log(ns.a);");
    const code = try s.bundleOf("main.js");
    // The namespace object exposes everything: impossible to know what gets read.
    try std.testing.expect(indexOf(code, "const a = 1") != null);
    try std.testing.expect(indexOf(code, "const b = 2") != null);
    try std.testing.expect(indexOf(code, "const c = 3") != null);
}

test "shaking: the stats count what is kept and what falls" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const a = 1; export const b = 2; export const c = 3;");
    try s.write("main.js", "import { a } from './lib.js'; console.log(a);");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    const b = try bundle(s.a(), Sandbox.io, full, &err);
    try std.testing.expect(b.stats.statements_dropped >= 2); // b and c
    try std.testing.expect(b.stats.statements_kept >= 2); // a and the console.log
    try std.testing.expectEqual(@as(u32, 0), b.stats.modules_dropped);
}

test "shaking: the report says WHAT died and WHY" {
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
    try std.testing.expect(indexOf(r.dead[0].reason, "no live reference") != null);
}

test "format iife: everything wrapped in a function, nothing exported" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("lib.js", "export const greet = () => 'salut';");
    try s.write("main.js", "import { greet } from './lib.js'; console.log(greet()); export const x = 1;");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    const r = try bundleReport(s.a(), Sandbox.io, full, &err, false, .{ .format = .iife });
    try std.testing.expect(indexOf(r.code, "(() => {") != null);
    try std.testing.expect(std.mem.endsWith(u8, r.code, "})();\n"));
    // An IIFE exports nothing — but we COUNT what is lost, to report it.
    try std.testing.expect(indexOf(r.code, "export {") == null);
    try std.testing.expectEqual(@as(u32, 1), r.stats.entry_exports);
}

test "format iife: clear refusal when the bundle has externals" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "import { join } from 'node:path'; console.log(join('a', 'b'));");
    var err: BundleError = .{};
    const full = try std.fs.path.join(s.a(), &.{ s.root, "main.js" });
    try std.testing.expectError(
        error.BundleFailed,
        bundleReport(s.a(), Sandbox.io, full, &err, false, .{ .format = .iife }),
    );
    try std.testing.expect(indexOf(err.message, "incompatible with external imports") != null);
    try std.testing.expect(indexOf(err.message, "--format esm") != null); // says what to do
}

test "format esm stays the default, unchanged" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export const x = 1;");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "(() => {") == null);
    try std.testing.expect(indexOf(code, "export { x };") != null);
}

// ---- the entry's export roots: ALL FOUR FORMS ----
// These tests fix no bug (all four forms worked): they LOCK IN the edge case
// "exported + zero internal reference", which is exactly what a naive mark
// phase (iterating references instead of exports) would break without anything
// else noticing.

test "export root: export <declaration> inline, zero references" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("main.js", "export function jamaisUtilisee(x) { return x; }\nconsole.log('ok');");
    const code = try s.bundleOf("main.js");
    try std.testing.expect(indexOf(code, "function jamaisUtilisee") != null);
    try std.testing.expect(indexOf(code, "export { jamaisUtilisee };") != null);
}

test "export root: export { a, b as c } (specifiers), zero references" {
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

test "export root: export default (expression AND binding)" {
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

test "export root: re-export — the root lives in the TARGET module" {
    var s = try Sandbox.init(std.testing.allocator);
    defer s.deinit();
    try s.write("dep.js", "export const cible = 1; export const inutile = 2;");
    try s.write("main.js", "export { cible } from './dep.js';\nconsole.log('ok');");
    const code = try s.bundleOf("main.js");
    // The binding lives in dep.js: that is what the root must reach.
    try std.testing.expect(indexOf(code, "const cible = 1") != null);
    try std.testing.expect(indexOf(code, "export { cible };") != null);
    // …without pulling in the rest of the target module.
    try std.testing.expect(indexOf(code, "inutile") == null);
}

test "export root: export * and export * as ns" {
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
        // The namespace is materialized, and exported under its public name.
        try std.testing.expect(indexOf(code, "const dep_ns = {") != null);
        try std.testing.expect(indexOf(code, "as ns };") != null);
    }
}

test "export root: exported survives, non-exported twin dies (no over-marking)" {
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
