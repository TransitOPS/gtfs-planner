/**
 * Dated change planning journey (spec 11, step 10; EV-10 claims CL-10 and
 * rejects FH-10).
 *
 * Real Chromium → Phoenix (`BROWSER_E2E=true`) → RouteSchedulesLive over the
 * throwaway pg_tmp database `bin/test-browser` seeds from
 * `test/support/browser_seed.exs`. Two dedicated backdated versions in that
 * seed carry this journey, so no other spec's counts move and neither becomes
 * the organization's default published version:
 *
 *   * "Browser Dated Change Version" — BROWSER_DATED_CHANGE, the complete and
 *     stale states. Its DC_WEEKDAY calendar runs Monday–Friday over 2026 with
 *     2026-11-11 removed as a calendar_date exception, so the accepted window
 *     2026-11-02..2026-11-13 holds ten weekdays, the removed Wednesday leaves
 *     exactly nine, and the removal has to survive the plan rather than be
 *     moved. DC_T_0700 and DC_T_2510 are the selection (the second starts at
 *     25:10, so a +300s shift projects 25:15 on the same service day), and
 *     DC_T_0800 is the unselected trip sharing that calendar. A second
 *     calendar, DC_WEEKEND, with one trip, makes the route genuinely
 *     multi-calendar for the calendar filter and the Calendars page.
 *   * "Browser Dated Change Wide Version" — BROWSER_DATED_CHANGE_WIDE, the
 *     incomplete state. DC_WIDE declares a 200,001-day range, one cell over
 *     the planner's date-work cap, so the plan is refused whole without
 *     enumerating anything.
 *
 * Every expected total below is read off the fixture above, never off the
 * planner's own output: 260 original dates on DC_WEEKDAY (261 weekdays in 2026
 * minus the removed one), nine of them in the window and 251 kept, so the
 * selection reports 2 selected trips, 2×9 = 18 changed trip-dates, 2×251 = 502
 * unchanged trip-dates and exactly 1 unaffected calendar user.
 *
 * The journey reads what this host can actually render. The plan card is
 * scoped to the accepted selection, which the Schedule page keeps inside one
 * resolved calendar, so `#dated-change-service-single` is what renders and the
 * report's multi-calendar switch does not appear. The exact 25:15 projection
 * is a dependency-read value the card does not print, so the journey proves it
 * through what the card does show: the after-midnight trip is in the selection,
 * no clock is left unresolved, the stored departure is still 25:10, and the
 * re-checked digest is unchanged.
 *
 * `bin/test-browser` runs this file in branch review; the captures land in the
 * package's `evidence/browser/` folder, resolved from SCHEDULE_SPEC_ROOT when
 * the runner points at the checkout that holds `.specs/`.
 */
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport, logInAs } from "./browser_helpers";

// The Playwright runner starts in `assets/`, so repository-relative inputs are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
// A worktree checkout carries no gitignored `.specs/`; SCHEDULE_SPEC_ROOT
// points the capture writes at the checkout that holds the package.
const SPEC_ROOT =
  process.env.SCHEDULE_SPEC_ROOT ||
  resolve(REPO_ROOT, ".specs", "ai-11-dated-change-planning");
const EVIDENCE_DIR = resolve(SPEC_ROOT, "evidence", "browser");

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Dated Change Version";
const WIDE_VERSION_NAME = "Browser Dated Change Wide Version";
const ROUTE = "BROWSER_DATED_CHANGE";
const WIDE_ROUTE = "BROWSER_DATED_CHANGE_WIDE";

// The weekday selection, and the unselected trip sharing its calendar.
const TRIP_IDS = ["DC_T_0700", "DC_T_2510"];
const SHARED_TRIP_ID = "DC_T_0800";
const WIDE_TRIP_ID = "DW_T_1000";

// The nine in-window dates the fixture leaves after 2026-11-11 is removed, and
// the removed date itself, which must appear in no list at all.
const WINDOW_DATES = [
  "2026-11-02",
  "2026-11-03",
  "2026-11-04",
  "2026-11-05",
  "2026-11-06",
  "2026-11-09",
  "2026-11-10",
  "2026-11-12",
  "2026-11-13",
];
const REMOVED_DATE = "2026-11-11";

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "320x800", width: 320, height: 800 },
];

