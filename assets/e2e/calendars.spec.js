import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// Browser E2E Version's calendars in list order. Three rows are fixtures other
// journeys own. BROWSER_PATTERN_SERVICE (the headsign and pattern routes' calendar)
// has no name, so it lists as "Untitled calendar", sorted by its service ID ahead of
// the named rows; it runs every day and has trips. The last two "Weekday" rows are
// BPS_WKDY (the timetable-paste calendar) and BROWSER_CMP_WEEKDAY (the
// pattern-comparison calendar); both run Monday to Friday and have trips. All three
// take part in the counts and the status filters below.
const SEEDED_NAMES = [
  "Untitled calendar",
  "Every day service",
  "Legacy service",
  "Metadata only",
  "Odd service id",
  "School days",
  "Unused calendar",
  "Weekday",
  "Weekday",
];

const SEEDED_COUNT = SEEDED_NAMES.length;

// BPS_WKDY has fixed dates, unlike the calendars seeded relative to today, so its
// place in the status filters depends on where the agency-local date falls.
const PASTE_WEEKDAY_FIRST = "2026-09-08";
const PASTE_WEEKDAY_LAST = "2027-06-25";

// BROWSER_PATTERN_SERVICE keeps the fixture default period, the whole of 2026.
const PATTERN_SERVICE_FIRST = "2026-01-01";
const PATTERN_SERVICE_LAST = "2026-12-31";

// "before", "during" or "after" a fixed service period, for an ISO date.
function servicePhase(date, first, last) {
  if (date < first) return "before";
  return date > last ? "after" : "during";
}

function pasteWeekdayPhase(date) {
  return servicePhase(date, PASTE_WEEKDAY_FIRST, PASTE_WEEKDAY_LAST);
}

function patternServicePhase(date) {
  return servicePhase(date, PATTERN_SERVICE_FIRST, PATTERN_SERVICE_LAST);
}

const VIEWPORTS = [
  { label: "1440x1000", width: 1440, height: 1000 },
  { label: "1280x900", width: 1280, height: 900 },
];

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

async function openCalendars(page, versionName = "Browser E2E Version") {
  await logIn(page);
  const versionId = await versionIdFor(page, versionName);
  await page.goto(`/gtfs/${versionId}/calendars`);
  await page.waitForSelector(
    "#calendars-list-container, #calendars-first-use-empty, #calendars-unavailable",
    { timeout: 15000 },
  );
  return versionId;
}

// The agency-local date the list shows, as midnight UTC.
async function agencyToday(page) {
  const text = await page.locator("#calendars-today").textContent();
  return new Date(`${text.split("·").pop().trim()} UTC`);
}

// School days, Unused calendar and the two Weekday fixtures run Monday to Friday, so
// which calendars run today depends on the agency-local date the list shows, not on
// the runner's clock. BPS_WKDY's and BROWSER_PATTERN_SERVICE's fixed dates can also
// keep them from running.
async function runsTodayNames(page) {
  const date = await agencyToday(page);
  const weekend = date.getUTCDay() === 0 || date.getUTCDay() === 6;
  const patternService =
    patternServicePhase(isoDate(date)) === "during" ? ["Untitled calendar"] : [];

  if (weekend) return [...patternService, "Every day service"];

  const names = [
    ...patternService,
    "Every day service",
    "School days",
    "Unused calendar",
    "Weekday",
  ];
  return pasteWeekdayPhase(isoDate(date)) === "during"
    ? [...names, "Weekday"]
    : names;
}

function isWeekday(date) {
  return date.getUTCDay() !== 0 && date.getUTCDay() !== 6;
}

// School days is seeded to end ten days from today and to lose the three dates after
// today, but it runs Monday to Friday. Its last service day is the last weekday on or
// before the end date, and only the weekdays among the removed dates are service days.
function schoolDaysCalendar(today) {
  let endsIn = 10;
  while (!isWeekday(shiftDays(today, endsIn))) endsIn -= 1;

  const daysOff = [1, 2, 3].filter((offset) =>
    isWeekday(shiftDays(today, offset)),
  ).length;

  // Three removed service days in a row make a break; fewer are days off.
  const removed = { 1: "1 day off", 2: "2 days off", 3: "1 break" }[daysOff];

  return { endsIn, removed };
}

async function expectRows(page, names, timeout = 8000) {
  await expect.poll(() => rowNames(page), { timeout }).toEqual(names);
  await expect(page.locator("#calendars-list tr")).toHaveCount(names.length);
}

// Row identity comes from the semantic detail link, not a column position: the
// Service dates column now carries a whole coverage bar and its caption.
async function rowNames(page) {
  const names = await page
    .locator("#calendars-list [data-calendar-link]")
    .allTextContents();

  return names.map((name) => name.trim());
}

