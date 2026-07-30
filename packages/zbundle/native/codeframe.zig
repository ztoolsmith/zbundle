//! CODEFRAMES: an error that shows the line it is talking about.
//!
//! `cannot resolve './dep.js'` tells you what went wrong. It does not tell you
//! WHERE, and in a file with thirty imports that is most of the work left to do.
//! A codeframe closes the gap:
//!
//!     src/main.ts:4:22
//!       4 │ import { helper } from './dep.js';
//!         │                       ^
//!
//! **Almost free, by now.** The byte-exact spans have been on every node since
//! day one, and 0.4.0 built the machinery that turns a byte offset into a
//! line and a column. This file is the presentation layer on top of both — it is
//! not a refusal being lifted, it is the same refusals finally saying where.
//!
//! Rendered in Zig rather than in the TS layer because this is where the sources
//! already are: the graph read them, and asking JS to read them again to point at
//! a character would be a second source of truth about the same bytes.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A position in a file, as a human counts them.
pub const Position = struct {
    /// 1-based.
    line: u32,
    /// 1-based, in UTF-16 code units — what an editor's status bar shows.
    column: u32,
    /// Byte offsets of the line holding the position.
    line_start: usize,
    line_end: usize,
};

/// Where `offset` falls in `source`.
///
/// The column counts **UTF-16 code units**, not bytes: that is what an editor
/// and a browser console both show, so a caret placed by byte count would drift
/// on any line containing an accent or an emoji.
pub fn locate(source: []const u8, offset: usize) Position {
    const at = @min(offset, source.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < at) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var line_end = at;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;

    return .{
        .line = line,
        .column = utf16Len(source[line_start..at]) + 1,
        .line_start = line_start,
        .line_end = line_end,
    };
}

/// The number of UTF-16 code units `bytes` decodes to. Invalid bytes count as
/// one unit each: a broken encoding must not make this loop lie about length.
fn utf16Len(bytes: []const u8) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            units += 1;
            continue;
        };
        if (i + n > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch {
            i += n;
            units += 1;
            continue;
        };
        // Beyond the BMP, one code point is a surrogate PAIR — two units.
        units += if (cp > 0xFFFF) 2 else 1;
        i += n;
    }
    return units;
}

/// How much of the offending line a frame shows, in UTF-16 units.
///
/// A minified file, a long string, a generated table: a line can be thousands of
/// characters, and dumping it whole gives an error message nobody reads and a CI
/// log nobody scrolls. The window keeps the caret in view and says, with an
/// ellipsis, that it cut.
pub const WINDOW: u32 = 100;

/// The longest a single quoted value may be in a message, in UTF-16 units.
///
/// A specifier or a path is normally short; nothing stops one from being three
/// thousand characters long, and a message that repeats it three times is not a
/// message anyone reads.
pub const VALUE_LIMIT: u32 = 120;

/// `text`, shortened around its MIDDLE when it exceeds `limit`.
///
/// The middle is what goes: the head of a path says where it starts and the tail
/// carries the file name, which are the two parts a reader needs. Cutting the end
/// instead would throw away exactly what identifies it.
///
/// Cuts on a character boundary — slicing bytes would produce invalid UTF-8 in an
/// error message, which is a poor way to report an error.
pub fn ellipsize(a: Allocator, text: []const u8, limit: u32) Allocator.Error![]const u8 {
    if (utf16Len(text) <= limit) return text;
    const keep = limit / 2;

    var head_end: usize = 0;
    var units: u32 = 0;
    while (head_end < text.len and units < keep) {
        const n = std.unicode.utf8ByteSequenceLength(text[head_end]) catch 1;
        const end = @min(head_end + n, text.len);
        units += utf16Len(text[head_end..end]);
        head_end = end;
    }

    var tail_start = text.len;
    units = 0;
    while (tail_start > 0 and units < keep) {
        var start = tail_start - 1;
        // Walk back over continuation bytes to the start of the character.
        while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
        units += utf16Len(text[start..tail_start]);
        tail_start = start;
    }
    if (tail_start < head_end) return text;

    return std.fmt.allocPrint(a, "{s}…{s}", .{ text[0..head_end], text[tail_start..] });
}

