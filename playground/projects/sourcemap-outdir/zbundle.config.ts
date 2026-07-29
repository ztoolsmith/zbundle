import { defineConfig } from "zbundle/config";

export default defineConfig({
  input: "main.js",
  // Two levels deep, and NOT the default: the `sources` entries must gain the
  // matching `../..`.
  output: { dir: "dist/build/js" },
  sourcemap: { sourceRoot: "/@src/", sourcesContent: true },
});
