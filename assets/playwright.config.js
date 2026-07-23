import { defineConfig } from "@playwright/test";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  testDir: "./e2e",

  // The browser suite intentionally shares one reset-and-seeded database and
  // includes stateful journeys. Retrying an individual test against mutated
  // state can hide the original failure or fail for the wrong reason. CI
  // workflow reruns rebuild the database from scratch.
  retries: 0,

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
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },

  webServer: {
    command:
      "MIX_ENV=test mix assets.deploy && BROWSER_E2E=true MIX_ENV=test PHX_SERVER=true PORT=4002 mix phx.server",
    cwd: resolve(__dirname, ".."),
    url: "http://127.0.0.1:4002",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
