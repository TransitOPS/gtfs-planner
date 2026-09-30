/**
 * Grid keyboard journeys for the advanced trip editing package (spec 18,
 * step 42; EV-39 rejects FH-40 and FH-41).
 *
 * Real Chromium → Phoenix (`BROWSER_E2E=true`) → RouteSchedulesLive → the
 * Gtfs facade, over the throwaway pg_tmp database `bin/test-browser` seeds
 * from `test/support/browser_seed.exs`. The fixture routes are step 41's:
 *
 *   BROWSER_SCHEDULES_GRID — BSG_T01–T06 follow the Base timing (a cell shows
 *     the departure; the last stop shows its arrival), BSG_T07–T11 the faster
 *     Peak timing, and BSG_CUSTOM is the last row with custom times;
 *   BROWSER_SCHEDULES_BULK — BSB_T001–BSB_T500 one minute apart, used for the
 *     Enter-to-refocus latency observation (PM-7).
 *
 * The assertions read the seed's literal clocks and the arithmetic each edit
 * promises. `bin/test-browser` runs this file in branch review; the journey
 * writes its captures and latency.json into the package's `evidence/browser/`
 * folder, resolved from SCHEDULE_SPEC_ROOT when the runner points at the
 * checkout that holds `.specs/`.
 */
import { test, expect } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { logInAs } from "./browser_helpers";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
// A worktree checkout carries no gitignored `.specs/`; SCHEDULE_SPEC_ROOT
// points the evidence writes at the checkout that holds the package.
const SPEC_ROOT =
  process.env.SCHEDULE_SPEC_ROOT ||
  resolve(REPO_ROOT, ".specs", "18-advanced-trip-editing");
const EVIDENCE_DIR = resolve(SPEC_ROOT, "evidence", "browser");

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser E2E Version";
const GRID_ROUTE = "BROWSER_SCHEDULES_GRID";
const BULK_ROUTE = "BROWSER_SCHEDULES_BULK";

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "1280x800", width: 1280, height: 800 },
];

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

function clockMinutes(text) {
  const match = /^(\d{1,3}):(\d{2})/.exec(String(text).trim());
  if (!match) throw new Error(`not a clock: ${text}`);
  return Number(match[1]) * 60 + Number(match[2]);
}

function clockAt(totalMinutes) {
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
}

for (const viewport of VIEWPORTS) {
  test.describe(`Schedules grid geometry ${viewport.label}`, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } });

    test("the cursor cell stays clear of the sticky grid bar on the last row", async ({
      page,
    }) => {
      test.setTimeout(60_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page);
      await page.goto(schedulesPath(versionId, GRID_ROUTE));
      await expect(page.locator("#trip-BSG_T01-start")).toHaveText("05:00");

      // Establish the cursor in the first row, then walk it to the last row
      // with the hook's own scroll-into-view (PM-10, FH-40).
      await page.locator("#cell-BSG_T01-1").click();
      await expect(page.locator("#cell-BSG_T01-1")).toBeFocused();
      await page.keyboard.press("Control+ArrowDown");
      await expect(page.locator("#cell-BSG_CUSTOM-1")).toBeFocused();

      // The document's end is the worst case: the region's bottom edge sits
      // nearest the sticky bar.
      await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
      await page.waitForTimeout(250);
      await page.keyboard.press("Control+ArrowDown");
      await expect(page.locator("#cell-BSG_CUSTOM-1")).toBeFocused();
      await page.waitForTimeout(250);

      const geometry = await page.evaluate(() => {
        const cell = document.activeElement;
        const bar = document.querySelector("#grid-bar");
        const cellBox = cell.getBoundingClientRect();
        const barBox = bar.getBoundingClientRect();

        return {
          cell: cell.id,
          cellTop: Math.round(cellBox.top),
          cellBottom: Math.round(cellBox.bottom),
          barTop: Math.round(barBox.top),
          barBottom: Math.round(barBox.bottom),
          covered: cellBox.bottom > barBox.top,
          inViewport: cellBox.top >= 0 && cellBox.bottom <= window.innerHeight,
          barInViewport: barBox.top >= 0 && barBox.bottom <= window.innerHeight,
          scrollY: Math.round(window.scrollY),
        };
      });

      console.log(`step 42 geometry ${viewport.label}: ${JSON.stringify(geometry)}`);

      expect(geometry.cell).toBe("cell-BSG_CUSTOM-1");
      expect(geometry.inViewport, JSON.stringify(geometry)).toBe(true);
      expect(geometry.barInViewport, JSON.stringify(geometry)).toBe(true);
      expect(geometry.covered, JSON.stringify(geometry)).toBe(false);

      await capture(page, `step-042-geometry-${viewport.label}`);
    });

    test("captures the ideal, selection, editing and saved states", async ({ page }) => {
      test.setTimeout(60_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page);
      await page.goto(schedulesPath(versionId, GRID_ROUTE));
      await expect(page.locator("#trip-BSG_T07-start")).toHaveText("08:00");
      // The section's last row renders before the captures, not a partial stream.
      await expect(page.locator("#trip-BSG_CUSTOM-start")).toHaveText("11:00");

      await expect(page.locator("#grid-bar")).toContainText(
        "Select trips to shift, copy or change them.",
      );
      await capture(page, `step-042-ideal-${viewport.label}`);

      await page.locator("#trip-select-BSG_T07").check();
      await expect(page.locator("#selection-count")).toHaveText("1 trip selected");
      await capture(page, `step-042-selection-${viewport.label}`);

      await page.locator("#clear-selection").click();
      await expect(page.locator("#selection-count")).toHaveCount(0);

      const cell = page.locator("#cell-BSG_T07-2");
      const target = clockAt(clockMinutes(await cell.textContent()) + 1);
      await cell.click();
      await page.keyboard.type("+1");
      await page.waitForSelector("#cell-editor.is-open");
      await expect(page.locator("#cell-reading")).toContainText("Reads as");
      await capture(page, `step-042-editing-${viewport.label}`);

      await page.keyboard.press("Enter");
      await expect(cell).toContainText(target);
      await expect(page.locator("#grid-bar-message")).toContainText("is now");
      await capture(page, `step-042-saved-${viewport.label}`);
    });
  });
}

