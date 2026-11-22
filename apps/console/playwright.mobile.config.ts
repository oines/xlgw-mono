import { join } from "node:path";
import { tmpdir } from "node:os";
import { defineConfig } from "@playwright/test";

const artifacts =
  process.env.E2E_ARTIFACT_DIR || join(tmpdir(), "xlgw-console-verification");

export default defineConfig({
  testDir: "./tests",
  testMatch: "mobile.spec.ts",
  timeout: 90000,
  expect: { timeout: 15000 },
  workers: 1,
  reporter: [
    ["list"],
    ["html", { outputFolder: join(artifacts, "mobile-report"), open: "never" }],
  ],
  outputDir: join(artifacts, "mobile-results"),
  use: {
    baseURL: process.env.E2E_API_ORIGIN || "http://127.0.0.1:18080",
    viewport: { width: 390, height: 844 },
    locale: "zh-CN",
    timezoneId: "Asia/Shanghai",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
});
