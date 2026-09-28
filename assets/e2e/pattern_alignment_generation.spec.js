import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Street-path generation (spec 12, step 32).
 *
 * `test.describe("generation")` opens the GEN-2 pattern (AL_S3 → AL_S4,
 * every section missing) for the empty-state overlay, the in-flight state
 * and the generated draft, and the GEN-1 pattern (touches the 40.7500 stop,
 * so BrowserStreetRouting reports :no_route) for the routing-unavailable
 * notice. Generation only drafts (CR-9): nothing here saves, so both
 * patterns stay missing and every viewport reuses them. The server is the
 * Playwright webServer block (BROWSER_E2E=true, BrowserStreetRouting —
 * no live Geoapify calls); only tiles are stubbed.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ALIGN_ROUTE = "BROWSER_ALIGN";
const GEN_PATTERN = "BROWSER-ALIGN-GEN-2";
const GEN_NOROUTE_PATTERN = "BROWSER-ALIGN-GEN-1";

const CAPTURE_DIR = process.env.PATTERN_ALIGNMENT_CAPTURE_DIR;

// A verified-transparent 1×1 PNG served for every tile request, so captures
// never depend on the network or on Geoapify credits.
const BLANK_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=",
  "base64",
);

async function captureViewport(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
}

async function captureFullPage(page, name) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: true,
    animations: "disabled",
  });
}

// An already authenticated session is redirected away from the login page, so
// the form is only filled when it is actually rendered.
async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function getVersionId(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function collectPageErrors(page) {
  const problems = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return problems;
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return (
        Boolean(main) &&
        main.classList.contains("phx-connected") &&
        window.liveSocket?.isConnected()
      );
    },
    { timeout: 20000 },
  );
}

async function stubTiles(page) {
  await page.route("**/map/tiles/**", async (route) => {
    await route.fulfill({ contentType: "image/png", body: BLANK_PNG });
  });
}

async function openAlignment(page, versionId, patternId) {
  await page.goto(
    `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${patternId}?task=alignment`,
  );
  await page.waitForSelector("#alignment-task", { timeout: 15000 });
  await page.waitForSelector("#alignment-sections", { timeout: 15000 });
  await waitForLiveView(page);
  await expect(
    page.locator("#alignment-map-root .leaflet-container"),
  ).toBeVisible({ timeout: 15000 });
  await expect(
    page.locator("#alignment-map-root .pa-stop-pin").first(),
  ).toBeVisible({ timeout: 15000 });
}