/// `file:line:column`, then the offending line, then a caret under the column.
///
/// The gutter is drawn with box characters rather than spaces so the frame
/// survives being quoted in a terminal, an issue, or a log. A tab in the source
/// is rendered as a single space in the frame: keeping it would put the caret
/// somewhere the tab width decides, which is nowhere reliable.
pub fn render(
    a: Allocator,
    display_path: []const u8,
    source: []const u8,
    offset: usize,
) Allocator.Error![]const u8 {
    const p = locate(source, offset);
    const raw = source[p.line_start..p.line_end];

    // The line, one CELL per character: its rendered bytes and how many UTF-16
    // units it takes. A tab or a stray `\r` renders as one space — keeping a tab
    // would put the caret wherever the terminal's tab width decides.
    const Cell = struct { text: []const u8, width: u32 };
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(a);
    var total: u32 = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
        const end = @min(i + n, raw.len);
        const ch = raw[i..end];
        const cell: Cell = if (ch.len == 1 and (ch[0] == '\t' or ch[0] == '\r'))
            .{ .text = " ", .width = 1 }
        else
            .{ .text = ch, .width = utf16Len(ch) };
        try cells.append(a, cell);
        total += cell.width;
        i = end;
    }

    // The window, centred on the caret when the line does not fit.
    var from_unit: u32 = 0;
    if (total > WINDOW) {
        const half = WINDOW / 2;
        from_unit = if (p.column > half) p.column - half else 0;
        if (from_unit + WINDOW > total) from_unit = total - WINDOW;
    }
    const to_unit = @min(from_unit + WINDOW, total);

    // Freed before returning: the call arena would swallow them, but depending on
    // the caller's allocator being an arena is a promise this file cannot check.
    var line_text: std.ArrayList(u8) = .empty;
    defer line_text.deinit(a);
    var caret_pad: std.ArrayList(u8) = .empty;
    defer caret_pad.deinit(a);
    // The ellipsis takes a unit of its own, so the caret must account for it.
    if (from_unit > 0) {
        try line_text.appendSlice(a, "…");
        try caret_pad.append(a, ' ');
    }
    var units: u32 = 0;
    for (cells.items) |cell| {
        defer units += cell.width;
        if (units < from_unit or units >= to_unit) continue;
        try line_text.appendSlice(a, cell.text);
        if (units + cell.width < p.column) {
            var k: u32 = 0;
            // One space per code UNIT, so the caret lines up with the text above
            // it however wide the character is.
            while (k < cell.width) : (k += 1) try caret_pad.append(a, ' ');
        }
    }
    if (to_unit < total) try line_text.appendSlice(a, "…");

    // The line number sets the gutter width, so the two rules line up.
    var num_buf: [16]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{p.line}) catch "?";
    var gutter: std.ArrayList(u8) = .empty;
    defer gutter.deinit(a);
    for (num) |_| try gutter.append(a, ' ');

    return std.fmt.allocPrint(
        a,
        "{s}:{d}:{d}\n  {s} │ {s}\n  {s} │ {s}^",
        .{ display_path, p.line, p.column, num, line_text.items, gutter.items, caret_pad.items },
    );
}

// ------------------------------------------------------------------ tests

test "locate: line and column are 1-based" {
    const src = "const a = 1;\nconst b = 2;\n";
    try std.testing.expectEqual(@as(u32, 1), locate(src, 0).line);
    try std.testing.expectEqual(@as(u32, 1), locate(src, 0).column);
    try std.testing.expectEqual(@as(u32, 1), locate(src, 6).line);
    try std.testing.expectEqual(@as(u32, 7), locate(src, 6).column);
    // First character of the second line.
    try std.testing.expectEqual(@as(u32, 2), locate(src, 13).line);
    try std.testing.expectEqual(@as(u32, 1), locate(src, 13).column);
}

test "locate: the column counts UTF-16 units, not bytes" {
    // `café` is 5 bytes for 4 units: a byte count would put the caret one past.
    const src = "const café = 1;\n";
    const at = std.mem.indexOf(u8, src, "= 1").?;
    const p = locate(src, at);
    try std.testing.expectEqual(@as(u32, 1), p.line);
    // c-o-n-s-t-space-c-a-f-é-space = 11 units, so `=` is at column 12.
    try std.testing.expectEqual(@as(u32, 12), p.column);
}

test "locate: an offset past the end clamps to the last line" {
    const src = "a\nb";
    const p = locate(src, 999);
    try std.testing.expectEqual(@as(u32, 2), p.line);
}

test "render: the caret sits under the column" {
    const gpa = std.testing.allocator;
    const src = "import { helper } from './dep.js';\nconsole.log(1);\n";
    const at = std.mem.indexOf(u8, src, "'./dep.js'").?;
    const out = try render(gpa, "src/main.ts", src, at);
    defer gpa.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "src/main.ts:1:24\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "import { helper }") != null);
    // The caret is on the LAST line of the frame, and its offset within that
    // line must match the column it announces.
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    const caret_line = it.first();
    const caret_at = std.mem.indexOfScalar(u8, caret_line, '^').?;
    const text_line = it.next().?;
    const bar = std.mem.indexOf(u8, text_line, "│ ").? + "│ ".len;
    try std.testing.expectEqual(bar + 23, caret_at); // column 24 -> 23 units in
}

