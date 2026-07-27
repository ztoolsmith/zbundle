import { defineConfig } from "zbundle/config";

// The simplest config there is — and that is the point: this project is judged
// through the COMMAND, so it proves the whole chain (config file -> CLI ->
// binding -> bundle -> execution) on a case whose result we already know.
export default defineConfig({
  input: "main.js",
  output: { dir: "dist" },
});
