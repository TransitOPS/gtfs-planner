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
    // saved paths stay unchanged and Cancel stays available. The fake
    // router resolves in milliseconds, so a post-click poll can miss the
    // panel entirely on a fast server: observe it with a MutationObserver
    // that clicks and reads the panel text synchronously at its
    // appearance edge, even if it vanishes a frame later.
    const inflightText = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("in-flight panel never appeared")),
          5000,
        );
        const read = () => {
          const panel = document.querySelector("#alignment-generating");
          if (panel) {
            clearTimeout(timer);
            observer.disconnect();
            resolve(panel.innerText);
          }
        };
        const observer = new MutationObserver(read);
        observer.observe(document.body, {
          childList: true,
          subtree: true,
        });
        document.querySelector("#alignment-generate-all").click();
        read();
      });
    });
    expect(inflightText).toContain("Finding a street path…");
    expect(inflightText).toContain("Cancel generation");
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

    // The Map line column header and one status cell per pattern row.
    await expect(page.locator("#patterns-list-container")).toContainText(
      "Map line",
    );
    await expect(
      page.locator(`#pattern-alignment-${EXPORTED_PATTERN}`),
    ).toContainText("Ready");
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
    ).toContainText("Ready");
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

  // The dialog holds the selection: it opens with every pattern that still
  // misses sections checked, and each toggle is a server round trip.
  async function chooseOnlyGenPatterns(page) {
    const boxes = page.locator('#alignment-bulk-dialog input[name="bulk-pattern"]');
    const count = await boxes.count();

    for (let index = 0; index < count; index += 1) {
      const box = boxes.nth(index);
      const value = await box.getAttribute("value");
      const wanted = value === GEN_OK_PATTERN || value === GEN_FAIL_PATTERN;

      if ((await box.isChecked()) !== wanted) await box.click();
      await expect(box).toBeChecked({ checked: wanted });
    }
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

    // The confirmation states the section count and the saved-paths
    // promise before any routing call happens.
    await page.locator("#patterns-bulk-generate").click();
    await expect(page.locator("#alignment-bulk-dialog")).toContainText(
      "Saved and custom paths stay unchanged, and nothing is saved until you review each suggestion.",
      { timeout: 15000 },
    );
    await chooseOnlyGenPatterns(page);
    await expect(page.locator("#alignment-bulk-summary")).toContainText(
      "2 sections in 2 patterns will get a suggested path.",
    );
    await page.locator("#patterns-list-container").scrollIntoViewIfNeeded();
    await captureViewport(page, "bulk-dialog-1440");

    // One pattern routes, the other needs drawing; both results render
    // per row with a shared summary notice.
    await page.locator("#alignment-bulk-dialog-confirm").click();
    await expect(page.locator("#patterns-bulk-notice")).toContainText(
      "Suggested paths for 1 of 2 sections",
      { timeout: 30000 },
    );
    await expect(
      page.locator(`#pattern-bulk-success-${GEN_OK_PATTERN}`),
    ).toContainText("Review suggestion");
    await expect(
      page.locator(`#pattern-bulk-failed-${GEN_FAIL_PATTERN}`),
    ).toContainText("Draw 1 section");
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

/**
 * Generation journeys (spec 12, step 37).
 *
 * `test.describe("generation journeys")` proves the full production
 * composition end to end: GEN-2 (AL_S3 → AL_S4, every section missing)
 * generates a street path, saves it through the shared-pair scope dialog
 * (S3 → S4 is also used by A, A-B and LONG, so "Only this pattern" is
 * the default), and exports; GEN-1 (touches the 40.7500 stop, so
 * BrowserStreetRouting reports :no_route) proves the phone-width routing
 * failure; the bulk dialog proves its phone-width layout without routing
 * (nothing here confirms, so no paths change). This block runs last in
 * the file because the save journey commits GEN-2's sections. The server
 * is the Playwright webServer block (BROWSER_E2E=true,
 * BrowserStreetRouting — no live Geoapify calls); only tiles are stubbed.
 *
 * NOTE: the subspec names BROWSER-ALIGN-GEN-1 for the save journey, but
 * the seeds prove GEN-1 touches the unroutable 40.7500 stop and GEN-2 is
 * the routable pattern (steps 32/36 precedent) — the journey runs on
 * GEN-2 and the failure journey on GEN-1.
 */
test.describe("generation journeys", () => {
  const SAVE_PATTERN = "BROWSER-ALIGN-GEN-2";
  const NOROUTE_PATTERN = "BROWSER-ALIGN-GEN-1";

  // The save dialog animates its panel opacity; wait for it to settle so
  // captures never catch it mid-fade (pattern_alignment.spec.js precedent).
  async function settleDialog(page, dialogId) {
    await page.waitForFunction(
      (id) => {
        const panel = document.querySelector(`#${id} > div > div`);
        return panel && getComputedStyle(panel).opacity === "1";
      },
      dialogId,
      { timeout: 5000 },
    );
  }

  async function openPatternsList(page, _versionId) {
    await page.goto(`/gtfs/${_versionId}/routes/${ALIGN_ROUTE}/patterns`);
    await page.waitForSelector("#patterns-list", { timeout: 15000 });
    await waitForLiveView(page);
    await expect(page.locator("#patterns-bulk-generate")).toBeVisible({
      timeout: 15000,
    });
  }

  test("generates, saves and exports the street path at desktop and phone widths", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await openAlignment(page, versionId, SAVE_PATTERN);

    // The first-alignment overlay offers generation for the missing section.
    await expect(page.locator("#alignment-generate-overlay")).toBeVisible({
      timeout: 15000,
    });
    // The in-flight panel is proven in the "generation" block above; the
    // instant fake may finish before any poll observes it here, so wait
    // for the settled draft directly (a click that starts nothing still
    // fails at the Unsaved assertion below).
    await page.locator("#alignment-generate-all").click();
    await expect(page.locator("#alignment-generating")).toBeHidden({
      timeout: 15000,
    });
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Unsaved",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "◷ Unsaved",
    );
    await expect(page.locator("#alignment-section-status-1")).toHaveClass(
      /badge-warning/,
    );
    await expect(page.locator("#status")).toContainText(
      "Suggested path ready. Review the streets before saving.",
      { timeout: 15000 },
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "gen-journey-generated-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // The S3 → S4 pair is shared, so saving asks for scope with
    // "Only this pattern" checked; confirming writes the override.
    await expect(page.locator("#alignment-save")).toBeEnabled();
    await page.locator("#alignment-save").click();
    await expect(page.locator("#alignment-save-dialog")).toHaveAttribute(
      "data-open",
      "true",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "Who should use this path?",
    );
    await expect(page.locator("#alignment-save-dialog")).toContainText(
      "Other patterns",
    );
    await expect(
      page.locator("#alignment-save-scope-1-local"),
    ).toBeChecked();
    await settleDialog(page, "alignment-save-dialog");
    await captureViewport(page, "gen-journey-scope-1440");
    await page.locator("#alignment-save-dialog-confirm").click();

    // The save materializes the now-complete pattern: sections read Saved
    // and the header reads Exported.
    await expect(page.locator("#status")).toContainText(
      "Alignment saved.",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "✓ Saved",
    );
    await expect(page.locator("#alignment-status")).toContainText(
      "✓ Exported",
    );
    // The save consumed the draft: Discard hides and Save disables.
    await expect(page.locator("#alignment-discard")).toHaveCount(0);
    await expect(page.locator("#alignment-save")).toBeDisabled();
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureViewport(page, "gen-journey-saved-1440");
    expect(await bodyFitsViewport(page)).toBe(true);

    // A phone-width load keeps the saved state without overflow (drafts
    // never persist, so the generated draft itself is covered by the
    // existing generated-320 capture).
    await page.setViewportSize({ width: 320, height: 900 });
    await openAlignment(page, versionId, SAVE_PATTERN);
    await expect(page.locator("#alignment-section-status-1")).toContainText(
      "✓ Saved",
    );
    await expect(page.locator("#alignment-status")).toContainText(
      "✓ Exported",
    );
    await captureFullPage(page, "gen-journey-saved-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("shows the routing failure at phone width", async ({ page }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    await page.setViewportSize({ width: 320, height: 900 });
    await openAlignment(page, versionId, NOROUTE_PATTERN);

    await page.locator("#alignment-generate-all").click();
    await expect(page.locator("#alignment-generate-notice")).toContainText(
      "No street path found",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-generate-notice")).toContainText(
      "Draw manually",
    );
    // The failure drafts nothing: the section stays missing.
    await expect(page.locator("#alignment-section-1")).toContainText(
      "Missing",
    );
    await page.locator("#alignment-task").scrollIntoViewIfNeeded();
    await captureFullPage(page, "gen-journey-route-error-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    expect(problems).toEqual([]);
  });

  test("opens the bulk confirmation at phone width without routing", async ({
    page,
  }) => {
    const problems = collectPageErrors(page);
    await stubTiles(page);
    await logIn(page);
    const versionId = await getVersionId(page);

    // The dialog opens over the default preselection and is dismissed
    // without confirming: no routing call runs and no path changes.
    await page.setViewportSize({ width: 320, height: 900 });
    await openPatternsList(page, versionId);
    await page.locator("#patterns-bulk-generate").click();
    await expect(page.locator("#alignment-bulk-dialog")).toContainText(
      "Patterns to include",
      { timeout: 15000 },
    );
    await expect(page.locator("#alignment-bulk-dialog")).toContainText(
      "nothing is saved until you review each suggestion.",
    );
    await page.locator("#patterns-list-container").scrollIntoViewIfNeeded();
    await captureFullPage(page, "gen-journey-bulk-320");
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.locator("#alignment-bulk-dialog-cancel").click();
    await expect(page.locator("#alignment-bulk-dialog")).toHaveAttribute(
      "data-open",
      "false",
      { timeout: 15000 },
    );

    expect(problems).toEqual([]);
  });
});
