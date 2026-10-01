// Scheduled pathway closures on the Evolutions station route (EV-21, step 15),
// the station-merge closure-file disclosure (EV-20, step 16), the fingerprinted
// delete confirmation (EV-31, step 20), the calendar reference refusals
// (EV-24, step 22), the rejected-closure import recovery (EV-26, step 24), the
// Pathways export omission notice (EV-27, step 25), the moment access preview
// at its own route (EV-28, step 26) and the integrated authoring-to-round-trip
// closure journey (EV-10, step 30).
//
// The whole file is the EV-10 gate, so every group runs against the one
// reset-and-seeded browser database the repository's Playwright configuration
// already uses (`mise run prepare:browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`. Cases that write remove what they wrote through the
// ordinary editor before they end, so groups stay runnable alone and the
// whole-file run does not depend on case order. The `authoring` group exercises
// the ordinary station
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

import { bodyFitsViewport, readZipTextMember } from "./browser_helpers";

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
const GUARDS_REFERENCE_PATH = path.join(FEATURE_DIR, "references/guards.html");
const ACCESS_REFERENCE_PATH = path.join(
  FEATURE_DIR,
  "references/access-preview.html",
);

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

// A server push can be followed by one next-frame focus re-assertion: the
// list region's scoped focus hook lands on the pushed target after LiveView's
// own restoration, then asserts it once more on the next animation frame.
// Waiting for the pushed target and then two frames in the page leaves that
// settled state, so a deliberate focus move afterwards is never raced.
async function waitForSettledFocus(page, selector) {
  await expect(page.locator(selector)).toBeFocused();
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        requestAnimationFrame(() => requestAnimationFrame(resolve));
      }),
  );
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

