import { defineConfig } from "@playwright/test";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));

// `bin/test-browser` sets PLAYWRIGHT_PORT to a free port per run so two
// checkouts never share a server. Without it the suite uses 4002.
const port = process.env.PLAYWRIGHT_PORT || "4002";

export default defineConfig({
  testDir: "./e2e",

  // The browser suite intentionally shares one freshly seeded database and
  // includes stateful journeys. Retrying an individual test against mutated
  // state can hide the original failure or fail for the wrong reason. Each
  // `bin/test-browser` run starts from a new database.
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
    baseURL: process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${port}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },

  webServer: {
    command: `MIX_ENV=test mix assets.deploy && BROWSER_E2E=true MIX_ENV=test PHX_SERVER=true PORT=${port} mix phx.server`,
    cwd: resolve(__dirname, ".."),
    url: `http://127.0.0.1:${port}`,
    // A port chosen by the wrapper belongs to this run's database; attaching to
    // whatever already listens there would test against another database.
    reuseExistingServer: !process.env.CI && !process.env.PLAYWRIGHT_PORT,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