test.describe("calendar list", () => {
  test("renders the scoped list with shared controls, statuses and layout at both desktop viewports", async ({
    page,
  }) => {
    await page.setViewportSize(VIEWPORTS[0]);
    const versionId = await openCalendars(page);

    for (const viewport of VIEWPORTS) {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.goto(`/gtfs/${versionId}/calendars`);
      await page.waitForSelector("#calendars-list-container", {
        timeout: 15000,
      });

      // The navigation item owns an active Calendars surface.
      const calendarsNav = page.locator('nav[aria-label="Main navigation"] a', {
        hasText: "Calendars",
      });
      await expect(calendarsNav).toHaveText("Calendars", { timeout: 5000 });
      await expect(calendarsNav).toHaveAttribute("aria-current", "page");

      // Semantic table: the calendar's name and regular days share one column.
      const table = page.locator("#calendars-list-container table");
      await expect(table).toBeVisible();
      await expect(table.locator("thead th")).toHaveText([
        /Calendar/,
        /When it runs/,
        "Trips",
        "Status",
      ]);

      expect(await rowNames(page)).toEqual(SEEDED_NAMES);

      // Result count, run-today and ending-soon counts, agency-local today, and the
      // feed-gap callout.
      await expect(page.locator("#result-count")).toContainText(
        String(SEEDED_COUNT),
      );
      await expect(
        page.locator("#calendar-counts-item-run-today"),
      ).toContainText(String((await runsTodayNames(page)).length));
      await expect(page.locator("#calendars-today")).toContainText("Today ·");
      await expect(page.locator("#calendars-feed-gap")).toBeVisible();

      // Status presentation comes from the real computed summaries.
      const rows = await page.locator("#calendars-list tr").allTextContents();
      const statusText = rows.join(" | ");
      expect(statusText).toContain("Runs today");
      expect(statusText).toContain("Ended");
      expect(statusText).toContain("No service");
      expect(statusText).toContain(
        `Ends in ${schoolDaysCalendar(await agencyToday(page)).endsIn} days`,
      );
      expect(statusText).toContain("Ends in 5 days");
      expect(statusText).toContain("Not used by trips");

      // Grouped trip usage is numeric and right-aligned in its own column. Every day
      // service also carries the Schedules scenario's 23 trips plus the advanced trip
      // editing journeys' 513 (12 grid, 1 frequency, 500 bulk) in this version.
      const dailyRow = page.locator("#calendars-list tr", {
        hasText: "Every day service",
      });
      await expect(dailyRow.locator('td[data-label="Trips"]')).toHaveText("539");
      await expect(
        page
          .locator("#calendars-list tr", { hasText: "School days" })
          .locator('td[data-label="Trips"]'),
      ).toHaveText("2");
      await expect(
        page
          .locator("#calendars-list tr", { hasText: "Legacy service" })
          .locator('td[data-label="Trips"]'),
      ).toHaveText("1");

      // Detail links keep URI-encoded service IDs.
      const oddLink = page.locator('#calendars-list [data-calendar-link="svc/odd name"]');
      await expect(oddLink).toHaveAttribute(
        "href",
        /service_id=svc%2Fodd\+name/,
      );

      // Calendar creation and the cross-calendar drawer are reachable from the
      // list; the editor's own controls are not.
      await expect(page.locator("#calendars-create")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/calendars/new`,
      );

      await expect(page.locator("#calendar-date-change")).toHaveText(
        "Change service on a date",
      );

      for (const label of [
        "Add break",
        "Duplicate calendar",
        "Delete calendar",
        "Extend end date",
      ]) {
        await expect(page.getByText(label, { exact: false })).toHaveCount(0);
      }

      // The table keeps its hierarchy without horizontal page overflow.
      const overflows = await page.evaluate(
        () => document.body.scrollWidth > window.innerWidth + 1,
      );
      expect(overflows).toBe(false);
    }
  });

  test("search, status filters and sorting round-trip through the URL", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await openCalendars(page);

    // Search by name.
    await page.fill("#calendar-search", "school");
    await expect
      .poll(() => rowNames(page), { timeout: 5000 })
      .toEqual(["School days"]);
    await expect(page.locator("#calendars-list tr")).toHaveCount(1);
    await expect(page.locator("#result-count")).toHaveText(
      `1 of ${SEEDED_COUNT} calendars`,
    );

    // Search by service ID.
    await page.fill("#calendar-search", "CAL_LEGACY");
    await expect
      .poll(() => rowNames(page), { timeout: 5000 })
      .toEqual(["Legacy service"]);

    // A search with no matches keeps the counts and offers to clear the filters.
    await page.fill("#calendar-search", "no such calendar");
    await expect(page.locator("#calendars-filtered-empty")).toBeVisible({
      timeout: 5000,
    });
    await expect(page.locator("#result-count")).toHaveText(
      `0 of ${SEEDED_COUNT} calendars`,
    );
    await page.click("#calendars-clear-filters");
    await expect(page.locator("#calendars-list tr")).toHaveCount(SEEDED_COUNT, {
      timeout: 5000,
    });

    // Status filters with the documented allowlist.
    // BPS_WKDY and BROWSER_PATTERN_SERVICE end on fixed dates, so each joins Legacy
    // service once its date passes.
    const today = isoDate(await agencyToday(page));
    const phase = pasteWeekdayPhase(today);
    const patternPhase = patternServicePhase(today);

    await page.selectOption("#calendar-status", "ended");
    await expectRows(page, [
      ...(patternPhase === "after" ? ["Untitled calendar"] : []),
      "Legacy service",
      ...(phase === "after" ? ["Weekday"] : []),
    ]);

    await page.selectOption("#calendar-status", "active_today");
    await expectRows(page, await runsTodayNames(page));

    // BROWSER_CMP_WEEKDAY is in its period for 30 days either side of today; BPS_WKDY
    // and BROWSER_PATTERN_SERVICE only between their fixed dates.
    await page.selectOption("#calendar-status", "active_period");
    await expectRows(page, [
      ...(patternPhase === "during" ? ["Untitled calendar"] : []),
      "Every day service",
      "School days",
      "Unused calendar",
      "Weekday",
      ...(phase === "during" ? ["Weekday"] : []),
    ]);

    await page.selectOption("#calendar-status", "unused");
    await expectRows(page, [
      "Metadata only",
      "Odd service id",
      "Unused calendar",
    ]);

    await page.selectOption("#calendar-status", "all");
    await expectRows(page, SEEDED_NAMES);

    // The URL carries the state, and reloading it reproduces the list. The unnamed
    // BROWSER_PATTERN_SERVICE matches through its service ID.
    await page.fill("#calendar-search", "service");
    await page.selectOption("#calendar-status", "all");
    await expectRows(page, [
      "Untitled calendar",
      "Every day service",
      "Legacy service",
      "Odd service id",
    ]);
    expect(page.url()).toContain("search=service");

    await page.reload();
    await page.waitForSelector("#calendars-list-container");
    await expect(page.locator("#calendar-search")).toHaveValue("service");
    await expectRows(page, [
      "Untitled calendar",
      "Every day service",
      "Legacy service",
      "Odd service id",
    ]);

    // Keyboard-reachable sort controls toggle direction through the URL.
    await page.goto(page.url().split("?")[0]);
    await page.waitForSelector("#calendars-list-container");

    const nameHeader = page
      .locator("#calendars-list-container thead th")
      .first();
    await expect(nameHeader).toHaveAttribute("aria-sort", "ascending");

    await nameHeader.locator("button").click();
    await expect(nameHeader).toHaveAttribute("aria-sort", "descending", {
      timeout: 5000,
    });
    await expectRows(page, [...SEEDED_NAMES].reverse());
    expect(page.url()).toContain("sort_dir=desc");

    // Period sorting keeps identities without an active date last in both directions.
    const periodHeader = page.locator("#calendars-list-container thead th", {
      hasText: "When it runs",
    });
    await periodHeader.locator("button").click();
    await expect(periodHeader).toHaveAttribute("aria-sort", "ascending", {
      timeout: 5000,
    });
    await expect
      .poll(async () => (await rowNames(page)).at(-1), { timeout: 8000 })
      .toBe("Metadata only");

    await periodHeader.locator("button").click();
    await expect(periodHeader).toHaveAttribute("aria-sort", "descending", {
      timeout: 5000,
    });
    await expect
      .poll(async () => (await rowNames(page)).at(-1), { timeout: 8000 })
      .toBe("Metadata only");
  });

  test("a version without calendars shows the first-use empty state, not a failed read", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    const versionId = await openCalendars(page, "Catalog Empty Version");

    await expect(page.locator("#calendars-first-use-empty")).toBeVisible();
    await expect(page.locator("#calendars-first-use-empty")).toContainText(
      "No calendars in Catalog Empty Version yet",
    );
    await expect(page.locator("#calendars-list-container")).toHaveCount(0);
    await expect(page.locator("#calendars-unavailable")).toHaveCount(0);
    await expect(page.locator("#calendars-create")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/calendars/new`,
    );
  });
});

// ---- Calendar coverage axis (step 4) ---------------------------------------

// Reads the geometry the shared axis and the row bars must agree on, so the two are
// one scale rather than two drawings that happen to sit above each other.
async function coverageGeometry(page) {
  return page.evaluate(() => {
    const axis = document.querySelector("#calendar-coverage-axis");
    const lane = document.querySelector(
      '[data-calendar-coverage="CAL_DAILY"] .calendar-coverage-lane',
    );
    if (!axis || !lane) throw new Error("coverage axis or row lane is missing");
    const a = axis.getBoundingClientRect();
    const l = lane.getBoundingClientRect();
    return {
      axisLeft: a.left,
      axisWidth: a.width,
      laneLeft: l.left,
      laneWidth: l.width,
      tickLabels: Array.from(
        axis.querySelectorAll(".calendar-coverage-tick-label"),
      ).map((label) => label.textContent.trim()),
    };
  });
}

test.describe("calendar coverage", () => {
  test("draws one shared axis, exact-date captions and the legend at every supported width", async ({
    page,
  }) => {
    const versionId = await openCalendars(page);

    for (const viewport of [
      { width: 1440, height: 900 },
      { width: 1024, height: 900 },
      { width: 390, height: 844 },
      { width: 320, height: 800 },
    ]) {
      await page.setViewportSize(viewport);
      await page.goto(`/gtfs/${versionId}/calendars`);
      await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
      await page.waitForSelector("#calendar-coverage-axis");

      // One axis for the whole table, one bar for every row, and the four columns stay
      // four: the axis row's cells are not header cells.
      await expect(page.locator("#calendar-coverage-axis")).toHaveCount(1);
      await expect(page.locator("[data-calendar-coverage]")).toHaveCount(
        SEEDED_COUNT,
      );
      await expect(
        page.locator("#calendars-list-container thead th"),
      ).toHaveText([/Calendar/, /When it runs/, "Trips", "Status"]);

      // The range control is a labelled group whose default is the whole feed.
      await expect(page.locator("#calendar-coverage-range")).toHaveAttribute(
        "role",
        "group",
      );
      await expect(page.locator("#calendar-coverage-range-whole")).toHaveAttribute(
        "aria-current",
        "true",
      );

      // The axis and the bars are one scale: same left edge, same width.
      const geometry = await coverageGeometry(page);
      expect(Math.abs(geometry.axisLeft - geometry.laneLeft)).toBeLessThan(1);
      expect(Math.abs(geometry.axisWidth - geometry.laneWidth)).toBeLessThan(1);
      expect(geometry.tickLabels.length).toBeGreaterThan(0);

      // The caption states the exact dates and counts in text. The patterns hold
      // whatever day the suite runs; School days' break or days-off wording follows
      // which of its removed dates fall on a weekday, so it is derived from today.
      const captions = await page
        .locator("[data-calendar-coverage] .calendar-coverage-caption")
        .allTextContents();

      await expect(
        page.locator(
          '[data-calendar-coverage="CAL_META"] .calendar-coverage-caption',
        ),
      ).toHaveText("No service dates");
      await expect(
        page.locator(
          '[data-calendar-coverage="svc/odd name"] .calendar-coverage-caption',
        ),
      ).toHaveText(/^1 date · [A-Z][a-z]{2} \d{1,2}, \d{4}$/);
      await expect(
        page.locator(
          '[data-calendar-coverage="CAL_LEGACY"] .calendar-coverage-caption',
        ),
      ).toHaveText(/^[A-Z][a-z]{2} \d{1,2}, \d{4} – [A-Z][a-z]{2} \d{1,2}, \d{4}$/);
      await expect(
        page.locator(
          '[data-calendar-coverage="CAL_SCHOOL"] .calendar-coverage-caption',
        ),
      ).toHaveText(
        new RegExp(`${schoolDaysCalendar(await agencyToday(page)).removed}$`),
      );
      expect(captions.join(" | ")).not.toContain("undefined");

      // The legend names every state in words.
      const legend = page.locator("#calendar-coverage-legend");
      for (const word of [
        "Regular service",
        "Day off",
        "Break",
        "Added date",
        "No service on any calendar",
        "Today",
      ]) {
        await expect(legend).toContainText(word);
      }

      // The wrapped layout stays inside the viewport at every supported width.
      const overflows = await page.evaluate(
        () => document.body.scrollWidth > window.innerWidth + 1,
      );
      expect(overflows).toBe(false);
    }
  });

  test("switches the timeline range through the URL and keeps the existing gap review entry", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    const versionId = await openCalendars(page);

    // The whole feed draws period bars: a few marks per row.
    const wholeMarks = await page
      .locator('[data-calendar-coverage="CAL_DAILY"] .calendar-coverage-mark')
      .count();

    // The group is keyboard reachable links, so the range is ordinary URL state.
    await page.click("#calendar-coverage-range-near");
    await expect(page).toHaveURL(/range=near/);
    await expect(page.locator("#calendar-coverage-range-near")).toHaveAttribute(
      "aria-current",
      "true",
    );
    await expect(page.locator("#calendar-coverage-range-whole")).not.toHaveAttribute(
      "aria-current",
      "true",
    );

    // The near range draws one day cell per served day, on the same shared axis.
    await expect
      .poll(
        async () =>
          page
            .locator('[data-calendar-coverage="CAL_DAILY"] .calendar-coverage-mark')
            .count(),
        { timeout: 5000 },
      )
      .toBeGreaterThan(Math.max(wholeMarks, 30));

    const geometry = await coverageGeometry(page);
    expect(Math.abs(geometry.axisLeft - geometry.laneLeft)).toBeLessThan(1);
    expect(Math.abs(geometry.axisWidth - geometry.laneWidth)).toBeLessThan(1);

    // Reloading the range URL reproduces the view, and the version-wide gap callout
    // with its date-change entry survives the range change.
    await page.reload();
    await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
    await expect(page.locator("#calendar-coverage-range-near")).toHaveAttribute(
      "aria-current",
      "true",
    );
    await expect(page.locator("#calendars-feed-gap")).toBeVisible();

    await page.click("#calendars-feed-gap-review");
    await waitForDrawerReady(page);
    await expect(page.locator("#calendar-date-change-drawer")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.locator("#calendar-date-change-drawer")).toBeHidden();
    await expect(page.locator("#calendars-feed-gap-review")).toBeFocused();

    // Back to the whole feed through the same control.
    await page.click("#calendar-coverage-range-whole");
    await expect(page).not.toHaveURL(/range=near/);
    await expect(page.locator("#calendar-coverage-range-whole")).toHaveAttribute(
      "aria-current",
      "true",
    );
  });
});

