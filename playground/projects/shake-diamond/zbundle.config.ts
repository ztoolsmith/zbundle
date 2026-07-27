import { defineConfig } from "zbundle/config";

// Tree-shaking through the CLI. `mode: "development"` is explicit here: it keeps
// minify OFF, so the `// expect-absent:` header still checks real names rather
// than shortened ones.
export default defineConfig({
  mode: "development",
  input: "main.js",
  output: { dir: "dist", clean: true },
});