// Import shows one workflow at a time and opens on Import feed. A station
// review that is not finished replaces the source choice with its own result,
// and an earlier case in this file leaves one behind, so it is started over
// before the choice is made.
async function chooseImportSource(page, source) {
  const startOver = page.locator("#diff-reset-btn, #diff-start-over-btn").first();

  if (await startOver.count()) {
    await startOver.click();
    await expect(startOver).toHaveCount(0);
  }

  await page.locator(`#import-source-${source}`).check();
  await expect(
    page.locator(source === "station" ? "#diff-upload-form" : "#gtfs-import-form"),
  ).toBeVisible();
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

function accessPath(versionId, stopId, query = "") {
  return `/gtfs/${versionId}/stops/${stopId}/evolutions/access${query}`;
}

function diagramPath(versionId, stopId) {
  return `/gtfs/${versionId}/stops/${stopId}/diagram`;
}

function calendarPath(versionId, serviceId) {
  return `/gtfs/${versionId}/calendars/show?service_id=${encodeURIComponent(serviceId)}`;
}

function exportPath(versionId, query = "") {
  return `/gtfs/${versionId}/export${query}`;
}

// The floorplan's pathways and child stops are lists beside the canvas; opening
// one of their rows is the ordinary route into the drawer that owns Delete
// pathway, Delete stop and Remove from diagram.
async function openPathwayDrawer(page, modeLabel) {
  await page.locator("#panel-tab-pathways").click();
  await expect(page.locator("#pathways-table")).toBeVisible();
  await page
    .locator("#pathways-table li", { hasText: modeLabel })
    .locator("button")
    .first()
    .click();
  await expect(page.locator("#pathway-drawer-overlay")).toHaveAttribute(
    "data-open",
    "true",
  );
}

async function openChildStopDrawer(page, stopId) {
  await page
    .locator("#child-stops-table li", { hasText: stopId })
    .locator("button")
    .first()
    .click();
  await expect(page.locator("#child-stop-drawer-overlay")).toHaveAttribute(
    "data-open",
    "true",
  );
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

// Step 30. The whole-file gate (EV-10) runs every group against one seeded
// database, so a case that writes through the ordinary editor removes exactly
// the rows it created before it ends. Later cases then see the seeded stations,
// closures and counts again instead of depending on the order other cases ran
// in. Deleting one loaded row is this group's own ordinary flow; the counts are
// asserted by the caller.
async function deleteClosureRow(page, row, expectedStart) {
  await row.locator("button").first().click();
  await expect(page.locator("#closure-editor-title")).toHaveText("Edit closure");

  if (expectedStart) {
    await expect(page.locator("#closure-start")).toHaveValue(expectedStart);
  } else {
    // The row loaded its own persisted window before the delete action.
    await expect(page.locator("#closure-start")).toHaveValue(/^\d{1,2}:\d{2}$/);
  }

  await page.locator("#delete-closure").click();
  await expect(page.locator("#closure-delete-dialog")).toBeVisible();
  await page.locator("#closure-delete-dialog-confirm").click();
  await expect(page.locator("#closure-delete-dialog")).toBeHidden();
  await expect(page.locator("#evolutions-status")).toContainText(
    "Closure deleted.",
  );
}

// Every authored closure on a station is removed through that same flow, so a
// case that created rows can hand the station back in its seeded state.
async function removeStationClosures(page, versionId, stopId, expectedCount) {
  await page.goto(evolutionsPath(versionId, stopId));
  await waitForLiveView(page);

  for (let remaining = expectedCount; remaining > 0; remaining -= 1) {
    await deleteClosureRow(
      page,
      page.locator("#closures-list tr[data-closure-id]").first(),
    );
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(
      remaining - 1,
    );
  }

  await expect(page.locator("#closures-empty")).toBeVisible();
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
      ).toHaveText("Closures");
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
  // write only into the version's own empty station, and the create case
  // deletes the rows it authored before it ends, so the seeded station the
  // other groups read keeps its two closures and the empty station stays
  // empty for every later group in the whole-file run.
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
      await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
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

      // The whole-file gate shares one seeded database, so the two closures
      // this case authored are removed through the ordinary delete flow before
      // it ends. Later groups then read the seeded empty station and the
      // seeded CAL_DAILY usage again.
      await page.setViewportSize(DESKTOP);
      await removeStationClosures(page, versionId, EMPTY_STATION, 2);
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
      await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
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

      // The whole-file gate shares one seeded database; restore the seeded
      // overnight window this case deliberately moved so the timeline, preview
      // and floorplan groups still read 22:00–26:00.
      await page.fill("#closure-end", "26:00");
      await page.locator("#save-closure").click();
      await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");
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
      "Delete the closure on Elevator · Mezzanine hall ↔ Platform 1?",
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
    await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
    await expect(page.locator("#closure-calendar option[value='CAL_DAILY']")).toHaveCount(1);

    // The whole-file gate shares one seeded database; this case removed the
    // seeded lift closure, so it recreates the same supported row through the
    // ordinary editor. Later groups (the station merge's unchanged-closures
    // check, the calendars/preview/timeline/range/floorplan reads and the
    // guards count) then see the seeded CAL_DAILY usage again.
    await page.selectOption("#closure-pathway", PUNCTUATED_PATHWAY);
    await page.selectOption("#closure-calendar", "CAL_DAILY");
    await page.fill("#closure-start", "09:00");
    await page.fill("#closure-end", "15:00");
    await page.fill("#closure-note", "Quarterly inspection.");
    await page.locator("#save-closure").click();
    await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(
      rowsBefore,
    );
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

    // The whole-file gate shares one seeded database; restore the seeded
    // overnight window so every later group reads 22:00–26:00.
    await page.fill("#closure-end", "26:00");
    await page.locator("#save-closure").click();
    await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");
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

// Step 24 / EV-26. A full import whose `pathway_evolutions.txt` row is outside
// the supported subset fails phase one. The Import page then shows the durable
// recovery card ahead of Import feed with the file, the CSV row and one bounded
// field/fix sentence, returns the upload form to its idle action, and keeps the
// failure until the failed version is discarded.
const REJECTION_LEVELS_FILE =
  "level_id,level_index,level_name\nBROWSER_EVO_REJECTION,1.0,Closure rejection";

const REJECTION_STOPS_FILE =
  "stop_id,stop_name,stop_lat,stop_lon,level_id\n" +
  "BROWSER_EVO_REJECTION_STOP,Rejection probe,1.0,1.0,BROWSER_EVO_REJECTION";

// Blank pathway_id: the first rejected row fails the import in phase one.
const REJECTED_PATHWAY_FILE =
  "pathway_id,service_id,start_time,end_time,is_closed\n" +
  ",CAL_DAILY,09:00:00,15:00:00,1";

// A direction column with a value is outside the supported subset.
const REJECTED_DIRECTION_FILE =
  "pathway_id,service_id,start_time,end_time,is_closed,direction\n" +
  "BROWSER_EVO/PW LIFT 1,CAL_DAILY,09:00:00,15:00:00,1,0";

// Blank service_id: the same phase-one failure on a different field.
const REJECTED_SERVICE_FILE =
  "pathway_id,service_id,start_time,end_time,is_closed\n" +
  "BROWSER_EVO/PW LIFT 1,,09:00:00,15:00:00,1";

const REJECTION_SENTENCES = {
  evolution_pathway_required: "Name the pathway, using the exact pathway_id",
  evolution_direction_unsupported: "Leave direction blank or remove the column",
  evolution_service_required: "Name the calendar, using the exact service_id",
};

const EXCHANGE_REFERENCE_PATH = path.join(FEATURE_DIR, "references/exchange.html");

// The same race stageDiffFiles handles applies to the full import's file input:
// LiveView only accepts the change once the input owns its upload ref.
async function stageImportFiles(page, files) {
  const input = page.locator("#gtfs-import-upload-input input");
  const entries = page.locator("#gtfs-import-upload-entries");
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

// The stopped run states its three counts as separate figures.
async function expectRunCounts(page, applied, failed, notTried) {
  await expect(page.locator("#diff-count-applied")).toHaveText(String(applied));
  await expect(page.locator("#diff-count-failed")).toHaveText(String(failed));
  await expect(page.locator("#diff-count-unapplied")).toHaveText(String(notTried));
}

function rejectionCard(page, code) {
  return page.locator(`[data-evolution-rejection="${code}"]`);
}

// The file list is a disclosure that opens closed, so the inventory is opened
// the way a person opens it before it is read.
async function openFileList(page) {
  const files = page.locator("#export-files");

  if (!(await files.evaluate((element) => element.open))) {
    await files.locator("summary").click();
  }

  await expect(page.locator("#export-inventory")).toBeVisible();
}

// Step 25 / EV-27. The full inventory lists the version's own closure count in
// the pathway_evolutions.txt row, under the extension sub-line; the Pathways
// notice has to quote that same count. The filename is the row header, so the
// count is the first cell, and a file with no records adds "left out" after 0.
async function closureInventoryCount(page) {
  await openFileList(page);

  const row = page
    .locator("#export-inventory tbody tr")
    .filter({ hasText: "pathway_evolutions.txt" });

  await expect(row).toHaveCount(1);

  const cell = (await row.locator("td").nth(0).innerText()).trim();
  return Number(cell.match(/^[\d,]+/)[0].replaceAll(",", ""));
}

// Upload a minimal full feed whose closure row fails phase one, submit it, and
// wait for the durable rejection element the Import page rebuilds from the run.
async function submitRejectedClosureImport(page, { name, code, file }) {
  await chooseImportSource(page, "feed");
  await page.fill("#gtfs-import-version-name", name);
  await stageImportFiles(page, [
    {
      name: "levels.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(REJECTION_LEVELS_FILE),
    },
    {
      name: "stops.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(REJECTION_STOPS_FILE),
    },
    {
      name: "pathway_evolutions.txt",
      mimeType: "text/plain",
      buffer: Buffer.from(file),
    },
  ]);

  await page.locator("#gtfs-import-submit").click();

  const card = rejectionCard(page, code);
  await expect(card).toBeVisible({ timeout: 60_000 });
  return card;
}

// Discard one failed import through its own two-step confirmation and wait for
// its card to leave the stream.
async function discardRun(page, card) {
  const runCard = page.locator("#import-recovery-runs > li", { has: card });
  const runId = (await runCard.getAttribute("id")).replace("import-run-", "");

  await page.locator(`#discard-${runId}`).click();
  await expect(page.locator("#import-discard-dialog")).toHaveAttribute(
    "data-open",
    "true",
  );
  await page.locator("#import-discard-dialog-confirm").click();
  await expect(runCard).toHaveCount(0, { timeout: 60_000 });
}

// Step 16 / EV-20. The station merge review discloses the ignored closure file
// from the durable run summary, and the upload never becomes closures.
test.describe("exchange", () => {
  test("station merge discloses the ignored closure file and leaves closures unchanged", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await seededVersionId(page);
    const importPath = `/gtfs/${versionId}/import`;

    await page.setViewportSize(DESKTOP);
    await page.goto(importPath);
    await waitForLiveView(page);

    // The new-version scope sentence is Import feed's, which the page opens on;
    // station changes keep their own current-version sentence.
    await expect(page.locator("#import-workspace-title")).toHaveText("Import a feed");
    await expect(page.locator("#import-workspace")).toContainText(
      `Creates a new version. ${VERSION_NAME} isn’t changed.`,
    );

    await chooseImportSource(page, "station");
    await expect(page.locator("#import-workspace-title")).toHaveText(
      "Update station data",
    );
    await expect(page.locator("#import-workspace")).toContainText(
      `Edits ${VERSION_NAME}, after you approve each change.`,
    );
    await expect(page.locator("#diff-upload-form")).not.toContainText("new version");
    await expect(page.locator("#diff-destination")).toContainText(
      `Approved changes go into ${VERSION_NAME}.`,
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
    await page.locator("#diff-decisions [data-review-row]").first().waitFor();

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

  // Step 24 / EV-26. The rejected row's file, CSV row and bounded sentence, the
  // recovery placement ahead of Import feed, the returned upload form and the
  // durable reload, then discard of only the failed version.
  test("a rejected closure row explains the field and its fix and stays until discarded", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await seededVersionId(page);
    const importPath = `/gtfs/${versionId}/import`;

    await page.setViewportSize(DESKTOP);
    await page.goto(importPath);
    await waitForLiveView(page);

    const card = await submitRejectedClosureImport(page, {
      name: "Browser rejected closure",
      code: "evolution_pathway_required",
      file: REJECTED_PATHWAY_FILE,
    });

    // The element names the file, the CSV row and one bounded field/fix sentence.
    await expect(card).toContainText("pathway_evolutions.txt");
    await expect(card).toContainText("Row 2 ·");
    await expect(card).toContainText(REJECTION_SENTENCES.evolution_pathway_required);
    await expect(card).toHaveAttribute("data-evolution-file", "pathway_evolutions.txt");
    await expect(card).toHaveAttribute("data-evolution-row", "2");

    // The card says the version stays unpublished; it never claims no version
    // was created.
    await expect(page.locator("#import-recovery-section")).toContainText(
      "remains unpublished until this failed import is discarded",
    );

    // Recovery precedes the Import feed form while it holds a run.
    expect(
      await page.evaluate(() =>
        Boolean(
          document
            .querySelector("#import-recovery-section")
            .compareDocumentPosition(document.querySelector("#import-workspace")) &
            Node.DOCUMENT_POSITION_FOLLOWING,
        ),
      ),
    ).toBe(true);

    // The upload action returns: the form is idle and its file input is usable.
    await expect(page.locator("#gtfs-import-submit")).toHaveText(/Import feed/);
    await expect(page.locator("#gtfs-import-upload-input input")).toBeEnabled();

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-024-production-desktop.png"),
      fullPage: true,
    });

    // The durable failure survives a reload and both narrower viewports.
    await page.reload();
    await waitForLiveView(page);
    await expect(rejectionCard(page, "evolution_pathway_required")).toContainText("Row 2");

    await page.setViewportSize(MOBILE);
    await page.reload();
    await waitForLiveView(page);
    await expect(rejectionCard(page, "evolution_pathway_required")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-024-production-mobile.png"),
      fullPage: true,
    });

    await page.setViewportSize(NARROW);
    await page.reload();
    await waitForLiveView(page);
    await expect(rejectionCard(page, "evolution_pathway_required")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-024-production-320.png"),
      fullPage: true,
    });

    // Discarding removes the failed version only; the published route version
    // is still the one this page is on. The assertions are scoped to this run so
    // the case does not depend on no other recoverable run existing.
    await page.setViewportSize(DESKTOP);
    await page.reload();
    await waitForLiveView(page);
    await discardRun(page, rejectionCard(page, "evolution_pathway_required"));
    await expect(page.locator("#import-recovery-runs")).not.toContainText(
      "Browser rejected closure",
    );
    expect(await seededVersionId(page)).toBe(versionId);
  });

  test("two failed imports keep their own recovery element and sentence", async ({ page }) => {
    await logIn(page);
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(`/gtfs/${versionId}/import`);
    await waitForLiveView(page);

    const directionCard = await submitRejectedClosureImport(page, {
      name: "Browser rejected direction",
      code: "evolution_direction_unsupported",
      file: REJECTED_DIRECTION_FILE,
    });

    const serviceCard = await submitRejectedClosureImport(page, {
      name: "Browser rejected service",
      code: "evolution_service_required",
      file: REJECTED_SERVICE_FILE,
    });

    await expect(directionCard).toContainText(
      REJECTION_SENTENCES.evolution_direction_unsupported,
    );
    await expect(serviceCard).toContainText(REJECTION_SENTENCES.evolution_service_required);

    const ids = await page
      .locator("[data-evolution-rejection]")
      .evaluateAll((elements) => elements.map((element) => element.id));

    expect(ids.length).toBe(2);
    expect(new Set(ids).size).toBe(2);

    expect(await bodyFitsViewport(page)).toBe(true);

    await discardRun(page, directionCard);
    await discardRun(page, serviceCard);
    await expect(page.locator("#import-recovery-runs")).not.toContainText(
      "Browser rejected direction",
    );
    await expect(page.locator("#import-recovery-runs")).not.toContainText(
      "Browser rejected service",
    );
  });

  // Step 25 / EV-27. The Pathways omission notice quotes the same count the full
  // inventory streams, the closure row is labeled as an extension, and Choose
  // Full export restores the closure file without leaving the page.
  test("the Pathways export names the closures it omits and offers the full export", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await seededVersionId(page);

    await page.setViewportSize(DESKTOP);
    await page.goto(exportPath(versionId, "?type=full"));
    await waitForLiveView(page);

    const count = await closureInventoryCount(page);
    // The seed carries two saved closures; whole-file runs let the authoring
    // group add closures on other stations and the delete group remove one
    // seeded row, so this case reads the version's own count instead of
    // hard-coding it. The ExUnit cases pin the exact 0/1/n copy.
    expect(count).toBeGreaterThanOrEqual(1);

    const closureRow = page
      .locator("#export-inventory tbody tr")
      .filter({ hasText: "pathway_evolutions.txt" });
    await expect(closureRow).toContainText("Scheduled closures · extension, not core GTFS");

    await page.locator("#export-type-pathways").check();
    await page.waitForURL(/type=pathways/);
    await waitForLiveView(page);

    const notice = page.locator("#export-pathways-closures-omitted");
    await expect(notice).toBeVisible();
    await expect(notice).toContainText(
      `Pathways export leaves out ${count} scheduled closures`,
    );
    await expect(notice).toContainText(
      "Choose Full export to include closures and their calendars.",
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-025-production-desktop.png"),
      fullPage: true,
    });

    // Choose Full export patches the URL and the selection; the notice that has
    // no truth left disappears instead of staying as a stale warning.
    await page.locator("#export-choose-full").click();
    await expect(page).toHaveURL(/type=full/);
    await expect(page.locator("#export-type-full")).toBeChecked();
    await expect(notice).toHaveCount(0);
    await expect(closureRow).toHaveCount(1);
    await expect(page.locator("#export-type-full")).toBeFocused();

    // Mobile and the 320px overflow check keep the notice and the file list.
    await page.locator("#export-type-pathways").check();
    await page.waitForURL(/type=pathways/);
    await waitForLiveView(page);
    await page.setViewportSize(MOBILE);
    await page.reload();
    await waitForLiveView(page);
    await expect(notice).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-025-production-mobile.png"),
      fullPage: true,
    });

    await page.setViewportSize(NARROW);
    await page.reload();
    await waitForLiveView(page);
    await expect(notice).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-025-production-320.png"),
      fullPage: true,
    });
  });

  test("a version without closures shows no Pathways omission", async ({ page }) => {
    await logIn(page);
    const versionId = await seededVersionId(page, NO_CALENDARS_VERSION_NAME);

    await page.setViewportSize(DESKTOP);
    await page.goto(exportPath(versionId, "?type=full"));
    await waitForLiveView(page);

    expect(await closureInventoryCount(page)).toBe(0);
    await expect(page.locator("#export-pathways-closures-omitted")).toHaveCount(0);

    await page.locator("#export-type-pathways").check();
    await page.waitForURL(/type=pathways/);
    await waitForLiveView(page);

    await expect(page.locator("#export-type-pathways")).toBeChecked();
    await expect(page.locator("#export-pathways-closures-omitted")).toHaveCount(0);
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("the Export GTFS action follows a closed file list and starts a durable run at 390", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await seededVersionId(page);

    await page.setViewportSize(MOBILE);
    await page.goto(exportPath(versionId, "?type=pathways"));
    await waitForLiveView(page);

    const action = page.locator("#start-export");
    await expect(action).toBeVisible();

    // The page lists the files before the action, but as a disclosure that
    // opens closed, so on a phone the action follows one summary row instead of
    // the whole inventory. It sits within a screen of that row.
    await expect(page.locator("#export-files")).not.toHaveAttribute("open", "");
    await expect(page.locator("#export-inventory")).toBeHidden();

    const gap = await page.evaluate(() => {
      const summary = document
        .querySelector("#export-files summary")
        .getBoundingClientRect();
      const start = document.querySelector("#start-export").getBoundingClientRect();

      return start.top - summary.bottom;
    });

    expect(gap).toBeGreaterThan(0);
    expect(gap).toBeLessThan(MOBILE.height);

    expect(await bodyFitsViewport(page)).toBe(true);

    await action.click();

    // The durable run reaches its ready artifact through the real runner.
    await expect(page.locator("#export-download-link")).toBeVisible({ timeout: 60_000 });
    await expect(page.locator("#export-run-status")).toContainText("Ready to download");
    await expect(page.locator("#export-files")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test.describe("export reference capture", () => {
    test.skip(() => !fs.existsSync(EXCHANGE_REFERENCE_PATH), "reference file not present");

    test("captures the export reference states at both viewports", async ({ page }, testInfo) => {
      const states = [
        { state: "export-pathways", suffix: "" },
        { state: "export-full", suffix: "-full" },
        { state: "export-no-closures", suffix: "-no-closures" },
      ];

      for (const { state, suffix } of states) {
        for (const [viewport, label] of [
          [DESKTOP, "desktop"],
          [MOBILE, "mobile"],
        ]) {
          await page.setViewportSize(viewport);
          await page.goto(`${pathToFileURL(EXCHANGE_REFERENCE_PATH).href}?state=${state}`);
          await page.waitForSelector("#export-inventory", { state: "visible" });
          await page.screenshot({
            path: capturePath(testInfo, `step-025-reference${suffix}-${label}.png`),
            fullPage: true,
          });
        }
      }
    });
  });

  test.describe("rejection reference capture", () => {
    test.skip(
      () => !fs.existsSync(EXCHANGE_REFERENCE_PATH),
      "reference file not present",
    );

    test("captures the reference rejection states at both viewports", async ({
      page,
    }, testInfo) => {
      const states = [
        { state: "failed-direction-unsupported", suffix: "" },
        { state: "failed-service-missing", suffix: "-service" },
      ];

      for (const { state, suffix } of states) {
        for (const [viewport, label] of [
          [DESKTOP, "desktop"],
          [MOBILE, "mobile"],
        ]) {
          await page.setViewportSize(viewport);
          await page.goto(`${pathToFileURL(EXCHANGE_REFERENCE_PATH).href}?state=${state}`);
          await page.waitForSelector("#import-recovery-section", { state: "visible" });
          await page.waitForFunction(() =>
            (document.querySelector("#import-evolution-rejection")?.textContent || "").includes(
              "row",
            ),
          );
          await page.screenshot({
            path: capturePath(testInfo, `step-024-reference${suffix}-${label}.png`),
            fullPage: true,
          });
        }
      }
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
    await chooseImportSource(page, "station");

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
    await page.locator("#diff-decisions [data-review-row]").first().waitFor();

    // One removal (the closure-backed lift) and one addition: nothing else in
    // the version is proposed for removal, so the partial apply is exact.
    await expect(page.locator("#diff-decisions [data-review-row]")).toHaveCount(2);
    await expect(
      page.locator("#diff-decisions [data-review-row][data-action='remove']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#diff-decisions [data-review-row][data-action='add']"),
    ).toHaveCount(1);

    // Removals are approved one at a time, never from the mixed list's bulk
    // action; the addition takes the bulk approval.
    await page
      .locator(
        "#diff-decisions [data-review-row][data-action='remove'] button[phx-click='approve-decision']",
      )
      .click();
    await page
      .locator("button[phx-click='approve-all'][phx-value-action='add']")
      .click();
    await expect(page.locator("#diff-apply-btn")).toBeEnabled();
    await page.locator("#diff-apply-btn").click();

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible({
      timeout: 30_000,
    });
    await expectRunCounts(page, 1, 1, 0);

    // The stopped run lists the change that did not apply, with the reason the
    // closures give; the change that did apply is counted, not listed.
    const failedRow = page.locator("#diff-failed-decisions li[data-decision-id]");

    await expect(failedRow).toHaveCount(1);
    await expect(failedRow).toContainText(LIFT_CLOSURE_PATHWAY);
    await expect(failedRow).toContainText(FAILED_REMOVAL);

    // The failed row links to the owning station with the exact encoded
    // natural ID, names that station, and the run offers no approval controls.
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
      page.locator("#diff-run-state button[phx-click='approve-decision']"),
    ).toHaveCount(0);
    await expect(
      page.locator("#diff-run-state button[phx-click='reject-decision']"),
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

    // The applied change is not listed in the run, so it is read where it now
    // lives: the addition joined the empty station's pathways.
    await page.goto(evolutionsPath(versionId, EMPTY_STATION));
    await waitForLiveView(page);
    await expect(
      page.locator(
        '#closure-pathway-list button[data-pathway-id="BROWSER_EVO_PW_MERGE_ADDED"]',
      ),
    ).toHaveCount(1);

    // The durable run rebuilds the same partial result after any reconnect.
    await page.goto(importPath);
    await waitForLiveView(page);
    await page.reload();
    await waitForLiveView(page);

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible();
    await expectRunCounts(page, 1, 1, 0);
    await expect(failedRow).toHaveCount(1);
    await expect(failedRow).toContainText(FAILED_REMOVAL);
    await expect(evolutionsLink).toHaveAttribute("href", evolutionsHref);
    await expect(page.locator(IGNORED_NOTICE_ID)).toBeVisible();
    await expect(page.locator("#diff-retry-btn")).toBeVisible();
    await expect(page.locator("#diff-retry-hint")).toContainText(
      "After the closures are deleted, Retry applies the failed removal again.",
    );

    // Retry re-runs the real apply worker against the surviving closure. A
    // client-side marker inside the run card makes the re-render observable
    // even when the apply phase completes between two DOM frames.
    await page.locator("#diff-run-state").evaluate((card) => {
      const marker = document.createElement("div");
      marker.id = "merge-results-retry-marker";
      marker.textContent = "retry marker";
      card.appendChild(marker);
    });

    await page.locator("#diff-retry-btn").click();
    await expect(page.locator("#merge-results-retry-marker")).toHaveCount(0, {
      timeout: 30_000,
    });

    await expect(page.locator("#diff-run-state[data-state='partial']")).toBeVisible({
      timeout: 30_000,
    });
    await expectRunCounts(page, 1, 1, 0);
    await expect(failedRow).toHaveCount(1);
    await expect(failedRow).toContainText(LIFT_CLOSURE_PATHWAY);

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
    // displayed month is a service day. Each cell names its state in words.
    const cells = page.locator('#closure-dates-months [id^="month-cell-"]');
    const labels = await cells.evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute("aria-label")),
    );

    expect(labels).toHaveLength(daysInNamedMonth(month));
    expect(labels.every((label) => label.includes(": Runs"))).toBe(true);

    // The calendar page draws a visible key beside its own preview; this
    // disclosure reuses only the month table, so the state words live in the
    // cell labels and the day-off and extra-service cells carry a × or + mark.

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

    // This form stays a draft, so the closures the other groups read are
    // untouched. The station may already carry authoring-group closures later in
    // the file, so the control is addressed without its first-use parent.
    await page.locator("#new-closure").click();
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

    // A dates-only calendar has no weekly row, so its added day is simply a day
    // it runs (not "Extra service"), and every other day is not a service day.
    const cells = page.locator('#closure-dates-months [id^="month-cell-"]');
    const labels = await cells.evaluateAll((nodes) =>
      nodes.map((node) => node.getAttribute("aria-label")),
    );

    expect(labels).toHaveLength(
      daysInNamedMonth(
        (await page.locator("#closure-dates-month").textContent()).trim(),
      ),
    );
    expect(labels.filter((label) => label.includes(": Runs"))).toHaveLength(1);
    expect(
      labels.filter((label) => label.includes(": Not a service day")),
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

    await page.locator("#new-closure").click();
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
    expect(initial.some((label) => label.includes(": Runs"))).toBe(true);
    expect(
      initial.some((label) => label.includes(": Not a service day")),
    ).toBe(true);

    // The seeded school calendar removes three consecutive days from its
    // weekly schedule. They span at most two consecutive months, so the open
    // month and its two neighbours hold exactly three removed cells.
    let removed = 0;
    let lastRemovedStep = -1;
    let month = await page.locator("#closure-dates-month").textContent();
    const steps = ["prev", "next", "next"];

    for (const [index, step] of steps.entries()) {
      await page.locator(`#closure-dates-${step}`).click();

      // The step is an async round trip: wait for its month before counting
      // the cells that month shows.
      await expect(page.locator("#closure-dates-month")).not.toHaveText(month);
      month = await page.locator("#closure-dates-month").textContent();

      const inMonth = await page
        .locator('#closure-dates-months [aria-label*=": Day off, no service"]')
        .count();

      removed += inMonth;
      if (inMonth > 0) lastRemovedStep = index;
    }

    expect(removed).toBe(3);

    // The walk ends on the month after the open one, which holds removed days
    // only when they cross a month boundary. Step back to the last month that
    // does, so the capture below shows the removed state whatever today is.
    for (let back = steps.length - 1 - lastRemovedStep; back > 0; back -= 1) {
      await page.locator("#closure-dates-prev").click();
      await expect(page.locator("#closure-dates-month")).not.toHaveText(month);
      month = await page.locator("#closure-dates-month").textContent();
    }

    await page
      .locator('#closure-dates-months [aria-label*=": Day off, no service"]')
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

// Step 22 / EV-24. Calendar reference guards: the calendar page names both the
// trips and the scheduled closures that keep a service alive, links every known
// pathway to the station that owns it with its exact encoded address, refuses a
// closure-only deletion as a closures refusal instead of blaming trips, and
// refuses the removal of the last stored date beside the action that tried it
// without dropping the loaded form.
test.describe("guards", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("names both references and keeps the loaded form when a deletion is refused", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);
    await page.goto(calendarPath(versionId, "CAL_DAILY"));
    await waitForLiveView(page);

    // The seeded calendar serves every trip the version's schedule fixtures, the
    // calendar fixture route and the advanced trip editing journeys assign to
    // CAL_DAILY (9 + 8 + 6 + 3 + 12 + 1 + 500 = 539, on seven routes) and already
    // carries two closures on the station's lift and stair pathways, so the page
    // has a card for each kind of reference.
    await expect(page.locator("#calendar-trips")).toContainText(
      "539 trips on 7 routes",
    );
    await expect(
      page.locator("#calendar-usage-route-CAL_ROUTE"),
    ).toHaveAttribute("href", `/gtfs/${versionId}/routes/CAL_ROUTE`);
    await expect(page.locator("#calendar-usage-closures")).toContainText(
      "2 scheduled closures use this calendar",
    );

    // A slash and spaces in the natural ID survive into the exact address of the
    // station that owns the pathway, and the link says which station it opens.
    await expect(
      page.locator(
        '#calendar-usage-pathways a[data-pathway-id="BROWSER_EVO/PW LIFT 1"]',
      ),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/stops/BROWSER_EVO_STATION/evolutions?pathway=BROWSER_EVO%2FPW+LIFT+1`,
    );
    await expect(
      page.locator(
        '#calendar-usage-pathways a[data-pathway-id="BROWSER_EVO_PW_STAIR"]',
      ),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/stops/BROWSER_EVO_STATION/evolutions?pathway=BROWSER_EVO_PW_STAIR`,
    );

    await expect(page.locator("#calendar-delete")).toBeVisible();
    await page.click("#calendar-delete");

    const blocked = page.locator("#calendar-delete-blocked-message");
    await expect(blocked).toBeVisible();
    await expect(blocked).toHaveAttribute("role", "alert");
    await expect(blocked).toBeFocused();
    await expect(blocked).toContainText(
      "Trips and closures use this calendar, so it can’t be deleted",
    );
    await expect(blocked).not.toContainText("This calendar is used by trips");
    await expect(blocked).toContainText("539 trips on");
    await expect(page.locator("#calendar-delete-closures")).toContainText(
      "2 scheduled closures use this calendar",
    );
    await expect(page.locator("#calendar-review-dialog")).toBeHidden();

    // The loaded form survives the refusal with its stored values.
    await expect(page.locator("#calendar-name")).toHaveValue(
      "Every day service",
    );
    await expect(page.locator("#calendar-weekdays-monday")).toBeChecked();

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-022-production-desktop.png"),
      fullPage: true,
    });

    // The same refusal at the phone and the narrow width, with no horizontal
    // page overflow at either.
    for (const [viewport, name] of [
      [MOBILE, "mobile"],
      [NARROW, "320"],
    ]) {
      await page.setViewportSize(viewport);
      await page.reload();
      await waitForLiveView(page);
      await expect(page.locator("#calendar-delete")).toBeVisible();
      await page.click("#calendar-delete");

      await expect(page.locator("#calendar-delete-blocked-message")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, `step-022-production-${name}.png`),
        fullPage: true,
      });
    }
  });

  test("refuses a closure-only calendar and its last stored date", async ({
    page,
  }, testInfo) => {
    const versionId = await seededVersionId(page);
    await page.setViewportSize(DESKTOP);

    // A dates-only calendar created through the real editor, whose only native
    // row is the added service date.
    await page.goto(`/gtfs/${versionId}/calendars/new`);
    await waitForLiveView(page);
    await page.fill("#calendar-name", "Guard check service");
    // The feed ID is made from the name; a new calendar keeps its field behind
    // a Change ID disclosure.
    await page.locator("#calendar-service-id-details summary").click();
    await page.fill("#calendar-service-id", "GUARD_ONLY");
    await page.click("#calendar-kind-dates-only");
    await page.fill("#calendar-date-input", "2026-05-01");

    await expect(
      page.locator("#calendar-draft-date-2026-05-01"),
    ).toBeVisible();

    await page.click("#calendar-save");
    await expect(page.locator("#calendar-exception-chips-2026-05-01")).toBeVisible();
    await expect(page.locator("#calendar-trips")).toContainText(
      "No trips use this calendar",
    );

    // A closure that references only this calendar.
    await page.goto(evolutionsPath(versionId, EMPTY_STATION));
    await waitForLiveView(page);
    await page.locator("#new-closure").click();
    await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
    await page.selectOption("#closure-pathway", "BROWSER_EVO_EMPTY_PW");
    await page.selectOption("#closure-calendar", "GUARD_ONLY");
    await page.fill("#closure-start", "06:00");
    await page.fill("#closure-end", "06:30");
    await page.locator("#save-closure").click();
    await expect(page.locator("#evolutions-status")).toContainText(
      "Closure saved.",
    );

    // The closure editor's own calendar address opens the guarded calendar.
    await page.locator("#closure-calendar-link").click();
    // The freshly mounted calendar view sends its own join patch after the
    // navigation, which would drop a disclosure opened against the dead render.
    await waitForLiveView(page);

    await expect(page.locator("#calendar-usage-closures")).toContainText(
      "1 scheduled closure uses this calendar",
    );
    await expect(
      page.locator(
        '#calendar-usage-pathways a[data-pathway-id="BROWSER_EVO_EMPTY_PW"]',
      ),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/stops/BROWSER_EVO_EMPTY_STATION/evolutions?pathway=BROWSER_EVO_EMPTY_PW`,
    );

    await expect(page.locator("#calendar-delete")).toBeVisible();
    await page.click("#calendar-delete");

    const blocked = page.locator("#calendar-delete-blocked-message");
    await expect(blocked).toBeVisible();
    await expect(blocked).toBeFocused();
    await expect(blocked).toContainText(
      "Scheduled closures use this calendar, so it can’t be deleted",
    );
    await expect(page.locator("#calendar-delete-closures")).toContainText(
      "1 scheduled closure uses this calendar",
    );
    await expect(blocked).not.toContainText(/trip/i);
    await expect(page.locator("#calendar-name")).toHaveValue(
      "Guard check service",
    );

    // The same refusal at the phone width.
    await page.setViewportSize(MOBILE);
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator("#calendar-delete")).toBeVisible();
    await page.click("#calendar-delete");

    await expect(page.locator("#calendar-delete-blocked-message")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-022-production-closures-only.png"),
      fullPage: true,
    });

    // Removing the only stored date is refused beside the attempted action, and
    // the stored change stays.
    await page.setViewportSize(DESKTOP);
    await page.reload();
    await waitForLiveView(page);
    await page.click("#calendar-exception-chips-remove-2026-05-01");

    const dateError = page.locator("#calendar-date-error");
    await expect(dateError).toBeVisible();
    await expect(dateError).toBeFocused();
    await expect(dateError).toContainText("May 1, 2026 was not removed");
    await expect(page.locator("#calendar-date-error-body")).toContainText(
      "1 scheduled closure uses it",
    );
    await expect(page.locator("#calendar-date-error-next")).toContainText(
      "Change or delete that closure on",
    );
    await expect(
      page.locator(
        '#calendar-date-error-pathways a[data-pathway-id="BROWSER_EVO_EMPTY_PW"]',
      ),
    ).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/stops/BROWSER_EVO_EMPTY_STATION/evolutions?pathway=BROWSER_EVO_EMPTY_PW`,
    );
    await expect(page.locator("#calendar-exception-chips-2026-05-01")).toBeVisible();

    // The narrow width keeps the refusal and adds no horizontal overflow.
    await page.setViewportSize(NARROW);
    await page.reload();
    await waitForLiveView(page);
    await page.click("#calendar-exception-chips-remove-2026-05-01");

    await expect(page.locator("#calendar-date-error")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-022-production-date-refused.png"),
      fullPage: true,
    });
  });

  // The reference is a self-contained file in the gitignored `.specs/`
  // workspace, so this case skips (rather than fails) in a checkout without it.
  test.describe("reference capture", () => {
    test.skip(
      () => !fs.existsSync(GUARDS_REFERENCE_PATH),
      "reference file not present",
    );

    test("captures the calendar guard states at both viewports", async ({
      page,
    }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(
        `${pathToFileURL(GUARDS_REFERENCE_PATH).href}?state=calendar-delete`,
      );
      await expect(page.locator("#calendar-delete-blocked")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-022-reference-desktop.png"),
        fullPage: true,
      });

      await page.setViewportSize(MOBILE);
      await page.goto(
        `${pathToFileURL(GUARDS_REFERENCE_PATH).href}?state=calendar-date-refused`,
      );
      await expect(page.locator("#calendar-date-error")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-022-reference-mobile.png"),
        fullPage: true,
      });
    });
  });

  // Step 23 / EV-25. Both floorplan deletion guards return :pathway_in_use for a
  // closure-backed pathway; the refusal stays inside the drawer that owns the
  // action, names the blocked pathways and links each one's Evolutions filter.
  // These cases write nothing: the seeded lift and stair closures stay, so no
  // later case sees a station whose closure set this group changed.
  test.describe("floorplan deletions", () => {
    test("refuses a closure-backed pathway delete and opens its scoped closures filter", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(diagramPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#pathways-table li")).toHaveCount(3);

      await openPathwayDrawer(page, "Elevator");
      await expect(
        page.locator("#pathway-form input[name='pathway_id']"),
      ).toHaveValue(PUNCTUATED_PATHWAY);

      await page.locator("#delete-pathway-button").click();
      await expect(page.locator("#station-diagram-confirmation")).toHaveAttribute(
        "data-open",
        "true",
      );
      await page.locator("#station-diagram-confirmation-confirm").click();

      const refusal = page.locator("#pathway-in-use-error");
      await expect(refusal).toBeVisible();
      await expect(refusal).toHaveAttribute("role", "alert");
      await expect(refusal).toBeFocused();
      await expect(refusal).toContainText("Pathway not deleted");
      await expect(refusal).toContainText(
        "This pathway has scheduled closures. Delete them on the station’s Closures tab first.",
      );

      // The exact natural ID travels in the data attribute and in the encoded
      // query of the scoped Evolutions address, not as a path segment.
      const link = page.locator("#pathway-in-use-error-0");
      await expect(link).toHaveCount(1);
      await expect(link).toHaveAttribute(
        "data-pathway-id",
        PUNCTUATED_PATHWAY,
      );
      await expect(link).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/stops/${STATION}/evolutions?pathway=BROWSER_EVO%2FPW+LIFT+1`,
      );
      await expect(link).toContainText("Open closures");

      // The drawer keeps the pathway it loaded, the confirmation it replaced is
      // closed, and no pathway was removed.
      await expect(page.locator("#pathway-drawer-overlay")).toHaveAttribute(
        "data-open",
        "true",
      );
      await expect(
        page.locator("#pathway-form input[name='pathway_id']"),
      ).toHaveValue(PUNCTUATED_PATHWAY);
      await expect(page.locator("#station-diagram-confirmation")).toHaveAttribute(
        "data-open",
        "false",
      );
      await expect(page.locator("#pathways-table li")).toHaveCount(3);

      // The drawer is a native modal dialog in the top layer, so the refusal
      // state is captured from the viewport rather than a full-page composite.
      await page.screenshot({
        path: capturePath(testInfo, "step-023-production-desktop.png"),
      });

      // The fix link opens the station's Evolutions page already filtered to
      // this pathway: one matching row, its pathway marked current.
      await link.click();
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

      // The same refusal at the phone width and at 320px, each with no
      // horizontal page overflow.
      for (const [viewport, name] of [
        [MOBILE, "mobile"],
        [NARROW, "320"],
      ]) {
        await page.setViewportSize(viewport);
        await page.goto(diagramPath(versionId, STATION));
        await waitForLiveView(page);
        await openPathwayDrawer(page, "Elevator");
        await page.locator("#delete-pathway-button").click();
        await page.locator("#station-diagram-confirmation-confirm").click();

        await expect(page.locator("#pathway-in-use-error")).toBeVisible();
        expect(await bodyFitsViewport(page)).toBe(true);
        await page.screenshot({
          path: capturePath(testInfo, `step-023-production-${name}.png`),
        });
      }
    });

    test("refuses a closure-backed child-stop delete and lists each blocked pathway", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      await page.setViewportSize(DESKTOP);
      await page.goto(diagramPath(versionId, STATION));
      await waitForLiveView(page);

      await openChildStopDrawer(page, "BROWSER_EVO_MEZZANINE");
      await expect(page.locator("#child-stop-form input[name='stop_name']")).toHaveValue(
        "Mezzanine hall",
      );

      await page.locator("#delete-child-stop-button").click();
      await expect(page.locator("#station-diagram-confirmation")).toHaveAttribute(
        "data-open",
        "true",
      );
      await page.locator("#station-diagram-confirmation-confirm").click();

      const refusal = page.locator("#child-stop-in-use-error");
      await expect(refusal).toBeVisible();
      await expect(refusal).toHaveAttribute("role", "alert");
      await expect(refusal).toBeFocused();
      await expect(refusal).toContainText("Stop not deleted");
      await expect(refusal).toContainText(
        "A pathway connected to this stop has scheduled closures. Delete them on the station’s Closures tab first.",
      );

      // The mezzanine is an endpoint of both closure-backed pathways, so each
      // one carries its own exact link and address.
      await expect(refusal.locator("a")).toHaveCount(2);
      await expect(
        refusal.locator(`a[data-pathway-id="${PUNCTUATED_PATHWAY}"]`),
      ).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/stops/${STATION}/evolutions?pathway=BROWSER_EVO%2FPW+LIFT+1`,
      );
      await expect(
        refusal.locator('a[data-pathway-id="BROWSER_EVO_PW_STAIR"]'),
      ).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/stops/${STATION}/evolutions?pathway=BROWSER_EVO_PW_STAIR`,
      );

      // The stop keeps its drawer, its loaded values, its placement and every
      // pathway: the guard refused before anything was deleted.
      await expect(page.locator("#child-stop-drawer-overlay")).toHaveAttribute(
        "data-open",
        "true",
      );
      await expect(page.locator("#child-stop-form input[name='stop_name']")).toHaveValue(
        "Mezzanine hall",
      );
      await expect(page.locator("#child-stop-form input[name='x']")).toHaveValue(
        "50.0",
      );
      await expect(page.locator("#child-stop-form input[name='y']")).toHaveValue(
        "30.0",
      );
      await expect(page.locator("#pathways-table li")).toHaveCount(3);
      await expect(page.locator("#child-stops-table")).toContainText(
        "BROWSER_EVO_MEZZANINE",
      );

      await page.screenshot({
        path: capturePath(testInfo, "step-023-production-stop-desktop.png"),
      });

      // Narrow widths keep the refusal inside the drawer with no overflow.
      for (const [viewport, name] of [
        [MOBILE, "mobile"],
        [NARROW, "320"],
      ]) {
        await page.setViewportSize(viewport);
        await page.goto(diagramPath(versionId, STATION));
        await waitForLiveView(page);
        await openChildStopDrawer(page, "BROWSER_EVO_MEZZANINE");
        await page.locator("#delete-child-stop-button").click();
        await page.locator("#station-diagram-confirmation-confirm").click();

        await expect(page.locator("#child-stop-in-use-error")).toBeVisible();
        expect(await bodyFitsViewport(page)).toBe(true);
        await page.screenshot({
          path: capturePath(testInfo, `step-023-production-stop-${name}.png`),
        });
      }
    });
  });

  // The reference is a self-contained file in the gitignored `.specs/`
  // workspace, so this case skips (rather than fails) in a checkout without it.
  test.describe("floorplan reference capture", () => {
    test.skip(
      () => !fs.existsSync(GUARDS_REFERENCE_PATH),
      "reference file not present",
    );

    test("captures the floorplan guard states at both viewports", async ({
      page,
    }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(
        `${pathToFileURL(GUARDS_REFERENCE_PATH).href}?state=floorplan-delete`,
      );
      await expect(page.locator("#pathway-form-error")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-023-reference-desktop.png"),
        fullPage: true,
      });

      await page.setViewportSize(MOBILE);
      await page.goto(
        `${pathToFileURL(GUARDS_REFERENCE_PATH).href}?state=floorplan-stop-delete`,
      );
      await expect(page.locator("#stop-form-error")).toBeVisible();
      await page.screenshot({
        path: capturePath(testInfo, "step-023-reference-mobile.png"),
        fullPage: true,
      });
    });
  });
});

// Step 26 / EV-28. The moment access preview through its own route. Expected
// labels, states and IDs are literal values from the seeded fixtures: the
// elevator carries a 09:00-15:00 closure on CAL_DAILY, the staircase a
// 22:00-26:00 one, and the seeded East entrance has no pathway at all. The
// group reads the shared station and writes nothing to the database, so it can
// run on its own (`--grep preview`) or with the rest of the file.
test.describe("preview", () => {
  const cell = (page, platformId, entrance, connection) =>
    page
      .locator(`#findings-table tbody[data-platform-id="${platformId}"] tr`, {
        hasText: entrance,
      })
      .locator(`td[data-connection="${connection}"]`);

  // The closure view's own table is not used here; this is the browser's route
  // back to the closure that contributed to a loss.
  const causes = (page) => page.locator("#preview-causes");

  test.describe("the moment access page", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("shows Lost step-free and Available walking for the elevator and staircase", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      // The view switch marks this route current and the station tab stays on
      // Evolutions.
      await expect(page.locator("#evolutions-tab-access")).toHaveAttribute(
        "aria-current",
        "page",
      );
      await expect(page.locator("#evolutions-tab-closures")).toHaveAttribute(
        "aria-current",
        "false",
      );
      await expect(page.locator("#station-tab-evolutions")).toHaveAttribute(
        "aria-current",
        "page",
      );

      // The moment defaults to the agency's today at noon in its own zone.
      await expect(page.locator("#preview-time")).toHaveValue("12:00:00");
      await expect(page.locator("#preview-zone")).toContainText(
        "America/New_York",
      );
      await expect(page.locator("#preview-zone")).toContainText(
        "25:00 means 1 AM on the next day of this service",
      );
      // The zone is the stored identifier, so it is secondary text, and the
      // moment line leaves the UTC offset out of its sentence.
      await expect(page.locator("#preview-moment")).not.toContainText("(12:00 PM UTC");

      // The elevator is closed 09:00-15:00: Platform 1 loses its step-free
      // connection in both directions and keeps walking over the staircase.
      await expect(
        cell(page, "BROWSER_EVO_PLATFORM", "North entrance", "step_free_to_platform"),
      ).toHaveAttribute("data-state", "lost");
      await expect(
        cell(page, "BROWSER_EVO_PLATFORM", "North entrance", "step_free_to_exit"),
      ).toHaveAttribute("data-state", "lost");
      await expect(
        cell(page, "BROWSER_EVO_PLATFORM", "North entrance", "walking_to_platform"),
      ).toHaveAttribute("data-state", "available");
      await expect(
        cell(page, "BROWSER_EVO_PLATFORM", "North entrance", "walking_to_exit"),
      ).toHaveAttribute("data-state", "available");

      // The concourse pair is untouched by the closure.
      await expect(
        cell(page, "BROWSER_EVO_MEZZANINE", "North entrance", "step_free_to_platform"),
      ).toHaveAttribute("data-state", "available");

      // The seeded East entrance has no pathway: every one of its cells is a
      // No route with its own word, and the note says it is not a loss.
      for (const connection of [
        "step_free_to_platform",
        "step_free_to_exit",
        "walking_to_platform",
        "walking_to_exit",
      ]) {
        const east = cell(page, "BROWSER_EVO_PLATFORM", "East entrance", connection);
        await expect(east).toHaveAttribute("data-state", "gap");
        await expect(east).toContainText("No route");
      }

      await expect(page.locator("#findings-gap-note")).toBeVisible();
      await expect(page.locator("#findings-gap-note")).toContainText(
        "Unreachable even without closures, so it is not counted as lost.",
      );
      await expect(page.locator("#findings-incomplete-badge")).toHaveCount(0);
      await expect(page.locator("#analysis-incomplete")).toHaveCount(0);

      // The answer names the step-free consequence and separates the closure,
      // what still works and the baseline gap.
      const title = page.locator("#preview-result-title");
      await expect(title).toHaveText("No step-free route to or from Platform 1");
      await expect(title).not.toContainText("East entrance");

      const body = page.locator("#preview-result-body");
      await expect(body).toContainText(
        "Elevator · Mezzanine hall ↔ Platform 1 (BROWSER_EVO/PW LIFT 1) is closed 09:00–15:00.",
      );
      await expect(body).toContainText(
        "Walking connections to and from Platform 1 remain.",
      );
      await expect(body).toContainText(
        "East entrance has no step-free route to Platform 1 even without closures.",
      );

      // The moment line and the coverage disclaimer are the page's own words.
      await expect(page.locator("#preview-moment")).toContainText(
        "12:00 service time",
      );
      await expect(page.locator("#preview-computed")).toContainText(
        "Calculated ",
      );
      await expect(page.locator("#preview-coverage")).toContainText(
        "It does not certify slopes, widths, or all wheelchair requirements.",
      );

      // Both closures are seeded, but only the elevator is active at noon.
      await expect(causes(page)).toContainText(
        "Active closures during this loss",
      );
      await expect(causes(page)).toContainText("BROWSER_EVO/PW LIFT 1");
      await expect(causes(page)).toContainText("09:00–15:00");
      await expect(
        causes(page).locator('a', { hasText: "Review closure" }),
      ).toHaveAttribute(
        "href",
        /\/evolutions\?closure=[0-9a-f-]{36}$/,
      );

      // Every interactive target in the feature region clears the 44px floor.
      const targets = page.locator(
        "#evolutions button:visible, #evolutions input:visible, #evolutions a:visible",
      );
      const count = await targets.count();

      for (let index = 0; index < count; index += 1) {
        const box = await targets.nth(index).boundingBox();
        if (box) expect(box.height).toBeGreaterThanOrEqual(44);
      }

      // Submitting a moment inside the closure keeps the same answer.
      await page.locator("#preview-time").fill("13:00:00");
      await page.locator("#update-preview").click();

      await expect(page.locator("#preview-moment")).toContainText(
        "13:00 service time",
      );
      await expect(page.locator("#preview-result-title")).toHaveText(
        "No step-free route to or from Platform 1",
      );
      await expect(
        cell(page, "BROWSER_EVO_PLATFORM", "North entrance", "step_free_to_platform"),
      ).toHaveAttribute("data-state", "lost");
      await expect(page.locator("#analysis-stale")).toHaveCount(0);
    });

    test("a newer check replaces the earlier answer and a failure is named with a retry", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#preview-result-title")).toHaveText(
        "No step-free route to or from Platform 1",
      );

      // 16:00 is after the elevator window and before the staircase's, so the
      // new check answers for its own moment and the earlier answer is gone.
      await page.locator("#preview-time").fill("16:00:00");
      await page.locator("#update-preview").click();

      await expect(page.locator("#preview-moment")).toContainText(
        "16:00 service time",
      );
      await expect(page.locator("#preview-result-title")).toHaveText(
        "No connection lost at this time",
      );
      await expect(page.locator("#preview-result-body")).toContainText(
        "No closure is active.",
      );
      await expect(causes(page)).toContainText("No closure is active at");
      await expect(page.locator("#analysis-stale")).toHaveCount(0);

      // A moment the loader cannot evaluate: a service date outside
      // PostgreSQL's own date range, reachable only through a link because a
      // browser date input cannot hold a negative year. The page names the
      // failure, keeps its instruction line and offers a retry.
      await page.goto(accessPath(versionId, STATION, "?date=-4714-12-31&time=12:00:00"));
      await waitForLiveView(page);

      await expect(page.locator("#analysis-error")).toBeVisible();
      await expect(page.locator("#analysis-error")).toContainText(
        "The access check stopped before it finished",
      );
      await expect(page.locator("#analysis-error-detail")).toContainText(
        "Nothing was changed.",
      );
      await expect(page.locator("#analysis-retry")).toBeVisible();
      await expect(page.locator("#preview-result")).toHaveCount(0);
      await expect(page.locator("#preview-findings")).toHaveCount(0);

      // Recovery is one ordinary moment away.
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#analysis-error")).toHaveCount(0);
      await expect(page.locator("#analysis-stale")).toHaveCount(0);
      await expect(page.locator("#preview-result-title")).toHaveText(
        "No step-free route to or from Platform 1",
      );
    });

    test("an incomplete station is never an all-clear and an unusable version zone hides the form", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      // The seeded empty station has platforms and a pathway but no entrance,
      // so the evaluation cannot answer and says why.
      await page.goto(accessPath(versionId, EMPTY_STATION));
      await waitForLiveView(page);

      await expect(page.locator("#analysis-incomplete")).toBeVisible();
      await expect(page.locator("#analysis-incomplete")).toContainText(
        "Access check incomplete",
      );
      await expect(page.locator("#incomplete-reasons")).toContainText(
        "no entrance",
      );
      await expect(
        page.locator("#findings-incomplete-badge"),
      ).toContainText("Incomplete");
      await expect(page.locator("#preview-result")).toHaveCount(0);
      await expect(page.locator("#findings-empty")).toBeVisible();
      await expect(page.locator("#incomplete-moment")).toContainText(
        "service time",
      );

      // The version that exists because it has no calendars also has no agency
      // time zone, so its access route refuses to name an instant and leaves
      // authoring reachable instead.
      const noCalendarsVersionId = await seededVersionId(
        page,
        NO_CALENDARS_VERSION_NAME,
      );

      await page.goto(accessPath(noCalendarsVersionId, NO_CALENDAR_STATION));
      await waitForLiveView(page);

      await expect(page.locator("#analysis-timezone-unavailable")).toBeVisible();
      await expect(page.locator("#analysis-timezone-unavailable")).toContainText(
        "this version has no agency time zone",
      );
      await expect(page.locator("#tz-reason")).toContainText(
        "No agency in this version has a time zone.",
      );
      await expect(page.locator("#preview-form")).toHaveCount(0);
      await expect(page.locator("#preview-findings")).toHaveCount(0);
      await expect(page.locator("#preview-result")).toHaveCount(0);
      await expect(page.locator("#tz-settings")).toHaveAttribute(
        "href",
        `/gtfs/${noCalendarsVersionId}/settings/agencies`,
      );

      // The closure list stays reachable from the refusal.
      await page.locator("#tz-closures").click();

      await expect(page.locator("#closures-card")).toBeVisible();
    });

    test("switching version leaves the earlier version's answer behind", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);
      await expect(page.locator("#preview-result-title")).toHaveText(
        "No step-free route to or from Platform 1",
      );

      const noCalendarsVersionId = await seededVersionId(
        page,
        NO_CALENDARS_VERSION_NAME,
      );

      await page.locator("#gtfs-version-trigger").click();
      await page
        .locator(`#gtfs-version-option-${noCalendarsVersionId}`)
        .click();

      // The station does not exist in the version that was chosen, so the page
      // refuses it rather than showing the version the reader left.
      await page.waitForURL(`**/gtfs/${noCalendarsVersionId}/stops`);
      await expect(page.getByText("Station not found")).toBeVisible();
      await expect(page.locator("#preview-result")).toHaveCount(0);
      await expect(page.locator("#preview-findings")).toHaveCount(0);
      await expect(page.locator("#evolutions")).toHaveCount(0);
    });
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
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#evolutions")).toHaveCSS(
        "font-family",
        /Figtree/,
      );
      await expect(page.locator("#findings-title")).toBeVisible();
      await expect(page.locator("#preview-result-title")).toHaveCSS(
        "font-family",
        /Gabarito/,
      );
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-026-production-desktop.png"),
        fullPage: true,
      });

      // Each width re-enters the route so the state is the route's own, not a
      // client-side reflow of the desktop render.
      await page.setViewportSize(MOBILE);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      // Below md the table is replaced by the list form of the same answer, and
      // the page still fits the viewport.
      await expect(page.locator("#findings-list")).toBeVisible();
      await expect(page.locator("#findings-table")).toBeHidden();
      await expect(
        page.locator(
          '#findings-list [data-platform-id="BROWSER_EVO_PLATFORM"] [data-connection-state="lost"]',
        ),
      ).toHaveCount(2);
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-026-production-mobile.png"),
        fullPage: true,
      });

      await page.setViewportSize(NARROW);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(testInfo, "step-026-production-320.png"),
        fullPage: true,
      });
    });

    // The reference is a self-contained file in the gitignored `.specs/`
    // workspace, so this case skips (rather than fails) in a checkout without it.
    test.describe("reference capture", () => {
      test.skip(() => !fs.existsSync(ACCESS_REFERENCE_PATH), "reference file not present");

      test("captures the reference states at the same viewports", async ({
        page,
      }, testInfo) => {
        await page.setViewportSize(DESKTOP);

        for (const [state, name] of [
          ["", "ideal"],
          ["?state=baseline-gap", "baseline-gap"],
          ["?state=incomplete", "incomplete"],
          ["?state=timezone", "timezone"],
          ["?state=error", "error"],
        ]) {
          await page.goto(
            `${pathToFileURL(ACCESS_REFERENCE_PATH).href}${state}`,
          );
          await expect(page.locator("#evolutions-view-nav")).toBeVisible();
          await page.screenshot({
            path: capturePath(testInfo, `step-026-reference-${name}-desktop.png`),
            fullPage: true,
          });
        }

        await page.setViewportSize(MOBILE);
        await page.goto(pathToFileURL(ACCESS_REFERENCE_PATH).href);
        await expect(page.locator("#preview-findings")).toBeVisible();
        await page.screenshot({
          path: capturePath(testInfo, "step-026-reference-ideal-mobile.png"),
          fullPage: true,
        });
      });
    });
  });
});

