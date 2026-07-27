import { defineConfig } from "zbundle/config";

// The IMPORTING WITNESS, through the CLI: this project declares
// `// expect-exports:`, so the harness imports the bundle the command produced
// and calls its exports. The export contract is checked on the artifact a user
// would actually ship.
export default defineConfig({
  input: "main.js",
  output: { dir: "dist" },
});