// ---- Calendar coverage details (step 5) ------------------------------------

const DETAILS_VERSION = "Browser Calendar Details";

// The next weekday strictly after `from`, so a removal default always has a
// calendar that runs on the chosen date whatever day the suite runs.
async function nextWeekday(page, from, days) {
  return page.evaluate(
    ({ from, days }) => {
      const date = new Date(from);
      date.setUTCDate(date.getUTCDate() + days);
      while (date.getUTCDay() === 0 || date.getUTCDay() === 6) {
        date.setUTCDate(date.getUTCDate() + 1);
      }
      return date.toISOString().slice(0, 10);
    },
    { from, days },
  );
}

test.describe("calendar coverage details", () => {
  test("keyboard activation opens the exact dates and Escape returns focus to its control", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    const versionId = await openCalendars(page, DETAILS_VERSION);

    const control = page.locator(
      '#calendars-list [data-calendar-coverage="DETAIL_SCHOOL"]',
    );
    await expect(control).toHaveJSProperty("tagName", "BUTTON");
    await expect(control).toHaveAttribute("aria-haspopup", "dialog");
    await expect(control).toContainText("break");

    // The control is keyboard reachable from its own row, not only clickable.
    await page.locator('#calendars-list [data-calendar-link="DETAIL_SCHOOL"]').focus();
    await page.keyboard.press("Tab");
    await expect(control).toBeFocused();

    // Activation by keyboard alone opens the inspector for this exact identity.
    await page.keyboard.press("Enter");
    await page.waitForSelector("#calendar-coverage-details-overlay[open]", {
      timeout: 15000,
    });
    const details = page.locator("#calendar-coverage-details");
    await expect(details).toContainText("DETAIL_SCHOOL");

    // The three removed regular service days are stated as a break with its exact
    // range, and the additions that sit after the weekly range are named exactly. The
    // pattern tolerates the whitespace the template leaves between the break label,
    // the range and the removed-day count, because a regular expression is matched
    // against the element's raw text.
    await expect(details).toContainText(
      /Break ·\s+[A-Z][a-z]{2} \d{1,2}, \d{4} – [A-Z][a-z]{2} \d{1,2}, \d{4}\s+·\s+3 service days removed/,
    );
    await expect(details).toContainText(/Extra service:[\s\S]*outside the regular schedule/);
    await expect(details).toContainText("Single days off:");
    await expect(details.locator("#calendar-coverage-details-dates li")).toHaveCount(8);
    await expect(details).toContainText("Service added");
    await expect(details).toContainText("Service removed");
    await expect(details).toContainText(/Next service/);
    await expect(details).toContainText("2 trips use this calendar");
    await expect(details).toContainText("BROWSER_DETAILS");

    // This row's own marks are compressed into bins on the long feed, so the inspector
    // says so instead of presenting an approximate bar as an exact date list.
    await expect(details.locator("#calendar-coverage-details-approximate")).toContainText(
      "compressed into bins and drawn approximately",
    );

    // Escape closes the inspector and returns focus to the control that opened it.
    await page.keyboard.press("Escape");
    await expect(page.locator("#calendar-coverage-details-overlay")).not.toHaveAttribute(
      "open",
      "",
    );
    await expect(control).toBeFocused();

    // A nine-year identity keeps exact dates outside the disclosed window: the count,
    // the exact span and the statement that no date is dropped.
    const long = page.locator('#calendars-list [data-calendar-coverage="DETAIL_LONG"]');
    await long.focus();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#calendar-coverage-details-overlay[open]", {
      timeout: 15000,
    });
    await expect(details.locator("#calendar-coverage-details-outside")).toContainText(
      /\d+ service dates before [A-Z][a-z]{2} \d{1,2}, \d{4}: [A-Z][a-z]{2} \d{1,2}, \d{4} – [A-Z][a-z]{2} \d{1,2}, \d{4}/,
    );
    await expect(details.locator("#calendar-coverage-details-outside")).toContainText(
      "none of them is dropped",
    );
    await expect(details).toContainText("No routes yet");

    // The same Escape contract holds for the control that opened this inspector.
    await page.keyboard.press("Escape");
    await expect(long).toBeFocused();

    // The near range clips the latest addition, so the inspector names the exact
    // date outside the drawn timeline instead of dropping it.
    await page.goto(`/gtfs/${versionId}/calendars?range=near`);
    await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
    await control.focus();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#calendar-coverage-details-overlay[open]", {
      timeout: 15000,
    });
    await expect(details.locator("#calendar-coverage-details-outside")).toContainText(
      /1 service date after [A-Z][a-z]{2} \d{1,2}, \d{4}: [A-Z][a-z]{2} \d{1,2}, \d{4}/,
    );
    await expect(details.locator("#calendar-coverage-details-outside")).toContainText(
      "none of them is dropped",
    );
  });

  test("routes an unreadable identity only to its repair actions, never into the date-change targets", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    const versionId = await openCalendars(page, DETAILS_VERSION);

    // The identity stays listed with its name and usage, but its name is not a link
    // and it has no coverage control. The detail page opens it with the stored dates
    // so they can be corrected, so the repair state's "Fix dates" is the only link there.
    const invalidRow = page.locator("#calendars-list tr", {
      hasText: "Details reversed range",
    });
    await expect(invalidRow).toBeVisible();
    await expect(
      page.locator('#calendars-list [data-calendar-link="DETAIL_REVERSED"]'),
    ).toHaveCount(0);
    const detailLinks = invalidRow.locator('a[href*="/calendars/show"]');
    await expect(detailLinks).toHaveCount(1);
    await expect(detailLinks).toHaveAttribute(
      "id",
      "calendar-coverage-fix-DETAIL_REVERSED",
    );
    await expect(detailLinks).toHaveText("Fix dates");
    await expect(
      page.locator('[data-calendar-coverage="DETAIL_REVERSED"]'),
    ).toHaveCount(0);
    await expect(invalidRow).toContainText("Range needs repair");
    await expect(
      page.locator("#calendar-coverage-repair-DETAIL_REVERSED"),
    ).toHaveAttribute("href", `/gtfs/${versionId}/import`);
    await expect(invalidRow).toContainText(
      "Correct the calendar file and import the feed again",
    );

    // The reviewed date change evaluates every target, so the unreadable identity is
    // not offered as a stop or a run target while the readable ones are.
    const today = await page.evaluate(() => new Date().toISOString());
    const date = await nextWeekday(page, today, 4);

    await page.click("#calendar-date-change");
    await page.waitForSelector("#calendar-date-change-form[data-phx-id]", {
      timeout: 15000,
    });
    await page.fill("#calendar-date-change-dates-date", date);
    await expect(
      page.locator("#calendar-date-change-remove-DETAIL_SCHOOL"),
    ).toBeVisible();
    await expect(page.locator("#calendar-date-change-add-DETAIL_SCHOOL")).toBeVisible();
    await expect(page.locator("#calendar-date-change-add-DETAIL_DATES")).toBeVisible();
    await expect(
      page.locator('[id^="calendar-date-change-add-DETAIL_REVERSED"]'),
    ).toHaveCount(0);
    await expect(
      page.locator('[id^="calendar-date-change-remove-DETAIL_REVERSED"]'),
    ).toHaveCount(0);
    await expect(page.locator("#calendar-date-change-drawer")).not.toContainText(
      "DETAIL_REVERSED",
    );
  });
});

