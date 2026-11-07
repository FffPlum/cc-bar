import path from "node:path";
import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const root = path.dirname(fileURLToPath(import.meta.url));
const contentSecurityPolicy = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self'",
  "connect-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join("; ");

export default defineConfig({
  base: "./",
  plugins: [
    react(),
    tailwindcss(),
    {
      name: "ccbar-production-csp",
      transformIndexHtml: {
        order: "post",
        handler(html, context) {
          if (!context.bundle) return html;
          return html.replace(
            "<!-- production-csp -->",
            `<meta http-equiv="Content-Security-Policy" content="${contentSecurityPolicy}">`,
          );
        },
      },
    },
  ],
  resolve: {
    alias: [
      { find: "@ccbar/host-api/macos", replacement: path.resolve(root, "../host-api/src/macos.ts") },
      { find: "@ccbar/host-api/window", replacement: path.resolve(root, "../host-api/src/window.ts") },
      { find: "@ccbar/host-api", replacement: path.resolve(root, "../host-api/src/index.ts") },
      { find: "@", replacement: path.resolve(root, "./src") },
    ],
  },
  build: {
    outDir: "../../Sources/CCBar/Resources/WebInterface",
    emptyOutDir: true,
    target: ["es2020", "safari17"],
    cssTarget: "safari17",
    sourcemap: false,
  },
});
