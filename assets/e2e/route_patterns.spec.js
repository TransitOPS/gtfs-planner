import { test, expect } from "@playwright/test";
import { bodyFitsViewport, readZipTextMember } from "./browser_helpers";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Read-only slice of the route pattern editor, plus the mutate / review / apply
 * journeys.
 *
 * The first test renders the route Patterns list, its states and Details
 * navigation at 1440px and 320px. The remaining tests drive the real editor
 * endpoints: keyboard stop search and insertion, the per-timing added-stop
 * review, a timing save with its next-day preview, copy and reorder, the
 * second-session stale review, dirty navigation, offline reconnection and a
 * downloaded export whose stop times are asserted from the mutated pattern.
 *
 * Every mutating journey uses its own `BROWSER_PATTERNS_EDIT_*` route from
 * `test/support/browser_seed.exs`, so no two journeys share modified records.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// Each viewport drives its own scenario records, so a journey that mutates a
// pattern never changes the starting point of the next viewport's journey.
const VIEWPORTS = [
  {
    label: "1440px",
    width: 1440,
    height: 1000,
    usedRoute: "BROWSER_PATTERNS_EDIT_USED",
    usedPattern: "BROWSER-EDIT-USED",
    deleteRoute: "BROWSER_PATTERNS_EDIT_DELETE",
    deletePattern: "BROWSER-EDIT-DELETE",
  },
  {
    label: "320px",
    width: 320,
    height: 800,
    usedRoute: "BROWSER_PATTERNS_EDIT_USED_B",
    usedPattern: "BROWSER-EDIT-USED-B",
    deleteRoute: "BROWSER_PATTERNS_EDIT_DELETE",
    deletePattern: "BROWSER-EDIT-DELETE-B",
  },
];

const CAPTURE_DIR = process.env.PATTERN_CAPTURE_DIR;