// ---- Calendar editor journeys (step 6) -------------------------------------

function isoDate(date) {
  return date.toISOString().slice(0, 10);
}

function shiftDays(date, days) {
  const shifted = new Date(date.getTime());
  shifted.setUTCDate(shifted.getUTCDate() + days);
  return shifted;
}

// The next Friday at or after today, so a Fri/Mon/Tue closure always spans a
// weekend whatever day the suite runs.
function nextFriday(from = new Date()) {
  const day = from.getUTCDay();
  const offset = (5 - day + 7) % 7;
  return shiftDays(from, offset);
}

async function openEditor(page, versionName, serviceId) {
  const versionId = await openCalendars(page, versionName);
  return openEditorFor(page, versionId, serviceId);
}

// Navigating straight to a detail route keeps a single authenticated session, so a
// journey with several editor visits never re-enters the login page.
async function openEditorFor(page, versionId, serviceId) {
  await page.goto(
    `/gtfs/${versionId}/calendars/show?service_id=${encodeURIComponent(serviceId)}`,
  );
  await waitForEditorReady(page);
  return versionId;
}

// The first paint is server-rendered, so the editor waits for the client patch
// (which stamps `data-phx-id`) before a journey types or clicks: without it the
// first interaction can be replaced by the arriving patch.
async function waitForEditorReady(page) {
  await page.waitForSelector("#calendar-form[data-phx-id]", { timeout: 15000 });
}

