// Sort glyph browser check (EV-22, step 30; AC-17).
//
// The three list surfaces that own their own headers — Blocks, Runs and
// Agencies — must show the same ▲/▼/↕ set as the shared `CoreComponents.table/1`
// header. Each journey clicks a header that is not the page's current sort key,
// so the click starts ascending, then asserts the sorted `<th>` keeps its
// `aria-sort` and carries the glyph in an `aria-hidden` span, and captures the
// header row. The page's current key would only toggle to descending, which
// would leave no `aria-sort="ascending"` header to check; the surfaces' defaults
// are Blocks by `block`, Runs by `sign_on` and Agencies by `name`.
//
// It reuses `bin/test-browser`'s freshly seeded database and the
// login/`versionIdFor` pattern of `runs.spec.js`. Captures are written to the
// feature's `.specs/33-duplicate-code/evidence/browser/`, overridable with
// `SORT_GLYPHS_CAPTURE_DIR` (the pattern `settings_agencies_feed.spec.js` uses);
// `.specs/` is gitignored, so a local run leaves reviewable images behind and CI
// never depends on them.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The Playwright runner starts in `assets/`, so repository-relative paths are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const CAPTURE_DIR =
  process.env.SORT_GLYPHS_CAPTURE_DIR ||
  resolve(REPO_ROOT, ".specs/33-duplicate-code/evidence/browser");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The seeded published versions that carry each surface's data.
const BLOCKS_VERSION = "Browser Blocks Version";
const RUNS_VERSION = "Browser Runs Version";
const AGENCIES_VERSION = "Browser Agencies Version";

const DESKTOP = { width: 1440, height: 1000 };

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published versions, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
async function versionIdFor(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

// A click that lands before the LiveView joins is dropped, so an action waits
// for the mounted view first, the way `settings_agencies_feed.spec.js` does.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
        !main.hasAttribute("data-phx-pending") &&
        window.liveSocket?.main?.isConnected?.(),
    );
  });
}

// One click on a header that is not the current sort key starts ascending, so
// the clicked `<th>` becomes the page's own `aria-sort="ascending"` header and
// shows the shared upward glyph in its decorative span.
async function sortAscending(header) {
  await header.locator("button").click();
  await expect(header).toHaveAttribute("aria-sort", "ascending");
  await expect(header.locator("span[aria-hidden='true']")).toHaveText("▲");
}

async function captureHeader(page, tableSelector, name) {
  const header = page.locator(`${tableSelector} thead`);
  await expect(header).toBeVisible();
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await header.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
}

test.describe("Sort glyphs at 1440x1000", () => {
  test.use({ viewport: DESKTOP });

  test("Blocks shows ▲ on the ascending header", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, BLOCKS_VERSION);

    await page.goto(`/gtfs/${versionId}/blocks`);
    await waitForLiveView(page);

    await sortAscending(page.locator("#blocks-timeline th.blocks-meta-out"));
    await captureHeader(page, "#blocks-timeline", "sort-blocks");
  });

  test("Runs shows ▲ on the ascending header", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, RUNS_VERSION);

    await page.goto(`/gtfs/${versionId}/runs`);
    await waitForLiveView(page);

    await sortAscending(page.locator("#runs-timeline thead th.runs-meta-id"));
    await captureHeader(page, "#runs-timeline", "sort-runs");
  });

  test("Agencies shows ▲ on the ascending header", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, AGENCIES_VERSION);

    await page.goto(`/gtfs/${versionId}/settings/agencies`);
    await waitForLiveView(page);

    const routes = page.locator("#agencies-list thead th").filter({ hasText: "Routes" });

    await sortAscending(routes);
    await captureHeader(page, "#agencies-list", "sort-agencies");
  });
});