/**
 * The keyboard journeys run once each at 1440 × 900. They work on their own
 * trips of BROWSER_SCHEDULES_GRID, so the mutation one makes cannot change
 * what another asserts.
 */
test.describe("Schedules grid keyboard journeys", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("a keyboard stop edit survives reload (FH-41)", async ({ page }) => {
    test.setTimeout(60_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));

    const edited = page.locator("#cell-BSG_T01-3");
    await expect(page.locator("#trip-BSG_T01-start")).toHaveText("05:00");
    await expect(page.locator("#cell-BSG_T01-2")).toHaveText("05:06");
    await expect(edited).toHaveText("05:12");
    await expect(page.locator("#cell-BSG_T01-4")).toHaveText("05:18");

    // The key map: `+` starts editing with that character; Enter commits
    // `later`, so later stops move +3 minutes.
    await edited.click();
    await page.keyboard.type("+3");
    await page.waitForSelector("#cell-editor.is-open");
    await expect(page.locator("#cell-reading")).toContainText("Reads as 05:15");
    await page.keyboard.press("Enter");

    await expect(edited).toHaveText("05:15");
    await expect(page.locator("#cell-BSG_T01-4")).toHaveText("05:21");
    await expect(page.locator("#cell-BSG_T01-2")).toHaveText("05:06");
    // Enter commits and moves down (AC-6); the earlier stops keep their times.
    await expect(page.locator("#cell-BSG_T02-3")).toBeFocused();

    await page.reload();
    await expect(edited).toHaveText("05:15");
    await expect(page.locator("#cell-BSG_T01-2")).toHaveText("05:06");
    await expect(page.locator("#trip-BSG_T01-start")).toHaveText("05:00");
  });

  test("Alt+Enter changes only the edited stop", async ({ page }) => {
    test.setTimeout(60_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));

    const edited = page.locator("#cell-BSG_T05-4");
    await expect(page.locator("#trip-BSG_T05-start")).toHaveText("07:00");
    await expect(edited).toHaveText("07:18");

    await edited.click();
    await page.keyboard.type("+3");
    await page.waitForSelector("#cell-editor.is-open");
    await expect(page.locator("#cell-reading")).toContainText("Reads as 07:21");
    await page.keyboard.press("Alt+Enter");

    await expect(edited).toHaveText("07:21");
    await expect(page.locator("#cell-BSG_T05-3")).toHaveText("07:12");
    await expect(page.locator("#cell-BSG_T05-5")).toHaveText("07:26");
    // The last stop's arrival is unchanged: only the edited stop moved.
    await expect(page.locator("#cell-BSG_T05-6")).toHaveText("07:30");
  });

  test("] nudges and Ctrl+Z restores the original time", async ({ page }) => {
    test.setTimeout(60_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));

    const cursor = page.locator("#cell-BSG_T06-2");
    await expect(page.locator("#trip-BSG_T06-start")).toHaveText("07:30");
    await expect(cursor).toHaveText("07:36");

    await cursor.click();
    await expect(cursor).toBeFocused();
    await page.keyboard.press("]");

    await expect(page.locator("#trip-BSG_T06-start")).toHaveText("07:31");
    await expect(cursor).toHaveText("07:37");
    await expect(page.locator("#undo-action")).toBeVisible();
    // The hook restores the cursor cell's focus after the write, so the undo
    // chord reaches the grid (PM-9).
    await expect(cursor).toBeFocused();

    await page.keyboard.press("Control+z");

    await expect(page.locator("#trip-BSG_T06-start")).toHaveText("07:30");
    await expect(cursor).toHaveText("07:36");
    await expect(page.locator("#grid-bar-message")).toContainText("Undid:");
    await expect(cursor).toBeFocused();
  });

  test("] in the Add trips drawer leaves trips unchanged", async ({ page }) => {
    test.setTimeout(60_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, GRID_ROUTE));

    await expect(page.locator("#trip-BSG_T04-start")).toHaveText("06:30");
    await expect(page.locator("#cell-BSG_T04-2")).toHaveText("06:36");

    await page.locator("#schedules-add-trips").click();
    await page.locator("#trip-drawer").waitFor({ state: "visible" });

    // The drawer is outside the hook's element and its field swallows the key:
    // the bracket lands in the input and no nudge is posted (AC-7).
    await page.locator("#trip-start").press("]");
    await expect(page.locator("#trip-start")).toHaveValue(/\]$/);

    await expect(page.locator("#trip-BSG_T04-start")).toHaveText("06:30");
    await expect(page.locator("#cell-BSG_T04-2")).toHaveText("06:36");

    await page.locator("#trip-drawer-cancel").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });
    await expect(page.locator("#trip-BSG_T04-start")).toHaveText("06:30");
  });
});