test.describe("calendar editor", () => {
  test("creates a weekly calendar from the list, previews a month and deletes it", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    const versionId = await openCalendars(page);

    await page.click("#calendars-create");
    await waitForEditorReady(page);
    await expect(page.locator("#calendars-create")).toHaveCount(0);

    await page.fill("#calendar-name", "Browser editor journey");
    // The suggested service ID is derived from the name and stays editable.
    await expect(page.locator("#calendar-service-id")).toHaveValue(
      "browser_editor_journey",
    );

    const today = new Date();
    await page.fill("#calendar-start-date", isoDate(shiftDays(today, -30)));
    await page.fill("#calendar-end-date", isoDate(shiftDays(today, 60)));
    await page.click("#calendar-save");

    // A LiveView navigate swaps the page without a document load event, so the
    // detail route is awaited through its own content.
    await page.waitForSelector("#periods-timeline", { timeout: 15000 });
    expect(page.url()).toContain("service_id=browser_editor_journey");
    await expect(page.locator("h1")).toContainText("Browser editor journey");
    await expect(page.locator("#calendar-name")).toHaveValue(
      "Browser editor journey",
    );
    await expect(page.locator("#calendar-weekdays-monday")).toBeChecked();
    await expect(page.locator("#calendar-weekdays-saturday")).not.toBeChecked();
    await expect(page.locator("#calendar-usage")).toContainText(
      "No trips use this calendar",
    );

    // One month of the real derived preview, with symbols, text and a legend.
    await expect(page.locator("#months table")).toHaveCount(1);
    await expect(page.locator("#months-legend")).toContainText("Runs");
    await expect(page.locator("#months-legend")).toContainText("Day off");
    await expect(page.locator("#months-legend")).toContainText(
      "Extra service",
    );
    await expect(page.locator("#months-legend")).toContainText(
      "Not a service day",
    );
    await expect(page.locator("#periods-timeline")).toBeVisible();

    // Keyboard month navigation moves the preview one month.
    const firstTitle = await page.locator("#calendar-preview-month").innerText();
    await page.locator("#months").focus();
    await page.keyboard.press("ArrowRight");
    await expect
      .poll(() => page.locator("#calendar-preview-month").innerText(), {
        timeout: 5000,
      })
      .not.toBe(firstTitle);

    for (const viewport of VIEWPORTS) {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });

      const overflows = await page.evaluate(
        () => document.body.scrollWidth > window.innerWidth + 1,
      );
      expect(overflows).toBe(false);
    }

    // The journey cleans up after itself so the shared list fixture is intact.
    await page.click("#calendar-delete");
    await expect(page.locator("#calendar-review-dialog")).toBeVisible();
    await page.click("#calendar-review-dialog-confirm");
    await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
    await expect(
      page.locator("#calendars-list tr", { hasText: "Browser editor journey" }),
    ).toHaveCount(0);
    await expect(page.locator("#calendars-list tr")).toHaveCount(SEEDED_COUNT);
  });

  test("reviews and applies a date change, guards dirty navigation and returns focus", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await openEditor(page, "Browser E2E Version", "CAL_UNUSED");

    // A date outside the weekly range is reviewed before anything is written.
    const outside = isoDate(shiftDays(new Date(), 40));
    await page.fill("#calendar-exception-date", outside);
    await expect(page.locator("#calendar-exception-date")).toHaveValue(outside);
    await page.click("#calendar-add-date");

    await expect(page.locator("#calendar-review-dialog")).toBeVisible();
    await expect(page.locator("#calendar-review-dialog")).toContainText(
      "Add service on",
    );
    await page.click("#calendar-review-dialog-cancel");
    await expect(page.locator("#calendar-review-dialog")).toBeHidden();
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toHaveCount(0);

    await page.click("#calendar-add-date");
    await page.click("#calendar-review-dialog-confirm");
    await expect(page.locator("#calendar-status")).toContainText(
      "Extra service added.",
      {
        timeout: 8000,
      },
    );
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toBeVisible();

    // The preview shows one month, so step to the month the new date falls in.
    const todayUtc = new Date();
    const outsideUtc = new Date(`${outside}T00:00:00Z`);
    const monthsAhead =
      (outsideUtc.getUTCFullYear() - todayUtc.getUTCFullYear()) * 12 +
      outsideUtc.getUTCMonth() -
      todayUtc.getUTCMonth();
    for (let step = 0; step < monthsAhead; step += 1) {
      await page.click("#calendar-preview-next");
    }
    await expect(page.locator(`#month-cell-${outside}`)).toHaveAttribute(
      "aria-label",
      /Extra service/,
    );

    // Restore the fixture state.
    await page.click(`#calendar-exception-chips-remove-${outside}`);
    await expect(page.locator("#calendar-status")).toContainText(
      "Regular schedule restored.",
      {
        timeout: 8000,
      },
    );
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toHaveCount(0);

    // A dirty schedule asks before an independent action, and Escape returns focus.
    await page.fill("#calendar-name", "Renamed without saving");
    await page.click("#calendar-delete");
    await expect(page.locator("#calendar-dirty-dialog")).toBeVisible();
    await expect(page.locator("#calendar-dirty-dialog")).toContainText(
      "haven’t saved it",
    );

    const focusedInDialog = await page.evaluate(() =>
      document
        .getElementById("calendar-dirty-dialog")
        .contains(document.activeElement),
    );
    expect(focusedInDialog).toBe(true);

    await page.keyboard.press("Escape");
    await expect(page.locator("#calendar-dirty-dialog")).toBeHidden();
    await expect(page.locator("#calendar-name")).toHaveValue(
      "Renamed without saving",
    );

    // Discarding the draft then runs the requested delete review, which is cancelled.
    await page.click("#calendar-delete");
    await page.click("#calendar-dirty-dialog-confirm");
    await expect(page.locator("#calendar-review-dialog")).toBeVisible();
    await expect(page.locator("#calendar-review-dialog")).toContainText(
      "Delete Unused calendar?",
    );
    await page.click("#calendar-review-dialog-cancel");
    await expect(page.locator("#calendar-name")).toHaveValue("Unused calendar");
  });

  test("associates validation errors and reports the trips blocking a delete", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    const versionId = await openCalendars(page);

    await page.goto(`/gtfs/${versionId}/calendars/new`);
    await waitForEditorReady(page);
    await page.fill("#calendar-name", "");
    await page.click("#calendar-save");

    await expect(page.locator("#calendar-name-error")).toBeVisible();
    await expect(page.locator("#calendar-name-error")).toContainText(
      "Enter a calendar name.",
    );
    await expect(page.locator("#calendar-name")).toHaveAttribute(
      "aria-invalid",
      "true",
    );

    // School days is used only on CAL_ROUTE; the Schedules scenario also runs
    // trips on CAL_DAILY, so that calendar's usage spans several routes.
    await openEditorFor(page, versionId, "CAL_SCHOOL");
    await page.click("#calendar-delete");

    await expect(page.locator("#calendar-delete-blocked")).toBeVisible();
    await expect(page.locator("#calendar-delete-blocked")).toContainText(
      "2 trips",
    );
    await expect(
      page.locator("#calendar-delete-blocked-route-CAL_ROUTE"),
    ).toHaveAttribute("href", `/gtfs/${versionId}/routes/CAL_ROUTE`);
    await expect(page.locator("#calendar-review-dialog")).toBeHidden();
    await expect(page.locator("#calendar-name")).toHaveValue("School days");
  });
});

