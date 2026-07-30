//! The TypeScript half of the codeframes.
//!
//! The Zig side renders frames for what it holds in memory — module sources. The
//! only errors that never reach it are the ones about the BUILD's own files: a
//! malformed `tsconfig.json`, a `zbundle.config.*` that will not parse. Their
//! text lives here, so their frame is rendered here, in the same shape.
//!
//! Symmetry rather than sharing: passing a whole source file across the N-API
//! boundary to have a caret drawn on the other side would be a lot of copying to
//! avoid twenty lines.

/** `file:line:column`, the offending line, and a caret under the column. */
export function codeframe(file: string, source: string, line: number, column: number): string {
  const lines = source.split("\n");
  const text = (lines[line - 1] ?? "").replace(/\t/g, " ");
  const num = String(line);
  const gutter = " ".repeat(num.length);
  // `column` is 1-based, and the caret pads with one space per unit before it.
  const pad = " ".repeat(Math.max(0, column - 1));
  return `${file}:${line}:${column}\n  ${num} │ ${text}\n  ${gutter} │ ${pad}^`;
}
