// Rosters browser journey.
//
// The journey walks the rosters page end to end in Chromium at 1440x1000
// against the seeded "Browser Rosters Version" in
// `test/support/browser_seed.exs` — the version that carries the five lines the
// page opens on — and captures each state beside the design prototype's
// `?state=` reference for the same state.
//
// The seed, read from `test/support/browser_seed.exs` and not from the page:
//
//   * three calendars — "Weekday", "Saturday" and "Sunday" — deriving the
//     {WKDY}, {SAT} and {SUN} day types, so the base week is Mon–Fri / Sat /
//     Sun by the most-dates default and one date (Labor Day, Monday 2026-09-07)
//     runs different service, which is what the export section's other-service
//     warning is about;
//   * the roster rules — 600 minutes of rest and a warning above 48 hours — so
//     "minimum 10 h" is the number the short-rest refusal names;
//   * nine runs over those three day types: 1001-1005 on weekdays, 6001-6002 on
//     Saturday, 7001-7002 on Sunday. 1005 is the late Sunday 7001's pair: it
//     signs off after 21:00 and leaves under ten hours of rest before an early
//     Monday sign-on;
//   * five lines, written through the production roster writers:
//       line 1 — Mon–Fri on 1001 with the pick recorded for E9001 (Ana Ferreira)
//       line 2 — Monday on 1002 and Sunday on 7001: SHORT REST
//       line 3 — Mon–Fri on 1003 plus Saturday on 6001: days off apart
//       line 4 — Saturday on 6002 and Sunday on 7002: an OPEN line
//       line 5 — Mon–Fri on 1004 with Friday's stored times moved ten minutes
//                earlier: the STALE slot ("Stale run"), which every writer
//                refreshes and only a re-cut leaves behind
//     and weekday run 1005 on no line at all, so "Create Mon–Fri line" has a
//     fully open run to build from and creates line 6;
//   * six synthetic operators E9001-E9006, four numbered and two not, which is
//     the seniority order the pick and the operators drawer both list in.
//
// Every expectation below is a literal from that seed or from the copy in
// `lib/gtfs_planner_web/live/gtfs/rosters_components.ex`, never a value read
// back out of the surface under test — except where the point of the
// assertion is that the page re-read the rows.
//
// The journeys share one seeded database and the later ones write, so they are
// serial and run in the order below: everything that reads the grid runs before
// the pick, the import and the delete change it.
//
// Captures go to `.specs/09-basic-rosters/evidence/browser/` through the
// repository's own `captureShot` helper; the last
// journey writes `qa-tour.md` from what the earlier ones recorded. `.specs/` is
// gitignored and lives in the primary checkout, so the captures and the tour
// are skipped (never failed) when that workspace is not linked.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport, captureShot, logInAs } from "./browser_helpers";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SPEC_PACKAGE = resolve(__dirname, "..", "..", ".specs", "09-basic-rosters");
const EVIDENCE_DIR = resolve(SPEC_PACKAGE, "evidence", "browser");
const REFERENCE_PROTOTYPE = resolve(SPEC_PACKAGE, "references", "rosters-prototype.html");

// `captureShot` records only when this names a directory, and the journey's
// verification command is a bare `bin/test-browser e2e/rosters.spec.js`, so the
// journey defaults it to the spec package evidence folder and an environment value
// still wins.
process.env.ROUTE16_CAPTURE_DIR ??= EVIDENCE_DIR;

// The credential is read from the seed rather than written here, so it cannot
// drift from the account `bin/test-browser` creates and this file does not
// become a second copy of a password.
const EDITOR = seededEditor();
const VERSION_NAME = "Browser Rosters Version";

// The seeded lines and the run the seeded open work offers.
const SEEDED_LINES = 5;
const CREATED_LINE = 6;
const OPEN_RUN = "1005";
const SHORT_REST_LINE = 2;
const SHORT_REST_RUN = "1002";

// The seeded operators in `Operations.list_operators/1` order: numbered first
// in ascending seniority, then the two without one by name.
const SEEDED_OPERATORS = [
  "E9003",
  "E9002",
  "E9001",
  "E9006",
  "E9004",
  "E9005",
];

// What the pick row offers on the line this journey records: everyone who holds
// no line in this version, in the same seniority order. E9001 and E9002 are
// missing because the seed put them on lines 1 and 5.
const PICK_OFFER = [
  "#3 Cleo Marchetti · E9003",
  "#21 Femi Adeyemi · E9006",
  "Devon Okafor · E9004",
  "Esi Halloran · E9005",
];
const PICKS_OPERATOR = "Cleo Marchetti";

// `test/fixtures/tods/operators_sample.csv`: two rows that import, one with no
// name and one whose seniority is not a number, and a column nothing stores.
const OPERATORS_CSV = resolve(
  __dirname,
  "..",
  "..",
  "test",
  "fixtures",
  "tods",
  "operators_sample.csv"
);

const DESKTOP = { width: 1440, height: 1000 };
const NARROW = { width: 1280, height: 900 };
// The mobile viewport the toast shell is asserted and captured at.
const MOBILE = { width: 390, height: 844 };