// ---- Cross-calendar date change drawer (step 7) ----------------------------

async function waitForDrawerReady(page) {
  await page.waitForSelector("#calendar-date-change-form[data-phx-id]", {
    timeout: 15000,
  });
}

// Every calendar running on a chosen date starts checked for removal, and that
// includes the Weekday and pattern-service fixtures other journeys own. A journey that
// changes only the calendars it names unchecks them, so the review counts just those and
// the fixtures stay as seeded. BPS_WKDY and BROWSER_PATTERN_SERVICE are listed only while
// a chosen date falls inside their fixed dates.
async function uncheckFixtureCalendars(page, dates) {
  await page.uncheck("#calendar-date-change-remove-BROWSER_CMP_WEEKDAY input");

  if (dates.some((date) => pasteWeekdayPhase(date) === "during")) {
    await page.uncheck("#calendar-date-change-remove-BPS_WKDY input");
  }

  // BROWSER_PATTERN_SERVICE runs every day of its period, so it is checked for
  // removal on any date inside it.
  if (dates.some((date) => patternServicePhase(date) === "during")) {
    await page.uncheck(
      "#calendar-date-change-remove-BROWSER_PATTERN_SERVICE input",
    );
  }
}

test.describe("cross-calendar date change drawer", () => {
  test("reviews and applies one atomic date change for several calendars at both desktop viewports", async ({
    page,
  }) => {
    await page.setViewportSize(VIEWPORTS[0]);
    const versionId = await openCalendars(page);

    // The preceding Friday sits inside CAL_SCHOOL's range, clear of its
    // upcoming seeded break and its final day (which would trim the range).
    const serviceDate = isoDate(nextFriday(shiftDays(new Date(), -7)));

    // This swap requires a calendar that does not already run on Friday.
    // Prepare that state explicitly instead of depending on earlier journeys.
    await openEditorFor(page, versionId, "CAL_UNUSED");
    const unusedFriday = await page.locator("#calendar-weekdays-friday").isChecked();
    if (unusedFriday) await page.locator("label:has(#calendar-weekdays-friday)").click();
    await expect(page.locator("#calendar-weekdays-friday")).not.toBeChecked();
    await page.click("#calendar-save");
    await expect(page.locator("#calendar-status")).toContainText(/Saved|No change/);

    try {
      for (const viewport of VIEWPORTS) {
        await page.setViewportSize({
          width: viewport.width,
          height: viewport.height,
        });
        await page.goto(`/gtfs/${versionId}/calendars`);
        await page.waitForSelector("#calendars-list-container", {
          timeout: 15000,
        });

        // Keyboard activation opens the drawer and moves focus into it.
        await page.locator("#calendar-date-change").focus();
        await page.keyboard.press("Enter");
        await expect(page.locator("#calendar-date-change-drawer")).toBeVisible();
        await waitForDrawerReady(page);

        expect(
          await page.evaluate(() =>
            document
              .getElementById("calendar-date-change-drawer")
              .contains(document.activeElement),
          ),
        ).toBe(true);

        // A reversed range is refused on its own control and writes nothing.
        await page.selectOption("#calendar-date-change-dates-mode", "range");
        await page.fill("#calendar-date-change-dates-date-from", serviceDate);
        await page.fill(
          "#calendar-date-change-dates-date-to",
          isoDate(shiftDays(new Date(serviceDate), -3)),
        );
        await expect(
          page.locator("#calendar-date-change-dates-date-to"),
        ).toHaveValue(isoDate(shiftDays(new Date(serviceDate), -3)));
        await expect(
          page.locator("#calendar-date-change-dates-date-to-error"),
        ).toContainText("on or after");

        // A single date defaults removal to the calendars running that day.
        await page.selectOption("#calendar-date-change-dates-mode", "single");
        await page.fill("#calendar-date-change-dates-date", serviceDate);
        await expect(
          page.locator("#calendar-date-change-dates-date"),
        ).toHaveValue(serviceDate);
        await expect(
          page.locator("#calendar-date-change-remove-CAL_SCHOOL input"),
        ).toBeChecked();
        await expect(
          page.locator("#calendar-date-change-remove-CAL_DAILY input"),
        ).toBeChecked();

        // Stop the school calendar and run the unused one instead, in one review.
        await page.uncheck("#calendar-date-change-remove-CAL_DAILY input");
        await uncheckFixtureCalendars(page, [serviceDate]);
        await expect(
          page.locator("#calendar-date-change-remove-CAL_DAILY input"),
        ).not.toBeChecked();
        await page.check("#calendar-date-change-add-CAL_UNUSED input");
        await expect(
          page.locator("#calendar-date-change-add-CAL_UNUSED input"),
        ).toBeChecked();

        await page.click("#calendar-date-change-review");
        await expect(
          page.locator("#calendar-date-change-review-panel"),
        ).toContainText("Result after applying");
        await expect(
          page.locator("#calendar-date-change-review-panel"),
        ).toContainText("Stop School days");
        await expect(
          page.locator("#calendar-date-change-review-panel"),
        ).toContainText("Run Unused calendar");
        await expect(
          page.locator("#calendar-date-change-review-count"),
        ).toContainText("This changes 2 calendars");
        await expect(
          page.locator("#calendar-date-change-review-count"),
        ).toContainText("GTFS: 2 rows change");

        await page.click("#calendar-date-change-apply");
        await expect(page.locator("#calendars-date-change-status")).toContainText(
          "Applied the date change",
          { timeout: 10000 },
        );
        await expect(page.locator("#calendar-date-change-drawer")).toBeHidden();

        try {
          // The committed rows survive a real reload through the editor surfaces.
          await openEditorFor(page, versionId, "CAL_SCHOOL");
          const schoolDate = page.locator(`#calendar-exception-chips-${serviceDate}`);
          const schoolBreak = schoolDate.locator("xpath=ancestor-or-self::tr");
          await expect(schoolBreak).toContainText("No service");
          // Consecutive removed days are grouped into a break; its dates are
          // deliberately collapsed until the reviewer asks to see them.
          const details = schoolBreak.locator("details");
          if (await details.count()) await details.locator("summary").click();
          await expect(schoolDate).toBeVisible();

          await openEditorFor(page, versionId, "CAL_UNUSED");
          await expect(
            page.locator(`#calendar-exception-chips-${serviceDate}`),
          ).toBeVisible();
          await expect(
            page.locator(`#calendar-exception-chips-${serviceDate}`),
          ).toContainText("Extra service");
        } finally {
          // Restore both committed rows even if a persistence assertion fails,
          // so later journeys never inherit this test's school day off.
          for (const serviceId of ["CAL_UNUSED", "CAL_SCHOOL"]) {
            await openEditorFor(page, versionId, serviceId);
            const date = page.locator(`#calendar-exception-chips-${serviceDate}`);
            const details = page.locator("details").filter({ has: date });
            if (await details.count()) await details.locator("summary").click();
            await page.click(`#calendar-exception-chips-remove-${serviceDate}`);
            await expect(page.locator("#calendar-status")).toContainText(
              "Regular schedule restored.", { timeout: 10000 },
            );
          }
        }

        // Escape closes the drawer and focus returns to the entry control.
        await page.goto(`/gtfs/${versionId}/calendars`);
        await page.waitForSelector("#calendars-list-container", {
          timeout: 15000,
        });
        await page.click("#calendar-date-change");
        await waitForDrawerReady(page);
        await page.keyboard.press("Escape");
        await expect(page.locator("#calendar-date-change-drawer")).toBeHidden();
        await expect(page.locator("#calendar-date-change")).toBeFocused();
      }
    } finally {
      await openEditorFor(page, versionId, "CAL_UNUSED");
      if ((await page.locator("#calendar-weekdays-friday").isChecked()) !== unusedFriday) {
        await page.locator("label:has(#calendar-weekdays-friday)").click();
      }
      await expect(page.locator("#calendar-weekdays-friday")).toBeChecked({ checked: unusedFriday });
      await page.click("#calendar-save");
      await expect(page.locator("#calendar-status")).toContainText(/Saved|No change/);
    }
  });
});

