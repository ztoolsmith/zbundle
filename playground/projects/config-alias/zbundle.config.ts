import { defineConfig } from "zbundle/config";

export default defineConfig({
  input: "main.js",
  output: { dir: "dist" },
  // `./src` is relative to THIS FILE, never to the working directory — run the
  // command from anywhere and it still means the same thing.
  resolve: { alias: { "#lib/": "./src/" } },
});