// The prototype states this journey mirrors, in the card's own order.
const REFERENCE_SCENARIOS = [
  ["default", "state=default"],
  ["slot-refusal", "state=slot-refusal"],
  ["pick", "state=pick"],
  ["operators", "state=operators"],
  ["import", "state=import"],
  ["delete-operator", "state=delete-operator"],
  ["settings-error", "state=settings-error"],
  ["export", "state=export"],
];

// What the qa tour reports; each journey fills its own keys.
const tour = {};

function seededEditor() {
  const seed = readFileSync(
    new URL("../../test/support/browser_seed.exs", import.meta.url),
    "utf8",
  );

  const email = seed.match(/email: "(diagram-test@gtfs-planner\.test)"/);
  const password = seed.match(
    /email: "diagram-test@gtfs-planner\.test",\s*\n\s*password: "([^"]+)"/
  );

  if (!email || !password) {
    throw new Error(
      "The seeded editor is not in test/support/browser_seed.exs; this spec reads its credential from the seed and will not guess one."
    );
  }

  return { email: email[1], password: password[1] };
}

// The seeded database names its published version, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
async function versionIdFor(page, versionName = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function rostersPath(versionId, query = "") {
  return `/gtfs/${versionId}/rosters${query}`;
}

// The grid streams its rows after mount, so every journey waits for the lines
// to arrive before measuring or clicking anything.
async function openRosters(page, versionId, expected = SEEDED_LINES) {
  await page.goto(rostersPath(versionId));
  await expect(page.locator("#rosters-page")).toHaveAttribute("data-load-state", "ready");
  await expect(page.locator("#rosters-grid-body tr.rosters-line-row")).toHaveCount(expected, {
    timeout: 30_000,
  });
}

// The line numbers the grid draws, in the order it draws them.
async function lineNumbers(page) {
  return page.$$eval("#rosters-grid-body .rosters-line-link", (links) =>
    links.map((link) => Number(link.id.split("-")[2]))
  );
}

async function slotState(page, line, weekday) {
  const slot = page.locator(`#slot-${line}-${weekday}`);
  return {
    state: await slot.getAttribute("data-slot"),
    warning: await slot.getAttribute("data-warning"),
    label: await slot.getAttribute("aria-label"),
  };
}

// A drawer is a top-layer `<dialog>`; the shared component carries its open
// state on the overlay, so every wait reads the component's own attribute.
async function openDrawer(page, drawerId) {
  await expect(page.locator(`#${drawerId}-overlay[data-open="true"]`)).toBeVisible();
}

// A closed drawer is either gone from the document — the page renders a
// drawer only while the assign it reads is there — or present with the
// component's own `data-open` off. Both are "closed".
async function closeDrawer(page, drawerId) {
  const overlay = page.locator(`#${drawerId}-overlay`);
  await expect(overlay).toHaveCount(0, { timeout: 15_000 });
}

function toastText(page) {
  return page.locator("#rosters-toast-text");
}

// The toast shell's computed bounds at the width being measured: the shell
// sits inside the viewport and the dismiss control keeps its 44px target.
async function expectToastShellFits(page, width) {
  const shell = await page.locator("#rosters-toast").boundingBox();
  const dismiss = await page
    .locator("#rosters-toast [data-role='dismiss-toast']")
    .boundingBox();

  expect(shell, "the toast shell must be rendered").not.toBeNull();
  expect(dismiss, "the dismiss control must be rendered").not.toBeNull();
  expect(shell.x).toBeGreaterThanOrEqual(0);
  expect(shell.x + shell.width).toBeLessThanOrEqual(width);
  expect(dismiss.width).toBeGreaterThanOrEqual(44);
  expect(dismiss.height).toBeGreaterThanOrEqual(44);
}

// A capture into the evidence folder named by the card. Drawers and dialogs
// live in the top layer, so they are captured against the viewport rather than
// as a full-page stitch of the page behind them.
async function capture(page, name, { fullPage = true } = {}) {
  await captureShot(page, name, { fullPage });
}

test.describe("Rosters page at 1440x1000", () => {
  test.use({ viewport: DESKTOP });
  // The journeys share one seeded database and the later ones write; running
  // them out of order would read a grid an earlier one had already changed.
  test.describe.configure({ mode: "serial" });

  test("an editor opens Operations › Rosters from the navigation and sees the seeded lines", async ({
    page,
  }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);

    // Arrived from another Operations section, so the journey exercises the
    // sub-nav rather than a typed URL.
    await page.goto(`/gtfs/${versionId}/blocks`);
    await expect(page.locator("#operations-tab-blocks")).toHaveAttribute("aria-current", "page");
    await page.locator("#operations-tab-rosters").click();
    await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/rosters$`));

    await openRosters(page, versionId);

    // The five seeded lines, in number order, so a journey that read another
    // version or another day would not see these five.
    expect(await lineNumbers(page)).toEqual([1, 2, 3, 4, 5]);

    // Line 1 works its weekday run; line 2's short rest is marked on the later
    // day of the pair, which is Monday here; line 5's Friday is the stale slot.
    expect(await slotState(page, 1, 1)).toMatchObject({ state: "work", warning: null });
    expect(await slotState(page, 2, 1)).toMatchObject({
      state: "work",
      warning: "short-rest",
    });
    expect(await slotState(page, 5, 5)).toMatchObject({ state: "stale" });
    expect(
      (await page.locator("#slot-5-5 .rosters-slot-times").textContent()).trim()
    ).toBe("Stale run");

    // The stale slot is the page's own message, not only a cell's marker, and
    // it offers the filter that finds it.
    await expect(page.locator("#rosters-stale-message")).toBeVisible();

    // Lines 1 and 5 are assigned and 4 is open, so the Operator column is
    // three different answers rather than one.
    await expect(page.locator("#rosters-line-1-open")).toHaveAttribute(
      "aria-label",
      /^Line 1, Assigned\./,
    );
    await expect(page.locator("#rosters-line-4-open")).toHaveAttribute(
      "aria-label",
      /^Line 4, Open\./,
    );

    tour.opened = {
      lines: await lineNumbers(page),
      shortRestWarning: (await slotState(page, 2, 1)).warning,
      staleTimes: await page.locator("#slot-5-5 .rosters-slot-times").textContent(),
      staleMessage: (await page.locator("#rosters-stale-message").textContent()).trim(),
    };

    await capture(page, "default-1440");
  });

  test("Create Mon–Fri line on the seeded open run adds a highlighted line", async ({ page }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId);

    // Run 1005 is the seed's open weekday run, so the builder is offered.
    const card = page.locator(`[id^="rosters-open-run-"][data-run="${OPEN_RUN}"]`);
    await expect(card).toHaveCount(1);
    await expect(page.locator(`#rosters-create-line-${OPEN_RUN}`)).toHaveText(
      "Create Mon–Fri line",
    );

    await page.locator(`#rosters-create-line-${OPEN_RUN}`).click();

    // The toast names the run, the days and what is left off.
    await expect(toastText(page)).toContainText(
      `Line ${CREATED_LINE} created: run ${OPEN_RUN}, Monday, Tuesday, Wednesday, Thursday, Friday.`,
    );

    // The shared shell at 1440x1000: root, text, icon and dismiss target —
    // and no Undo control on this page.
    const toast = page.locator("#rosters-toast");
    await expect(toast).toBeVisible();
    await expect(toast).toHaveAttribute("role", "status");
    await expect(toast).toHaveAttribute("aria-live", "polite");
    await expect(toast).toHaveAttribute("data-role", "rosters-toast");
    await expect(page.locator("#rosters-toast-text")).toBeVisible();
    await expect(page.locator("#rosters-toast [data-role='toast-icon']")).toHaveCount(1);
    await expect(page.locator("#rosters-toast [data-role='dismiss-toast']")).toBeVisible();
    await expect(page.locator("#rosters-toast [data-role='undo']")).toHaveCount(0);

    await expectToastShellFits(page, DESKTOP.width);

    // Read while the toast is up: it dismisses itself after four seconds, and
    // the grid assertions below take their own time.
    const toastWords = (await toastText(page).textContent()).trim();
    await capture(page, "create-line-1440");

    // The same shell at 390x844: the responsive max width keeps it inside the
    // mobile viewport and the dismiss target stays 44px.
    await page.setViewportSize(MOBILE);
    await expect(toast).toBeVisible();
    await expectToastShellFits(page, MOBILE.width);
    await capture(page, "create-line-390");
    await page.setViewportSize(DESKTOP);

    // The line is on the grid, and it is the highlighted one.
    expect(await lineNumbers(page)).toEqual([1, 2, 3, 4, 5, CREATED_LINE]);
    const newRow = page.locator(`#rosters-grid-body tr:has(#rosters-line-${CREATED_LINE}-open)`);
    await expect(newRow).toHaveAttribute("data-new", "true");
    await expect(page.locator(`#rosters-line-${CREATED_LINE}-open`)).toHaveAttribute(
      "aria-label",
      new RegExp(`^Line ${CREATED_LINE}, Open\\.`),
    );

    // All five weekdays work the run it was built from, and the weekend is off.
    for (const weekday of [1, 2, 3, 4, 5]) {
      const slot = await slotState(page, CREATED_LINE, weekday);
      expect(slot).toMatchObject({ state: "work", warning: null });
      await expect(page.locator(`#slot-${CREATED_LINE}-${weekday}`)).toContainText(OPEN_RUN);
    }
    for (const weekday of [6, 7]) {
      expect((await slotState(page, CREATED_LINE, weekday)).state).toBe("off");
    }

    // And the run it was built from left the open work it was on.
    await expect(page.locator(`[id^="rosters-open-run-"][data-run="${OPEN_RUN}"]`)).toHaveCount(0);

    tour.created = {
      run: OPEN_RUN,
      line: CREATED_LINE,
      highlighted: await newRow.getAttribute("data-new"),
      toast: toastWords,
      weekdaySlots: await Promise.all(
        [1, 2, 3, 4, 5, 6, 7].map((w) => slotState(page, CREATED_LINE, w)),
      ),
    };
  });

  test("the short-rest line's Monday drawer refuses the group and saves the day as a warning", async ({
    page,
  }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    // The journey before this one created a line, so the grid carries six.
    await openRosters(page, versionId, SEEDED_LINES + 1);

    // Line 2's Monday holds run 1002, whose Sunday neighbour 7001 signs off too
    // late for the sign-on, which is the seed's short rest.
    await expect(page.locator(`#slot-${SHORT_REST_LINE}-1`)).toHaveAttribute(
      "data-warning",
      "short-rest",
    );
    await page.locator(`#slot-${SHORT_REST_LINE}-1`).click();
    await openDrawer(page, "rosters-slot-drawer");

    // The candidate the drawer opened on is the line's own Monday run.
    await expect(page.locator(`#rosters-slot-run-${SHORT_REST_RUN}`)).toBeChecked();

    // The group's own action is on screen and off, with the sentence that says
    // why underneath it — a control that vanished would leave the planner
    // looking for it.
    const setGroup = page.locator("#rosters-set-group");
    await expect(setGroup).toHaveText(`Set Mon–Fri to run ${SHORT_REST_RUN}`);
    await expect(setGroup).toBeDisabled();
    await expect(setGroup).toHaveAttribute("aria-describedby", "rosters-group-reason");

    const reason = (await page.locator("#rosters-group-reason").textContent()).trim();
    expect(reason).toContain("rest after run 1002");
    expect(reason).toContain("minimum 10 h.");

    // The day's own action is available and says what it will do: this refusal
    // is about the group, not about the day.
    const setDay = page.locator("#rosters-set-day");
    await expect(setDay).toHaveText(`Set Monday to run ${SHORT_REST_RUN}`);
    await expect(setDay).toBeEnabled();

    tour.slotRefusal = {
      line: SHORT_REST_LINE,
      run: SHORT_REST_RUN,
      groupLabel: (await setGroup.textContent()).trim(),
      groupDisabled: true,
      reason,
      dayLabel: (await setDay.textContent()).trim(),
    };

    await capture(page, "slot-refusal-1440", { fullPage: false });

    // Set Monday saves the day anyway: a manual per-day edit is allowed to leave
    // the rest short where a group write refuses.
    await setDay.click();
    await closeDrawer(page, "rosters-slot-drawer");

    const monday = await slotState(page, SHORT_REST_LINE, 1);
    expect(monday.state).toBe("work");
    expect(monday.warning).toBe("short-rest");
    expect(monday.label).toContain("Sun → Mon");
    expect(monday.label).toContain("minimum 10 h.");
    await expect(page.locator(`#slot-${SHORT_REST_LINE}-1`)).toContainText(SHORT_REST_RUN);

    // The other days are untouched: one day saved, not the week.
    for (const weekday of [2, 3, 4, 5, 6]) {
      expect((await slotState(page, SHORT_REST_LINE, weekday)).state).toBe("off");
    }

    tour.slotRefusal.saved = monday;
    tour.slotRefusal.sundayHeld = (await slotState(page, SHORT_REST_LINE, 7)).label;

    await capture(page, "short-rest-1440");
  });

  test("Record pick lists operators in seniority order and saving shows the operator", async ({
    page,
  }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId, SEEDED_LINES + 1);

    // The created line is the open one this journey records a pick for.
    await page.locator(`#rosters-record-pick-${CREATED_LINE}`).click();
    await expect(page.locator("#rosters-pick-form")).toBeVisible();

    // The select is the organization's own seniority order, minus everybody who
    // already holds a line in this version.
    const options = await page.$$eval("#rosters-pick-operator option", (nodes) =>
      nodes.map((node) => node.textContent.trim())
    );
    expect(options).toEqual(PICK_OFFER);

    tour.pick = {
      line: CREATED_LINE,
      options,
      excluded: ["E9001", "E9002"],
    };

    // The pick row opens under its line, at the bottom of the grid, so the
    // capture scrolls it into view rather than showing the row half cut off.
    await page.locator("#rosters-pick-form").scrollIntoViewIfNeeded();
    await capture(page, "pick-1440", { fullPage: false });

    await page.locator("#rosters-pick-operator").selectOption({ label: PICK_OFFER[0] });
    await page.locator("#rosters-pick-save").click();

    // The write is visible, not only reported.
    await expect(page.locator(`#rosters-record-pick-${CREATED_LINE}`)).toHaveCount(0);
    await expect(page.locator("#rosters-pick-form")).toHaveCount(0);
    const operator = page.locator(`#rosters-grid-body tr:has(#rosters-line-${CREATED_LINE}-open)`);
    await expect(operator).toContainText(PICKS_OPERATOR);
    await expect(operator).toContainText("E9003");
    await expect(page.locator(`#rosters-line-${CREATED_LINE}-open`)).toHaveAttribute(
      "aria-label",
      new RegExp(`^Line ${CREATED_LINE}, Assigned\\.`),
    );
    await expect(toastText(page)).toHaveText(
      `Pick recorded: ${PICKS_OPERATOR} holds line ${CREATED_LINE}.`,
    );

    tour.pick.recorded = (await operator.innerText()).replace(/\s+/g, " ").trim();
    tour.pick.toast = (await toastText(page).textContent()).trim();

    await capture(page, "pick-saved-1440");
  });

  test("importing operators_sample.csv shows the review and adds operators", async ({ page }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId, SEEDED_LINES + 1);

    await page.locator("#rosters-operators-button").click();
    await openDrawer(page, "rosters-operators-drawer");

    // The seeded six, in the order the operators drawer's own query returns:
    // numbered by seniority, then the two without one by name.
    const seededIds = await page.$$eval("#rosters-operators-rows tr", (rows) =>
      rows.map((row) => row.querySelector("td:nth-child(2)").textContent.trim())
    );
    expect(seededIds).toEqual(SEEDED_OPERATORS);

    tour.operators = { seeded: seededIds, drawerOrder: "seniority, then unnumbered by name" };

    await capture(page, "operators-1440", { fullPage: false });

    await page.locator("#rosters-import-operators").click();
    await openDrawer(page, "rosters-operators-drawer");
    await expect(page.locator("#rosters-operator-import")).toBeVisible();

    // Nothing is importable until a file is chosen, and the primary says so.
    await expect(page.locator("#rosters-import-apply")).toBeDisabled();
    await expect(page.locator("#rosters-import-reason")).toHaveText(
      "Choose a CSV file to review.",
    );

    await page.locator("#rosters-import-file input[type=file]").setInputFiles(OPERATORS_CSV);

    // The review counts what the parser classified: two rows to add, none to
    // update, two skipped, and the column nothing stores.
    await expect(page.locator("#rosters-import-review-title")).toContainText("operators_sample.csv");
    await expect(page.locator("#rosters-import-count-add")).toHaveText("2");
    await expect(page.locator("#rosters-import-count-update")).toHaveText("0");
    await expect(page.locator("#rosters-import-count-skipped")).toHaveText("2");
    await expect(page.locator("#rosters-import-skipped")).toContainText("E4201");
    await expect(page.locator("#rosters-import-skipped")).toContainText("E4202");
    await expect(page.locator("#rosters-import-ignored")).toHaveText("phone");
    await expect(page.locator("#rosters-import-apply")).toHaveText("Import 2 operators");
    await expect(page.locator("#rosters-import-apply")).toBeEnabled();

    tour.import = {
      file: "operators_sample.csv",
      add: 2,
      update: 0,
      skipped: 2,
      skippedIds: ["E4201", "E4202"],
      ignoredColumns: "phone",
      applyLabel: (await page.locator("#rosters-import-apply").textContent()).trim(),
    };

    await capture(page, "import-review-1440", { fullPage: false });

    await page.locator("#rosters-import-apply").click();

    // The drawer is the list again, re-read from the writers, and the toast
    // reports what the file did and what it left out.
    await expect(page.locator("#rosters-operators-table")).toBeVisible();
    await expect(page.locator("#rosters-import-review")).toHaveCount(0);
    await expect(page.locator("#rosters-toast-text")).toHaveText(
      "2 operators added, 0 updated. 2 rows were skipped.",
    );

    const afterImport = await page.$$eval("#rosters-operators-rows tr", (rows) =>
      rows.map((row) => row.querySelector("td:nth-child(2)").textContent.trim())
    );
    expect(afterImport).toContain("E4101");
    expect(afterImport).toContain("E4200");
    expect(afterImport).not.toContain("E4201");
    expect(afterImport).not.toContain("E4202");
    expect(afterImport).toHaveLength(SEEDED_OPERATORS.length + 2);

    tour.import.afterImport = afterImport;
    tour.import.toast = (await page.locator("#rosters-toast-text").textContent()).trim();
  });

  test("deleting an operator through the confirmation leaves their line Open", async ({ page }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId, SEEDED_LINES + 1);

    await page.locator("#rosters-operators-button").click();
    await openDrawer(page, "rosters-operators-drawer");

    // The operator this journey recorded the pick for, found by the employee ID
    // the row prints rather than by an internal id.
    const row = page.locator("#rosters-operators-rows tr").filter({ hasText: "E9003" });
    await expect(row).toHaveCount(1);
    await row.locator('button[id^="rosters-edit-operator"]').click();

    await expect(page.locator("#rosters-operator-form")).toBeVisible();
    await expect(page.locator("#rosters-operator-holds-line")).toContainText(
      `holds line ${CREATED_LINE}.`,
    );

    await page.locator("#rosters-delete-operator").click();

    // The confirmation asks, names the operator, and keeps the way out.
    await expect(page.locator("#rosters-delete-operator-confirm[data-open='true']")).toBeVisible();
    await expect(page.locator("#rosters-delete-operator-confirm-title")).toHaveText(
      `Delete ${PICKS_OPERATOR}?`,
    );
    await expect(page.locator("#rosters-delete-operator-confirm-cancel")).toHaveText(
      "Keep operator",
    );

    tour.deleteOperator = {
      operator: PICKS_OPERATOR,
      holdsLine: (await page.locator("#rosters-operator-holds-line").textContent()).trim(),
      body: (await page.locator("#rosters-delete-operator-body").textContent()).trim(),
    };

    await capture(page, "delete-operator-1440", { fullPage: false });

    await page.locator("#rosters-delete-operator-confirm-confirm").click();

    // The operator is gone and the line they held is Open again — the delete
    // re-read the roster rather than only reporting it.
    await expect(page.locator("#rosters-toast-text")).toHaveText(`${PICKS_OPERATOR} deleted.`);
    await expect(page.locator("#rosters-operators-rows")).not.toContainText("E9003");
    await expect(page.locator(`#rosters-line-${CREATED_LINE}-open`)).toHaveAttribute(
      "aria-label",
      new RegExp(`^Line ${CREATED_LINE}, Open\\.`),
    );
    await expect(page.locator(`#rosters-record-pick-${CREATED_LINE}`)).toHaveText("Record pick");

    await page.locator("#rosters-operators-drawer-close").click();
    await closeDrawer(page, "rosters-operators-drawer");

    tour.deleteOperator.toast = (await page.locator("#rosters-toast-text").textContent()).trim();
    tour.deleteOperator.lineAfter = await page
      .locator(`#rosters-grid-body tr:has(#rosters-line-${CREATED_LINE}-open)`)
      .innerText()
      .then((text) => text.replace(/\s+/g, " ").trim());

    await capture(page, "line-open-1440");
  });

  test("settings with 479 shows the range error and saves nothing", async ({ page }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId, SEEDED_LINES + 1);

    await page.locator("#rosters-settings-button").click();
    await openDrawer(page, "rosters-settings-drawer");

    // The seed's own rest rule, 600 minutes, is under the field's 480 ceiling by
    // 121 rather than by one, so 479 cannot be a rounding of a legal value.
    await expect(page.locator("#rosters-settings-rest")).toHaveValue("600");

    await page.fill("#rosters-settings-rest", "479");
    // The form is `novalidate` and validates on blur, so the error comes from
    // the server's own range rather than from the browser's number input.
    await page.locator("#rosters-settings-rest").blur();

    await expect(page.locator("#rosters-settings-rest-error")).toHaveText(
      "must be a whole number between 480 and 720",
    );
    await expect(page.locator("#rosters-settings-rest")).toHaveAttribute("aria-invalid", "true");

    // Only the field the reader touched is marked.
    await expect(page.locator("#rosters-settings-warn")).toHaveAttribute("aria-invalid", "false");

    // And saving is refused: the value does not reach the roster.
    await page.locator("#rosters-settings-save").click();
    await expect(page.locator("#rosters-settings-rest-error")).toBeVisible();
    await expect(page.locator("#rosters-settings-rest")).toHaveValue("479");

    tour.settings = {
      field: "min_rest_minutes",
      seeded: 600,
      entered: 479,
      message: (await page.locator("#rosters-settings-rest-error").textContent()).trim(),
      saved: false,
    };

    await capture(page, "settings-error-1440", { fullPage: false });

    // Closing without saving leaves the version's rules as the seed wrote them.
    await page.locator("#rosters-settings-cancel").click();
    await closeDrawer(page, "rosters-settings-drawer");
    await page.locator("#rosters-settings-button").click();
    await expect(page.locator("#rosters-settings-rest")).toHaveValue("600");
    await page.locator("#rosters-settings-cancel").click();
    await closeDrawer(page, "rosters-settings-drawer");
  });

  test("the export section names what the file carries, and the page fits 1280", async ({ page }) => {
    await logInAs(page, EDITOR);
    const versionId = await versionIdFor(page);
    await openRosters(page, versionId, SEEDED_LINES + 1);

    await expect(page.locator("#rosters-export")).toBeVisible();

    // The planned-data note is always on screen: what the file is, then what
    // it does not know.
    const note = (await page.locator("#rosters-export-note").innerText()).replace(/\s+/g, " ");
    expect(note).toContain("Planned from the pick.");
    expect(note).toContain("Vacations, sick days and extraboard are not included.");

    // Labor Day 2026-09-07 is the seed's date that runs different service, so
    // the other-service warning is here rather than only possible.
    const warnings = (
      await page.locator("#rosters-export-warnings").innerText()
    ).replace(/\s+/g, " ");
    expect(warnings).toContain("date runs different service");
    expect(warnings).toContain("Sep 7, 2026");
    // The open lines and the stale slot are named too, because the file leaves
    // them out: this journey has deleted the operator who held the line it
    // created, so four of the six lines have nobody.
    expect(warnings).toContain("4 lines have no operator.");
    expect(warnings).toContain("1 stale slot was skipped.");
    const warningCount = await page.locator("#rosters-export-warnings li").count();
    expect(warningCount).toBeGreaterThanOrEqual(2);

    // The preview is a disclosure, so the rows are behind a control rather than
    // on the page.
    await expect(page.locator("#rosters-export-preview")).not.toHaveAttribute("open", "");
    await page.locator("#rosters-export-preview summary").click();
    await expect(page.locator("#rosters-export-preview tbody tr").first()).toBeVisible();

    tour.export = {
      note,
      warnings,
      warningCount,
      previewRows: await page.locator("#rosters-export-preview tbody tr").count(),
    };

    await capture(page, "export-1440");

    // The default view at 1280: the narrowest width the page is asked to hold,
    // which is where the grid's own scroll must stay inside its container.
    await page.setViewportSize(NARROW);
    expect(await bodyFitsViewport(page)).toBe(true);
    const measured = await page.evaluate(() => ({
      bodyScrollWidth: document.body.scrollWidth,
      innerWidth: window.innerWidth,
      documentScrollWidth: document.documentElement.scrollWidth,
    }));

    tour.viewport = { ...measured, fits: true, size: NARROW };

    await capture(page, "default-1280");
  });
});

