import { defineConfig } from "@playwright/test";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  testDir: "./e2e",

  retries: process.env.CI ? 1 : 0,

  workers: 1,

  projects: [
    {
      name: "chromium",
      use: {
        browserName: "chromium",
      },
    },
  ],

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:4002",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },

  webServer: {
    command:
      "MIX_ENV=test mix assets.deploy && MIX_ENV=test PHX_SERVER=true PORT=4002 mix phx.server",
    cwd: resolve(__dirname, ".."),
    url: "http://127.0.0.1:4002",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
