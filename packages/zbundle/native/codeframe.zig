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

    // Freed before returning: the call arena would swallow them, but depending on
    // the caller's allocator being an arena is a promise this file cannot check.
    var line_text: std.ArrayList(u8) = .empty;
    defer line_text.deinit(a);
    var caret_pad: std.ArrayList(u8) = .empty;
    defer caret_pad.deinit(a);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch 1;
        const end = @min(i + n, raw.len);
        const ch = raw[i..end];
        if (ch.len == 1 and (ch[0] == '\t' or ch[0] == '\r')) {
            try line_text.append(a, ' ');
            if (units + 1 < p.column) try caret_pad.append(a, ' ');
            units += 1;
        } else {
            try line_text.appendSlice(a, ch);
            const w = utf16Len(ch);
            if (units + w < p.column) {
                var k: u32 = 0;
                // One space per code UNIT, so the caret lines up with the text
                // above it however wide the character is.
                while (k < w) : (k += 1) try caret_pad.append(a, ' ');
            }
            units += w;
        }
        i = end;
    }

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