test.describe("reference prototype captures", () => {
  test.skip(() => !existsSync(REFERENCE_PROTOTYPE), "reference prototype not present");
  test.use({ viewport: DESKTOP });

  test("the rosters states beside production", async ({ page }) => {
    test.setTimeout(120_000);

    const referenceUrl = pathToFileURL(REFERENCE_PROTOTYPE).href;

    for (const [name, query] of REFERENCE_SCENARIOS) {
      await page.goto(`${referenceUrl}?${query}`);
      await page.waitForLoadState("load");
      await expect(page.locator("body")).toBeVisible();

      // Recorded for the side-by-side comparison only: the prototype's own
      // markup and pixels are not what this journey asserts.
      tour[`reference_${name.replaceAll("-", "_")}`] = {
        state: query,
        bodyWidth: await page.evaluate(() => document.body.scrollWidth),
        viewportWidth: DESKTOP.width,
      };

      await capture(page, `reference-${name}-1440`);
    }
  });
});

// The tour is the capture artifact's own index: entrypoint, setup, scenarios,
// expected outcomes, the automated coverage of each and the numbers the
// journeys measured. It is written last so it reports the whole run, and it is
// skipped rather than failed when the gitignored `.specs/` workspace is not
// linked.
test.describe("qa tour", () => {
  test.skip(() => !existsSync(SPEC_PACKAGE), "spec package not present");
  test.use({ viewport: DESKTOP });

  test("writes qa-tour.md from the measured journey", async () => {
    test.skip(
      !process.env.ROUTE16_CAPTURE_DIR,
      "no capture directory, so no tour to write"
    );

    const value = (key) =>
      tour[key] === undefined ? "(not measured)" : JSON.stringify(tour[key], null, 2);

    const markdown = [
      "# Rosters browser QA tour",
      "",
      "Entrypoint: `/gtfs/<version>/rosters` for the published **Browser Rosters",
      "Version** seeded by `test/support/browser_seed.exs`, reached here through",
      "Operations › Rosters in the sub-nav of another Operations section.",
      "",
      "## Preconditions",
      "",
      "1. Run `bin/test-browser e2e/rosters.spec.js` from the repository root.",
      "2. Let the wrapper create, migrate and seed its own disposable `pg_tmp`",
      "   database and start a Phoenix server on a free port.",
      "3. Log in as the seeded editor `diagram-test@gtfs-planner.test`; this spec",
      "   reads that credential out of the seed rather than carrying a copy.",
      "",
      "Chromium at 1440x1000 (the default view repeated at 1280x900), one worker,",
      "no retries, one freshly seeded database shared by the journeys in order.",
      "",
      "## Scenarios",
      "",
      "| # | Steps | Expected observation | Automated gate |",
      "| --- | --- | --- | --- |",
      "| 1 | Sign in, open any Operations section, choose **Rosters** | Five seeded lines in number order; line 2's Monday carries the short-rest marker and line 5's Friday reads `Stale run`; the stale message offers the filter that finds it | EV-26 `rosters_grid_live_test.exs` · EV-25 `rosters_summary_live_test.exs` · EV-27 `rosters_filter_live_test.exs` |",
      "| 2 | On run 1005 in Open work, choose **Create Mon–Fri line** | Line 6 is created, highlighted (`data-new=\"true\"`), works run 1005 on the five weekdays, is off at the weekend, and run 1005 leaves Open work | EV-30 `rosters_open_work_live_test.exs` |",
      "| 3 | Open line 2's Monday, read the refused **Set Mon–Fri**, then **Set Monday** | The group action is disabled with the sentence naming the rest it would leave and `minimum 10 h.`; the day's own action saves and the cell keeps its short-rest warning | EV-29 `rosters_slot_live_test.exs` |",
      "| 4 | Choose **Record pick** on line 6 and save an operator | The select lists the seniority order minus the two operators already holding a line; the saved row shows the operator's name and employee ID | EV-33 `rosters_pick_live_test.exs` |",
      "| 5 | In **Operators**, import `test/fixtures/tods/operators_sample.csv` | The review shows Add 2 · Update 0 · Skipped 2, the two skipped IDs with their reasons, `phone` as unused, and the toast reports both halves | EV-36 `rosters_operator_import_live_test.exs` · EV-20, EV-21 |",
      "| 6 | Edit the operator who holds line 6 and delete them | The confirmation asks first, names the line, and after it the line reads Open with `Record pick` again | EV-34 `rosters_operators_live_test.exs` · EV-35 `rosters_operator_delete_live_test.exs` |",
      "| 7 | Open **Roster settings** and type 479 into minimum rest | The field's own range error appears on blur, only that field is `aria-invalid`, and saving is refused; closing leaves 600 | EV-37 `rosters_settings_live_test.exs` |",
      "| 8 | Read the export section, then narrow the window to 1280x900 | The planned-data note and the other-service warning naming Labor Day are on screen; the page has no horizontal overflow at 1280 | EV-38 `rosters_export_live_test.exs` · EV-22 |",
      "",
      "## Captures",
      "",
      "`default-1440`, `create-line-1440`, `slot-refusal-1440`, `short-rest-1440`,",
      "`pick-1440`, `pick-saved-1440`, `operators-1440`, `import-review-1440`,",
      "`delete-operator-1440`, `line-open-1440`, `settings-error-1440`,",
      "`export-1440` and `default-1280` are this run's production captures;",
      "`reference-<state>-1440` are the same states from the prototype.",
      "",
      "## Comparison with the prototype",
      "",
      "The prototype's numbers are its own: thirteen lines, thirty runs and its",
      "own operators. The journey asserts the seeded data above and compares the",
      "captures for layout and copy only. Ignored on both sides: the dark",
      "\"Design prototype\" bar, its design notes, its state switcher, its sample",
      "organization and version names, and the JavaScript simulation.",
      "",
      "| Production | Prototype state | Compared for |",
      "| --- | --- | --- |",
      "| `default-1440` | `?state=default` | scope card, count strip, messages, grid columns and the tinted new row |",
      "| `create-line-1440` | `?state=created` | the highlighted new line and the toast's shape of words |",
      "| `slot-refusal-1440` | `?state=slot-refusal` | the disabled group action, its reason under the footer and the day's primary beside it |",
      "| `pick-1440` | `?state=pick` | the pick row's select width, its two buttons and the label above them |",
      "| `operators-1440` | `?state=operators` | the four-column table, its seniority column and the two footer actions |",
      "| `import-review-1440` | `?state=import` | the review's counts, its skipped list and the unused-columns line |",
      "| `delete-operator-1440` | `?state=delete-operator` | the confirmation's body sentence and its two buttons |",
      "| `settings-error-1440` | `?state=settings-error` | the error's placement under its own field |",
      "| `export-1440` | `?state=export` | the note's two halves, the warning block's left rule and the preview disclosure |",
      "",
      "## Automated coverage of the same behaviour",
      "",
      "Each journey's behaviour is also covered headlessly by the ExUnit",
      "LiveView tests, which read the stored rows back through the `Gtfs` facade;",
      "this journey is the visual, measured and real-browser counterpart.",
      "",
      "## Measured on this run",
      "",
      "### 1 · The seeded lines",
      "",
      "```json",
      value("opened"),
      "```",
      "",
      "### 2 · Create Mon–Fri line",
      "",
      "```json",
      value("created"),
      "```",
      "",
      "### 3 · The refused group and the saved day",
      "",
      "```json",
      value("slotRefusal"),
      "```",
      "",
      "### 4 · Record pick",
      "",
      "```json",
      value("pick"),
      "```",
      "",
      "### 5 · The operator list and the import review",
      "",
      "```json",
      value("operators"),
      "```",
      "",
      "```json",
      value("import"),
      "```",
      "",
      "### 6 · Deleting an operator",
      "",
      "```json",
      value("deleteOperator"),
      "```",
      "",
      "### 7 · The settings range error",
      "",
      "```json",
      value("settings"),
      "```",
      "",
      "### 8 · The export section",
      "",
      "```json",
      value("export"),
      "```",
      "",
      "### Viewport fit at 1280x900",
      "",
      "```json",
      value("viewport"),
      "```",
      "",
      "### Reference states",
      "",
      "```json",
      value("reference_default"),
      "```",
      "",
      "A \"Measured on this run\" block reads `(not measured)` when its journey",
      "did not run.",
      "",
      "## Product discovery, not verification",
      "",
      "A planner who reads the grid at 1280 px with 60 lines open sees a dense",
      "week; ask whether the line number column should stay pinned and whether",
      "the paid column needs a second line at that width. Nothing in this tour",
      "depends on the answer.",
      "",
    ].join("\n");

    const target = resolve(EVIDENCE_DIR, "qa-tour.md");
    mkdirSync(EVIDENCE_DIR, { recursive: true });
    writeFileSync(target, markdown);

    expect(existsSync(target)).toBe(true);
    expect(readFileSync(target, "utf8")).toContain("## Scenarios");
  });
});