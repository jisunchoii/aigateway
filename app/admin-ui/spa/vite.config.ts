import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Build output goes to ../bff/static so the Dockerfile copies it into the BFF image and
// FastAPI serves it. The dev server proxies /api to a locally running BFF on :8000.
export default defineConfig({
  plugins: [react()],
  build: { outDir: "../bff/static", emptyOutDir: true },
  server: { proxy: { "/api": "http://localhost:8000" } },
});