test "render: a multi-byte line keeps the caret aligned" {
    const gpa = std.testing.allocator;
    const src = "const café = '→';\n";
    const at = std.mem.indexOf(u8, src, "'→'").?;
    const out = try render(gpa, "x.ts", src, at);
    defer gpa.free(out);
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    const caret_line = it.first();
    const text_line = it.next().?;
    // Same gutter on both rules, and one space per code UNIT before the caret —
    // counting bytes would push it two places right (é and → are multi-byte).
    const caret_at = std.mem.indexOfScalar(u8, caret_line, '^').?;
    const bar_text = std.mem.indexOf(u8, text_line, "│ ").? + "│ ".len;
    try std.testing.expectEqual(bar_text + 13, caret_at);
}

test "render: a tab becomes one space so the caret stays put" {
    const gpa = std.testing.allocator;
    const src = "\tconst x = 1;\n";
    const at = std.mem.indexOf(u8, src, "x").?;
    const out = try render(gpa, "x.ts", src, at);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\t") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x.ts:1:8") != null);
}

test "render: a long line is windowed around the caret" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "const pad = \"");
    var k: usize = 0;
    while (k < 3000) : (k += 1) try buf.append(gpa, 'x');
    try buf.appendSlice(gpa, "\" + HERE;\n");
    const at = std.mem.indexOf(u8, buf.items, "HERE").?;

    const out = try render(gpa, "x.ts", buf.items, at);
    defer gpa.free(out);
    // The whole frame stays readable: dumping 3000 characters into an error
    // message is an error message nobody reads.
    try std.testing.expect(out.len < 400);
    // The caret's target is still visible, and the cut is announced.
    try std.testing.expect(std.mem.indexOf(u8, out, "HERE") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "…") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

test "render: the caret stays aligned inside a window" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var k: usize = 0;
    while (k < 300) : (k += 1) try buf.append(gpa, 'a');
    try buf.appendSlice(gpa, "TARGET");
    const at = std.mem.indexOf(u8, buf.items, "TARGET").?;

    const out = try render(gpa, "x.ts", buf.items, at);
    defer gpa.free(out);
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    const caret_line = it.first();
    const text_line = it.next().?;
    // Compared in UNITS, not bytes: the text line may hold an ellipsis (3 bytes
    // for 1 unit) where the caret line holds a space, and a byte comparison would
    // report a 2-place drift on a perfectly aligned frame. That mistake is the
    // whole reason this file counts units in the first place.
    const bar_text = std.mem.indexOf(u8, text_line, "│ ").? + "│ ".len;
    const bar_caret = std.mem.indexOf(u8, caret_line, "│ ").? + "│ ".len;
    const target_at = std.mem.indexOf(u8, text_line, "TARGET").?;
    const before_target = utf16Len(text_line[bar_text..target_at]);
    const before_caret = utf16Len(caret_line[bar_caret..std.mem.indexOfScalar(u8, caret_line, '^').?]);
    try std.testing.expectEqual(before_target, before_caret);
}

test "render: a short line is NOT windowed" {
    const gpa = std.testing.allocator;
    const src = "const x = 1;\n";
    const out = try render(gpa, "x.ts", src, 6);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "…") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const x = 1;") != null);
}

test "ellipsize: a short value is untouched" {
    const gpa = std.testing.allocator;
    const out = try ellipsize(gpa, "./dep.ts", 120);
    try std.testing.expectEqualStrings("./dep.ts", out); // same slice, nothing freed
}

test "ellipsize: a long value keeps its head AND its tail" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "/very/long/start/");
    var k: usize = 0;
    while (k < 500) : (k += 1) try buf.append(gpa, 'x');
    try buf.appendSlice(gpa, "/the-file.ts");

    const out = try ellipsize(gpa, buf.items, 40);
    defer gpa.free(out);
    // The head says where it starts, the tail carries the name: both are what a
    // reader needs, so the MIDDLE is what goes.
    try std.testing.expect(std.mem.startsWith(u8, out, "/very/long"));
    try std.testing.expect(std.mem.endsWith(u8, out, "the-file.ts"));
    try std.testing.expect(std.mem.indexOf(u8, out, "…") != null);
    try std.testing.expect(utf16Len(out) <= 41); // limit + the ellipsis
}

test "ellipsize: it cuts on a character boundary" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Multi-byte throughout: a byte-wise cut would produce invalid UTF-8, which
    // is a poor way to report an error.
    var k: usize = 0;
    while (k < 200) : (k += 1) try buf.appendSlice(gpa, "é");

    const out = try ellipsize(gpa, buf.items, 40);
    defer gpa.free(out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}