test.describe("generation", () => {
  test("generates a street path from the empty state through review at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, versionId, GEN_PATTERN);

    // The first-alignment overlay offers the suggested street path with
    // Draw manually as the secondary path.
    await expect(page.locator("#alignment-generate-overlay")).toBeVisible({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-generate-overlay")).toContainText(
      "Give this pattern a path",
    );
    await expect(page.locator("#alignment-generate-all")).toContainText(
      "Generate street paths",
    );
    await expect(page.locator("#alignment-overlay-draw")).toContainText(
      "Or draw a section",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "generate-empty-1440");

    // The in-flight overlay renders before the routed legs arrive; the
    // saved paths stay unchanged and Cancel stays available.
    await page.locator("#alignment-generate-all").click();
    await expect(page.locator("#alignment-generating")).toBeVisible({
      timeout: 5000,
    });
    await expect(page.locator("#alignment-generating")).toContainText(
      "Finding a street path…",
    );
    await expect(page.locator("#alignment-cancel-generation")).toContainText(
      "Cancel generation",
    );
    await captureViewport(page, "generate-inflight-1440");

    // The routed legs land as a dirty draft awaiting review before saving.
    await expect(page.locator("#alignment-generating")).toBeHidden({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );
    await expect(page.locator("#status")).toContainText(
      "Suggested path ready. Review the streets before saving.",
      { timeout: 15000 },
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "generated-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // A phone-width run starts from a fresh load (drafts never persist),
    // so the generated draft captures cleanly at 320 px too.
    await page.setViewportSize({ width: 320, height: 900 });
    await openAlignment(page, versionId, GEN_PATTERN);
    await page.locator("#alignment-generate-all").click();
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );
    await captureFullPage(page, "generated-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("shows the routing-unavailable notice when no street path exists", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, versionId, GEN_NOROUTE_PATTERN);

    await page.locator("#alignment-generate-all").click();
    await expect(page.locator("#alignment-generate-notice")).toContainText(
      "No street path found",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-generate-notice")).toContainText(
      "Gen Hilltop → Gen Valley",
    );
    await expect(page.locator("#alignment-generate-retry")).toContainText(
      "Retry",
    );
    await expect(page.locator("#alignment-generate-draw")).toContainText(
      "Draw manually",
    );
    // The failure drafts nothing: the section stays missing.
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Missing",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "route-error-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

/**
 * Follow streets (spec 12, step 33).
 *
 * `test.describe("follow streets")` opens the ACTIONS pattern (section 1
 * holds three saved interior points on its own stop pair), selects two
 * neighbouring points in the keyboard list and captures the selection
 * actions with Follow streets enabled. Clicking it routes between the
 * run's neighbours through BrowserStreetRouting — no live Geoapify calls
 * — and replaces exactly that run as an unsaved draft (CR-9: nothing here
 * saves, so the pattern stays saved and every viewport reuses it).
 */
test.describe("follow streets", () => {
  const FOLLOW_PATTERN = "BROWSER-ALIGN-ACTIONS";

  async function selectNeighbourRun(page) {
    const edit = page.locator("#alignment-map-root [data-pa-edit]");
    await expect(edit).toBeEnabled({ timeout: 15000 });
    await edit.click();
    await page.locator("#alignment-point-list-toggle").click();
    await expect(
      page.locator("#alignment-point-list .pa-point-row"),
    ).toHaveCount(3);
    await page.locator('#alignment-point-list [data-point-check="0"]').check();
    await page.locator('#alignment-point-list [data-point-check="1"]').check();
  }

  test("routes between the selected neighbours at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, versionId, FOLLOW_PATTERN);
    await selectNeighbourRun(page);

    // Two neighbouring points enable Follow streets; nothing routes until
    // the action runs.
    const follow = page.locator("#alignment-point-list [data-follow-streets]");
    await expect(follow).toBeEnabled();
    await expect(follow).toContainText("Follow streets");
    await expect(page.locator("#alignment-point-list")).toContainText(
      "Delete points (2)",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "follow-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // Follow streets replaces exactly the selected run with the routed
    // leg: the section turns Unsaved and Undo enables.
    await follow.click();
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );
    await expect(
      page.locator("#alignment-map-root [data-pa-undo]"),
    ).toBeEnabled({ timeout: 15000 });
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "follow-result-1440");

    // A phone-width run starts from a fresh load (drafts never persist),
    // so the enabled action captures cleanly at 320 px too.
    await page.setViewportSize({ width: 320, height: 900 });
    await openAlignment(page, versionId, FOLLOW_PATTERN);
    await selectNeighbourRun(page);
    await expect(
      page.locator("#alignment-point-list [data-follow-streets]"),
    ).toBeEnabled();
    await captureFullPage(page, "follow-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

/**
 * Patterns list (spec 12, step 35).
 *
 * `test.describe("patterns list")` opens the BROWSER_ALIGN route's Patterns
 * list, where every row carries its batched alignment status from
 * `Gtfs.route_alignment_summary/3`. The ACTIONS pattern is fully drawn and
 * applied, so its cell reads Exported; several patterns still miss sections.
 * Clicking a cell patches to that pattern's Alignment task in the same
 * LiveView (no remount). Nothing here writes, so every viewport reuses the
 * same rows.
 */
test.describe("patterns list", () => {
  const EXPORTED_PATTERN = "BROWSER-ALIGN-ACTIONS";

  async function openPatternsList(page, versionId) {
    await page.goto(`/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns`);
    await page.waitForSelector("#patterns-list", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#patterns-list [id^='pattern-alignment-']").first(),
    ).toBeVisible({ timeout: 15000 });
  }

  test("shows the Alignment column and patches to the task at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openPatternsList(page, versionId);

    // The Alignment column header and one status cell per pattern row.
    await expect(page.locator("#patterns-list-container")).toContainText(
      "Alignment",
    );
    await expect(
      page.locator(`#pattern-alignment-${EXPORTED_PATTERN}`),
    ).toContainText("✓ Exported");
    await expect(page.locator("#patterns-list")).toContainText("missing");
    await page.locator("#patterns-list-container").scrollIntoViewIfNeeded();
    await captureViewport(page, "patterns-list-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // The cell patches to the Alignment task without remounting the page.
    await page.locator(`#pattern-alignment-${EXPORTED_PATTERN}`).click();
    await expect(page).toHaveURL(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${EXPORTED_PATTERN}?task=alignment`,
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-task")).toBeVisible({
      timeout: 15000,
    });

    // A phone-width load stacks each row under its labels, including the
    // Alignment status, without horizontal overflow.
    await page.setViewportSize({ width: 320, height: 900 });
    await openPatternsList(page, versionId);
    await expect(
      page.locator(`#pattern-alignment-${EXPORTED_PATTERN}`),
    ).toContainText("✓ Exported");
    await captureFullPage(page, "patterns-list-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });
});

/**
 * Bulk generation (spec 12, step 36).
 *
 * `test.describe("bulk generation")` opens the BROWSER_ALIGN route's
 * Patterns list, narrows the preselected set to the two GEN patterns
 * (GEN-2 routes through BrowserStreetRouting, GEN-1 touches the 40.7500
 * failure stop), captures the capped confirmation dialog, confirms, and
 * captures the per-pattern results: GEN-2 reads "Review suggestion" with
 * a Review action, GEN-1 reads "Draw 1 section". Reviewing GEN-2 patches
 * to its Alignment task with the suggestion applied as an unsaved draft
 * (CR-9: nothing here saves, so the seeds stay reusable). The server is
 * the Playwright webServer block (BROWSER_E2E=true, BrowserStreetRouting —
 * no live Geoapify calls); only tiles are stubbed.
 */
test.describe("bulk generation", () => {
  const GEN_OK_PATTERN = "BROWSER-ALIGN-GEN-2";
  const GEN_FAIL_PATTERN = "BROWSER-ALIGN-GEN-1";

  async function openPatternsList(page, versionId) {
    await page.goto(`/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns`);
    await page.waitForSelector("#patterns-list", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(
      page.locator("#patterns-bulk-generate"),
    ).toBeVisible({ timeout: 15000 });
  }

  async function selectOnlyGenPatterns(page) {
    const checked = page.locator(
      '#patterns-list input[name="bulk-pattern"]:checked',
    );

    while ((await checked.count()) > 0) {
      await checked.first().click();
    }

    await page.locator(`#pattern-bulk-select-${GEN_OK_PATTERN}`).check();
    await page.locator(`#pattern-bulk-select-${GEN_FAIL_PATTERN}`).check();
  }

  test("confirms two patterns and reviews the per-pattern results at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openPatternsList(page, versionId);
    await selectOnlyGenPatterns(page);

    // The confirmation states the section count and the saved-paths
    // promise before any routing call happens.
    await page.locator("#patterns-bulk-generate").click();
    await expect(page.locator("#alignment-bulk-dialog")).toContainText(
      "Create suggestions for 2 sections in 2 patterns. Saved paths and custom paths stay unchanged. Review the results before saving.",
      { timeout: 15000 },
    );
    await page.locator("#patterns-list-container").scrollIntoViewIfNeeded();
    await captureViewport(page, "bulk-dialog-1440");

    // One pattern routes, the other needs drawing; both results render
    // per row with a shared summary notice.
    await page.locator("#alignment-bulk-dialog-confirm").click();
    await expect(page.locator("#patterns-bulk-notice")).toContainText(
      "1 of 2 sections generated",
      { timeout: 30000 },
    );
    await expect(
      page.locator(`#pattern-bulk-success-${GEN_OK_PATTERN}`),
    ).toContainText("◷ Review suggestion");
    await expect(
      page.locator(`#pattern-bulk-failed-${GEN_FAIL_PATTERN}`),
    ).toContainText("! Draw 1 section");
    await page.locator("#patterns-list-container").scrollIntoViewIfNeeded();
    await captureViewport(page, "bulk-results-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // A phone-width view stacks the result rows without overflow.
    await page.setViewportSize({ width: 320, height: 900 });
    await expect(
      page.locator(`#pattern-bulk-success-${GEN_OK_PATTERN}`),
    ).toBeVisible({ timeout: 15000 });
    await captureFullPage(page, "bulk-results-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    // Reviewing the successful pattern patches to its Alignment task
    // with the suggestion applied as an unsaved draft.
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator(`#pattern-bulk-review-${GEN_OK_PATTERN}`).click();
    await expect(page).toHaveURL(
      `/gtfs/${versionId}/routes/${ALIGN_ROUTE}/patterns/${GEN_OK_PATTERN}?task=alignment`,
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-task")).toBeVisible({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );

    expect(problems).toEqual([]);
  });
});