// Step 27 (EV-29): the service-time timeline under the moment preview. The
// seeded station carries a daytime elevator window and an overnight staircase
// window that runs to 26:00, so whatever day the suite runs on the timeline
// shows the selected service date's own instances plus the previous service
// date's spill-over, and the axis always reaches past 24:00.
test.describe("timeline", () => {
  // The zone the seeded version's agency runs in, so the dates the page
  // resolved are labelled the way the page labels them without depending on the
  // runner's own timezone.
  const AGENCY_TZ = "America/New_York";

  async function agencyToday(page) {
    return page.evaluate(
      (timeZone) =>
        new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date()),
      AGENCY_TZ,
    );
  }

  function shiftDays(iso, days) {
    const [year, month, day] = iso.split("-").map(Number);

    return new Date(Date.UTC(year, month - 1, day) + days * 86_400_000)
      .toISOString()
      .slice(0, 10);
  }

  // The page's own civil label for a date: weekday, month and day (`%a, %b %-d`).
  function civilLabel(iso) {
    const [year, month, day] = iso.split("-").map(Number);
    const date = new Date(Date.UTC(year, month - 1, day));
    const part = (options) =>
      new Intl.DateTimeFormat("en-US", { timeZone: "UTC", ...options }).format(
        date,
      );

    return `${part({ weekday: "short" })}, ${part({ month: "short" })} ${day}`;
  }

  const closureRow = (page, serviceDate, pathwayId) =>
    page
      .locator(`#timeline-rows > li[data-service-date="${serviceDate}"]`)
      .filter({ hasText: pathwayId });

  const boundary = (row, phase) =>
    row.locator(`[data-boundary-phase="${phase}"]`);

  // A boundary action patches the route, and the patched query encodes the
  // colon in the service time, so the wait reads the parameters rather than
  // matching a spelled-out URL.
  async function waitForMoment(page, versionId, date, time) {
    await page.waitForURL(
      (url) =>
        url.pathname ===
          `/gtfs/${versionId}/stops/${STATION}/evolutions/access` &&
        url.searchParams.get("date") === date &&
        url.searchParams.get("time") === time,
    );
  }

  // The earlier answer stays on screen under its stale label while the new
  // moment is calculated, so a check waits for the new answer itself.
  async function waitForMomentApplied(page, time) {
    await page.waitForFunction(
      (expected) => {
        const moment = document.querySelector("#preview-moment");

        return Boolean(
          moment &&
            moment.textContent.includes(`${expected} service time`) &&
            !document.querySelector("#analysis-stale"),
        );
      },
      time,
    );
  }

  const connectionCell = (page, connection) =>
    page
      .locator(
        '#findings-table tbody[data-platform-id="BROWSER_EVO_PLATFORM"] tr',
        { hasText: "North entrance" },
      )
      .locator(`td[data-connection="${connection}"]`);

  test.describe("the closure timeline", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("draws the selected date's overnight window, its spill-over and its exact actions", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      const today = await agencyToday(page);
      const yesterday = shiftDays(today, -1);
      const tomorrow = shiftDays(today, 1);

      // The default moment is the agency's own today at noon, which the form
      // and the timeline's title both name.
      await expect(page.locator("#preview-date")).toHaveValue(today);
      await expect(page.locator("#timeline-title")).toHaveText(
        `Closures on ${civilLabel(today)}`,
      );

      // The staircase window runs to 26:00, so the axis reaches past midnight
      // and the sub-line maps those hours onto the local clock.
      await expect(page.locator("#preview-timeline")).toHaveAttribute(
        "data-axis-seconds",
        "93600",
      );
      await expect(page.locator("#timeline-sub")).toHaveText(
        `Service hours 00:00–26:00. 24:00–26:00 is 12:00 AM–2:00 AM on ${civilLabel(tomorrow)}. Choose a boundary to preview that moment.`,
      );
      await expect(page.locator("#timeline-cursor-label")).toHaveText(
        "Selected time · 12:00",
      );

      // Three instances intersect the displayed span: yesterday's staircase
      // window, today's elevator window and today's staircase window.
      await expect(page.locator("#timeline-rows > li")).toHaveCount(3);

      // The previous service date's instance is clipped where the span starts,
      // carries its own service date, and keeps its own window.
      const spill = closureRow(page, yesterday, "BROWSER_EVO_PW_STAIR");
      await expect(spill).toHaveCount(1);
      await expect(spill).toHaveAttribute("data-from-seconds", "0");
      await expect(spill).toHaveAttribute("data-to-seconds", "7200");
      await expect(spill).toContainText(
        `From ${civilLabel(yesterday)} service`,
      );
      await expect(spill).toContainText("22:00–26:00");
      await expect(spill.locator("[data-timeline-closed]")).toHaveAttribute(
        "style",
        /left: 0\.000%; width: 7\.692%/,
      );
      await expect(boundary(spill, "closes")).toHaveCount(0);
      await expect(spill).toContainText(
        `Boundary actions are on the ${civilLabel(yesterday)} service date.`,
      );

      const lift = closureRow(page, today, "BROWSER_EVO/PW LIFT 1");
      const stair = closureRow(page, today, "BROWSER_EVO_PW_STAIR");

      await expect(boundary(lift, "before")).toHaveAttribute(
        "data-boundary-time",
        "32340",
      );
      await expect(boundary(lift, "closes")).toHaveAttribute(
        "data-boundary-time",
        "32400",
      );
      await expect(boundary(lift, "during")).toHaveAttribute(
        "data-boundary-time",
        "43200",
      );
      await expect(boundary(lift, "reopens")).toHaveAttribute(
        "data-boundary-time",
        "54000",
      );
      await expect(boundary(lift, "before")).toContainText("08:59");
      await expect(boundary(lift, "reopens")).toContainText("15:00");

      // The default noon moment is the elevator window's own midpoint, so that
      // action is the current one and the others are not.
      await expect(boundary(lift, "during")).toHaveAttribute(
        "aria-pressed",
        "true",
      );
      await expect(boundary(lift, "closes")).toHaveAttribute(
        "aria-pressed",
        "false",
      );

      // A 24:00 and a 26:00 action are exact instants like any other: they stay
      // in service seconds rather than being reparsed as a clock label.
      await expect(boundary(stair, "during")).toHaveAttribute(
        "data-boundary-time",
        "86400",
      );
      await expect(boundary(stair, "during")).toContainText("24:00");
      await expect(boundary(stair, "reopens")).toHaveAttribute(
        "data-boundary-time",
        "93600",
      );
      await expect(boundary(stair, "reopens")).toContainText("26:00");

      // Closes shows the loss that window causes: 09:00 closes the elevator, so
      // step-free travel is lost while the staircase keeps walking.
      await boundary(lift, "closes").click();
      await waitForMoment(page, versionId, today, "09:00:00");
      await waitForMomentApplied(page, "09:00");

      await expect(connectionCell(page, "step_free_to_platform")).toHaveAttribute(
        "data-state",
        "lost",
      );
      await expect(connectionCell(page, "walking_to_platform")).toHaveAttribute(
        "data-state",
        "available",
      );
      await expect(page.locator("#preview-moment")).toContainText(
        "09:00 service time",
      );
      await expect(boundary(lift, "closes")).toHaveAttribute(
        "aria-pressed",
        "true",
      );
      await expect(page.locator("#analysis-stale")).toHaveCount(0);

      // Reopens at 26:00 restores it, and the moment line names the instant the
      // action carried: 2:00 AM on the next civil day.
      await boundary(stair, "reopens").click();
      await waitForMoment(page, versionId, today, "26:00:00");
      await waitForMomentApplied(page, "26:00");

      await expect(page.locator("#preview-result-title")).toHaveText(
        "No connection lost at this time",
      );
      await expect(page.locator("#preview-moment")).toContainText(
        "26:00 service time",
      );
      await expect(page.locator("#preview-moment")).toContainText("2:00 AM");
      await expect(page.locator("#timeline-cursor-label")).toHaveText(
        "Selected time · 26:00",
      );
      await expect(boundary(stair, "reopens")).toHaveAttribute(
        "aria-pressed",
        "true",
      );
      await expect(boundary(stair, "closes")).toHaveAttribute(
        "aria-pressed",
        "false",
      );
    });

    test("keeps the boundary actions keyboard operable and inside the viewport", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.setViewportSize(MOBILE);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      const today = await agencyToday(page);
      const stair = closureRow(page, today, "BROWSER_EVO_PW_STAIR");
      const actions = stair.locator("[data-boundary-phase]");

      // Every action keeps the 44px target floor at the phone width.
      await expect(actions).toHaveCount(4);

      for (let index = 0; index < 4; index += 1) {
        const box = await actions.nth(index).boundingBox();
        if (box) expect(box.height).toBeGreaterThanOrEqual(44);
      }

      // A boundary is a real button: it is reachable by keyboard and fires on
      // Enter, which is what a keyboard-only reader has.
      await actions.nth(2).focus();
      await page.keyboard.press("Enter");
      await waitForMoment(page, versionId, today, "24:00:00");
      await waitForMomentApplied(page, "24:00");

      await expect(page.locator("#timeline-cursor-label")).toHaveText(
        "Selected time · 24:00",
      );
      expect(await bodyFitsViewport(page)).toBe(true);

      // At 320 the page still has no horizontal overflow, and each action's own
      // label stays inside the button that carries it.
      await page.setViewportSize(NARROW);
      await page.goto(accessPath(versionId, STATION, `?date=${today}&time=24:00:00`));
      await waitForLiveView(page);

      expect(await bodyFitsViewport(page)).toBe(true);

      const narrow = closureRow(page, today, "BROWSER_EVO_PW_STAIR").locator(
        "[data-boundary-phase]",
      );

      for (let index = 0; index < (await narrow.count()); index += 1) {
        const overflow = await narrow
          .nth(index)
          .evaluate((element) => element.scrollWidth - element.clientWidth);

        expect(overflow).toBeLessThanOrEqual(1);
      }
    });
  });

  test.describe("rendered result", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("matches the reference timeline hierarchy with production fonts and tokens", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);

      await page.setViewportSize(DESKTOP);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#timeline-title")).toBeVisible();
      await expect(page.locator("#timeline-title")).toHaveCSS(
        "font-family",
        /Gabarito/,
      );
      await expect(page.locator("#timeline-sub")).toContainText(
        "Service hours 00:00–26:00.",
      );
      await expect(page.locator("#timeline-rows > li").first()).toBeVisible();
      await expect(page.locator("#timeline-rows > li").first()).toHaveCSS(
        "font-family",
        /Figtree/,
      );
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-027-production-desktop.png"),
        fullPage: true,
      });

      // Each width re-enters the route so the state is the route's own, not a
      // client-side reflow of the desktop render.
      await page.setViewportSize(MOBILE);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      await expect(page.locator("#timeline-rows > li").first()).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-027-production-mobile.png"),
        fullPage: true,
      });

      await page.setViewportSize(NARROW);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-027-production-320.png"),
        fullPage: true,
      });
    });

    // The reference is a self-contained file in the gitignored `.specs/`
    // workspace, so this case skips (rather than fails) in a checkout without it.
    test.describe("reference capture", () => {
      test.skip(() => !fs.existsSync(ACCESS_REFERENCE_PATH), "reference file not present");

      test("captures the reference timeline at the same viewports", async ({
        page,
      }, testInfo) => {
        await page.setViewportSize(DESKTOP);
        await page.goto(
          `${pathToFileURL(ACCESS_REFERENCE_PATH).href}?state=overnight`,
        );
        await expect(page.locator("#preview-timeline")).toBeVisible();
        await page.screenshot({
          path: capturePath(testInfo, "step-027-reference-desktop.png"),
          fullPage: true,
        });

        await page.setViewportSize(MOBILE);
        await page.goto(
          `${pathToFileURL(ACCESS_REFERENCE_PATH).href}?state=overnight`,
        );
        await expect(page.locator("#preview-timeline")).toBeVisible();
        await page.screenshot({
          path: capturePath(testInfo, "step-027-reference-mobile.png"),
          fullPage: true,
        });
      });
    });
  });
});

