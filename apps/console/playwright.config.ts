import { join } from "node:path";
import { tmpdir } from "node:os";
import { defineConfig } from "@playwright/test";

const port = Number(process.env.E2E_WEB_PORT || 5174);

const artifacts =
  process.env.E2E_ARTIFACT_DIR || join(tmpdir(), "xlgw-console-verification");

export default defineConfig({
  testDir: "./tests",
  testMatch: "workbench.spec.ts",
  timeout: 60000,
  expect: { timeout: 10000 },
  fullyParallel: false,
  workers: 1,
  reporter: [
    ["list"],
    ["html", { outputFolder: join(artifacts, "web-report"), open: "never" }],
  ],
  outputDir: join(artifacts, "web-results"),
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    viewport: { width: 1440, height: 1000 },
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: `npm run dev -- --port ${port} --strictPort`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
    env: {
      API_PROXY_TARGET: process.env.E2E_API_ORIGIN || "http://127.0.0.1:8080",
    },
  },
});
