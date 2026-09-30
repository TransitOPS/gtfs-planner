/**
 * Bulk and frequency journeys for the advanced trip editing package (spec 18,
 * step 43; EV-40 rejects FH-40 and FH-45).
 *
 * Real Chromium → Phoenix (`BROWSER_E2E=true`) → RouteSchedulesLive → the Gtfs
 * facade, over the throwaway pg_tmp database `bin/test-browser` seeds from
 * `test/support/browser_seed.exs`. The fixture routes are step 41's:
 *
 *   BROWSER_SCHEDULES_GRID — BSG_T08–T10 are the Peak trips 08:30/09:00/09:30
 *     (the faster of the pattern's two timings; the last column shows the
 *     arrival);
 *   BROWSER_SCHEDULES_FREQ — BSF_T1, one linked frequency trip with the window
 *     09:00–10:00 every 10 minutes;
 *   BROWSER_SCHEDULES_MUTATE — one pattern carrying listed trips and a
 *     frequency trip on CAL_DAILY (the imported mix).
 *
 * The file runs with one worker and in declaration order. The surface
 * captures run first and write nothing; the journeys then act on their own
 * rows and leave GRID's CAL_DAILY trips as they found them: the shift is
 * undone in its own test, and the copy and the paste write CAL_SCHOOL rows
 * only. `route_schedules_grid.spec.js` runs after this file (alphabetically)
 * and reads BSG_T01, T04, T05, T06, T07, BSG_CUSTOM and BSB_T001 on CAL_DAILY,
 * none of which these journeys write.
 *
 * `bin/test-browser` runs this file in branch review; the captures land in the
 * package's `evidence/browser/` folder, resolved from SCHEDULE_SPEC_ROOT when
 * the runner points at the checkout that holds `.specs/`.
 */
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { logInAs } from "./browser_helpers";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
// A worktree checkout carries no gitignored `.specs/`; SCHEDULE_SPEC_ROOT
// points the capture writes at the checkout that holds the package.
const SPEC_ROOT =
  process.env.SCHEDULE_SPEC_ROOT ||
  resolve(REPO_ROOT, ".specs", "18-advanced-trip-editing");
const EVIDENCE_DIR = resolve(SPEC_ROOT, "evidence", "browser");

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "[redacted]",
};

const VERSION_NAME = "Browser E2E Version";
const GRID_ROUTE = "BROWSER_SCHEDULES_GRID";
const FREQ_ROUTE = "BROWSER_SCHEDULES_FREQ";
const MUTATE_ROUTE = "BROWSER_SCHEDULES_MUTATE";

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "1280x800", width: 1280, height: 800 },
];

// The window editor writes as the value changes, and a native paste shortcut
// reaches the grid hook: Chromium maps paste to Cmd+V on macOS and Ctrl+V
// elsewhere (the hook accepts either modifier for its own chords).
const PASTE_CHORD = process.platform === "darwin" ? "Meta+v" : "Control+v";

