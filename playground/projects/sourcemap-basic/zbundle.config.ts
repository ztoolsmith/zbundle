import { defineConfig } from "zbundle/config";

export default defineConfig({
  input: "main.js",
  output: { dir: "dist" },
  sourcemap: true,
});