const INTEND = {
  firstDate: "2026-11-02",
  lastDate: "2026-11-13",
  deltaSeconds: "300",
  approvalNote:
    "Board approved the temporary Saturday service for this window.",
  sourceLabel: "Board memo 2026-14",
};

// The fixture's own numbers, restated here so the assertions below compare the
// rendered report against the seed rather than against itself.
const EXPECTED = {
  selectedTrips: 2,
  changedTripDates: 18,
  unchangedTripDates: 502,
  unaffectedCalendarUsers: 1,
  originalDates: 260,
  normalDates: 251,
  inWindowDates: 9,
};

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function schedulesPath(versionId, routeId) {
  return `/gtfs/${versionId}/routes/${routeId}/schedules`;
}

async function openSchedules(page, path, { timeout } = {}) {
  await page.goto(path);
  await expect(page.locator("#dated-change-form")).toBeVisible({ timeout });
}

async function selectTrips(page, tripIds) {
  for (const tripId of tripIds) {
    await page.locator(`#trip-select-${tripId}`).click();
  }
}

async function fillIntent(page, intent) {
  await page.fill("#dated-change-first-date", intent.firstDate);
  await page.fill("#dated-change-last-date", intent.lastDate);
  await page.fill("#dated-change-delta-seconds", intent.deltaSeconds);
  await page.fill("#dated-change-approval-note", intent.approvalNote);
  await page.fill("#dated-change-source-label", intent.sourceLabel);
}

// The button reviews the inputs; it never saves them.
async function submitIntent(page) {
  await page.locator("#dated-change-accept").click();
  await expect(page.locator("#dated-change-accepted")).toBeVisible();
}

// The helper panel is sticky under the page head, and its composer can sit
// below the fold on a page as long as a complete plan makes it. The send
// control is a submit button inside the composer's own form, so the journey
// submits that form rather than reaching for a button the viewport has already
// scrolled away: the request the panel answers is identical either way.
async function askHelper(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page
    .locator("#agent-composer")
    .evaluate((form) => form.requestSubmit());
}

async function analyze(page) {
  await page.locator("#dated-change-analyze").click();
  await expect(page.locator("#dated-change-analyze")).toBeEnabled();
}

// The plan card is always rendered, so a state is an element rather than a
// missing one; the dates are a stream, so a page is read from its own ids.
async function expectDateRows(page, dates) {
  await expect(page.locator("#dated-change-dates")).toBeVisible();

  for (const date of dates) {
    await expect(page.locator(`#dated-change-date-${date}`)).toBeVisible();
  }

  await expect(
    page.locator("#dated-change-dates > div[id^='dated-change-date-']"),
  ).toHaveCount(dates.length);
}

// Captures stay viewport-sized: the form and the plan sit under the sticky grid
// bar, so a full-page shot would move that bar out of its fixed position. The
// plan is scrolled into view first so the card, not the timetable, is the
// subject of every report capture, and the acknowledgement toast a native save
// raises is dismissed first because it is fixed over the top of the card at
// 320x800 and would hide the state it follows.
async function capture(page, name, { selector } = {}) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });

  const dismiss = page.locator(
    '#flash-info button[aria-label="Dismiss message"]',
  );
  if (await dismiss.count()) {
    await dismiss.click();
    await expect(page.locator("#flash-info")).toHaveCount(0);
  }

  if (selector) {
    // Pinned rather than merely scrolled into view: at 320x800 the plan card
    // is taller than the viewport, and the minimum scroll Playwright would
    // choose leaves the state banner above the fold.
    await page.evaluate((target) => {
      const el = document.querySelector(target);
      const top = window.scrollY + el.getBoundingClientRect().top;
      window.scrollTo({ top: Math.max(top - 16, 0) });
    }, selector);
  }

  await page.screenshot({
    path: resolve(EVIDENCE_DIR, `${name}.png`),
    fullPage: false,
    animations: "disabled",
  });
}