// The version is resolved by name so the journeys read the fixture the seed
// names, not whichever version is the organization's latest published default.
async function versionIdFor(page) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: VERSION_NAME });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${VERSION_NAME} is missing its version ID`);
  return versionId;
}

function schedulesPath(versionId, routeId) {
  return `/gtfs/${versionId}/routes/${routeId}/schedules`;
}

// Captures stay viewport-sized: the sticky grid bar's position is part of the
// observation, and a full-page shot would move it into the page flow.
async function capture(page, name) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(EVIDENCE_DIR, `${name}.png`),
    fullPage: false,
    animations: "disabled",
  });
}

/**
 * Selects the three Peak trips BSG_T08–T10 the way a keyboard operator does:
 * Space toggles the cursor row and becomes the anchor, and two Shift+ArrowDown
 * presses extend the range over T09 and T10 (AC-8).
 */
async function selectThreeTrips(page) {
  await page.locator("#cell-BSG_T08-1").click();
  await expect(page.locator("#cell-BSG_T08-1")).toBeFocused();
  await page.keyboard.press("Space");
  await expect(page.locator("#trip-select-BSG_T08")).toBeChecked();

  await page.keyboard.press("Shift+ArrowDown");
  await page.keyboard.press("Shift+ArrowDown");

  await expect(page.locator("#selection-count")).toHaveText("3 trips selected");
  await expect(page.locator("#trip-select-BSG_T09")).toBeChecked();
  await expect(page.locator("#trip-select-BSG_T10")).toBeChecked();
}

// The service day the copy and the paste target, chosen in the review's own
// select rather than accepted from its default.
async function chooseServiceDay(page, selectId, serviceId) {
  await page.selectOption(selectId, serviceId);
}

/**
 * The five surfaces this step adds, captured at both viewports. Every state is
 * a review or a preview, so the two passes write nothing and cannot change
 * what the journeys below assert (INV-2).
 */
for (const viewport of VIEWPORTS) {
  test.describe(`Schedules bulk surface captures ${viewport.label}`, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } });

    test("captures the shift, copy, paste, mixed and convert surfaces", async ({ page }) => {
      test.setTimeout(120_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page);

      // The Shift strip's preview: +5 from the review's defaults, amber cells,
      // the original time in the cell's title.
      await page.goto(schedulesPath(versionId, GRID_ROUTE));
      await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:30");
      await selectThreeTrips(page);

      await page.locator("#bulk-shift").click();
      await expect(page.locator("#shift-strip")).toBeVisible();
      await expect(page.locator("#strip-apply")).toBeEnabled();
      await expect(page.locator("#cell-BSG_T08-1")).toHaveText("08:35");
      await expect(page.locator("#cell-BSG_T08-1")).toHaveClass(/is-preview/);
      await capture(page, `step-043-shift-preview-${viewport.label}`);

      await page.locator("#strip-cancel").click();
      await expect(page.locator("#shift-strip")).toHaveCount(0);

      // The Copy to calendar review on School days: the metric cells, the
      // shared-dates card and the one primary. Cancel keeps the selection.
      await page.locator("#bulk-copy").click();
      await expect(page.locator("#change-review")).toBeVisible();
      await chooseServiceDay(page, "#review-target", "CAL_SCHOOL");
      await expect(page.locator("#change-review-title")).toHaveText(
        "Copy 3 trips to School days?",
      );
      await expect(page.locator("#review-skip-help")).toHaveText("None do on School days.");
      await capture(page, `step-043-copy-review-${viewport.label}`);

      await page.locator("#review-cancel").click();
      await expect(page.locator("#change-review")).toHaveCount(0);

      // The Paste copied trips dialog: the clipboard, then a new first
      // departure on School days (a review only; nothing is pasted yet).
      await page.locator("#cell-BSG_T10-1").click();
      await page.keyboard.press("Control+c");
      await expect(page.locator("#grid-bar-message")).toContainText("3 trips copied.");
      await page.keyboard.press(PASTE_CHORD);
      await expect(page.locator("#paste-dialog")).toBeVisible();

      await chooseServiceDay(page, "#paste-service", "CAL_SCHOOL");
      await page.locator("#paste-new-time").check();
      await page.fill("#paste-at", "14:00");
      await page.locator("#paste-at").blur();
      await expect(page.locator("#paste-result")).toContainText("14:00, 14:30, 15:00");
      await capture(page, `step-043-paste-dialog-${viewport.label}`);

      await page.locator("#paste-cancel").click();
      await expect(page.locator("#paste-dialog")).toHaveCount(0);

      // The imported listed/frequency mix on the mutation route.
      await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
      await expect(page.locator("#mixed-service-warning")).toBeVisible();
      await capture(page, `step-043-mixed-warning-${viewport.label}`);

      // The Convert review on the frequency route: the stored window's six
      // departures, the three metric cells and the irreversible footer.
      await page.goto(schedulesPath(versionId, FREQ_ROUTE));
      await expect(page.locator("#trip-BSF_T1-frequency")).toContainText(
        "Every 10 min, 09:00–10:00",
      );
      await page.locator("#trip-BSF_T1-menu").click();
      await page.locator("#trip-BSF_T1-convert").click();
      await expect(page.locator("#convert-review")).toBeVisible();
      await expect(page.locator("#convert-review-title")).toHaveText(
        "Convert to 6 scheduled trips?",
      );
      await capture(page, `step-043-freq-convert-${viewport.label}`);

      await page.locator("#convert-keep").click();
      await expect(page.locator("#convert-review")).toHaveCount(0);
    });
  });
}

/**
 * The bulk journeys, in order, against the freshly seeded database. They act
 * on BSG_T08–T10 unless noted, so they cannot change what another journey
 * asserts.
 */
test.describe("Schedules bulk journeys", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("Shift times +5 previews, applies and Undo restores (FH-45)", async ({ page }) => {
    test.setTimeout(90_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));
    await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:30");
    await expect(page.locator("#trip-BSG_T09-start")).toHaveText("09:00");
    await expect(page.locator("#trip-BSG_T10-start")).toHaveText("09:30");

    await selectThreeTrips(page);
    await page.locator("#bulk-shift").click();
    await expect(page.locator("#shift-strip")).toBeVisible();
    await expect(page.locator("#strip-min")).toHaveValue("5");
    await expect(page.locator("#strip-apply")).toHaveText("Shift 3 trips");
    await expect(page.locator("#strip-apply")).toBeEnabled();

    // The review previews the new times in the grid and writes nothing: the
    // first cell reads +5 in the preview ground with the stored time in its
    // title.
    await expect(page.locator("#cell-BSG_T08-1")).toHaveText("08:35");
    await expect(page.locator("#cell-BSG_T08-1")).toHaveClass(/is-preview/);
    await expect(page.locator("#cell-BSG_T08-1")).toHaveAttribute("title", "Was 08:30");
    await expect(page.locator("#cell-BSG_T10-1")).toHaveText("09:35");

    await page.locator("#strip-apply").click();
    await expect(page.locator("#shift-strip")).toHaveCount(0);
    await expect(page.locator("#grid-bar-message")).toContainText("Shifted 3 trips 5 min later.");
    await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:35");
    await expect(page.locator("#trip-BSG_T09-start")).toHaveText("09:05");
    await expect(page.locator("#trip-BSG_T10-start")).toHaveText("09:35");
    await expect(page.locator("#undo-action")).toBeVisible();

    // Undo restores every shifted time (R10, AC-21).
    await page.locator("#undo-action").click();
    await expect(page.locator("#grid-bar-message")).toContainText("Undid:");
    await expect(page.locator("#cell-BSG_T08-1")).toHaveText("08:30");
    await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:30");
    await expect(page.locator("#trip-BSG_T09-start")).toHaveText("09:00");
    await expect(page.locator("#trip-BSG_T10-start")).toHaveText("09:30");
  });

  test("Copy to School days reports the skips and the shared dates", async ({ page }) => {
    test.setTimeout(90_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));
    await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:30");

    // The first copy finds no departure there and copies all three.
    await selectThreeTrips(page);
    await page.locator("#bulk-copy").click();
    await expect(page.locator("#change-review")).toBeVisible();
    await chooseServiceDay(page, "#review-target", "CAL_SCHOOL");
    await expect(page.locator("#change-review-title")).toHaveText(
      "Copy 3 trips to School days?",
    );
    await expect(page.locator("#review-skip")).toBeChecked();
    await expect(page.locator("#review-skip-help")).toHaveText("None do on School days.");
    // PM-12: the shared-dates sentence, not the date count.
    await expect(page.locator("#change-review")).toContainText("Also changes · Every day service");
    await expect(page.locator("#change-review")).toContainText(/both run on \d+ dates/);
    await expect(page.locator("#review-apply")).toHaveText("Copy 3 trips");

    await page.locator("#review-apply").click();
    await expect(page.locator("#change-review")).toHaveCount(0);
    await expect(page.locator("#grid-bar-message")).toContainText(
      "Copied 3 trips to School days.",
    );

    // The second copy finds the three copies just created and skips them all;
    // the primary cannot be applied and the review says why.
    await selectThreeTrips(page);
    await page.locator("#bulk-copy").click();
    await expect(page.locator("#change-review")).toBeVisible();
    await chooseServiceDay(page, "#review-target", "CAL_SCHOOL");
    await expect(page.locator("#review-skip-help")).toHaveText(
      "3 trips already run at the same time on School days.",
    );
    await expect(
      page.locator("#change-review").getByText("Skipped · already leaves at this time"),
    ).toHaveCount(3);
    await expect(page.locator("#review-apply")).toHaveText("Copy 0 trips");
    await expect(page.locator("#review-apply")).toBeDisabled();

    await page.locator("#review-cancel").click();
    await expect(page.locator("#change-review")).toHaveCount(0);
  });

  test("Paste copied trips at a new first departure creates them", async ({ page }) => {
    test.setTimeout(90_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));
    await expect(page.locator("#trip-BSG_T08-start")).toHaveText("08:30");

    await selectThreeTrips(page);
    await page.locator("#cell-BSG_T10-1").click();
    await page.keyboard.press("Control+c");
    await expect(page.locator("#grid-bar-message")).toContainText("3 trips copied.");

    await page.keyboard.press(PASTE_CHORD);
    await expect(page.locator("#paste-dialog")).toBeVisible();
    await expect(page.locator("#paste-dialog-title")).toHaveText("Paste 3 trips");

    // School days at 14:00: each copy keeps its spacing, so the review lists
    // the three departures the anchor offset produces.
    await chooseServiceDay(page, "#paste-service", "CAL_SCHOOL");
    await page.locator("#paste-new-time").check();
    await page.fill("#paste-at", "14:00");
    await page.locator("#paste-at").blur();
    await expect(page.locator("#paste-result")).toHaveText(
      "Adds 3 trips on School days: 14:00, 14:30, 15:00. They start without a block.",
    );
    await expect(page.locator("#paste-apply")).toHaveText("Paste 3 trips");

    await page.locator("#paste-apply").click();
    await expect(page.locator("#paste-dialog")).toHaveCount(0);
    await expect(page.locator("#grid-bar-message")).toContainText(
      "Pasted 3 trips on School days.",
    );

    // The created trips are on the target day at the new first departure.
    await expect(page.locator("#calendar-filter")).toBeVisible();
    await page.selectOption("#calendar-filter", "CAL_SCHOOL");
    await expect(
      page.locator("#trip-BROWSER_SCHEDULES_GRID-0-CAL_SCHOOL-1400-start"),
    ).toHaveText("14:00");
    await expect(
      page.locator("#trip-BROWSER_SCHEDULES_GRID-0-CAL_SCHOOL-1430-start"),
    ).toHaveText("14:30");
    await expect(
      page.locator("#trip-BROWSER_SCHEDULES_GRID-0-CAL_SCHOOL-1500-start"),
    ).toHaveText("15:00");
  });

  test("add a frequency window and Convert creates the listed departures", async ({ page }) => {
    test.setTimeout(120_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, FREQ_ROUTE));
    await expect(page.locator("#trip-BSF_T1-frequency")).toContainText(
      "Every 10 min, 09:00–10:00",
    );

    // The Edit drawer shows the stored window; Add window appends a row that
    // starts where the last one ends.
    await page.locator("#trip-BSF_T1-edit").click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await expect(page.locator("#frequency-windows")).toBeVisible();
    await expect(page.locator("#windows-0-from")).toHaveValue("09:00");
    await expect(page.locator("#windows-0-until")).toHaveValue("10:00");
    await expect(page.locator("#windows-0-every")).toHaveValue("10");

    await page.locator("#win-add").click();
    await expect(page.locator("#windows-row-1")).toBeVisible();
    await expect(page.locator("#windows-1-from")).toHaveValue("10:00");
    await expect(page.locator("#windows-1-every")).toHaveValue("10");

    await page.fill("#windows-1-until", "11:00");
    await page.locator("#windows-1-until").blur();
    await expect(page.locator("#windows-row-1")).toContainText(
      "6 departures · last 10:50; the next would be 11:00, when this window ends.",
    );

    await page.locator("#trip-drawer-save").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });
    await expect(page.locator("#grid-bar-message")).toContainText(
      "Saved the frequency service 09:00–11:00.",
    );
    await expect(page.locator("#trip-BSF_T1-frequency")).toContainText("10:00–11:00");

    // Convert reviews one trip per departure of both windows: 09:00–09:50 and
    // 10:00–10:50.
    await page.locator("#trip-BSF_T1-menu").click();
    await page.locator("#trip-BSF_T1-convert").click();
    await expect(page.locator("#convert-review")).toBeVisible();
    await expect(page.locator("#convert-review-title")).toHaveText(
      "Convert to 12 scheduled trips?",
    );
    await expect(page.locator("#convert-review")).toContainText(
      "BROWSER_SCHEDULES_FREQ-0-CAL_DAILY-0900",
    );
    await expect(page.locator("#convert-review")).toContainText(
      "BROWSER_SCHEDULES_FREQ-0-CAL_DAILY-1050",
    );
    await expect(page.locator("#convert-status")).toContainText("This can't be undone.");

    await page.locator("#convert-apply").click();
    await expect(page.locator("#convert-review")).toHaveCount(0);
    await expect(page.locator("#grid-bar-message")).toContainText(
      "Converted frequency service to 12 scheduled trips.",
    );
    // Convert is not undoable (R10).
    await expect(page.locator("#undo-action")).toHaveCount(0);

    // The frequency row and its window are gone; twelve listed trips replace
    // them, the first at 09:00 and the last at 10:50.
    await expect(page.locator("#trip-BSF_T1-frequency")).toHaveCount(0);
    await expect(page.locator("#section-BROWSER-SCHED-PF1-table tbody tr")).toHaveCount(12);
    await expect(
      page.locator("#trip-BROWSER_SCHEDULES_FREQ-0-CAL_DAILY-0900-start"),
    ).toHaveText("09:00");
    await expect(
      page.locator("#trip-BROWSER_SCHEDULES_FREQ-0-CAL_DAILY-1050-start"),
    ).toHaveText("10:50");
  });

  test("the imported mix shows the mixed-service warning", async ({ page }) => {
    test.setTimeout(60_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, MUTATE_ROUTE));
    await expect(page.locator("#trip-SM_T1-start")).toHaveText("06:00");

    const warning = page.locator("#mixed-service-warning");
    await expect(warning).toBeVisible();
    await expect(warning).toContainText(
      "This pattern runs listed trips and frequency service on the same days.",
    );
    await expect(warning).toContainText("Convert the frequency service to scheduled trips.");
    await expect(page.locator("#mixed-convert")).toBeVisible();
  });
});
