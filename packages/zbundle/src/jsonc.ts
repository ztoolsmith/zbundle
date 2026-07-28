//! A JSONC reader — JSON with comments and trailing commas, which is what a
//! `tsconfig.json` actually is. `JSON.parse` chokes on both.
//!
//! **Why hand-written rather than `jsonc-parser`.** The TypeScript layer ships
//! zero runtime dependencies, and that is a property worth more than the ~80
//! lines below: every dependency here would be installed by every user of
//! zbundle, forever, to read one small file. The grammar is tiny and frozen.
//!
//! It is a real parser, not a comment-stripping regex: `"http://x"` inside a
//! string must not lose its tail, and that is exactly what a regex gets wrong.

export class JsoncError extends Error {
  constructor(
    message: string,
    readonly line: number,
    readonly column: number,
  ) {
    super(message);
  }
}

export function parseJsonc(text: string, file = "<jsonc>"): unknown {
  let i = 0;

  const where = (at: number): { line: number; column: number } => {
    let line = 1;
    let column = 1;
    for (let k = 0; k < at && k < text.length; k++) {
      if (text[k] === "\n") {
        line++;
        column = 1;
      } else column++;
    }
    return { line, column };
  };

  const die = (message: string, at = i): never => {
    const { line, column } = where(at);
    throw new JsoncError(`${file}:${line}:${column}: ${message}`, line, column);
  };

  /** Whitespace AND comments — the only place the JSONC grammar differs. */
  const skip = (): void => {
    for (;;) {
      while (i < text.length && /\s/.test(text[i]!)) i++;
      if (text[i] === "/" && text[i + 1] === "/") {
        while (i < text.length && text[i] !== "\n") i++;
        continue;
      }
      if (text[i] === "/" && text[i + 1] === "*") {
        const start = i;
        i += 2;
        while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
        if (i >= text.length) die("unterminated block comment", start);
        i += 2;
        continue;
      }
      return;
    }
  };

  const string = (): string => {
    if (text[i] !== '"') die(`expected a string, found ${JSON.stringify(text[i] ?? "<eof>")}`);
    const start = i;
    i++;
    let out = "";
    while (i < text.length && text[i] !== '"') {
      if (text[i] === "\\") {
        const esc = text[i + 1];
        i += 2;
        switch (esc) {
          case '"': out += '"'; break;
          case "\\": out += "\\"; break;
          case "/": out += "/"; break;
          case "b": out += "\b"; break;
          case "f": out += "\f"; break;
          case "n": out += "\n"; break;
          case "r": out += "\r"; break;
          case "t": out += "\t"; break;
          case "u": {
            const hex = text.slice(i, i + 4);
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) die("invalid \\u escape", i);
            out += String.fromCharCode(parseInt(hex, 16));
            i += 4;
            break;
          }
          default: die(`invalid escape \\${esc ?? "<eof>"}`, i - 1);
        }
        continue;
      }
      out += text[i];
      i++;
    }
    if (i >= text.length) die("unterminated string", start);
    i++; // closing quote
    return out;
  };

  const value = (): unknown => {
    skip();
    const c = text[i];
    if (c === undefined) die("unexpected end of input");
    if (c === "{") return object();
    if (c === "[") return array();
    if (c === '"') return string();
    if (text.startsWith("true", i)) return (i += 4), true;
    if (text.startsWith("false", i)) return (i += 5), false;
    if (text.startsWith("null", i)) return (i += 4), null;
    const num = /^-?\d+(\.\d+)?([eE][+-]?\d+)?/.exec(text.slice(i));
    if (num) {
      i += num[0].length;
      return Number(num[0]);
    }
    return die(`unexpected character ${JSON.stringify(c)}`);
  };

  const object = (): Record<string, unknown> => {
    i++; // {
    const out: Record<string, unknown> = {};
    skip();
    if (text[i] === "}") return i++, out;
    for (;;) {
      skip();
      // A trailing comma left us facing the closer: legal in JSONC.
      if (text[i] === "}") return i++, out;
      const key = string();
      skip();
      if (text[i] !== ":") die(`expected ':' after key ${JSON.stringify(key)}`);
      i++;
      out[key] = value();
      skip();
      if (text[i] === ",") {
        i++;
        continue;
      }
      if (text[i] === "}") return i++, out;
      die(`expected ',' or '}' in object`);
    }
  };

  const array = (): unknown[] => {
    i++; // [
    const out: unknown[] = [];
    skip();
    if (text[i] === "]") return i++, out;
    for (;;) {
      skip();
      if (text[i] === "]") return i++, out;
      out.push(value());
      skip();
      if (text[i] === ",") {
        i++;
        continue;
      }
      if (text[i] === "]") return i++, out;
      die(`expected ',' or ']' in array`);
    }
  };

  const result = value();
  skip();
  if (i < text.length) die("trailing content after the top-level value");
  return result;
}