/**
 * PM-7's latency observation: one real commit in the 500-trip section, timed
 * from the Enter keystroke to the cursor cell's refocus. It is one machine's
 * observation, not a performance guarantee.
 */
test.describe("Schedules grid latency observation", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("records the Enter-to-refocus time on the 500-trip section", async ({ page }) => {
    test.setTimeout(120_000);

    await logInAs(page, EDITOR_USER);
    const versionId = await versionIdFor(page);
    await page.goto(schedulesPath(versionId, BULK_ROUTE));

    const edited = page.locator("#cell-BSB_T001-2");
    await expect(edited).toBeVisible({ timeout: 30_000 });
    await expect(page.locator("#cell-BSB_T500-1")).toHaveCount(1, { timeout: 30_000 });
    await expect(page.locator("#trip-BSB_T500-start")).toHaveText("13:19", {
      timeout: 30_000,
    });
    await expect(edited).toHaveText("05:06");

    await edited.click();
    await page.keyboard.type("+3");
    await page.waitForSelector("#cell-editor.is-open");
    await expect(page.locator("#cell-reading")).toContainText("Reads as 05:09");

    // Instrument the commit: the capture listener records the Enter keystroke,
    // and every later focus into a grid cell is timed from it. The first is the
    // re-rendered edited cell, the last is the cell Enter moves down to.
    await page.evaluate(() => {
      window.__enterToRefocus = { enterAt: null, events: [] };

      document.addEventListener(
        "keydown",
        (event) => {
          if (
            event.key === "Enter" &&
            event.target instanceof Element &&
            event.target.id === "cell-editor-input"
          ) {
            window.__enterToRefocus.enterAt = performance.now();
          }
        },
        true,
      );

      document.addEventListener(
        "focusin",
        (event) => {
          const record = window.__enterToRefocus;
          if (record.enterAt === null) return;

          const target = event.target;
          if (
            !(target instanceof Element) ||
            !target.matches('#schedules-grid td[id^="cell-"]')
          ) {
            return;
          }

          record.events.push({ cell: target.id, at: performance.now() });
        },
        true,
      );
    });

    await page.keyboard.press("Enter");
    await expect(edited).toHaveText("05:09", { timeout: 30_000 });
    await expect(page.locator("#cell-BSB_T002-2")).toBeFocused({ timeout: 30_000 });

    const record = await page.evaluate(() => window.__enterToRefocus);
    const first = record.events[0];
    const refocus = record.events[record.events.length - 1];

    const latency = {
      route: BULK_ROUTE,
      viewport: "1440x900",
      section_pattern: "BROWSER-SCHED-PB1",
      trips_in_section: 500,
      edited_cell: "cell-BSB_T001-2",
      committed_time: "05:09",
      edit_to_same_row_refocus_ms: first ? Math.round(first.at - record.enterAt) : null,
      same_row_refocused_cell: first ? first.cell : null,
      enter_to_refocus_ms: refocus ? Math.round(refocus.at - record.enterAt) : null,
      refocused_cell: refocus ? refocus.cell : null,
      focus_events: record.events.map((event) => event.cell),
      recorded_at: new Date().toISOString(),
    };

    // Enter moves the cursor down (AC-6), so the refocus after the write lands
    // on the next row's same column; the first focus event is recorded for the
    // record, the last one is the observation.
    expect(latency.refocused_cell).toBe("cell-BSB_T002-2");
    expect(latency.focus_events).toContain("cell-BSB_T001-2");
    expect(latency.enter_to_refocus_ms).toBeGreaterThan(0);

    mkdirSync(EVIDENCE_DIR, { recursive: true });
    writeFileSync(resolve(EVIDENCE_DIR, "latency.json"), `${JSON.stringify(latency, null, 2)}\n`);
  });
});