// Viewport captures for transient overlays, full-page captures for task
// surfaces: a fixed dialog is laid out against the viewport, so a full-page
// capture would composite it over unrelated page content.
async function capture(page, name, { fullPage = true } = {}) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });

  if (!fullPage) {
    // A dialog lives in the top layer; letting it settle with animations
    // disabled captures the painted surface instead of a mid-transition frame.
    await page.waitForTimeout(300);
    await page.screenshot({
      path: resolve(CAPTURE_DIR, `${name}.png`),
      fullPage: false,
      animations: "disabled",
    });
    return;
  }

  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`), fullPage });
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
      return Boolean(main) && main.classList.contains("phx-connected") && window.liveSocket?.isConnected();
    },
    { timeout: 20000 },
  );
}

async function openPattern(page, versionId, routeId, patternId, task) {
  await page.goto(`/gtfs/${versionId}/routes/${routeId}/patterns/${patternId}?task=${task}`);
  await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
  await waitForLiveView(page);
}

// Types into the LiveSelect stop search and selects the only match with the
// keyboard, exercising the same path an operator uses. Waiting for the scoped
// result count keeps the selection deterministic instead of racing the
// previous query's options.
async function searchAndSelectStop(page, text) {
  const input = page.locator('#pattern-stop-search input[type="text"]');
  await input.click();
  await input.fill(text);
  await expect(page.locator("#pattern-stop-search-status")).toContainText("1 match", {
    timeout: 10000,
  });
  await input.press("ArrowDown");
  await expect(page.locator("#pattern-stop-search ul div[data-idx='0']")).toBeVisible();
  await input.press("Enter");
}

// Acknowledge every timing in the open review; the final apply stays disabled
// until each timing's current values are explicitly acknowledged.
// Waits for the review dialog to be open with its per-timing content, so an
// acknowledgement is never clicked into a dialog that is still rendering.
async function waitForReviewDialog(page) {
  await expect(page.locator("#stop-review-dialog[data-open='true']")).toBeVisible();
  await expect(page.locator("#stop-review-dialog input[type='checkbox']").first()).toBeVisible();
}

async function acknowledgeReview(page) {
  await waitForReviewDialog(page);

  const boxes = page.locator('#stop-review-dialog input[type="checkbox"]');
  const count = await boxes.count();

  for (let index = 0; index < count; index += 1) {
    const box = boxes.nth(index);
    await box.check();

    // Each acknowledgement is a server round trip, so the checkbox reports the
    // acknowledged state the review actually holds.
    try {
      await expect(box).toHaveAttribute("data-acknowledged", "true", { timeout: 5000 });
    } catch {
      await box.uncheck();
      await box.check();
      await expect(box).toHaveAttribute("data-acknowledged", "true", { timeout: 10000 });
    }
  }
}

async function downloadExport(page) {
  await page.goto("/gtfs/" + (await getVersionId(page)) + "/export");
  await page.waitForSelector("#start-export", { timeout: 15000 });

  const previousHref = await page.locator("#export-download-link").getAttribute("href");

  await page.locator("#start-export").click();
  await expect
    .poll(() => page.locator("#export-download-link").getAttribute("href"), {
      timeout: 120000,
    })
    .not.toBe(previousHref);

  const downloadPromise = page.waitForEvent("download");
  await page.locator("#export-download-link").click();
  const download = await downloadPromise;
  const path = await download.path();

  return readFileSync(path);
}

let versionId;
let problems;

test.beforeEach(async ({ page }) => {
  problems = collectPageErrors(page);
  await logIn(page);
  versionId = await getVersionId(page);
});

test.afterEach(() => {
  expect(problems ?? [], "browser reported errors").toEqual([]);
});

for (const viewport of VIEWPORTS) {
  test(`pattern list, empty and unlinked states, and details navigation at ${viewport.label}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    // Ready list: counts, honest labels and the route's own patterns.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_READY/patterns`);
    await page.waitForSelector("#patterns-list-container", { timeout: 10000 });

    await expect(page.locator("#patterns-count")).toContainText("2 patterns");
    await expect(page.locator("#pattern-trip-count")).toContainText("2 trips in this version");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Central – Valley Hospital");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("All day");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Direction 0");
    await expect(page.locator("#patterns-BROWSER-P1")).toContainText("Typical");
    await expect(page.locator("#patterns-BROWSER-P2")).toContainText("Direction 1");
    await expect(page.locator("#patterns-BROWSER-P2")).toContainText("Not used yet");
    await expect(page.getByText("Outbound", { exact: true })).toHaveCount(0);
    await expect(page.getByText("Inbound", { exact: true })).toHaveCount(0);
    expect(await bodyFitsViewport(page), "list overflows").toBe(true);

    // Details navigation: opening a pattern lands on Stops.
    await page.locator("#pattern-open-BROWSER-P1").click();
    await page.waitForSelector("#pattern-stops", { timeout: 10000 });
    await expect(page.locator("#pattern-task-stops")).toHaveAttribute("aria-current", "page");
    await expect(page.locator("#pattern-stop-1")).toContainText("Pattern Stop 1");
    await expect(page.locator("#pattern-stop-1")).toContainText("First stop");
    await expect(page.locator("#edit-status")).toContainText("Saved in this version");
    await expect(page.locator("#published-version-notice")).toContainText("a published version");

    // The Details task shows the stored values and the Pattern ID disclosure.
    await page.locator("#pattern-task-details").click();
    await page.waitForSelector("#pattern-details-form", { timeout: 10000 });
    await expect(page.locator("#pattern-details-name")).toHaveValue("Central – Valley Hospital");
    await expect(page.locator("#pattern-details-form")).toContainText("Headsign for new trips");
    await page.locator("#pattern-details-additional summary").click();
    await expect(page.locator("#pattern-details-id")).toContainText("BROWSER-P1");
    expect(await bodyFitsViewport(page), "details overflows").toBe(true);

    // First use: a route with no trips and no patterns.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_EMPTY/patterns`);
    await page.waitForSelector("#patterns-empty", { timeout: 10000 });
    await expect(page.locator("#patterns-empty")).toContainText("Add the first pattern");
    await expect(page.locator("#patterns-create-empty")).toBeVisible();
    expect(await bodyFitsViewport(page), "empty state overflows").toBe(true);

    const createBox = await page.locator("#patterns-create-empty").boundingBox();
    expect(createBox).not.toBeNull();
    expect(createBox.height).toBeGreaterThanOrEqual(44);

    // Unlinked trips: build affordance without mutating anything.
    await page.goto(`/gtfs/${versionId}/routes/BROWSER_PATTERNS_UNLINKED/patterns`);
    await page.waitForSelector("#patterns-unlinked", { timeout: 10000 });
    await expect(page.locator("#patterns-unlinked")).toContainText(
      "Group existing trips into patterns",
    );
    await expect(page.locator("#patterns-build")).toBeVisible();
    expect(await bodyFitsViewport(page), "unlinked state overflows").toBe(true);

    const buildBox = await page.locator("#patterns-build").boundingBox();
    expect(buildBox).not.toBeNull();
    expect(buildBox.height).toBeGreaterThanOrEqual(44);
  });

  test(`keyboard stop search adds a stop that must be reviewed and acknowledged at ${viewport.label}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPattern(page, versionId, viewport.usedRoute, viewport.usedPattern, "stops");

    // The insertion position is chosen before the search, so the staged stop
    // lands where the operator asked for it.
    await page.selectOption("#pattern-insert-after", "1");

    // Keyboard search: the scoped query returns the version's stops with their
    // names and IDs, and keyboard selection stages the chosen stop.
    const searchInput = page.locator('#pattern-stop-search input[type="text"]');
    await searchInput.click();
    await searchInput.fill("Pattern Stop");
    await page.waitForSelector("#pattern-stop-option-BROWSER_PATTERN_STOP_1", { timeout: 10000 });
    await expect(page.locator("#pattern-stop-search-status")).toContainText("4 matches");

    await searchInput.fill("Pattern Stop 4");
    await expect(page.locator("#pattern-stop-search-status")).toContainText("1 match", {
      timeout: 10000,
    });
    await expect(page.locator("#pattern-stop-option-BROWSER_PATTERN_STOP_4")).toBeVisible();
    await searchInput.press("ArrowDown");
    await expect(page.locator("#pattern-stop-search ul div[data-idx='0']")).toBeVisible();
    await searchInput.press("Enter");

    await expect(page.locator("#pattern-stop-2")).toContainText("Pattern Stop 4");
    await expect(page.locator("#pattern-stops")).toHaveAttribute("data-dirty", "true");
    await capture(page, `step7-stops-added-${viewport.label}`);

    await page.locator("#pattern-save-stops").click();

    // The review must come from the server result, and every timing has to be
    // acknowledged before the final apply is available.
    await expect(page.locator("#stop-review-dialog[data-open='true']")).toBeVisible();
    await expect(page.locator("#stop-review-dialog-title")).toContainText("Update 1 trip?");
    await expect(page.locator("#stop-review-dialog-body")).toContainText("a published version");
    await expect(page.locator("#stop-review-dialog-confirm")).toBeDisabled();
    await capture(page, `step7-stop-review-${viewport.label}`, { fullPage: false });

    await acknowledgeReview(page);
    await expect(page.locator("#stop-review-dialog-confirm")).toBeEnabled();
    await page.locator("#stop-review-dialog-confirm").click();

    await expect(page.locator("#status")).toContainText("1 trips updated", { timeout: 15000 });
    await expect(page.locator("#stop-review-dialog[data-open='true']")).toBeHidden();

    // The occurrence order is persisted, not just rendered.
    await page.reload();
    await page.waitForSelector("#pattern-stops", { timeout: 10000 });
    await waitForLiveView(page);
    await expect(page.locator("#pattern-stop-2")).toContainText("Pattern Stop 4");
    await expect(page.locator("#pattern-stop-4")).toContainText("Pattern Stop 3");
    expect(await bodyFitsViewport(page), "stops overflows").toBe(true);
  });

  test(`a timing save previews next-day clocks and updates only its trips at ${viewport.label}`, async ({
    page,
  }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPattern(
      page,
      versionId,
      "BROWSER_PATTERNS_EDIT_EXPORT",
      "BROWSER-EDIT-EXPORT",
      "timings",
    );

    await expect(page.locator("#timing-row-1")).toContainText(
      "Arrival relative to first departure",
    );
    await expect(page.locator("#timing-arrival-1")).toHaveValue("00:00");

    await page.fill("#timing-preview", "25:00");
    await expect(page.locator("#timing-preview-1")).toContainText("01:00 +1 day");
    await capture(page, `step7-timings-preview-${viewport.label}`);

    await page.fill("#timing-preview", "08:00");
    await page.fill("#timing-departure-2", "06:00");
    await expect(page.locator("#timing-preview-2")).toContainText("08:04");

    await page.locator("#timing-save").click();

    await expect(page.locator("#timing-review-dialog[data-open='true']")).toBeVisible();
    await expect(page.locator("#timing-review-dialog-title")).toContainText("Update 1 trip?");
    await page.locator("#timing-review-dialog-confirm").click();

    await expect(page.locator("#status")).toContainText("1 trips updated");
    await page.reload();
    await page.waitForSelector("#timing-rows", { timeout: 10000 });
    await waitForLiveView(page);
    await expect(page.locator("#timing-departure-2")).toHaveValue("06:00");
    expect(await bodyFitsViewport(page), "timings overflows").toBe(true);
  });

  test(`copy, reorder and delete dialogs behave truthfully at ${viewport.label}`, async ({
    page,
  }) => {
    test.setTimeout(60_000);
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPattern(
      page,
      versionId,
      "BROWSER_PATTERNS_EDIT_UNUSED",
      "BROWSER-EDIT-UNUSED",
      "stops",
    );

    // Copying produces a separate service with no trips and its own stop list.
    const originalUrl = page.url();
    await page.locator("#pattern-copy").click();
    await page.waitForURL(
      (url) =>
        url.href !== originalUrl && /patterns\/[^?]+\?task=stops$/.test(url.href),
      { timeout: 15000 },
    );
    await waitForLiveView(page);
    await expect(page.locator("#pattern-trip-total")).toContainText("0");

    await page.locator("#pattern-stop-2-move-up").click();
    await expect(page.locator("#pattern-stop-1")).toContainText("Pattern Stop 2");
    // Reordering returns focus to the moved occurrence.
    await expect(page.locator("#pattern-stop-1")).toBeFocused();

    await page.locator("#pattern-save-stops").click();
    await expect(page.locator("#stop-review-dialog[data-open='true']")).toBeHidden();
    await expect(page.locator("#status")).toContainText("Changes saved in this version");

    // The custom-trip pattern blocks structural edits and explains why.
    await openPattern(
      page,
      versionId,
      "BROWSER_PATTERNS_EDIT_CUSTOM",
      "BROWSER-EDIT-CUSTOM",
      "stops",
    );

    await expect(page.locator("#pattern-stops-custom")).toContainText(
      "keep their imported stop times",
    );
    await expect(page.locator("#pattern-remove-stop-1")).toBeDisabled();
    await capture(page, `step7-custom-blocked-${viewport.label}`);

    // A used pattern refuses deletion; an unused one confirms and deletes.
    await openPattern(page, versionId, viewport.usedRoute, viewport.usedPattern, "stops");

    await page.locator("#pattern-delete").click();
    await expect(page.locator("#pattern-blocked-dialog[data-open='true']")).toBeVisible();
    await expect(page.locator("#pattern-blocked-dialog")).toContainText("in use");
    await expect(page.locator("#pattern-blocked-dialog")).not.toContainText("Move trips");
    await capture(page, `step7-blocked-delete-${viewport.label}`, { fullPage: false });
    await page.locator("#pattern-blocked-dialog-cancel").click();

    await openPattern(page, versionId, viewport.deleteRoute, viewport.deletePattern, "stops");

    await page.locator("#pattern-delete").click();
    await expect(page.locator("#pattern-delete-dialog[data-open='true']")).toBeVisible();
    await page.locator("#pattern-delete-dialog-confirm").click();
    await page.waitForURL(/patterns$/, { timeout: 15000 });
    await expect(page.locator("#patterns-heading, #patterns-empty").first()).toBeVisible();
  });
}

test("a second session's stale review keeps the edits and offers Refresh review", async ({
  browser,
}) => {
  test.setTimeout(120_000);
  const context = await browser.newContext();
  const pageA = await context.newPage();
  const pageB = await context.newPage();
  try {
    await logIn(pageA);
    versionId = await getVersionId(pageA);
    await logIn(pageB);

    await openPattern(
      pageA,
      versionId,
      "BROWSER_PATTERNS_EDIT_STALE",
      "BROWSER-EDIT-STALE",
      "stops",
    );

    await openPattern(
      pageB,
      versionId,
      "BROWSER_PATTERNS_EDIT_STALE",
      "BROWSER-EDIT-STALE",
      "details",
    );

    // An interior insertion, so the review proposes an estimated value instead
    // of requiring explicit terminal times.
    await pageA.selectOption("#pattern-insert-after", "1");
    await searchAndSelectStop(pageA, "Pattern Stop 4");
    await expect(pageA.locator("#pattern-stop-2")).toContainText("Pattern Stop 4");
    await pageA.locator("#pattern-save-stops").click();
    await expect(pageA.locator("#stop-review-dialog[data-open='true']")).toBeVisible();
    await acknowledgeReview(pageA);

    // The other session changes the pattern while the review is open.
    const currentName = await pageB.inputValue("#pattern-details-name");
    await pageB.fill("#pattern-details-name", `${currentName} renamed`);
    await pageB.locator("#pattern-details-submit").click();
    await expect(pageB.locator("#status")).toContainText("Changes saved in this version");

    await pageA.locator("#stop-review-dialog-confirm").click();

    await expect(pageA.locator("#stop-review-error")).toContainText("changed since");
    await expect(pageA.locator("#stop-review-refresh")).toBeVisible();
    await expect(pageA.locator("#pattern-stop-2")).toContainText("Pattern Stop 4");

    await pageA.locator("#stop-review-refresh").click();
    await expect(pageA.locator("#stop-review-dialog[data-open='true']")).toBeVisible();
    await acknowledgeReview(pageA);
    await pageA.locator("#stop-review-dialog-confirm").click();
    await expect(pageA.locator("#status")).toContainText("updated");
  } finally {
    await context.close();
  }
});

test("dirty navigation asks before discarding staged edits", async ({ page }) => {
  await openPattern(
    page,
    versionId,
    "BROWSER_PATTERNS_EDIT_UNUSED",
    "BROWSER-EDIT-UNUSED",
    "details",
  );

  await page.fill("#pattern-details-name", "Unsaved browser rename");
  await expect(page.locator("#edit-status")).toContainText("Unsaved changes");

  await page.locator("#pattern-back").click();
  await expect(page.locator("#discard-changes-dialog[data-open='true']")).toBeVisible();
  await page.locator("#discard-changes-dialog-cancel").click();

  await expect(page.locator("#discard-changes-dialog[data-open='true']")).toBeHidden();
  await expect(page.locator("#pattern-details-name")).toHaveValue("Unsaved browser rename");
});

test("a lost connection disables committing and reconnection announces recovery", async ({
  page,
}) => {
  await openPattern(
    page,
    versionId,
    "BROWSER_PATTERNS_EDIT_UNUSED",
    "BROWSER-EDIT-UNUSED",
    "stops",
  );

  await expect(page.locator("#pattern-connectivity")).toBeHidden();

  // The repository's established idiom for an offline editor: a real socket
  // disconnect, which is what a lost connection looks like to the client.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator("#pattern-connectivity")).toBeVisible();
  await expect(page.locator("#pattern-connectivity")).toContainText("Connection lost");
  await expect(page.locator("#pattern-save-stops")).toBeDisabled();
  await capture(page, "step7-offline", { fullPage: false });

  await page.evaluate(() => window.liveSocket.connect());
  await expect(page.locator("#pattern-connectivity")).toBeHidden({ timeout: 20000 });
  await expect(page.locator("#status")).toContainText("Reconnected");
  await expect(page.locator("#pattern-save-stops")).toBeEnabled();
});

test("the downloaded export carries the mutated pattern's exact stop times", async ({ page }) => {
  test.setTimeout(240_000);
  await openPattern(
    page,
    versionId,
    "BROWSER_PATTERNS_EDIT_EXPORT",
    "BROWSER-EDIT-EXPORT",
    "timings",
  );

  await page.fill("#timing-departure-2", "07:30");
  await page.locator("#timing-save").click();
  await expect(page.locator("#timing-review-dialog[data-open='true']")).toBeVisible();
  await page.locator("#timing-review-dialog-confirm").click();
  await expect(page.locator("#status")).toContainText("1 trips updated");

  const zip = await downloadExport(page);
  const stopTimes = readZipTextMember(zip, "stop_times.txt");
  const rows = stopTimes
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.split(","));

  const header = rows[0];
  const tripIndex = header.indexOf("trip_id");
  const stopIndex = header.indexOf("stop_id");
  const arrivalIndex = header.indexOf("arrival_time");
  const departureIndex = header.indexOf("departure_time");

  const tripRows = rows
    .slice(1)
    .filter((row) => row[tripIndex] === "BROWSER_EXPORT_T1");

  const byStop = new Map(tripRows.map((row) => [row[stopIndex], row]));

  expect(byStop.get("BROWSER_PATTERN_STOP_1")[arrivalIndex]).toBe("08:00:00");
  expect(byStop.get("BROWSER_PATTERN_STOP_1")[departureIndex]).toBe("08:00:00");
  expect(byStop.get("BROWSER_PATTERN_STOP_2")[arrivalIndex]).toBe("08:04:00");
  expect(byStop.get("BROWSER_PATTERN_STOP_2")[departureIndex]).toBe("08:07:30");
  expect(byStop.get("BROWSER_PATTERN_STOP_3")[arrivalIndex]).toBe("08:10:00");
  expect(byStop.get("BROWSER_PATTERN_STOP_3")[departureIndex]).toBe("08:11:00");

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    writeFileSync(resolve(CAPTURE_DIR, "ev-11-export-stop-times.txt"), stopTimes);
  }
});
