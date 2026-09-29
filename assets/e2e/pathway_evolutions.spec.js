// Scheduled pathway closures on the Evolutions station route (EV-21, step 15)
// and the station-merge closure-file disclosure (EV-20, step 16).
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
// navigation waits for the mounted view first.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected(),
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

    test("the row list is keyboard operable and keeps focus on the selected row", async ({
      page,
    }) => {
      const versionId = await seededVersionId(page);
      await page.goto(evolutionsPath(versionId, STATION));
      await waitForLiveView(page);

      const firstRow = page
        .locator("#closures-list tr[data-closure-id]")
        .first();
      const rowButton = firstRow.locator("button[aria-current]");
      await expect(rowButton).toHaveAttribute("aria-current", "false");

      await rowButton.focus();
      await expect(rowButton).toBeFocused();
      await page.keyboard.press("Enter");

      await expect(rowButton).toHaveAttribute("aria-current", "true");
      await expect(page.locator("#evolutions-status")).toContainText(
        "Selected closure on Elevator",
      );
      // Focus stays on the row the keyboard user activated, not on the body.
      await expect(rowButton).toBeFocused();
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
