import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
const root = path.dirname(fileURLToPath(import.meta.url));
export default defineConfig({
  resolve: {
    alias: [
      {
        find: "@ccbar/host-api/window",
        replacement: path.resolve(root, "../host-api/src/window.ts"),
      },
      {
        find: "@ccbar/host-api/macos",
        replacement: path.resolve(root, "../host-api/src/macos.ts"),
      },
      {
        find: "@ccbar/host-api",
        replacement: path.resolve(root, "../host-api/src/index.ts"),
      },
      { find: "@", replacement: path.resolve(root, "src") },
    ],
  },
  test: {
    environment: "jsdom",
    include: ["tests/**/*.test.{ts,tsx}"],
    setupFiles: ["./tests/setup.ts"],
  },
});
