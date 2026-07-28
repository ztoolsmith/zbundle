import { defineConfig } from "zbundle/config";

// Deliberately bare: no `resolve.alias`. If the tsconfig were not read, `#lib/*`
// would stay a bare specifier and the bundle would import it instead of
// inlining it — the judge would catch that immediately.
export default defineConfig({
  input: "main.js",
  output: { dir: "dist" },
});