// Step 28 (EV-8): the bounded range check under the moment preview. The seeded
// station carries a daily 09:00-15:00 elevator closure, so whatever day the
// suite runs on the range reports the step-free loss that window causes on each
// service date it covers, with the exact local window, the closure that caused
// it and a Show at link to the backend's own preview target.
test.describe("range", () => {
  // The zone the seeded version's agency runs in, so the dates the page
  // resolved are named the way the page names them without depending on the
  // runner's own timezone.
  const AGENCY_TZ = "America/New_York";

  async function agencyToday(page) {
    return page.evaluate(
      (timeZone) =>
        new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date()),
      AGENCY_TZ,
    );
  }

  function shiftDays(iso, days) {
    const [year, month, day] = iso.split("-").map(Number);

    return new Date(Date.UTC(year, month - 1, day) + days * 86_400_000)
      .toISOString()
      .slice(0, 10);
  }

  // The page's own short span label for two dates: one date, a same-month
  // range, a same-year range, or both years.
  function shortRange(first, last) {
    const [fy, fm, fd] = first.split("-").map(Number);
    const [ly, lm, ld] = last.split("-").map(Number);
    const month = (m) =>
      new Intl.DateTimeFormat("en-US", { timeZone: "UTC", month: "short" })
        .format(new Date(Date.UTC(2026, m - 1, 1)));

    if (first === last) return `${month(fm)} ${fd}, ${fy}`;
    if (fy !== ly) return `${month(fm)} ${fd}, ${fy}–${month(lm)} ${ld}, ${ly}`;
    if (fm !== lm) return `${month(fm)} ${fd}–${month(lm)} ${ld}, ${ly}`;

    return `${month(fm)} ${fd}–${ld}, ${ly}`;
  }

  async function checkRange(page, first, last) {
    await page.fill("#range-first", first);
    await page.fill("#range-last", last);
    await page.locator("#check-range").click();
  }

  // The rows the wide layout shows. When the report groups, a row carries the
  // number of days it covers; in the every-period view each row is one period.
  async function periodCounts(page) {
    return page
      .locator("#range-periods-table tbody tr")
      .evaluateAll((nodes) => nodes.map((node) => Number(node.dataset.periodCount)));
  }

  test.describe("the range check", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("checks the selected dates and lists every period the backend reported", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      // The form opens on the selected service date for both endpoints, and
      // nothing has been checked yet.
      const today = await agencyToday(page);
      const tomorrow = shiftDays(today, 1);

      await expect(page.locator("#range-first")).toHaveValue(today);
      await expect(page.locator("#range-last")).toHaveValue(today);
      await expect(page.locator("#range-empty")).toContainText("No range checked yet.");
      await expect(page.locator("#range-result")).toHaveCount(0);

      await checkRange(page, today, tomorrow);

      // The summary names the exact service dates, the covered local span and
      // the zone the service times count from.
      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, tomorrow)}`,
      );
      await expect(page.locator("#range-result")).toContainText("(America/New_York)");
      await expect(page.locator("#range-computed")).toContainText(
        "with lost connections · Checked ",
      );
      await expect(page.locator("#range-empty")).toHaveCount(0);
      await expect(page.locator("#range-no-loss")).toHaveCount(0);
      await expect(page.locator("#range-stale")).toHaveCount(0);

      // The elevator's 09:00-15:00 window loses the step-free connection on
      // every service date the range covers, so at least one period per date.
      const counts = await periodCounts(page);
      const periods = counts.reduce((total, count) => total + count, 0);

      expect(counts.length).toBeGreaterThan(0);
      expect(periods).toBeGreaterThanOrEqual(2);

      const first = page.locator("#range-periods-table tbody tr").first();

      // The window leads in service time, as the closure list and the
      // timeline do; the clock time is the secondary line.
      await expect(first.locator("[id$='-when']")).toContainText("09:00–15:00");
      await expect(first.locator("[id$='-when']")).toContainText("9:00 AM – 3:00 PM");
      await expect(first).toContainText("No step-free route to Platform 1");
      await expect(first).toContainText(
        "Step-free to platform · North entrance ↔ Platform 1",
      );
      await expect(first).toContainText("BROWSER_EVO/PW LIFT 1");
      await expect(first).toContainText("09:00–15:00");
      await expect(first.locator("[id$='-lost']")).not.toContainText("Walking");

      // The Show at link names the pair the backend chose for the period, and
      // following it lands the moment preview on that same instant.
      const showAt = first.locator("a[id$='-show'], a[id*='range-show']").first();
      const targetDate = await showAt.getAttribute("data-show-date");
      const targetTime = await showAt.getAttribute("data-show-time");

      expect(targetDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(targetTime).toBe("09:00");

      await showAt.click();

      await page.waitForURL(
        (url) =>
          url.pathname ===
            `/gtfs/${versionId}/stops/${STATION}/evolutions/access` &&
          url.searchParams.get("date") === targetDate &&
          url.searchParams.get("time") === "09:00:00",
      );

      await expect(page.locator("#preview-moment")).toContainText(
        "09:00 service time",
      );

      // The range is an earlier check of a different span now: it stays on
      // screen under its own stale label rather than being replaced by the
      // moment the preview just answered for.
      await expect(page.locator("#range-stale")).toContainText(
        "Results are from an earlier check",
      );
      await expect(page.locator("#range-stale-detail")).toContainText(
        `service dates ${shortRange(today, tomorrow)}`,
      );
      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, tomorrow)}`,
      );

      // List every period restores exactly the periods the backend returned:
      // the grouped rows' own day counts add up to the every-period rows.
      if ((await page.locator("#range-view").count()) > 0) {
        const groupedRows = await counts.length;

        await page.locator("#range-view-all").click();
        await expect(page.locator("#range-view-all")).toHaveAttribute(
          "aria-pressed",
          "true",
        );
        await expect(page.locator("#range-periods-table tbody tr")).toHaveCount(
          periods,
        );

        await page.locator("#range-view-grouped").click();
        await expect(page.locator("#range-periods-table tbody tr")).toHaveCount(
          groupedRows,
        );
        await expect(page.locator("#range-view-grouped")).toHaveAttribute(
          "aria-pressed",
          "true",
        );
      }
    });

    test("a refused span is inline invalid and keeps the earlier result", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      const today = await agencyToday(page);
      const tomorrow = shiftDays(today, 1);

      await checkRange(page, today, today);
      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, today)}`,
      );
      await expect(page.locator("#range-stale")).toHaveCount(0);

      // A last date before the first: the message names the field and the
      // earlier range stays under its stale label.
      await checkRange(page, tomorrow, today);

      await expect(page.locator("#range-invalid")).toContainText(
        "Choose a last date on or after the first date.",
      );
      await expect(page.locator("#range-last")).toHaveAttribute(
        "aria-invalid",
        "true",
      );
      await expect(page.locator("#range-stale")).toContainText(
        "Results are from an earlier check",
      );
      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, today)}`,
      );

      // A span over 31 service days is the other refusal the context owns.
      await checkRange(page, today, shiftDays(today, 31));

      await expect(page.locator("#range-invalid")).toContainText(
        "Choose 31 days or fewer.",
      );
      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, today)}`,
      );

      // A valid range recovers and both the refusal and the stale label go.
      await checkRange(page, today, today);

      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, today)}`,
      );
      await expect(page.locator("#range-invalid")).toHaveCount(0);
      await expect(page.locator("#range-stale")).toHaveCount(0);
    });

    test("stays keyboard operable and inside the viewport at phone widths", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);

      await page.setViewportSize(MOBILE);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);

      const today = await agencyToday(page);

      // The form is a real form: the last date submits it on Enter.
      await page.locator("#range-first").fill(today);
      await page.locator("#range-last").fill(today);
      await page.locator("#range-last").press("Enter");

      await expect(page.locator("#range-result")).toContainText(
        `Service dates ${shortRange(today, today)}`,
      );

      // Below `md` the rows are the list form, and every control keeps the
      // 44px target floor.
      await expect(page.locator("#range-periods-list > li").first()).toBeVisible();
      await expect(page.locator("#range-periods-table")).toBeHidden();

      for (const selector of ["#check-range", "#range-periods-list a[id$='-show']"]) {
        const box = await page.locator(selector).first().boundingBox();
        if (box) expect(box.height).toBeGreaterThanOrEqual(44);
      }

      expect(await bodyFitsViewport(page)).toBe(true);

      // At 320 the page still has no horizontal overflow and no row pushes its
      // own content past its box.
      await page.setViewportSize(NARROW);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);
      await checkRange(page, today, today);

      await expect(page.locator("#range-result")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);

      const rows = page.locator("#range-periods-list > li");
      const rowOverflows = await rows.evaluateAll((nodes) =>
        nodes.map((node) => node.scrollWidth - node.clientWidth),
      );

      for (const overflow of rowOverflows) {
        expect(overflow).toBeLessThanOrEqual(1);
      }
    });
  });

  test.describe("rendered result", () => {
    test.beforeEach(async ({ page }) => {
      await logIn(page);
    });

    test("matches the reference range hierarchy with production fonts and tokens", async ({
      page,
    }, testInfo) => {
      const versionId = await seededVersionId(page);
      const today = await agencyToday(page);

      await page.setViewportSize(DESKTOP);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);
      await checkRange(page, today, today);

      await expect(page.locator("#range-title")).toBeVisible();
      await expect(page.locator("#range-title")).toHaveCSS("font-family", /Gabarito/);
      await expect(page.locator("#range-result")).toHaveCSS("font-family", /Figtree/);
      await expect(page.locator("#range-periods-table tbody tr").first()).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-028-production-desktop.png"),
        fullPage: true,
      });

      // Each width re-enters the route so the state is the route's own, not a
      // client-side reflow of the desktop render.
      await page.setViewportSize(MOBILE);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);
      await checkRange(page, today, today);

      await expect(page.locator("#range-periods-list > li").first()).toBeVisible();
      await expect(page.locator("#range-periods-table")).toBeHidden();
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-028-production-mobile.png"),
        fullPage: true,
      });

      await page.setViewportSize(NARROW);
      await page.goto(accessPath(versionId, STATION));
      await waitForLiveView(page);
      await checkRange(page, today, today);

      await expect(page.locator("#range-result")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, "step-028-production-320.png"),
        fullPage: true,
      });
    });

    // The reference is a self-contained file in the gitignored `.specs/`
    // workspace, so this case skips (rather than fails) in a checkout without it.
    test.describe("reference capture", () => {
      test.skip(() => !fs.existsSync(ACCESS_REFERENCE_PATH), "reference file not present");

      test("captures the reference range states at the same viewports", async ({
        page,
      }, testInfo) => {
        await page.setViewportSize(DESKTOP);

        for (const [state, name] of [
          ["ideal", "ideal"],
          ["range-invalid", "invalid"],
          ["timeout", "timeout"],
          ["range-no-loss", "no-loss"],
        ]) {
          await page.goto(`${pathToFileURL(ACCESS_REFERENCE_PATH).href}?state=${state}`);
          await expect(page.locator("#range-section")).toBeVisible();
          await page.locator("#range-section").scrollIntoViewIfNeeded();

          await page.screenshot({
            path: capturePath(testInfo, `step-028-reference-${name}-desktop.png`),
            fullPage: true,
          });
        }

        await page.setViewportSize(MOBILE);

        for (const [state, name] of [
          ["ideal", "ideal"],
          ["range-invalid", "invalid"],
        ]) {
          await page.goto(`${pathToFileURL(ACCESS_REFERENCE_PATH).href}?state=${state}`);
          await expect(page.locator("#range-section")).toBeVisible();

          await page.screenshot({
            path: capturePath(testInfo, `step-028-reference-${name}-mobile.png`),
            fullPage: true,
          });
        }
      });
    });
  });
});

