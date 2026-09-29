// Scheduled pathway closures on the Evolutions station route (EV-21, step 15),
// the station-merge closure-file disclosure (EV-20, step 16), and the
// fingerprinted delete confirmation (EV-31, step 20).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The `authoring` group exercises the ordinary station
// navigation into the real closure list, its states, its exact natural IDs and
// its keyboard operation, and captures the rendered result at the two required
// viewports. The `exchange` group reviews a station-merge upload that carries
// `pathway_evolutions.txt`, which station merge must disclose and never apply.
// Expected labels, counts and IDs are literal values from the seeded
// browser fixtures, not values read out of the component under test.
import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { bodyFitsViewport } from "./browser_helpers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser E2E Version";
const NO_CALENDARS_VERSION_NAME = "Browser Schedules No Calendars";

// The seeded Evolutions fixtures: one station with three pathways and two
// closures, plus the stations that produce the view's other states.
const STATION = "BROWSER_EVO_STATION";
const EMPTY_STATION = "BROWSER_EVO_EMPTY_STATION";
const NO_PATHWAY_STATION = "BROWSER_EVO_NOPATHWAY_STATION";
const NO_CALENDAR_STATION = "BROWSER_EVO_NOCAL_STATION";
const NON_STATION_STOP = "BROWSER_EVO_ENTRANCE";

// Step 16: the closure row this upload proposes is a valid full-import row on a
// pathway that already carries a saved closure, so a station merge that applied
// the file would change the lift's rendered window.
const IGNORED_CLOSURE_FILE =
  "pathway_id,service_id,start_time,end_time,is_closed\n" +
  "BROWSER_EVO/PW LIFT 1,CAL_DAILY,09:00:00,10:00:00,1";

const IGNORED_NOTICE =
  "pathway_evolutions.txt is not applied by station merge. Existing scheduled closures are unchanged.";

const IGNORED_NOTICE_ID = "#diff-evolutions-ignored";

// One pathway ID carries a slash and a space, so `?pathway=` has to be encoded
// and decoded exactly rather than read as a path segment.
const PUNCTUATED_PATHWAY = "BROWSER_EVO/PW LIFT 1";

const DESKTOP = { width: 1440, height: 1000 };
const MOBILE = { width: 390, height: 844 };
const NARROW = { width: 320, height: 844 };

// The canonical feature package (with its reference and evidence folder) lives
// in the primary repository checkout; the `.specs/` workspace is gitignored, so
// a checkout without it falls back to Playwright's own output folder instead of
// writing outside the project.
const FEATURE_DIR = path.resolve(__dirname, "../../.specs/pathway-evolutions");
const EVIDENCE_DIR = path.join(FEATURE_DIR, "evidence/browser");
const REFERENCE_PATH = path.join(FEATURE_DIR, "references/closures.html");

function capturePath(testInfo, name) {
  return fs.existsSync(EVIDENCE_DIR)
    ? path.join(EVIDENCE_DIR, name)
    : testInfo.outputPath(name);
}

async function logIn(page, account = EDITOR) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', account.email);
  await page.fill('input[name="user[password]"]', account.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// A click or key press that lands before the LiveView joins is dropped, so each
// navigation waits for the mounted view first. The socket reports connected
// before its view channel can push, so the wait has to name the view itself.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    const view = window.liveSocket?.main;

    return Boolean(
      main &&
        view &&
        view.isConnected() &&
        !view.joinPending &&
        !main.hasAttribute("data-phx-pending"),
    );
  });
}

