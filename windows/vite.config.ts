import { defineConfig } from "vite";

// Tauri serves the frontend from a fixed port in dev and from dist/ in release.
export default defineConfig({
  clearScreen: false,
  server: { port: 5173, strictPort: true },
  build: { target: "esnext", outDir: "dist", emptyOutDir: true },
});