// Step 29 / EV-9. The static pathway floorplan on the authoring locator and on
// the access preview. Expected coordinates, natural IDs and states are literal
// values from the seeded browser fixtures: the Evolutions station has a
// non-square 100 x 80 diagram with one drawing-free closure dot per scheduled
// pathway, and the diagram station keeps a second level whose cross-level
// elevator ends on it. The group reads the shared station and writes nothing to
// the database, so it can run on its own (`--grep floorplan`) or with the rest
// of the file.
const FLOORPLAN_STATION = "BROWSER_STATION";
const FLOORPLAN_L1_ELEVATOR = "BROWSER_PW_ELEVATOR";
const FLOORPLAN_L1_CROSS_LEVEL = "BROWSER_PW_CROSS_LEVEL";

test.describe("floorplan", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  // One diagram unit is one percent of the image width on both axes, so a
  // stored point always lands at x% across and y% of the width down - which for
  // a 100 x 80 image is y / 80 of the height.
  function storedPixel(box, x, y) {
    return { x: box.x + (x / 100) * box.width, y: box.y + (y / 100) * box.width };
  }

  async function expectCenteredOnStoredPoint(page, selector, box, x, y) {
    const target = await page.locator(selector).boundingBox();
    const expected = storedPixel(box, x, y);

    expect(target).not.toBeNull();
    expect(Math.abs(target.x + target.width / 2 - expected.x)).toBeLessThanOrEqual(2);
    expect(Math.abs(target.y + target.height / 2 - expected.y)).toBeLessThanOrEqual(2);
  }

  test("lays the stored coordinates on the non-square image without spilling", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const island = page.locator("#closure-floorplan");
    await expect(island).toHaveAttribute("phx-update", "ignore");
    await expect(island).toHaveAttribute("phx-hook", "PathwayEvolutionsFloorplan");
    await expect(page.locator('#closure-locator [phx-hook="DiagramCanvas"]')).toHaveCount(0);
    await expect(page.locator("#locator-view-diagram")).toHaveAttribute("aria-pressed", "true");

    // The seeded image is 100 x 80: the viewBox must be the image's own aspect
    // ratio, not the prototype's 1060 x 936 fixture.
    await expect(page.locator("#closure-floorplan-svg")).toHaveAttribute("viewBox", "0 0 100 80");

    const imageBox = await page.locator("#closure-floorplan-image").boundingBox();
    const svgBox = await page.locator("#closure-floorplan-svg").boundingBox();
    expect(imageBox).not.toBeNull();
    expect(svgBox).not.toBeNull();
    expect(Math.abs(svgBox.x - imageBox.x)).toBeLessThanOrEqual(1);
    expect(Math.abs(svgBox.y - imageBox.y)).toBeLessThanOrEqual(1);
    expect(Math.abs(svgBox.width - imageBox.width)).toBeLessThanOrEqual(1);
    expect(Math.abs(svgBox.height - imageBox.height)).toBeLessThanOrEqual(1);

    // The walkway runs from the North entrance (20,15) to the Mezzanine (50,30);
    // its own midpoint sits exactly on the stored average in screen pixels.
    const walkway = page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_WALK"]');
    await expect(walkway.locator("line.evo-fp-line")).toHaveAttribute("x1", "20");
    await expect(walkway.locator("line.evo-fp-line")).toHaveAttribute("y1", "15");
    await expect(walkway.locator("line.evo-fp-line")).toHaveAttribute("x2", "50");
    await expect(walkway.locator("line.evo-fp-line")).toHaveAttribute("y2", "30");
    await expectCenteredOnStoredPoint(
      page,
      '#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_WALK"]',
      imageBox,
      35,
      22.5,
    );

    // Every pathway group stays inside the image's own bounds.
    const groups = page.locator("#closure-floorplan-svg [data-pathway-id]");
    await expect(groups).toHaveCount(3);

    for (let index = 0; index < 3; index += 1) {
      const groupBox = await groups.nth(index).boundingBox();
      expect(groupBox.x).toBeGreaterThanOrEqual(imageBox.x - 1);
      expect(groupBox.x + groupBox.width).toBeLessThanOrEqual(imageBox.x + imageBox.width + 1);
      expect(groupBox.y).toBeGreaterThanOrEqual(imageBox.y - 1);
      expect(groupBox.y + groupBox.height).toBeLessThanOrEqual(imageBox.y + imageBox.height + 1);
    }

    // A saved closure is a dot, never a phantom closed-time state; the lift and
    // the staircase each carry one.
    await expect(
      page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO/PW LIFT 1"] .evo-fp-dot'),
    ).toHaveCount(1);
    await expect(
      page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_STAIR"] .evo-fp-dot'),
    ).toHaveCount(1);
    await expect(
      page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_WALK"] .evo-fp-dot'),
    ).toHaveCount(0);

    // At md+ the floorplan replaces the list.
    await expect(page.locator("#closure-floorplan-panel")).toBeVisible();
    await expect(page.locator("#closure-pathway-list")).toBeHidden();
  });

  test("draws a cross-level pathway as a marker at its on-level endpoint", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.goto(evolutionsPath(versionId, FLOORPLAN_STATION));
    await waitForLiveView(page);

    // Level 1: the cross-level elevator is a marker at Platform A's stored point
    // and keeps its own labelled button, while a same-level pathway is a line.
    await expect(page.locator("#closure-floorplan-level-BROWSER_L1")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    const box = await page.locator("#closure-floorplan-image").boundingBox();
    const crossLevel = page.locator(
      `#closure-floorplan-svg [data-pathway-id="${FLOORPLAN_L1_CROSS_LEVEL}"]`,
    );

    await expect(crossLevel).toHaveAttribute("transform", "translate(30 40)");
    await expect(crossLevel.locator(".evo-fp-marker-icon")).toHaveCount(1);
    await expect(crossLevel.locator("line.evo-fp-line")).toHaveCount(0);
    await expectCenteredOnStoredPoint(
      page,
      `#closure-floorplan-svg [data-pathway-id="${FLOORPLAN_L1_CROSS_LEVEL}"]`,
      box,
      30,
      40,
    );
    await expect(
      page.locator(
        `#closure-floorplan-svg [data-pathway-id="${FLOORPLAN_L1_ELEVATOR}"] line.evo-fp-line`,
      ),
    ).toHaveCount(1);

    // The other level's own 1 x 1 image keeps the same stored point space: the
    // marker moves to Mezzanine Landing D (45,55) with no geometry change.
    await page.locator("#closure-floorplan-level-BROWSER_L2").click();

    await expect(page.locator("#closure-floorplan-level-BROWSER_L2")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(page.locator("#closure-floorplan-svg")).toHaveAttribute("viewBox", "0 0 100 100");
    await expect(crossLevel).toHaveAttribute("transform", "translate(45 55)");
    await expect(page.locator("#closure-floorplan-level-label")).toContainText("Browser Level 2");
  });

  test("selects the same pathway from the floorplan keyboard and the list", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    // The list route: choosing the walkway opens a new closure on it.
    await page.locator("#locator-view-list").click();
    await page.locator('#closure-pathway-list button[data-pathway-id="BROWSER_EVO_PW_WALK"]').click();
    await expect(page.locator("#closure-pathway")).toHaveValue("BROWSER_EVO_PW_WALK");

    // Back to the floorplan with a clean draft closed, so the overlay starts on
    // the list's own first pathway (the elevator). Closing the editor hands
    // focus to the idle heading through the list region's scoped focus hook.
    await page.locator("#locator-view-diagram").click();
    await page.locator("#discard-closure").click();
    await waitForSettledFocus(page, "#closure-idle-title");

    const lift = page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO/PW LIFT 1"]');
    await expect(lift).toHaveAttribute("tabindex", "0");

    await lift.focus();
    await expect(lift).toBeFocused();
    await page.keyboard.press("ArrowRight");

    const stairs = page.locator(
      '#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_STAIR"]',
    );
    await expect(stairs).toHaveAttribute("tabindex", "0");
    await expect(stairs).toBeFocused();
    await page.keyboard.press("ArrowRight");

    const walkway = page.locator('#closure-floorplan-svg [data-pathway-id="BROWSER_EVO_PW_WALK"]');
    await expect(walkway).toHaveAttribute("tabindex", "0");
    await expect(walkway).toBeFocused();
    await page.keyboard.press("Enter");

    // Enter selects exactly the pathway the list selected, and focus stays on
    // the pathway the reader activated.
    await expect(page.locator("#closure-pathway")).toHaveValue("BROWSER_EVO_PW_WALK");
    await expect(walkway).toBeFocused();

    // Space activates the same control after the draft is closed again, once
    // the close has settled and the floorplan is deliberately focused anew.
    await page.locator("#discard-closure").click();
    await waitForSettledFocus(page, "#closure-idle-title");

    const elevator = page.locator(
      '#closure-floorplan-svg [data-pathway-id="BROWSER_EVO/PW LIFT 1"]',
    );
    await elevator.focus();
    await expect(elevator).toBeFocused();
    await page.keyboard.press("Space");
    await expect(page.locator("#closure-pathway")).toHaveValue("BROWSER_EVO/PW LIFT 1");
  });

  test("falls back to the visible list when the floorplan image cannot load", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.route("**/uploads/diagrams/**", (route) => route.abort());
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    await expect(page.locator("#closure-floorplan-missing")).toBeVisible();
    await expect(page.locator("#closure-floorplan-panel")).toBeHidden();
    await expect(page.locator("#locator-toggle")).toBeHidden();
    await expect(page.locator("#closure-pathway-list")).toBeVisible();
    // Nothing is left to switch to once the image is gone: the list is the locator.
    await expect(page.locator("#locator-view-list")).toBeHidden();

    await page.unroute("**/uploads/diagrams/**");
  });

  test("renders the list and the availability note for a station with no floorplan", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.goto(evolutionsPath(versionId, EMPTY_STATION));
    await waitForLiveView(page);

    await expect(page.locator("#closure-floorplan-missing")).toBeVisible();
    await expect(page.locator("#locator-toggle")).toHaveCount(0);
    await expect(page.locator("#closure-floorplan")).toHaveCount(0);
    await expect(page.locator("#closure-pathway-list")).toBeVisible();
  });

  test("draws the moment's closed set with text and pattern on the access preview", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    const versionId = await seededVersionId(page);

    await page.goto(accessPath(versionId, STATION));
    await waitForLiveView(page);
    await expect(page.locator("#preview-floorplan")).toBeVisible();

    await expect(page.locator("#preview-floorplan-badge")).toContainText("1 pathway closed");
    await expect(page.locator("#preview-floorplan-closed")).toContainText("BROWSER_EVO/PW LIFT 1");
    await expect(page.locator("#preview-floorplan-closed")).toContainText(
      "Elevator · Mezzanine hall ↔ Platform 1",
    );
    await expect(page.locator("#preview-floorplan-closed")).toContainText("dashed line");
    await expect(page.locator("#preview-floorplan-missing")).toBeHidden();

    const lift = page.locator(
      '#preview-floorplan-canvas-svg [data-pathway-id="BROWSER_EVO/PW LIFT 1"]',
    );
    await expect(lift.locator("line.evo-fp-line")).toHaveAttribute("stroke-dasharray", "7 5");
    await expect(lift.locator(".evo-fp-closed-word")).toHaveText("Closed");

    // Activating the closed pathway highlights its existing cause rows only;
    // it selects nothing and writes nothing.
    const cause = page.locator('#preview-causes li[data-cause-pathway="BROWSER_EVO/PW LIFT 1"]');
    await expect(cause).toHaveCount(1);
    await expect(cause).not.toHaveClass(/evo-cause-highlight/);

    await lift.click();
    await expect(cause).toHaveClass(/evo-cause-highlight/);
    await expect(page.locator("#preview-causes a", { hasText: "Review closure" }).first()).toBeVisible();

    await lift.click();
    await expect(cause).not.toHaveClass(/evo-cause-highlight/);

    // Below md the findings and their causes carry the answer, as the reference
    // does, and the page still has no horizontal overflow.
    await page.setViewportSize(MOBILE);
    await page.goto(accessPath(versionId, STATION));
    await waitForLiveView(page);
    await expect(page.locator("#preview-floorplan")).toBeHidden();
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test.describe("reference capture", () => {
    test.skip(() => !fs.existsSync(REFERENCE_PATH), "reference file not present");

    test("captures the reference floorplan at both viewports", async ({ page }, testInfo) => {
      await page.setViewportSize(DESKTOP);
      await page.goto(pathToFileURL(REFERENCE_PATH).href);
      await expect(page.locator("#closure-floorplan")).toBeVisible();
      await page.locator("#closure-floorplan").scrollIntoViewIfNeeded();

      await page.screenshot({
        path: capturePath(testInfo, "step-029-reference-desktop.png"),
        fullPage: true,
      });

      // Below md the reference hides the panel and shows the list instead.
      await page.setViewportSize(MOBILE);
      await page.goto(pathToFileURL(REFERENCE_PATH).href);
      await expect(page.locator("#closure-floorplan-panel")).toBeHidden();
      await expect(page.locator("#closure-pathway-list")).toBeVisible();

      await page.screenshot({
        path: capturePath(testInfo, "step-029-reference-mobile.png"),
        fullPage: true,
      });

      // The companion access preview shows the closed overlay at md+ only.
      await page.setViewportSize(DESKTOP);
      await page.goto(pathToFileURL(ACCESS_REFERENCE_PATH).href);
      await expect(page.locator("#preview-floorplan")).toBeVisible();

      await page.screenshot({
        path: capturePath(testInfo, "step-029-reference-access-desktop.png"),
        fullPage: true,
      });
    });
  });
});