for (const viewport of VIEWPORTS) {
  test.describe(`Dated change planning ${viewport.label}`, () => {
    test.use({ viewport: { width: viewport.width, height: viewport.height } });

    // The complete state: the accepted window is analyzed and the report says
    // exactly which dates it covers, which trips it would change, and which
    // other trips share the calendar without being in the selection.
    test("reports the accepted window's dates and changes nothing", async ({
      page,
    }) => {
      test.setTimeout(180_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page, VERSION_NAME);

      await openSchedules(page, schedulesPath(versionId, ROUTE));
      await selectTrips(page, TRIP_IDS);
      await expect(page.locator("#dated-change-selected-count")).toHaveText(
        String(EXPECTED.selectedTrips),
      );

      await fillIntent(page, INTEND);
      await submitIntent(page);

      // The acceptance names what was reviewed, in the editor's own terms.
      await expect(
        page.locator("#dated-change-accepted-summary"),
      ).toContainText("2026-11-02 to 2026-11-13");
      await expect(
        page.locator("#dated-change-accepted-summary"),
      ).toContainText("300 seconds");

      await analyze(page);
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );

      // The exact totals, each read from its own labelled element rather than
      // from a blob of text.
      await expect(
        page.locator("#dated-change-total-selected-trips dd"),
      ).toHaveText(String(EXPECTED.selectedTrips));
      await expect(
        page.locator("#dated-change-total-changed-trip-dates dd"),
      ).toHaveText(String(EXPECTED.changedTripDates));
      await expect(
        page.locator("#dated-change-total-unchanged-trip-dates dd"),
      ).toHaveText(String(EXPECTED.unchangedTripDates));
      await expect(
        page.locator("#dated-change-total-other-trips-on-these-calendars dd"),
      ).toHaveText(String(EXPECTED.unaffectedCalendarUsers));

      // One calendar in the selection, so the report names it with its exact
      // in-window count instead of offering a switch it cannot page.
      await expect(page.locator("#dated-change-service-single")).toHaveText(
        "Calendar DC_WEEKDAY · 9 in window",
      );
      await expect(page.locator("#dated-change-service")).toHaveCount(0);

      // The nine dates the window really holds, and not the removed one.
      await expectDateRows(page, WINDOW_DATES);
      await expect(
        page.locator(`#dated-change-date-${REMOVED_DATE}`),
      ).toHaveCount(0);
      await expect(page.locator("#dated-change-page-summary")).toContainText(
        `Showing 9 of ${EXPECTED.inWindowDates} dates on page 1 of 1.`,
      );

      // The after-midnight trip is in the selection and every clock in it
      // projects, so the plan is a complete exact-time plan and carries no
      // unresolved-clock warning.
      await expect(page.locator("#dated-change-timing-warning")).toHaveCount(0);

      // Paging the other two sets of the same partition moves 251 kept and 260
      // original dates through the same card.
      await page
        .locator('label[for="dated-change-kind-option-normal"]')
        .click();
      await expect(page.locator("#dated-change-page-summary")).toContainText(
        `Showing 50 of ${EXPECTED.normalDates} dates on page 1 of 6.`,
      );
      await expect(
        page.locator(`#dated-change-date-${REMOVED_DATE}`),
      ).toHaveCount(0);
      await expect(page.locator("#dated-change-page-next")).toBeVisible();

      await page
        .locator('label[for="dated-change-kind-option-original"]')
        .click();
      await expect(page.locator("#dated-change-page-summary")).toContainText(
        `Showing 50 of ${EXPECTED.originalDates} dates on page 1 of 6.`,
      );
      await expect(
        page.locator(`#dated-change-date-${REMOVED_DATE}`),
      ).toHaveCount(0);

      await page
        .locator('label[for="dated-change-kind-option-temporary"]')
        .click();
      await expectDateRows(page, WINDOW_DATES);

      // INV-1: the plan is a report. It says so, it names what a later
      // execution would still need, and it offers no apply control anywhere.
      await expect(page.locator("#dated-change-plan-scope")).toContainText(
        "Planning only — no changes saved. This page cannot apply what it reports.",
      );
      await expect(page.locator("#dated-change-stages")).toContainText(
        "What a later execution would still need",
      );
      await expect(page.locator("#dated-change-digest")).toContainText(
        "Dependencies checked:",
      );
      await expect(
        page.getByRole("button", { name: /apply|save changes|commit/i }),
      ).toHaveCount(0);

      // The stored timetable is untouched: the after-midnight trip still
      // departs at 25:10 and nothing moved to the next service day.
      await expect(page.locator(`#trip-${TRIP_IDS[1]}-start`)).toHaveText(
        "25:10",
      );

      // The native path to the calendar the plan was read from.
      await expect(page.locator("#dated-change-calendar-link")).toContainText(
        "Open the DC_WEEKDAY calendar",
      );

      await capture(page, `step-010-complete-${viewport.label}`, {
        selector: "#dated-change-plan",
      });

      // A fresh re-check of an unchanged timetable keeps the plan current,
      // which is the honest claim the freshness line makes.
      await page.locator("#dated-change-refresh").click();
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );
      await expect(page.locator("#dated-change-state-freshness")).toHaveText(
        "Checked against a full dependency read just now.",
      );
    });

    // The native workflow the plan is a report about still works while the
    // plan is on screen: selecting another trip, switching the helper pack,
    // asking the helper a question the provider refuses, and navigating to the
    // calendar are all ordinary page actions.
    test("leaves the native timetable and the helper working around the plan", async ({
      page,
    }) => {
      test.setTimeout(180_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page, VERSION_NAME);

      await openSchedules(page, schedulesPath(versionId, ROUTE));
      await selectTrips(page, TRIP_IDS);
      await fillIntent(page, INTEND);
      await submitIntent(page);
      await analyze(page);
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );

      // A helper request is not a native change, so the plan keeps its report
      // and stops claiming it was checked a moment ago. The request itself is
      // refused by the provider, which is what the panel renders.
      await page.locator("#agent-helper-open").click();
      await expect(page.locator("#agent-panel")).toBeVisible();
      await askHelper(page, "Is the provider reachable?");
      await expect(page.locator("#agent-entries")).toContainText(
        "The helper is unavailable right now.",
        { timeout: 30_000 },
      );
      await expect(page.locator("#agent-retry-2")).toBeVisible();
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );
      await expect(page.locator("#dated-change-state-freshness")).toHaveText(
        "Not re-checked since this was prepared, so edits made elsewhere are not detected yet.",
      );
      await expect(page.locator("#dated-change-totals")).toBeVisible();
      expect(await bodyFitsViewport(page)).toBe(true);

      // Switching to the dated-change helper drops the acceptance with the
      // conversation it belonged to, and keeps the typed draft.
      await page
        .locator('label[for="schedule-helper-mode-option-dated_changes"]')
        .click();
      await expect(page.locator("#dated-change-accepted")).toHaveCount(0);
      await expect(page.locator("#dated-change-plan")).toContainText(
        "No plan yet.",
      );
      await expect(page.locator("#dated-change-first-date")).toHaveValue(
        INTEND.firstDate,
      );
      await page
        .locator('label[for="schedule-helper-mode-option-service_queries"]')
        .click();

      // The unselected trip sharing the calendar is still selectable, so the
      // plan's "other trips on these calendars" count describes a real row.
      await page.locator(`#trip-select-${SHARED_TRIP_ID}`).click();
      await expect(page.locator("#dated-change-selected-count")).toHaveText(
        "3",
      );

      // Owned native navigation: the plan's own calendar link resolves to this
      // version's calendar editor, and the trip row is still there afterwards.
      // The pack switch above dropped the accepted source and the plan, not the
      // timetable's own selection, so the three selected trips are still the
      // selection this analysis reads; re-clicking their checkboxes would
      // deselect them.
      await fillIntent(page, INTEND);
      await submitIntent(page);
      await analyze(page);

      const calendarPath = await page
        .locator("#dated-change-calendar-link a")
        .getAttribute("href");
      expect(calendarPath).toBe(
        `/gtfs/${versionId}/calendars/show?service_id=DC_WEEKDAY`,
      );
      await page.locator("#dated-change-calendar-link a").click();
      await expect(page.locator("#calendar-title")).toContainText("DC_WEEKDAY");

      await page.goto(schedulesPath(versionId, ROUTE));
      await expect(page.locator("#dated-change-form")).toBeVisible();
      await expect(page.locator("#dated-change-plan")).toContainText(
        "No plan yet.",
      );
      await expect(page.locator(`#trip-${SHARED_TRIP_ID}-start`)).toHaveText(
        "08:00",
      );
    });

    // The incomplete states: refused inputs keep the typed draft and move
    // focus to the first field that has to change, and a calendar whose date
    // work is over the planner's cap is refused whole rather than answered
    // from part of it.
    test("refuses unreadable inputs and an over-cap calendar without discarding anything", async ({
      page,
    }) => {
      test.setTimeout(180_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page, VERSION_NAME);

      await openSchedules(page, schedulesPath(versionId, ROUTE));
      await selectTrips(page, TRIP_IDS);
      await fillIntent(page, INTEND);
      // A first date the form cannot read at all, and an approval note that was
      // never supplied. Both are ordinary mistakes rather than forged events.
      await page.fill("#dated-change-first-date", "");
      await page.fill("#dated-change-approval-note", "   ");
      await page.locator("#dated-change-accept").click();

      const errors = page.locator("#dated-change-input-errors");
      await expect(errors).toBeVisible();
      await expect(errors).toContainText("four-digit year");
      await expect(errors).toContainText("approval note");
      // The refusal keeps what was typed and puts focus on the first field
      // that has to change.
      await expect(page.locator("#dated-change-last-date")).toHaveValue(
        INTEND.lastDate,
      );
      await expect(page.locator("#dated-change-source-label")).toHaveValue(
        INTEND.sourceLabel,
      );
      await expect(page.locator("#dated-change-first-date")).toBeFocused();

      await capture(page, `step-010-incomplete-form-${viewport.label}`, {
        selector: "#dated-change-planner",
      });

      // The same refusal names no report, so nothing on screen reads as one.
      await expect(page.locator("#dated-change-plan")).toContainText(
        "No plan yet.",
      );
      await expect(page.locator("#dated-change-totals")).toHaveCount(0);
      expect(await bodyFitsViewport(page)).toBe(true);

      // A correctable draft still analyzes, so the refusal is about the
      // inputs rather than about the page.
      await fillIntent(page, INTEND);
      await submitIntent(page);
      await analyze(page);
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );
      expect(await bodyFitsViewport(page)).toBe(true);

      // The over-cap calendar: the plan is refused with the exact cell count
      // the fixture declares, and it names no dates at all. Its own page takes
      // far longer to read than an ordinary one, because the calendar it names
      // declares two centuries of Saturdays.
      const wideVersionId = await versionIdFor(page, WIDE_VERSION_NAME);
      await openSchedules(page, schedulesPath(wideVersionId, WIDE_ROUTE), {
        timeout: 90_000,
      });
      await selectTrips(page, [WIDE_TRIP_ID]);
      await fillIntent(page, INTEND);
      await submitIntent(page);
      await analyze(page);

      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "The plan is incomplete, so nothing below is a complete answer.",
      );
      await expect(page.locator("#dated-change-state-message")).toContainText(
        "200001",
      );
      await expect(page.locator("#dated-change-state-message")).toContainText(
        "200000",
      );
      await expect(page.locator("#dated-change-totals")).toHaveCount(0);
      await expect(page.locator("#dated-change-dates")).toHaveCount(0);
      await expect(page.locator("#dated-change-state-freshness")).toContainText(
        "Nothing was computed",
      );
      await expect(
        page.getByRole("button", { name: /apply|save changes|commit/i }),
      ).toHaveCount(0);

      await capture(page, `step-010-incomplete-plan-${viewport.label}`, {
        selector: "#dated-change-plan",
      });
    });

    // The stale states: a native save on this timetable relabels the retained
    // plan rather than deleting it, and a full dependency read says plainly
    // that it no longer matches.
    test("keeps a stale report on screen and says why it is not current", async ({
      page,
    }) => {
      test.setTimeout(180_000);

      await logInAs(page, EDITOR_USER);
      const versionId = await versionIdFor(page, VERSION_NAME);

      await openSchedules(page, schedulesPath(versionId, ROUTE));
      await selectTrips(page, TRIP_IDS);
      await fillIntent(page, INTEND);
      await submitIntent(page);
      await analyze(page);
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );
      const digest = await page.locator("#dated-change-digest").innerText();

      // A real native save through the page's own drawer control: a headsign
      // edit on the selected trip, which writes a row the plan read. The
      // saved value differs from the trip's own default, so the row now claims
      // a headsign of its own and the grid prints it.
      await page.locator(`#trip-${TRIP_IDS[0]}-edit`).click();
      await page.fill("#trip-headsign", "Dated change outbound (QA)");
      await page.locator("#trip-drawer-save").click();
      await expect(page.locator("#trip-headsign").first()).toHaveCount(0);
      await expect(page.locator(`#trip-${TRIP_IDS[0]}-headsign`)).toHaveText(
        "To Dated change outbound (QA)",
      );

      // The plan is kept and relabelled rather than deleted, because a person
      // is still reading it, and it no longer claims currency.
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "This plan is no longer current.",
      );
      await expect(page.locator("#dated-change-state-message")).toContainText(
        "A native change to this timetable was saved after this plan was prepared.",
      );
      await expect(page.locator("#dated-change-state-freshness")).toContainText(
        "Not re-checked since this was prepared",
      );

      // The dates it was prepared from are still on screen, still saying what
      // they are, rather than silently describing a version they no longer
      // match.
      await expectDateRows(page, WINDOW_DATES);

      await capture(page, `step-010-stale-${viewport.label}`, {
        selector: "#dated-change-plan",
      });

      // A full dependency read compares the content digest rather than counts,
      // so the relabelled plan says which it is: the same report, no longer
      // current, with the digest it was read at still on screen.
      await page.locator("#dated-change-refresh").click();
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "This plan is no longer current.",
      );
      await expect(page.locator("#dated-change-state-message")).toContainText(
        "The timetable changed since this plan was prepared.",
      );
      await expect(page.locator("#dated-change-state-freshness")).toHaveText(
        "Checked against a full dependency read just now.",
      );
      await expect(page.locator("#dated-change-digest")).toHaveText(digest);
      await expectDateRows(page, WINDOW_DATES);

      // Restoring the headsign through the same native control makes the
      // timetable match the report again, which a re-check can only say after
      // reading it, and the fixture is left as this file found it.
      await page.locator(`#trip-${TRIP_IDS[0]}-edit`).click();
      await page.fill("#trip-headsign", "Dated change outbound");
      await page.locator("#trip-drawer-save").click();

      // The restored value is this trip's own default, so the row stops
      // claiming a headsign of its own and the grid line goes away entirely
      // (Headsigns rule 2: a trip that follows its effective default shows
      // nothing). Asserting the *absence* of the line is what distinguishes
      // "the save landed" from "the row still reads (QA)": a stale row would
      // still carry the `#trip-...-headsign` cell with its old text, and a
      // substring match on that stale text would pass while proving nothing.
      await expect(page.locator(`#trip-${TRIP_IDS[0]}-headsign`)).toHaveCount(
        0,
      );

      // The drawer closes on a successful save, so the grid is on screen again
      // before the re-check below reads the restored timetable.
      await expect(page.locator("#trip-headsign")).toHaveCount(0);

      await page.locator("#dated-change-refresh").click();
      await expect(page.locator("#dated-change-state-headline")).toHaveText(
        "Plan complete.",
      );
      await expect(page.locator("#dated-change-digest")).toHaveText(digest);
    });
  });
}