test("retains sequential dates, shows pending, recovers a stale write and guards dirty departures", async ({page, context}) => {
  let held = null;
  let holdApply = false;
  await page.routeWebSocket(/\/live\/websocket/, ws => {
    const server = ws.connectToServer();
    ws.onMessage(message => {
      if (holdApply && String(message).includes('date_change_apply')) {
        held = () => server.send(message);
      } else server.send(message);
    });
  });
  const versionId = await openCalendars(page);
  await page.click("#calendar-date-change");
  await waitForDrawerReady(page);
  const first = isoDate(nextFriday(shiftDays(new Date(), 4)));
  const second = isoDate(shiftDays(new Date(first), 7));
  await page.selectOption("#calendar-date-change-dates-mode", "several");
  await page.fill("#calendar-date-change-dates-date-add", first);
  await page.click("#calendar-date-change-dates-add");
  await page.fill("#calendar-date-change-dates-date-add", second);
  await expect(page.locator(`#calendar-date-change-dates-chip-${first}`)).toBeVisible();
  await page.click("#calendar-date-change-dates-add");
  await expect(page.locator(`#calendar-date-change-dates-chip-${second}`)).toBeVisible();
  await page.uncheck("#calendar-date-change-remove-CAL_SCHOOL input");
  const unusedRemoval = page.locator("#calendar-date-change-remove-CAL_UNUSED input");
  if (await unusedRemoval.count()) await unusedRemoval.uncheck();
  await uncheckFixtureCalendars(page, [first, second]);
  await page.click("#calendar-date-change-review");
  await expect(page.locator("#calendar-date-change-review-panel")).toBeVisible();

  // A second ordinary editor changes the source after review, causing a real
  // rejected write. The database and domain writer are not mocked.
  const other = await context.newPage();
  await openEditorFor(other, versionId, "CAL_DAILY");
  await other.fill("#calendar-name", "Every day service updated");
  await other.click("#calendar-save");
  await expect(other.locator("#calendar-status")).toContainText("Saved");

  holdApply = true;
  await page.click("#calendar-date-change-apply");
  await expect.poll(() => held !== null).toBe(true);
  await expect(page.locator("#calendar-date-change-apply")).toBeDisabled();
  await expect(page.locator("#calendar-date-change-apply")).toContainText("Applying");
  await expect(page.locator("#calendar-date-change-drawer-close")).toBeDisabled();
  await expect(page.locator("#calendar-date-change-form")).toHaveAttribute("inert", "");
  await page.keyboard.press("Escape");
  await expect(page.locator("#calendar-date-change-drawer")).toBeVisible();
  holdApply = false;
  held();
  await expect(page.locator("#calendar-date-change-error")).toContainText("changed in another session");
  await page.click("#calendar-date-change-refresh");
  await page.click("#calendar-date-change-review");
  await expect(page.locator("#calendar-date-change-review-panel")).toContainText("Every day service updated");

  await page.click("#calendar-date-change-apply");
  await expect(page.locator("#calendars-date-change-status")).toContainText("Applied the date change");
  await page.click("#calendar-date-change");
  await waitForDrawerReady(page);

  // Disconnect only this client's transport; no shared server/database stop.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator("#calendar-date-change-drawer")).toBeHidden();
  await page.evaluate(() => window.liveSocket.connect());
  await expect(page.locator("#calendars-list-container")).toBeVisible();

  await openEditorFor(other, versionId, "CAL_DAILY");
  for (const date of [first, second]) {
    await expect(other.locator(`#calendar-exception-chips-${date}`)).toContainText("No service");
    await other.click(`#calendar-exception-chips-remove-${date}`);
    await expect(other.locator("#calendar-status")).toContainText("Regular schedule restored.");
  }
  await other.fill("#calendar-name", "Every day service");
  await other.click("#calendar-save");
  await expect(other.locator("#calendar-status")).toContainText("Saved");
  await other.close();

  await openEditorFor(page, versionId, "CAL_DAILY");
  await page.fill("#calendar-name", "School days");
  await page.click("#calendar-save");
  await expect(page.locator("#calendar-name")).toHaveValue("School days");
  await expect(page.locator("#calendar-name")).toHaveAttribute("aria-invalid", "true");
  await page.fill("#calendar-name", "Every day service");
  await page.click("#calendar-save");
  await expect(page.locator("#calendar-status")).toContainText("No change was needed");
  await page.fill("#calendar-name", "Unsaved draft");
  await expect(page.locator("#calendar-editor")).toHaveAttribute("data-dirty", "true");
  await page.locator('#calendar-editor nav a').click();
  await expect(page.locator("#calendar-dirty-dialog")).toBeVisible();
  await page.locator('#calendar-dirty-dialog [data-dialog-dismiss]').click();
  await expect(page.locator("#calendar-name")).toHaveValue("Unsaved draft");
  await page.evaluate(() => {
    const event = new Event("beforeunload", {cancelable: true});
    window.dispatchEvent(event);
    if (!event.defaultPrevented) throw new Error("dirty unload was not guarded");
  });
});