// Step 30 / EV-10. The integrated journey this whole-file gate exists for: an
// editor authors one closure through the keyboard, reloads it, sees the
// step-free loss it causes while walking and the staircase stay available,
// reopens the boundary at its end, checks the same service date as a one-day
// range, meets the calendar reference refusal, round-trips the closure through
// the real full export and the durable Import feed, and deletes the row it
// authored. Every expected value is a literal from the seeded fixtures or from
// the row this case created; the case removes that row before it ends, so it
// runs alone (`--grep journey`) and leaves no order dependence behind.
test.describe("journey", () => {
  const AGENCY_TZ = "America/New_York";

  async function agencyToday(page) {
    return page.evaluate(
      (timeZone) =>
        new Intl.DateTimeFormat("en-CA", { timeZone }).format(new Date()),
      AGENCY_TZ,
    );
  }

  const connectionCell = (page, connection) =>
    page
      .locator(
        '#findings-table tbody[data-platform-id="BROWSER_EVO_PLATFORM"] tr',
        { hasText: "North entrance" },
      )
      .locator(`td[data-connection="${connection}"]`);

  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("an editor creates, previews, exports, re-imports and deletes a closure", async ({
    page,
  }, testInfo) => {
    // The export builds assets and the round-trip import publishes a version,
    // so the integrated journey needs more than the default 30 seconds.
    test.setTimeout(300_000);

    const versionId = await seededVersionId(page);
    const today = await agencyToday(page);

    // --- Keyboard create: the list's primary action is a real button, the
    // editor opens on its first field, and Enter on the focused save action
    // commits the same way a click would. ---
    await page.setViewportSize(DESKTOP);
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    const createAction = page.locator("#new-closure");
    await createAction.focus();
    await expect(createAction).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#closure-editor-title")).toHaveText("New closure");
    await expect(page.locator("#closure-pathway")).toBeFocused();

    await page.selectOption("#closure-pathway", PUNCTUATED_PATHWAY);
    await page.selectOption("#closure-calendar", "CAL_DAILY");
    await page.fill("#closure-start", "16:00");
    await page.fill("#closure-end", "17:00");
    await page.fill("#closure-note", "Journey check.");
    await expect(page.locator("#closure-summary")).toContainText(
      "closes 16:00–17:00 on each service day of Every day service",
    );

    await page.locator("#save-closure").focus();
    await expect(page.locator("#save-closure")).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#evolutions-status")).toContainText("Closure saved.");
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(3);

    // --- Reload: the authored row rebuilds identically, including its note. ---
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(3);

    const authoredListRow = page
      .locator("#closures-list tr[data-closure-id]")
      .filter({ hasText: "16:00–17:00" });
    await expect(authoredListRow).toHaveCount(1);
    await authoredListRow.locator("button").first().click();
    await expect(page.locator("#closure-note")).toHaveValue("Journey check.");

    await page.screenshot({
      path: capturePath(testInfo, "step-030-journey-authoring-desktop.png"),
      fullPage: true,
    });

    // --- Moment preview: the authored window loses the step-free connection
    // while walking over the staircase stays available. ---
    await page.goto(accessPath(versionId, STATION, `?date=${today}&time=16:30:00`));
    await waitForLiveView(page);

    await expect(page.locator("#preview-moment")).toContainText(
      "16:30 service time",
    );
    await expect(page.locator("#preview-result-title")).toHaveText(
      "No step-free route to or from Platform 1",
    );
    await expect(connectionCell(page, "step_free_to_platform")).toHaveAttribute(
      "data-state",
      "lost",
    );
    await expect(connectionCell(page, "walking_to_platform")).toHaveAttribute(
      "data-state",
      "available",
    );
    await expect(page.locator("#preview-result-body")).toContainText(
      "Elevator · Mezzanine hall ↔ Platform 1 (BROWSER_EVO/PW LIFT 1) is closed 16:00–17:00.",
    );
    await expect(page.locator("#preview-result-body")).toContainText(
      "Walking connections to and from Platform 1 remain.",
    );

    await page.screenshot({
      path: capturePath(testInfo, "step-030-journey-preview-desktop.png"),
      fullPage: true,
    });

    await page.setViewportSize(MOBILE);
    await page.goto(accessPath(versionId, STATION, `?date=${today}&time=16:30:00`));
    await waitForLiveView(page);
    await expect(page.locator("#preview-result-title")).toHaveText(
      "No step-free route to or from Platform 1",
    );
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-030-journey-preview-mobile.png"),
      fullPage: true,
    });

    await page.setViewportSize(NARROW);
    await page.goto(accessPath(versionId, STATION, `?date=${today}&time=16:30:00`));
    await waitForLiveView(page);
    await expect(page.locator("#preview-result")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, "step-030-journey-preview-320.png"),
      fullPage: true,
    });

    // --- Reopen the boundary the authored closure owns: 17:00 restores the
    // step-free connection at exactly that instant. ---
    await page.setViewportSize(DESKTOP);
    await page.goto(accessPath(versionId, STATION, `?date=${today}&time=16:30:00`));
    await waitForLiveView(page);

    const authoredTimelineRow = page
      .locator(`#timeline-rows > li[data-service-date="${today}"]`)
      .filter({ hasText: "16:00–17:00" });
    await expect(authoredTimelineRow).toHaveCount(1);
    await expect(
      authoredTimelineRow.locator('[data-boundary-phase="closes"]'),
    ).toHaveAttribute("data-boundary-time", "57600");

    await authoredTimelineRow.locator('[data-boundary-phase="reopens"]').click();
    await page.waitForURL(
      (url) =>
        url.pathname ===
          `/gtfs/${versionId}/stops/${STATION}/evolutions/access` &&
        url.searchParams.get("date") === today &&
        url.searchParams.get("time") === "17:00:00",
    );
    await expect(page.locator("#preview-result-title")).toHaveText(
      "No connection lost at this time",
    );
    await expect(page.locator("#preview-moment")).toContainText(
      "17:00 service time",
    );

    // --- One-day range: the same service date reports the seeded daytime
    // window and the authored 16:00–17:00 window. ---
    await page.fill("#range-first", today);
    await page.fill("#range-last", today);
    await page.locator("#check-range").click();

    const rangePeriods = page.locator("#range-periods-table tbody");
    await expect(rangePeriods).toContainText("BROWSER_EVO/PW LIFT 1");
    await expect(rangePeriods).toContainText("09:00–15:00");
    await expect(rangePeriods).toContainText("16:00–17:00");
    await expect(page.locator("#range-no-loss")).toHaveCount(0);

    // --- Protected reference: the calendar both windows use cannot be deleted
    // while any closure references it. ---
    await page.goto(calendarPath(versionId, "CAL_DAILY"));
    await waitForLiveView(page);
    await expect(page.locator("#calendar-usage-closures")).toContainText(
      "scheduled closures use this calendar",
    );
    await expect(page.locator("#calendar-delete")).toBeVisible();
    await page.click("#calendar-delete");
    await expect(page.locator("#calendar-delete-blocked-message")).toContainText(
      "Trips and closures use this calendar, so it can’t be deleted",
    );
    await expect(page.locator("#calendar-delete-closures")).toContainText(
      "scheduled closures use this calendar",
    );

    // --- Full export round trip: the real durable export writes the supported
    // row into pathway_evolutions.txt, and the same archive imports through
    // the durable Import feed into a new version that carries it. ---
    await page.goto(exportPath(versionId, "?type=full"));
    await waitForLiveView(page);
    await expect(
      page
        .locator("#export-inventory tbody tr")
        .filter({ hasText: "pathway_evolutions.txt" }),
    ).toHaveCount(1);

    // An earlier case's ready export can already render this link, so the
    // journey waits for its own run's href and ready status before downloading
    // the archive this moment wrote.
    const previousDownloadHref = (await page.locator("#export-download-link").count())
      ? await page.locator("#export-download-link").getAttribute("href")
      : null;

    await page.locator("#start-export").click();
    await expect
      .poll(() => page.locator("#export-download-link").getAttribute("href"), {
        timeout: 60_000,
      })
      .not.toBe(previousDownloadHref);
    await expect(page.locator("#export-run-status")).toContainText(
      "Ready to download",
    );

    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const download = await downloadPromise;
    const zip = fs.readFileSync(await download.path());

    expect(download.suggestedFilename()).toMatch(/\.zip$/);

    const closureCsv = readZipTextMember(zip, "pathway_evolutions.txt");
    expect(closureCsv).toContain(
      "pathway_id,service_id,start_time,end_time,is_closed",
    );
    expect(closureCsv).toContain(
      "BROWSER_EVO/PW LIFT 1,CAL_DAILY,16:00:00,17:00:00,1,",
    );

    const importName = `Browser journey import ${Date.now()}`;
    await page.goto(`/gtfs/${versionId}/import`);
    await waitForLiveView(page);
    await chooseImportSource(page, "feed");
    await page.fill("#gtfs-import-version-name", importName);
    await stageImportFiles(page, [
      { name: `${importName}.zip`, mimeType: "application/zip", buffer: zip },
    ]);
    await page.locator("#gtfs-import-submit").click();

    await expect(page.locator("#gtfs-import-result-title")).toHaveText(
      `Imported “${importName}”`,
      { timeout: 120_000 },
    );

    const importedHref = await page
      .locator("#gtfs-import-view-version")
      .getAttribute("href");
    expect(importedHref).toMatch(/^\/gtfs\/[0-9a-f-]+\/routes$/);
    const importedVersionId = importedHref.split("/")[2];

    await page.goto(
      `/gtfs/${importedVersionId}/stops/${STATION}/evolutions?pathway=${encodeURIComponent(PUNCTUATED_PATHWAY)}`,
    );
    await waitForLiveView(page);
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);
    await expect(page.locator("#closures-list")).toContainText("09:00–15:00");
    await expect(page.locator("#closures-list")).toContainText("16:00–17:00");

    // --- Delete the row this journey authored, through its own confirmation,
    // so the seeded station is what every later reader sees. ---
    await page.goto(evolutionsPath(versionId, STATION));
    await waitForLiveView(page);

    await deleteClosureRow(
      page,
      page
        .locator("#closures-list tr[data-closure-id]")
        .filter({ hasText: "16:00–17:00" }),
      "16:00",
    );
    await expect(page.locator("#closures-list tr[data-closure-id]")).toHaveCount(2);
    await expect(page.locator("#closures-list")).toContainText("09:00–15:00");
    await expect(page.locator("#closures-list")).toContainText("22:00–26:00");
  });
});