// The same race applies to file inputs: LiveView only accepts an upload change
// event once the input owns its upload ref. Stage through the ref and the
// rendered entry, retrying the change once, so a dropped event cannot leave the
// Compute diff button disabled.
async function stageDiffFiles(page, files) {
  const input = page.locator("#diff-upload-input input");
  const entries = page.locator("#diff-upload-entries");
  let lastError;

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await waitForLiveView(page);
    await expect(input).toHaveAttribute("data-phx-upload-ref", /.+/);
    await input.setInputFiles(files);

    try {
      for (const file of files) {
        await expect(entries).toContainText(file.name, { timeout: 5_000 });
      }
      return;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError;
}

async function seededVersionId(page, name = VERSION_NAME) {
  // The version menu starts closed, so its options are attached to the document
  // but not visible; read them the way the other browser specs do.
  await page.waitForSelector("[data-version-option]", { state: "attached" });

  const versionId = await page.evaluate((label) => {
    const option = Array.from(
      document.querySelectorAll("[data-version-option]"),
    ).find((button) => button.textContent.trim().startsWith(label));

    return option?.dataset.versionId ?? null;
  }, name);

  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

function evolutionsPath(versionId, stopId, query = "") {
  return `/gtfs/${versionId}/stops/${stopId}/evolutions${query}`;
}

const MONTH_NAMES = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

// The read-only grid renders exactly one cell per civil day, so a month title
// names how many cells it must hold.
function daysInNamedMonth(label) {
  const [name, year] = label.split(" ");
  return new Date(Date.UTC(Number(year), MONTH_NAMES.indexOf(name) + 1, 0)).getUTCDate();
}

// The real beforeunload listener the editor mounts guards unsaved input; the
// only way to observe it without leaving the browser is to dispatch the event
// in the page and read whether the listener refused it.
async function unloadGuarded(page) {
  return page.evaluate(() => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  });
}

test.describe("authoring", () => {
  test.describe("the station closure list", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("opens the real list from the station tab with the tab marked current", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(`/gtfs/${versionId}/stops/${STATION}`);
      await waitForLiveView(page);
      await page.locator("#station-tab-evolutions").click();
      await page.waitForURL(/\/evolutions$/);
      await waitForLiveView(page);

      await expect(page.locator("#closures-title")).toHaveText(
        "Closures at this station",
      );
      await expect(page.locator("#closures-count")).toHaveText("2 closures");

      // The station tabs mark the real destination once, and nothing on the
      // page claims the feature is still to come.
      await expect(
        page.locator("#station-sub-nav a[aria-current='page']"),
      ).toHaveCount(1);
      await expect(
        page.locator("#station-sub-nav a[aria-current='page']"),
      ).toHaveText("Evolutions");
      await expect(
        page.locator("#main-navigation #nav-stops[aria-current='page']"),
      ).toHaveCount(1);
      await expect(page.getByText("Coming soon")).toHaveCount(0);

      // Two saved closures, each carrying its pathway, exact ID, calendar and
      // window; the overnight window says so in text.
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
      await expect(page.locator("#closures-table thead th")).toHaveText([
        "Pathway",
        "Calendar",
        "Window",
      ]);
      await expect(page.locator("#closures-list")).toContainText(
        "Elevator · Mezzanine hall ↔ Platform 1",
      );
      await expect(page.locator("#closures-list")).toContainText(
        PUNCTUATED_PATHWAY,
      );
      await expect(page.locator("#closures-list")).toContainText("09:00–15:00");
      await expect(page.locator("#closures-list")).toContainText("22:00–26:00");
      await expect(page.locator("#closures-list")).toContainText(
        "Ends the next day",
      );
      await expect(page.locator("#closures-list")).toContainText(
        "Every day service",
      );

      // The pathway list names each pathway by its exact natural ID.
      await expect(page.locator("#closure-pathway-list button")).toHaveCount(3);
      await expect(
        page.locator(
          `#closure-pathway-list button[data-pathway-id="${PUNCTUATED_PATHWAY}"]`,
        ),
      ).toHaveCount(1);

      // Every interactive target in the feature region clears the 44px floor.
      const targets = page.locator(
        "#evolutions button, #evolutions input, #evolutions a",
      );
      const count = await targets.count();
      for (let index = 0; index < count; index++) {
        const box = await targets.nth(index).boundingBox();
        if (box) expect(box.height).toBeGreaterThanOrEqual(44);
      }
    });

    test("the row list is keyboard operable and moves focus into the editor", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      const firstRow = page
        .locator("#closures-list tr[data-closure-id]")
        .first();
      const rowButton = firstRow.locator("button[aria-current]");
      const rowId = await firstRow.getAttribute("data-closure-id");
      await expect(rowButton).toHaveAttribute("aria-current", "false");

      await rowButton.focus();
      await expect(rowButton).toBeFocused();
      await page.keyboard.press("Enter");

      await expect(rowButton).toHaveAttribute("aria-current", "true");
      await expect(page.locator("#evolutions-status")).toContainText(
        "Selected closure on Elevator",
      );
      // Choosing a row opens the editor on it and the editor takes focus, which
      // is the reference's behaviour; the row keeps its id as the return path.
      await expect(page.locator("#closure-editor")).toHaveAttribute(
        "data-closure-id",
        rowId,
      );
      await expect(page.locator("#closure-editor-title")).toBeFocused();
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
    });

    test("search and ?pathway keep an exact ID containing punctuation", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      await page.fill("#closures-search", PUNCTUATED_PATHWAY);
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(1);
      await expect(page.locator("#closures-count")).toHaveText(
        "1 of 2 closures match",
      );

      await page.goto(
        evolutionsPath(
          versionId,
          STATION,
          `?pathway=${encodeURIComponent(PUNCTUATED_PATHWAY)}`,
        ),
      );
      await waitForLiveView(page);

      await expect(page.locator("#closures-search")).toHaveValue(
        PUNCTUATED_PATHWAY,
      );
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(1);
      await expect(
        page.locator(
          `#closure-pathway-list button[data-pathway-id="${PUNCTUATED_PATHWAY}"][aria-current="true"]`,
        ),
      ).toHaveCount(1);

      // A value outside the station is ignored rather than resolved.
      await page.goto(
        evolutionsPath(versionId, STATION, "?pathway=BROWSER_EVO%2FPW%20OTHER"),
      );
      await waitForLiveView(page);

      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
      await expect(
        page.locator("#closure-pathway-list button[aria-current='true']"),
      ).toHaveCount(0);

      // A closure id outside the station exposes no row and no selection.
      await page.goto(
        evolutionsPath(
          versionId,
          STATION,
          "?closure=00000000-0000-4000-8000-000000000000",
        ),
      );
      await waitForLiveView(page);

      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
      await expect(page.locator("#evolutions-status")).toBeHidden();
    });

    test("a filtered empty result differs from a first-use station", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      await page.fill("#closures-search", "no such closure");
      await expect(page.locator("#closures-filtered-empty")).toBeVisible();
      await expect(page.locator("#closures-filtered-empty")).toContainText(
        "No closures match “no such closure”",
      );
      await expect(page.locator("#closures-count")).toHaveText(
        "0 of 2 closures match",
      );
      await expect(page.locator("#closures-empty")).toHaveCount(0);

      await page.getByRole("button", { name: "Clear search" }).click();
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
      await expect(page.locator("#closures-filtered-empty")).toHaveCount(0);
      await expect(page.locator("#closures-search")).toBeFocused();
      await expect(page.locator("#evolutions-status")).toContainText(
        "Search cleared",
      );

      await page.goto(evolutionsPath(versionId, EMPTY_STATION));
      await waitForLiveView(page);

      await expect(page.locator("#closures-empty")).toBeVisible();
      await expect(page.locator("#closures-empty")).toContainText(
        "No closures scheduled at Evolutions Empty Station",
      );
      await expect(page.locator("#closures-empty #new-closure")).toBeVisible();
      await expect(page.locator("#closures-filtered-empty")).toHaveCount(0);
      await expect(page.locator("#closures-search")).toHaveCount(0);

      // The primary action on this state uses the design system's action ink.
      await expect(page.locator("#closures-empty #new-closure")).toHaveCSS(
        "background-color",
        "rgb(200, 24, 112)",
      );
    });

    test("the no-pathway and no-calendar states name what is missing", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(evolutionsPath(versionId, NO_PATHWAY_STATION));
      await waitForLiveView(page);
      await expect(page.locator("#closures-no-pathways")).toBeVisible();
      await expect(page.locator("#closures-no-pathways")).toContainText(
        "has no pathways yet",
      );
      await expect(page.locator("#closures-no-pathways a")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/stops/${NO_PATHWAY_STATION}/diagram`,
      );
      await expect(page.locator("#closure-pathway-list")).toHaveCount(0);

      const noCalendarsVersionId = await seededVersionId(
        page,
        NO_CALENDARS_VERSION_NAME,
      );
      await page.goto(
        evolutionsPath(noCalendarsVersionId, NO_CALENDAR_STATION),
      );
      await waitForLiveView(page);
      await expect(page.locator("#closures-no-calendars")).toBeVisible();
      await expect(page.locator("#closures-no-calendars")).toContainText(
        `No calendars in ${NO_CALENDARS_VERSION_NAME}`,
      );
      await expect(page.locator("#closures-no-calendars a")).toHaveAttribute(
        "href",
        `/gtfs/${noCalendarsVersionId}/calendars`,
      );
    });

    test("an absent or non-station target exposes no closure data", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      for (const stopId of ["NO_SUCH_STATION", NON_STATION_STOP]) {
        await page.goto(evolutionsPath(versionId, stopId));
        await page.waitForURL((url) => url.pathname.endsWith(`/stops`));
        await waitForLiveView(page);

        await expect(page.locator("#closures-card")).toHaveCount(0);
        await expect(page.locator("#closures-list")).toHaveCount(0);
        await expect(page.locator("#evolutions")).toHaveCount(0);
        await expect(page.getByText("Station not found")).toBeVisible();
      }
    });
  });

  test("a visitor without a session is sent through the ordinary login form", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await seededVersionId(page);

    // Drop the session cookie and visit the route as a visitor would.
    await page.context().clearCookies();
    await page.goto(evolutionsPath(versionId, STATION));
    await page.waitForURL((url) => url.pathname.startsWith("/users/log_in"));

    await expect(page.locator('input[name="user[email]"]')).toBeVisible();
    await expect(page.locator('input[name="user[password]"]')).toBeVisible();
    await expect(page.getByRole("button", { name: "Log in" })).toBeVisible();
  });

  test.describe("rendered result", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("matches the reference hierarchy with production fonts and tokens at both widths", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);

      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      // The feature region uses the design system font and the scoped tokens,
      // not a page-level default.
      await expect(page.locator("#evolutions")).toHaveCSS(
        "font-family",
        /Figtree/,
      );
      await expect(page.locator("#closures-card")).toHaveCSS(
        "border-radius",
        "8px",
      );
      await expect(page.locator("#closures-count")).toHaveCSS(
        "color",
        "rgb(88, 100, 121)",
      );

      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, "step-015-production-desktop.png"),
        fullPage: true,
      });

      await page.setViewportSize(MOBILE);
      await page.reload();
      await waitForLiveView(page);

      expect(await bodyFitsViewport(page)).toBe(true);
      await expect(
        page.locator("#closures-list tr[data-closure-id]"),
      ).toHaveCount(2);
      await page.screenshot({
        path: capturePath(testInfo, "step-015-production-mobile.png"),
        fullPage: true,
      });

      await page.setViewportSize(NARROW);
      await page.reload();
      await waitForLiveView(page);

      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, "step-015-production-320.png"),
        fullPage: true,
      });
    });

    // The reference is a self-contained file in the gitignored `.specs/`
    // workspace, so this case skips (rather than fails) in a checkout without it.
    test.describe("reference capture", () => {
      test.skip(
        () => !fs.existsSync(REFERENCE_PATH),
        "reference file not present",
      );

      test("captures the reference states at the same viewports", async ({
        page,
      }, testInfo) => {
        await page.setViewportSize(DESKTOP);

        for (const [state, name] of [
          ["", "desktop"],
          ["?state=empty", "empty"],
          ["?state=filtered-empty", "filtered-empty"],
          ["?state=no-pathways", "no-pathways"],
          ["?state=no-calendars", "no-calendars"],
        ]) {
          await page.goto(`${pathToFileURL(REFERENCE_PATH).href}${state}`);
          await expect(page.locator("#closures-card")).toBeVisible();
          await page.screenshot({
            path: capturePath(testInfo, `step-015-reference-${name}.png`),
            fullPage: true,
          });
        }

        await page.setViewportSize(MOBILE);
        await page.goto(pathToFileURL(REFERENCE_PATH).href);
        await expect(page.locator("#closures-card")).toBeVisible();
        await page.screenshot({
          path: capturePath(testInfo, "step-015-reference-mobile.png"),
          fullPage: true,
        });
      });
    });
  });

  // Step 18 / EV-22. The create-and-edit inspector through the ordinary route:
  // a persisted row reloads identically, a rejected save keeps the entered
  // strings and lands focus on the first invalid field, a duplicate tuple links
  // to the closure this station already has, a stale row asks for an explicit
  // reload, and the overlap notice names the window it overlaps. The cases
  // write only into the version's own empty station, so the seeded station the
  // other groups read keeps its two closures.
  test.describe("the closure editor", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("creates a closure, reloads it unchanged, edits it, and names an overlap", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, EMPTY_STATION));
      await waitForLiveView(page);

      await expect(page.locator("#closures-empty")).toBeVisible();
      await page.locator("#closures-empty #new-closure").click();
      await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
      // With no pathway chosen yet, the picker is the field that takes focus.
      await expect(page.locator("#closure-pathway")).toBeFocused();

      await page.selectOption("#closure-pathway", "BROWSER_EVO_EMPTY_PW");
      await page.selectOption("#closure-calendar", "CAL_DAILY");
      await page.fill("#closure-start", "09:00");
      await page.fill("#closure-end", "10:00");
      await page.fill("#closure-note", "Morning lift check.");
      await expect(page.locator("#closure-summary")).toContainText(
        "closes 09:00–10:00 on each service day of Every day service",
      );

      await page.locator("#save-closure").click();

      await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");
      await expect(page.locator("#closures-empty")).toHaveCount(0);
      await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(1);
      await expect(page.locator("#closure-editor")).toHaveAttribute(
        "data-closure-id",
        /[0-9a-f-]{36}/,
      );
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      await expect(page.locator("#closure-end")).toHaveValue("10:00");
      await expect(page.locator("#closure-note")).toHaveValue("Morning lift check.");
      // The saved row carries a real preview address with its exact service time.
      await expect(page.locator("#preview-closure-impact")).toHaveAttribute(
        "href",
        /\/evolutions\/access\?date=\d{4}-\d{2}-\d{2}&time=09%3A00%3A00$/,
      );

      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-desktop.png"),
        fullPage: true,
      });

      // The stored row rebuilds identically after a reload.
      await page.reload();
      await waitForLiveView(page);
      await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(1);
      await expect(page.locator("#closures-list")).toContainText("09:00–10:00");

      // Editing the note persists and reloads through the same route.
      await page.locator("#closures-list tr[data-closure-id] button").first().click();
      await expect(page.locator("#closure-note")).toHaveValue("Morning lift check.");
      await page.fill("#closure-note", "Lift check moved to the afternoon.");
      await page.locator("#save-closure").click();
      await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");

      await page.reload();
      await waitForLiveView(page);
      await page.locator("#closures-list tr[data-closure-id] button").first().click();
      await expect(page.locator("#closure-note")).toHaveValue(
        "Lift check moved to the afternoon.",
      );

      // A second window on the same pathway and calendar names the one it
      // overlaps, in words and in service times.
      await page.locator("#new-closure").click();
      await page.selectOption("#closure-pathway", "BROWSER_EVO_EMPTY_PW");
      await page.selectOption("#closure-calendar", "CAL_DAILY");
      await page.fill("#closure-start", "09:30");
      await page.fill("#closure-end", "10:30");
      await page.locator("#save-closure").click();

      await expect(page.locator("#closure-notice-overlap")).toContainText(
        "Overlaps another closure.",
      );
      await expect(page.locator("#closure-notice-overlap")).toContainText(
        "also closes 09:00–10:00",
      );
      await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);

      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-overlap.png"),
        fullPage: true,
      });

      // Mobile and the narrow overflow check keep the editor usable.
      await page.setViewportSize(MOBILE);
      await page.reload();
      await waitForLiveView(page);
      await page.locator("#closures-list tr[data-closure-id] button").first().click();
      await expect(page.locator("#closure-form")).toBeVisible();
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-mobile.png"),
        fullPage: true,
      });

      await page.setViewportSize(NARROW);
      await page.reload();
      await waitForLiveView(page);
      await page.locator("#closures-list tr[data-closure-id] button").first().click();
      await expect(page.locator("#closure-form")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-320.png"),
        fullPage: true,
      });
    });

    test("a rejected save keeps the entered strings and focuses the first invalid field", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      await page.locator("#closures-list tr[data-closure-id] button").first().click();
      await expect(page.locator("#closure-editor-title")).toHaveText("Edit closure");
      await expect(page.locator("#closure-start")).toHaveValue("09:00");

      await page.fill("#closure-end", "02:00");
      await page.locator("#save-closure").click();

      await expect(page.locator("#closure-errors")).toContainText("Closure not saved");
      await expect(page.locator("#closure-errors-list")).toContainText(
        "must be later than the start time",
      );
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      await expect(page.locator("#closure-end")).toHaveValue("02:00");
      await expect(page.locator("#closure-end")).toHaveAttribute("aria-invalid", "true");
      // The scoped focus hook lands on the first invalid field.
      await expect(page.locator("#closure-end")).toBeFocused();
      // The kept entry is unsaved input, so no preview is offered for it.
      await expect(page.locator("#preview-closure-impact")).toHaveCount(0);
      await expect(page.locator("#closure-preview-unavailable")).toContainText(
        "Save or discard your edits to preview the saved closure.",
      );

      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-validation.png"),
        fullPage: true,
      });

      // The rejected save wrote nothing; restoring the saved window is a no-op.
      await page.fill("#closure-end", "15:00");
      await page.locator("#save-closure").click();
      await expect(page.locator("#evolutions-status")).toContainText("No changes to save.");
      await expect(page.locator("#closures-list")).toContainText("09:00–15:00");
      await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);
    });

    test("a duplicate tuple links to the closure this station already has", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      await page.locator("#new-closure").click();
      await page.selectOption("#closure-pathway", PUNCTUATED_PATHWAY);
      await page.selectOption("#closure-calendar", "CAL_DAILY");
      await page.fill("#closure-start", "09:00");
      await page.fill("#closure-end", "15:00");
      await page.locator("#save-closure").click();

      await expect(page.locator("#closure-errors")).toContainText(
        "This closure already exists.",
      );
      await expect(page.locator("#closure-duplicate")).toContainText(
        "Another closure has the same pathway, calendar and window.",
      );
      await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);

      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-duplicate.png"),
        fullPage: true,
      });

      await page.locator("#closure-open-existing").click();
      await expect(page.locator("#closure-editor-title")).toHaveText("Edit closure");
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      await expect(page.locator("#closure-end")).toHaveValue("15:00");
      // It is the lift's own saved closure, not a copy.
      await expect(page.locator("#closure-note")).toHaveValue("Quarterly inspection.");
      await expect(page.locator("#closure-duplicate")).toHaveCount(0);
    });

    test("a stale save keeps the entries until Reload closure is chosen", async ({
      page,
      context,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      const stairsRow = page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "BROWSER_EVO_PW_STAIR" });
      await stairsRow.locator("button").first().click();
      await expect(page.locator("#closure-end")).toHaveValue("26:00");

      // Another signed-in session changes the same row through the ordinary
      // route while this editor is open.
      const other = await context.newPage();
      await other.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(other);
      await other
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "BROWSER_EVO_PW_STAIR" })
        .locator("button")
        .first()
        .click();
      await other.fill("#closure-end", "26:30");
      await other.locator("#save-closure").click();
      await expect(other.locator("#evolutions-status")).toContainText("Closure saved.");
      await other.close();

      // The first editor still holds the row it loaded: its save is stale.
      await page.fill("#closure-end", "27:00");
      await page.locator("#save-closure").click();

      await expect(page.locator("#closure-stale")).toContainText(
        "Closure changed after you opened it",
      );
      await expect(page.locator("#closure-end")).toHaveValue("27:00");
      await expect(page.locator("#save-closure")).toBeDisabled();
      await expect(page.locator("#closure-stale")).toBeFocused();

      await page.screenshot({
        path: capturePath(testInfo, "step-018-production-stale.png"),
        fullPage: true,
      });

      await page.locator("#closure-reload").click();

      await expect(page.locator("#closure-stale")).toHaveCount(0);
      await expect(page.locator("#closure-end")).toHaveValue("26:30");
      await expect(page.locator("#evolutions-status")).toContainText("Closure reloaded.");
      await expect(page.locator("#save-closure")).toBeEnabled();
    });

    // Step 19 / EV-7. Unsaved input is never dropped silently: an in-app link,
    // the browser's own Back guard and the unload listener all refuse to leave
    // until the reader makes an explicit choice.
    test("guards a link departure, the unload event and history traversal while edits are unsaved", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      await page.locator("#closures-list tr[data-closure-id]").first().locator("button").first().click();
      await expect(page.locator("#closure-start")).toHaveValue("09:00");
      await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);
      await expect(page.locator("#discard-closure")).toHaveText("Close");

      // A clean inspector leaves without a question.
      expect(await unloadGuarded(page)).toBe(false);

      // The seeded lift closure with its saved window changed to 16:00.
      await page.fill("#closure-end", "16:00");

      // The in-app link is stopped in the same moment as the blur that has not
      // round-tripped yet, so the guard has to know the saved values itself.
      await page
        .getByRole("navigation", { name: "Station views" })
        .getByRole("link", { name: "Details" })
        .click();

      await expect(page.locator("#closure-dirty-dialog")).toBeVisible();
      await expect(page.locator("#closure-dirty-dialog-title")).toHaveText(
        "Discard closure edits?",
      );
      await expect(page.locator("#closure-dirty-body")).toContainText(
        "Your changes to Elevator · Mezzanine hall ↔ Platform 1 are not saved. Discarding restores the saved closure.",
      );
      await expect(page.locator("#closure-dirty-dialog-cancel")).toHaveText("Keep editing");
      await expect(page.locator("#closure-dirty-dialog-confirm")).toHaveText("Discard edits");
      expect(page.url()).toContain("/evolutions");

      // A native modal dialog is anchored to the viewport and lives in the top
      // layer, so a full-page capture composites it over the wrong page offset;
      // the panel's own paint also lands a frame after `open`.
      await page.evaluate(
        () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      );
      await page.waitForTimeout(300);
      await page.screenshot({
        path: capturePath(testInfo, "step-019-production-dirty-dialog.png"),
      });

      // Keeping the edits retains the entry and the announced reason.
      await page.locator("#closure-dirty-dialog-cancel").click();
      await expect(page.locator("#closure-dirty-dialog")).toBeHidden();
      await expect(page.locator("#closure-end")).toHaveValue("16:00");
      await expect(page.locator("#closure-dirty-chip")).toHaveText(/Unsaved changes/);
      await expect(page.locator("#discard-closure")).toHaveText("Discard edits");
      await expect(page.locator("#evolutions-status")).toContainText(
        "Your unsaved changes are still here.",
      );

      // The mounted unload listener now refuses to leave.
      expect(await unloadGuarded(page)).toBe(true);

      // Browser Back asks too. Cancelling the confirmation stays on the page
      // with every entered string intact.
      let asked = 0;

      page.once("dialog", (dialog) => {
        asked += 1;
        dialog.dismiss();
      });

      await page.evaluate(() => window.history.back());
      await expect.poll(() => asked).toBe(1);
      expect(page.url()).toContain("/evolutions");
      await expect(page.locator("#closure-end")).toHaveValue("16:00");

      // Accepting it leaves the page.
      page.once("dialog", (dialog) => {
        asked += 1;
        dialog.accept();
      });

      await page.evaluate(() => window.history.back());
      await expect.poll(() => asked).toBe(2);
      await expect(page).not.toHaveURL(/evolutions/);
    });

    // Step 19 / EV-7. The server-side half of the same guard: switching rows or
    // starting a new closure is a choice, not a silent replacement of input.
    test("row switching and starting a new closure ask before unsaved edits are dropped", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      const lift = page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "BROWSER_EVO/PW LIFT 1" });
      const stairs = page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "BROWSER_EVO_PW_STAIR" });

      await lift.locator("button").first().click();
      await page.fill("#closure-end", "16:00");
      await page.locator("#closure-end").blur();
      await expect(page.locator("#discard-closure")).toHaveText("Discard edits");

      // Switching rows while dirty waits for the explicit choice.
      await stairs.locator("button").first().click();
      await expect(page.locator("#closure-dirty-dialog")).toBeVisible();
      await expect(page.locator("#closure-editor-title")).toHaveText("Edit closure");
      await expect(page.locator("#closure-end")).toHaveValue("16:00");

      await page.locator("#closure-dirty-dialog-cancel").click();
      await expect(page.locator("#closure-dirty-dialog")).toBeHidden();
      await expect(page.locator("#closure-end")).toHaveValue("16:00");

      // Asking again and discarding opens the other row on its saved values.
      await stairs.locator("button").first().click();
      await page.locator("#closure-dirty-dialog-confirm").click();

      await expect(page.locator("#closure-end")).toHaveValue("26:00");
      await expect(page.locator("#closure-note")).toHaveValue(
        "Slip replacement across the overnight window.",
      );
      await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);
      await expect(page.locator("#evolutions-status")).toContainText(
        "Closure edits discarded.",
      );

      // Starting a new closure while dirty asks the same question, and its own
      // confirmation clears the draft instead of leaving it behind.
      await page.fill("#closure-note", "Draft note for a new closure.");
      await page.locator("#new-closure").click();

      await expect(page.locator("#closure-dirty-dialog")).toBeVisible();
      await page.locator("#closure-dirty-dialog-confirm").click();

      await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
      await expect(page.locator("#closure-note")).toHaveValue("");
      await expect(page.locator("#closure-start")).toHaveValue("");
      await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);
      await expect(page.locator("#closure-pathway")).toBeFocused();

      // The footer's own action restores an existing row in place, then closes
      // the clean inspector.
      await stairs.locator("button").first().click();
      await page.fill("#closure-end", "23:00");
      await page.locator("#closure-end").blur();
      await expect(page.locator("#discard-closure")).toHaveText("Discard edits");

      await page.locator("#discard-closure").click();

      await expect(page.locator("#closure-end")).toHaveValue("26:00");
      await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);
      await expect(page.locator("#evolutions-status")).toContainText(
        "Closure edits discarded.",
      );

      await page.locator("#discard-closure").click();

      await expect(page.locator("#closure-idle")).toBeVisible();
      await expect(page.locator("#evolutions-status")).toContainText("Closure closed.");
    });

    // The reference is a self-contained file in the gitignored `.specs/`
    // workspace, so this case skips (rather than fails) in a checkout without it.
    test.describe("reference capture", () => {
      test.skip(
        () => !fs.existsSync(REFERENCE_PATH),
        "reference file not present",
      );

      test("captures the reference editor states", async ({ page }, testInfo) => {
        await page.setViewportSize(DESKTOP);

        for (const [state, name] of [
          ["creating", "desktop"],
          ["validation", "validation"],
          ["duplicate", "duplicate"],
          ["stale", "stale"],
          ["forbidden", "forbidden"],
          ["saved-overlap", "saved-overlap"],
          ["saved-no-dates", "saved-no-dates"],
          ["dirty", "dirty"],
          ["dirty-dialog", "dirty-dialog"],
        ]) {
          await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=${state}`);
          await expect(page.locator("#closure-editor")).toBeVisible();
          await page.screenshot({
            path: capturePath(testInfo, `step-018-reference-${name}.png`),
            fullPage: true,
          });
        }

        await page.setViewportSize(MOBILE);
        await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=editing`);
        await expect(page.locator("#closure-editor")).toBeVisible();
        await page.screenshot({
          path: capturePath(testInfo, "step-018-reference-mobile.png"),
          fullPage: true,
        });
      });
    });
  });
});

// Step 20 / EV-31. Deleting a closure is an explicit, fingerprinted action:
// its confirmation names the saved row and says the calendar stays, cancelling
// keeps a dirty form, and a row changed by another session is refused as stale
// instead of being removed on an old fingerprint.
test.describe("delete", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("a confirmed delete removes one row, keeps its calendar and pathway, and focuses the list", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const lift = page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: "BROWSER_EVO/PW LIFT 1" });
    const rowsBefore = await page.locator("#closures-list tr[data-closure-id]").count();

    await lift.locator("button").first().click();
    await expect(page.locator("#closure-start")).toHaveValue("09:00");
    await expect(page.locator("#closure-end")).toHaveValue("15:00");

    // Delete is offered only for a persisted row, and the confirmation names
    // the saved pathway, calendar and window before anything is removed.
    await page.locator("#delete-closure").click();

    await expect(page.locator("#closure-delete-dialog")).toBeVisible();
    await expect(page.locator("#closure-delete-dialog-title")).toHaveText(
      "Delete this closure?",
    );
    await expect(page.locator("#closure-delete-pathway")).toContainText(
      "Elevator · Mezzanine hall ↔ Platform 1",
    );
    await expect(page.locator("#closure-delete-pathway")).toContainText(
      "BROWSER_EVO/PW LIFT 1",
    );
    await expect(page.locator("#closure-delete-calendar")).toHaveText("Every day service");
    await expect(page.locator("#closure-delete-window")).toContainText("09:00–15:00");
    await expect(page.locator("#closure-delete-body")).toContainText(
      "Every day service stays unchanged.",
    );
    await expect(page.locator("#closure-delete-dialog-cancel")).toHaveText("Keep closure");
    await expect(page.locator("#closure-delete-dialog-confirm")).toHaveText("Delete closure");
    // The shared dialog opens on its dismissal action.
    await expect(page.locator("#closure-delete-dialog-cancel")).toBeFocused();

    // A native modal dialog lives in the top layer, so the confirm state is
    // captured from the viewport after the panel's own paint lands.
    await page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    );
    await page.waitForTimeout(300);
    await page.screenshot({
      path: capturePath(testInfo, "step-020-production-desktop.png"),
    });

    // The confirmation shows its own busy state and then removes exactly the
    // one row, announcing the outcome and handing focus to the list.
    await page.locator("#closure-delete-dialog-confirm").click();

    await expect(page.locator("#evolutions-status")).toContainText(
      "Closure deleted. Every day service is unchanged.",
    );
    await expect(page.locator("#closure-delete-dialog")).toBeHidden();
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(
      rowsBefore - 1,
    );
    await expect(lift).toHaveCount(0);
    await expect(page.locator("#closures-list")).toBeFocused();
    await expect(page.locator("#closure-idle")).toBeVisible();

    // The delete survives a reload, and the row's pathway and calendar survive
    // with it: the pathway is still listed and the calendar is still offered.
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(
      rowsBefore - 1,
    );
    await expect(page.locator("#closures-list")).not.toContainText("BROWSER_EVO/PW LIFT 1");
    await expect(page.locator("#closure-pathway-list")).toContainText(
      "BROWSER_EVO/PW LIFT 1",
    );

    await page.locator("#new-closure").click();
    await expect(page.locator("#closure-calendar option[value='CAL_DAILY']")).toHaveCount(1);
  });

  test("cancelling the delete keeps the closure and a dirty form's values", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const stairs = page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: "BROWSER_EVO_PW_STAIR" });
    const rowsBefore = await page.locator("#closures-list tr[data-closure-id]").count();

    await stairs.locator("button").first().click();
    await expect(page.locator("#closure-start")).toHaveValue("22:00");
    await page.fill("#closure-end", "27:00");
    await page.locator("#closure-end").blur();
    await expect(page.locator("#closure-dirty-chip")).toHaveText(/Unsaved changes/);

    // A delete has its own explicit confirmation, so the dirty guard does not
    // intercept it: the dialog names the saved window, not the unsaved one.
    await page.locator("#delete-closure").click();
    await expect(page.locator("#closure-delete-dialog")).toBeVisible();
    await expect(page.locator("#closure-delete-window")).toContainText("22:00–");
    await expect(page.locator("#closure-delete-window")).not.toContainText("27:00");

    await page.locator("#closure-delete-dialog-cancel").click();

    await expect(page.locator("#closure-delete-dialog")).toBeHidden();
    await expect(page.locator("#closure-end")).toHaveValue("27:00");
    await expect(page.locator("#closure-dirty-chip")).toHaveText(/Unsaved changes/);
    await expect(page.locator("#delete-closure")).toBeFocused();
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(rowsBefore);

    // The dialog holds at the phone and narrow widths with no page overflow.
    for (const [name, viewport] of [
      ["mobile", MOBILE],
      ["320", NARROW],
    ]) {
      await page.setViewportSize(viewport);
      await page.reload();
      await waitForLiveView(page);
      await stairs.locator("button").first().click();
      await expect(page.locator("#closure-start")).toHaveValue("22:00");
      await page.locator("#delete-closure").click();
      await expect(page.locator("#closure-delete-dialog")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);
      await page.evaluate(
        () =>
          new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      );
      await page.waitForTimeout(300);
      await page.screenshot({
        path: capturePath(testInfo, `step-020-production-${name}.png`),
      });
      await page.locator("#closure-delete-dialog-cancel").click();
      await expect(page.locator("#closure-delete-dialog")).toBeHidden();
    }
  });

  test("a stale fingerprint refuses the delete and preserves the row and entries", async ({
    page,
    context,
  }) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const stairs = page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: "BROWSER_EVO_PW_STAIR" });

    await stairs.locator("button").first().click();
    await expect(page.locator("#closure-start")).toHaveValue("22:00");
    await page.fill("#closure-end", "27:00");
    await page.locator("#closure-end").blur();

    // Another signed-in session changes the same row through the ordinary
    // route while this editor still holds the row it loaded.
    const other = await context.newPage();
    await other.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(other);
    await other
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: "BROWSER_EVO_PW_STAIR" })
      .locator("button")
      .first()
      .click();
    await expect(other.locator("#closure-start")).toHaveValue("22:00");
    await other.fill("#closure-end", "28:00");
    await other.locator("#save-closure").click();
    await expect(other.locator("#evolutions-status")).toContainText("Closure saved.");
    await other.close();

    // The confirmed delete presents the fingerprint this editor loaded, so it
    // is refused and the row is not removed.
    await page.locator("#delete-closure").click();
    await expect(page.locator("#closure-delete-dialog")).toBeVisible();
    await page.locator("#closure-delete-dialog-confirm").click();

    await expect(page.locator("#evolutions-status")).toContainText("Delete refused");
    await expect(page.locator("#closure-stale")).toContainText(
      "Closure changed after you opened it",
    );
    await expect(page.locator("#closure-delete-dialog")).toBeHidden();
    await expect(page.locator("#closure-end")).toHaveValue("27:00");

    // The other session's row is what a reload shows; discarding first keeps
    // the unload guard out of the way of the reload.
    await page.locator("#discard-closure").click();
    await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);
    await page.reload();
    await waitForLiveView(page);
    await stairs.locator("button").first().click();
    await expect(page.locator("#closure-end")).toHaveValue("28:00");
  });

  test.describe("reference capture", () => {
    test.skip(() => !fs.existsSync(REFERENCE_PATH), "reference file not present");

    test("captures the reference delete confirmation at both widths", async ({
      page,
    }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=delete-confirm`);
      await expect(page.locator("#closure-delete-dialog")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-020-reference-desktop.png"),
      });

      await page.setViewportSize(MOBILE);
      await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=delete-confirm`);
      await expect(page.locator("#closure-delete-dialog")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-020-reference-mobile.png"),
      });
    });
  });
});

// Step 16 / EV-20. The station merge review discloses the ignored closure file
// from the durable run summary, and the upload never becomes closures.
test.describe("exchange", () => {
  test("station merge discloses the ignored closure file and leaves closures unchanged", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    const importPath = `/gtfs/${versionId}/import`;

    await page.setViewportSize(DESKTOP);
    await page.goto(importPath);
    await waitForLiveView(page);
    await page.waitForSelector("#diff-upload-input input");

    // An earlier durable review in this version disables the upload step until
    // Reset returns the form to it; a fresh browser database has no such run.
    const resetButton = page.locator("#diff-reset-btn").first();
    if (await resetButton.count()) {
      await resetButton.click();
      await page.waitForSelector("#diff-upload-input input");
    }

    // The new-version scope sentence is Import feed's; Update station data keeps
    // its own current-version sentence.
    await expect(page.locator("#gtfs-import-section")).toContainText("new version");
    await expect(page.locator("#station-data-section")).not.toContainText("new version");
    await expect(page.locator("#diff-destination")).toContainText(
      "Reviewed changes apply to version",
    );

    await stageDiffFiles(page, [
      {
        name: "levels.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(
          "level_id,level_index,level_name\nBROWSER_EVO_MERGE,1.0,Closure review",
        ),
      },
      {
        name: "pathway_evolutions.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(IGNORED_CLOSURE_FILE),
      },
    ]);

    // The click waits for the compute button to leave its disabled state, which
    // is what the server renders once both upload entries are staged.
    await page.locator("#diff-compute-btn").click();
    await page
      .locator("#diff-decisions [data-version-diff-row]")
      .first()
      .waitFor();

    const notice = page.locator(IGNORED_NOTICE_ID);
    await expect(notice).toBeVisible();
    await expect(notice).toContainText(IGNORED_NOTICE);

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-016-production-desktop.png"),
      fullPage: true,
    });

    // The review is durable: a reload rebuilds the notice from the run summary.
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator(IGNORED_NOTICE_ID)).toContainText(IGNORED_NOTICE);

    // The file never reached the Evolutions list: the seeded lift still carries
    // its saved 09:00–15:00 window, and the station still has exactly two rows.
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);
    await expect(
      page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "BROWSER_EVO/PW LIFT 1" }),
    ).toContainText("09:00–15:00");

    await page.goto(importPath);
    await waitForLiveView(page);
    await page.setViewportSize(MOBILE);
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator(IGNORED_NOTICE_ID)).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-016-production-mobile.png"),
      fullPage: true,
    });

    await page.setViewportSize(NARROW);
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator(IGNORED_NOTICE_ID)).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-016-production-320.png"),
      fullPage: true,
    });
  });
});

// Step 17 / EV-30. A station-merge apply whose closure-backed pathway removal
// fails keeps that failure, the applied sibling and the Retry path on the
// Import page, rebuilt from the durable run after a reload. The upload lists
// every pathway already in the version except the closure-backed lift, plus one
// new walkway, so the apply has exactly one failed removal and one applied
// sibling instead of deleting unrelated seeded data. The listed rows carry the
// seeded attributes verbatim, which is what keeps them out of the decisions.
const MERGE_RESULT_PATHWAYS = [
  "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional,traversal_time,length,stair_count",
  "BROWSER_PW_ELEVATOR,BROWSER_STOP_C,BROWSER_STOP_A,5,1,45,12.5,",
  "BROWSER_PW_SAME_LEVEL,BROWSER_STOP_A,BROWSER_STOP_B,1,1,20,8.0,",
  "BROWSER_PW_CROSS_LEVEL,BROWSER_STOP_A,BROWSER_STOP_D,5,0,60,25.0,",
  "CATALOG_PW_FULL,CATALOG_PATHWAY_STATION,CATALOG_PATHWAY_TO_A,2,0,32,18.5,24",
  "CATALOG_PW_PARTIAL,CATALOG_PATHWAY_STATION,CATALOG_PATHWAY_TO_B,1,1,,45.0,",
  "BROWSER_EVO_PW_WALK,BROWSER_EVO_ENTRANCE,BROWSER_EVO_MEZZANINE,1,1,30,18.0,",
  "BROWSER_EVO_PW_STAIR,BROWSER_EVO_MEZZANINE,BROWSER_EVO_PLATFORM,2,1,60,14.0,",
  "BROWSER_EVO_EMPTY_PW,BROWSER_EVO_EMPTY_A,BROWSER_EVO_EMPTY_B,1,1,,,",
  "BROWSER_EVO_PW_MERGE_ADDED,BROWSER_EVO_EMPTY_A,BROWSER_EVO_EMPTY_B,1,1,30,,",
].join("\n");

const FAILED_REMOVAL =
  "Not removed: this pathway has scheduled closures.";

const LIFT_CLOSURE_PATHWAY = PUNCTUATED_PATHWAY;

test.describe("merge-results", () => {
  test("a partial apply keeps the failed closure-backed removal and retries it", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await seededVersionId(page);
    const importPath = `/gtfs/${versionId}/import`;

    await page.setViewportSize(DESKTOP);
    await page.goto(importPath);
    await waitForLiveView(page);
    await page.waitForSelector("#diff-upload-input input");

    // An earlier durable review in this version disables the upload step until
    // Reset returns the form to it; a fresh browser database has no such run.
    const resetButton = page.locator("#diff-reset-btn").first();
    if (await resetButton.count()) {
      await resetButton.click();
      await page.waitForSelector("#diff-upload-input input");
    }

    await stageDiffFiles(page, [
      {
        name: "pathways.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(MERGE_RESULT_PATHWAYS),
      },
      {
        name: "pathway_evolutions.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(IGNORED_CLOSURE_FILE),
      },
    ]);

    await page.locator("#diff-compute-btn").click();
    await page.locator("#diff-decisions [data-version-diff-row]").first().waitFor();

    // One removal (the closure-backed lift) and one addition: nothing else in
    // the version is proposed for removal, so the partial apply is exact.
    await expect(page.locator("#diff-decisions [data-version-diff-row]")).toHaveCount(2);
    await expect(
      page.locator("#diff-decisions article[data-version-diff-action='remove']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#diff-decisions article[data-version-diff-action='add']"),
    ).toHaveCount(1);

    await page
      .locator("button[phx-click='approve-all'][phx-value-action='remove']")
      .click();
    await page
      .locator("button[phx-click='approve-all'][phx-value-action='add']")
      .click();
    await expect(page.locator("#diff-apply-btn")).toBeEnabled();
    await page.locator("#diff-apply-btn").click();

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.locator("#diff-run-counts")).toHaveText(
      "Applied 1 · Failed 1 · Unapplied 0",
    );

    const failedRow = page.locator(
      "#diff-results article[data-version-diff-status='failed']",
    );
    const appliedRow = page.locator(
      "#diff-results article[data-version-diff-status='applied']",
    );

    await expect(failedRow).toHaveCount(1);
    await expect(appliedRow).toHaveCount(1);
    await expect(failedRow).toHaveAttribute(
      "data-apply-failure-code",
      "pathway_in_use",
    );
    await expect(failedRow).toContainText(LIFT_CLOSURE_PATHWAY);
    await expect(
      failedRow.locator("[data-role='version-diff-summary']"),
    ).toHaveText(FAILED_REMOVAL);
    await expect(appliedRow).toContainText("BROWSER_EVO_PW_MERGE_ADDED");

    // The terminal row links to the owning station with the exact encoded
    // natural ID, names that station, and drops the approval controls.
    const encodedQuery = new URLSearchParams({
      pathway: LIFT_CLOSURE_PATHWAY,
    }).toString();
    const evolutionsHref = `/gtfs/${versionId}/stops/${STATION}/evolutions?${encodedQuery}`;
    const evolutionsLink = failedRow.locator(
      "[data-role='version-diff-evolutions-link']",
    );

    await expect(evolutionsLink).toHaveCount(1);
    await expect(evolutionsLink).toHaveAttribute("href", evolutionsHref);
    await expect(evolutionsLink).toContainText("Evolutions Test Station");
    // The link carries the design system's action ink, as the reference does.
    await expect(evolutionsLink).toHaveCSS("color", "rgb(200, 24, 112)");
    await expect(
      page.locator("#diff-results button[phx-click='approve-decision']"),
    ).toHaveCount(0);
    await expect(
      page.locator("#diff-results button[phx-click='reject-decision']"),
    ).toHaveCount(0);

    // Step 16's omission notice is durable review state, so the apply keeps it.
    await expect(page.locator(IGNORED_NOTICE_ID)).toContainText(IGNORED_NOTICE);

    await page.screenshot({
      path: capturePath(testInfo, "step-017-production-desktop.png"),
      fullPage: true,
    });

    // The link really opens the owning station's Evolutions view with that one
    // pathway selected.
    await evolutionsLink.click();
    await page.waitForURL((url) => url.pathname.endsWith("/evolutions"));
    await waitForLiveView(page);

    expect(new URL(page.url()).searchParams.get("pathway")).toBe(
      LIFT_CLOSURE_PATHWAY,
    );
    await expect(page.locator("#closures-search")).toHaveValue(
      LIFT_CLOSURE_PATHWAY,
    );
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(1);
    await expect(page.locator("#closures-list")).toContainText("09:00–15:00");

    // The durable run rebuilds the same partial result after any reconnect.
    await page.goto(importPath);
    await waitForLiveView(page);
    await page.reload();
    await waitForLiveView(page);

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible();
    await expect(page.locator("#diff-run-counts")).toHaveText(
      "Applied 1 · Failed 1 · Unapplied 0",
    );
    await expect(failedRow).toHaveCount(1);
    await expect(appliedRow).toHaveCount(1);
    await expect(
      failedRow.locator("[data-role='version-diff-summary']"),
    ).toHaveText(FAILED_REMOVAL);
    await expect(evolutionsLink).toHaveAttribute("href", evolutionsHref);
    await expect(page.locator(IGNORED_NOTICE_ID)).toBeVisible();
    await expect(page.locator("#diff-retry-btn")).toBeVisible();
    await expect(page.locator("#diff-retry-hint")).toContainText(
      "After the closures are deleted, Retry applies the failed removal again.",
    );

    // Retry re-runs the real apply worker against the surviving closure. A
    // client-side marker inside the streamed result makes the re-render
    // observable even when the apply phase completes between two DOM frames.
    await page.locator("#diff-results").evaluate((list) => {
      const marker = document.createElement("li");
      marker.id = "merge-results-retry-marker";
      marker.textContent = "retry marker";
      list.appendChild(marker);
    });

    await page.locator("#diff-retry-btn").click();
    await expect(page.locator("#merge-results-retry-marker")).toHaveCount(0, {
      timeout: 30_000,
    });

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.locator("#diff-run-counts")).toHaveText(
      "Applied 1 · Failed 1 · Unapplied 0",
    );
    await expect(failedRow).toHaveCount(1);
    await expect(failedRow).toContainText(LIFT_CLOSURE_PATHWAY);
    await expect(appliedRow).toHaveCount(1);
    await expect(appliedRow).toContainText("BROWSER_EVO_PW_MERGE_ADDED");

    // Mobile and the narrow overflow check keep the same result hierarchy.
    await page.setViewportSize(MOBILE);
    await page.reload();
    await waitForLiveView(page);

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible();
    await expect(failedRow).toBeVisible();
    await expect(evolutionsLink).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-017-production-mobile.png"),
      fullPage: true,
    });

    await page.setViewportSize(NARROW);
    await page.reload();
    await waitForLiveView(page);

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-017-production-320.png"),
      fullPage: true,
    });
  });

  // The reference is a self-contained file in the gitignored `.specs/`
  // workspace, so this case skips (rather than fails) in a checkout without it.
  test.describe("reference capture", () => {
    test.skip(() => !fs.existsSync(REFERENCE_PATH), "reference file not present");

    test("captures the reference merge-result at both viewports", async ({
      page,
    }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(
        `${pathToFileURL(REFERENCE_PATH).href}?state=merge-result`,
      );
      await page.waitForSelector("#diff-run-state");
      await page.screenshot({
        path: capturePath(testInfo, "step-017-reference-desktop.png"),
        fullPage: true,
      });

      await page.setViewportSize(MOBILE);
      await page.goto(
        `${pathToFileURL(REFERENCE_PATH).href}?state=merge-result`,
      );
      await page.waitForSelector("#diff-run-state");
      await page.screenshot({
        path: capturePath(testInfo, "step-017-reference-mobile.png"),
        fullPage: true,
      });
    });
  });
});

// Step 21 / EV-23. The selected calendar's read-only service dates: the
// disclosure behind #closure-dates-toggle, one month at a time from the native
// evaluator, its month navigation, the exact `Open calendar` address and the
// guard around leaving with unsaved input. The cases only read the seeded
// version, so the authoring and delete groups keep their rows.
test.describe("calendars", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("opens the saved closure's calendar one month at a time and keeps its exact address", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const lift = page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: PUNCTUATED_PATHWAY });

    await lift.locator("button").first().click();
    await expect(page.locator("#closure-calendar")).toHaveValue("CAL_DAILY");

    // A freshly opened row shows the toggle closed, and it says so in text and
    // in `aria-expanded` rather than by color.
    await expect(page.locator("#closure-dates-toggle")).toHaveAttribute(
      "aria-expanded",
      "false",
    );
    await expect(page.locator("#closure-dates-toggle")).toContainText(
      "Show service dates",
    );
    await expect(page.locator("#closure-dates")).toBeHidden();

    await page.locator("#closure-dates-toggle").click();

    await expect(page.locator("#closure-dates-toggle")).toHaveAttribute(
      "aria-expanded",
      "true",
    );
    await expect(page.locator("#closure-dates-toggle")).toContainText(
      "Hide service dates",
    );
    await expect(page.locator("#closure-dates")).toBeVisible();

    // One month, named by the navigator and by the buttons that move it.
    const month = (await page.locator("#closure-dates-month").textContent()).trim();
    expect(month).toMatch(/^[A-Z][a-z]+ \d{4}$/);

    const nextMonth = (
      await page.locator("#closure-dates-next").getAttribute("aria-label")
    ).replace(/^Show /, "");
    const previousMonth = (
      await page.locator("#closure-dates-prev").getAttribute("aria-label")
    ).replace(/^Show /, "");
    expect(nextMonth).not.toBe(month);
    expect(previousMonth).not.toBe(month);

    // The everyday seeded calendar serves every day, so every cell of the
    // displayed month is a service day and the legend names all four native
    // states in words.
    const cells = page.locator('#closure-dates-months [id^="month-cell-"]');
    const labels = await cells.evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute("aria-label")),
    );

    expect(labels).toHaveLength(daysInNamedMonth(month));
    expect(labels.every((label) => label.includes("Regular service"))).toBe(
      true,
    );

    for (const word of [
      "Regular service",
      "Service removed",
      "Service added",
      "No service scheduled",
    ]) {
      await expect(page.locator("#closure-dates-months-legend")).toContainText(
        word,
      );
    }

    // Dates are read-only: no field, no select, no cell event.
    await expect(
      page.locator("#closure-dates input, #closure-dates select, #closure-dates textarea"),
    ).toHaveCount(0);
    await expect(page.locator("#closure-dates-months [phx-click]")).toHaveCount(
      0,
    );

    // The exact calendar address, and the calendar page's own encoded shape.
    await expect(page.locator("#closure-calendar-link")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/calendars/show?service_id=CAL_DAILY`,
    );

    // The buttons and the grid's own keyboard binding move the same month, and
    // the entered window is still the saved one.
    await page.locator("#closure-dates-next").click();
    await expect(page.locator("#closure-dates-month")).toHaveText(nextMonth);

    await page.locator("#closure-dates-prev").click();
    await expect(page.locator("#closure-dates-month")).toHaveText(month);

    await page.locator("#closure-dates-months").focus();
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#closure-dates-month")).toHaveText(nextMonth);

    await page.keyboard.press("ArrowLeft");
    await expect(page.locator("#closure-dates-month")).toHaveText(month);

    await expect(page.locator("#closure-start")).toHaveValue("09:00");
    await expect(page.locator("#closure-end")).toHaveValue("15:00");
    await expect(page.locator("#closure-dirty-chip")).toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-021-production-desktop.png"),
      fullPage: true,
    });

    // The same disclosure at the phone and the narrow width, with no
    // horizontal page overflow at either.
    for (const [viewport, name] of [
      [MOBILE, "mobile"],
      [NARROW, "320"],
    ]) {
      await page.setViewportSize(viewport);
      await page.reload();
      await waitForLiveView(page);

      await page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: PUNCTUATED_PATHWAY })
        .locator("button")
        .first()
        .click();
      await page.locator("#closure-dates-toggle").click();
      await expect(page.locator("#closure-dates")).toBeVisible();
      await expect(page.locator("#closure-dates-month")).toHaveText(month);

      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, `step-021-production-${name}.png`),
        fullPage: true,
      });
    }

    // A clean departure follows the exact address the link carries.
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    await page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: PUNCTUATED_PATHWAY })
      .locator("button")
      .first()
      .click();

    await page.locator("#closure-calendar-link").click();

    await expect(page).toHaveURL(
      `/gtfs/${versionId}/calendars/show?service_id=CAL_DAILY`,
    );
    await expect(page.locator("h1")).toContainText("Every day service");
  });

  test("a dates-only calendar shows its added day, its exact encoded ID and the exit guard", async ({
    page,
  }) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, EMPTY_STATION));
    await waitForLiveView(page);

    // The station has no closures, so this form stays a draft and the seeded
    // closures the other groups read are untouched.
    await page.locator("#closures-empty #new-closure").click();
    await page.selectOption("#closure-pathway", "BROWSER_EVO_EMPTY_PW");
    await page.selectOption("#closure-calendar", "svc/odd name");

    // The slash and the space are one value in the query, exactly as the
    // calendars list writes this address.
    await expect(page.locator("#closure-calendar-link")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/calendars/show?service_id=svc%2Fodd+name`,
    );

    await page.locator("#closure-dates-toggle").click();
    await expect(page.locator("#closure-dates")).toBeVisible();

    // A dates-only calendar has no weekly row, so only its added day is a
    // service day in the month the grid opens on.
    const cells = page.locator('#closure-dates-months [id^="month-cell-"]');
    const labels = await cells.evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute("aria-label")),
    );

    expect(labels).toHaveLength(
      daysInNamedMonth(
        (await page.locator("#closure-dates-month").textContent()).trim(),
      ),
    );
    expect(labels.filter((label) => label.includes("Service added"))).toHaveLength(
      1,
    );
    expect(
      labels.filter((label) => label.includes("No service scheduled")),
    ).toHaveLength(labels.length - 1);
    await expect(page.locator("#closure-dates-none")).toHaveCount(0);

    // Leaving with the draft is not silent: the calendar link waits for the
    // same discard choice every other in-app link does.
    await page.locator("#closure-calendar-link").click();

    await expect(page.locator("#closure-dirty-dialog")).toBeVisible();
    await expect(page.locator("#closure-dirty-body")).toContainText(
      "This new closure is not saved",
    );
    expect(page.url()).toContain("/evolutions");

    await page.locator("#closure-dirty-dialog-cancel").click();
    await expect(page.locator("#closure-dirty-dialog")).toBeHidden();
    await expect(page.locator("#closure-calendar")).toHaveValue("svc/odd name");
    await expect(page.locator("#closure-dates")).toBeVisible();
  });

  test("reads the weekly calendar's released days from the native evaluator", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, EMPTY_STATION));
    await waitForLiveView(page);

    await page.locator("#closures-empty #new-closure").click();
    await page.selectOption("#closure-pathway", "BROWSER_EVO_EMPTY_PW");
    await page.selectOption("#closure-calendar", "CAL_SCHOOL");
    await page.locator("#closure-dates-toggle").click();
    await expect(page.locator("#closure-dates")).toBeVisible();

    // The weekday calendar serves weekdays and not weekends in the displayed
    // month, and the legend names every state rather than relying on color.
    const labels = async () =>
      page
        .locator('#closure-dates-months [id^="month-cell-"]')
        .evaluateAll((nodes) =>
          nodes.map((node) => node.getAttribute("aria-label")),
        );

    const initial = await labels();
    expect(initial.some((label) => label.includes("Regular service"))).toBe(true);
    expect(
      initial.some((label) => label.includes("No service scheduled")),
    ).toBe(true);

    // The seeded school calendar removes three consecutive days from its
    // weekly schedule. They span at most two consecutive months, so the open
    // month and its two neighbours hold exactly three removed cells.
    let removed = 0;

    for (const step of ["prev", "next", "next"]) {
      await page.locator(`#closure-dates-${step}`).click();
      removed += await page
        .locator('#closure-dates-months [aria-label*="Service removed"]')
        .count();
    }

    expect(removed).toBe(3);

    await page
      .locator('#closure-dates-months [aria-label*="Service removed"]')
      .first()
      .waitFor();

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-021-production-removed-desktop.png"),
      fullPage: true,
    });
  });

  // The reference is a self-contained file in the gitignored `.specs/`
  // workspace, so this case skips (rather than fails) in a checkout without it.
  test.describe("reference capture", () => {
    test.skip(() => !fs.existsSync(REFERENCE_PATH), "reference file not present");

    test("captures the reference editing state with the dates open", async ({
      page,
    }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=editing`);
      await expect(page.locator("#closure-editor")).toBeVisible();
      await page.locator("#closure-dates-toggle").click();
      await expect(page.locator("#closure-dates")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-021-reference-desktop.png"),
        fullPage: true,
      });

      await page.setViewportSize(MOBILE);
      await page.goto(`${pathToFileURL(REFERENCE_PATH).href}?state=editing`);
      await page.locator("#closure-dates-toggle").click();
      await expect(page.locator("#closure-dates")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-021-reference-mobile.png"),
        fullPage: true,
      });
    });
  });
});