test("browser Back and Forward require explicit discard and cancellation retains the draft", async ({page}) => {
  const versionId = await openCalendars(page);
  const listUrl = page.url();
  await page.locator("#calendars-list [data-calendar-link='CAL_SCHOOL']").click();
  await waitForEditorReady(page);
  const editorUrl = page.url();
  await page.fill("#calendar-name", "History draft");
  await expect(page.locator("#calendar-editor")).toHaveAttribute("data-dirty", "true");
  const cancel = async dialog => { expect(dialog.message()).toContain("Discard unsaved"); await dialog.dismiss(); };
  page.once("dialog", cancel);
  await page.evaluate(() => history.back());
  await expect(page).toHaveURL(editorUrl);
  await expect(page.locator("#calendar-name")).toHaveValue("History draft");
  page.once("dialog", dialog => dialog.accept());
  await page.evaluate(() => history.back());
  await expect(page).toHaveURL(listUrl);
  await expect(page.locator("#calendars-list-container")).toBeVisible();
  await page.goForward();
  await waitForEditorReady(page);
  await expect(page.locator("#calendar-name")).toHaveValue("School days");

  // Create a forward destination by leaving cleanly and returning with Back.
  await page.locator("#calendar-editor nav a").click();
  await expect(page.locator("#calendars-list-container")).toBeVisible();
  await page.goBack();
  await waitForEditorReady(page);
  await page.fill("#calendar-name", "Forward draft");
  await expect(page.locator("#calendar-editor")).toHaveAttribute("data-dirty", "true");
  page.once("dialog", cancel);
  await page.evaluate(() => history.forward());
  await expect(page).toHaveURL(editorUrl);
  await expect(page.locator("#calendar-name")).toHaveValue("Forward draft");
  page.once("dialog", dialog => dialog.accept());
  await page.evaluate(() => history.forward());
  await expect(page.locator("#calendars-list-container")).toBeVisible();
  expect(page.url()).toContain(`/gtfs/${versionId}/calendars`);
});

// The list and the combination selection it now carries are one surface: these two journeys read
// them at every supported width and across versions, without writing anything.

async function switchVersionTo(page, versionName) {
  await page.locator("#gtfs-version-trigger").click();
  await page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName })
    .click();
  await page.waitForURL(/\/gtfs\/[0-9a-f-]+\/calendars/);
  await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
}

test("switches versions on the list and keeps each version's own identities", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  const versionId = await openCalendars(page);

  // Row identity comes from the semantic detail link, whose attribute is the exact service ID.
  await expect(
    page.locator("#calendars-list [data-calendar-link]"),
  ).toHaveCount(SEEDED_COUNT);
  await expect(
    page.locator('#calendars-list [data-calendar-link="CAL_DAILY"]'),
  ).toBeVisible();
  await expect(
    page.locator('#calendars-list [data-calendar-link="DETAIL_SCHOOL"]'),
  ).toHaveCount(0);

  // Switching versions reloads the list for the version the panel names, with that version's own
  // scoped identities and no row from the version left behind (AC-2). The unreadable imported
  // identity still keeps its row, but it is not selectable and has no detail link.
  await switchVersionTo(page, "Browser Calendar Details");
  const detailsVersionId = new URL(page.url()).pathname.split("/")[2];
  expect(detailsVersionId).not.toBe(versionId);
  await expect(page.locator("#calendars-list tr")).toHaveCount(4);
  await expect(
    page.locator("#calendars-list [data-calendar-link]"),
  ).toHaveCount(3);
  await expect(
    page.locator('#calendars-list [data-calendar-link="DETAIL_SCHOOL"]'),
  ).toBeVisible();
  await expect(page.locator("#calendar-select-DETAIL_REVERSED")).toBeDisabled();
  await expect(
    page.locator('#calendars-list [data-calendar-link="CAL_DAILY"]'),
  ).toHaveCount(0);

  // Switching back reads the first version's rows again rather than caching the second's.
  await switchVersionTo(page, "Browser E2E Version");
  expect(new URL(page.url()).pathname).toContain(
    `/gtfs/${versionId}/calendars`,
  );
  await expect(
    page.locator("#calendars-list [data-calendar-link]"),
  ).toHaveCount(SEEDED_COUNT);
  await expect(
    page.locator('#calendars-list [data-calendar-link="CAL_DAILY"]'),
  ).toBeVisible();
});

test("keeps the list and its selection controls labelled, keyboard reachable and overflow-free at every supported width", async ({
  page,
}) => {
  const versionId = await openCalendars(page);

  for (const viewport of [
    { width: 1440, height: 1000 },
    { width: 1024, height: 900 },
    { width: 390, height: 844 },
    { width: 320, height: 800 },
  ]) {
    await page.setViewportSize(viewport);
    await page.goto(`/gtfs/${versionId}/calendars`);
    await page.waitForSelector("#calendars-list-container", { timeout: 15000 });

    // Every control the list offers takes focus where it stands, including the combination's own
    // select-all control.
    for (const id of [
      "#calendar-search",
      "#calendar-status",
      "#calendar-date-change",
      "#calendars-create",
      "#calendar-select-all",
    ]) {
      await page.locator(id).focus();
      await expect(page.locator(id)).toBeFocused();
    }

    // The sort control is a labelled button inside its own column header, and both selection
    // controls name the calendars they act on.
    const sortButton = page
      .locator("#calendars-list-container thead th button")
      .first();
    await sortButton.focus();
    await expect(sortButton).toBeFocused();
    await expect(page.locator("#calendar-select-all")).toHaveAttribute(
      "aria-label",
      /calendar/i,
    );
    await expect(page.locator("#calendar-select-CAL_UNUSED")).toHaveAttribute(
      "aria-label",
      "Select Unused calendar",
    );

    // The page never scrolls sideways at any supported width.
    expect(
      await page.evaluate(
        () => document.body.scrollWidth <= window.innerWidth + 1,
      ),
    ).toBe(true);
  }
});
