import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Timetable assistance (AI-04): the reviewed-source controls on the existing
 * Paste page (step 3) and the prepared-batch handoff (step 5).
 *
 * `#timetable-source-form` sits beside `#paste-form` and records what the
 * copied table means — where it came from, which dates it covers and what it
 * did not settle — without touching what the native paste writes. The
 * mapping is never entered twice: the Columns step's Use-as selects are what
 * the accepted source is built from.
 *
 * The journey runs on the ordinary page through normal login and Paste
 * navigation against the seeded `BROWSER_PASTE` route. Captures land in the
 * canonical spec evidence folder; override with `AI04_CAPTURE_DIR`.
 *
 * Step 5's `native batches` journey drives the real helper: the panel reads
 * the accepted source, prepares a batch and hands it to the page's own native
 * review, which is applied independently of the rows no batch has covered. The
 * only scripted boundary is the provider HTTP, through
 * `GtfsPlanner.Agents.BrowserOpenRouter`; the pack, the dispatch fence, the
 * host re-prepare and the native apply are all production.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const PASTE_ROUTE = "BROWSER_PASTE";

const CAPTURE_DIR =
  process.env.AI04_CAPTURE_DIR ||
  resolve(
    import.meta.dirname,
    "..",
    "test-results",
    "captures",
    "ai-04-timetable-assistance",
  );

// Two rows whose first departure matches exactly one seeded feed trip each
// (BPS_1201 at 06:00 and BPS_1205 at 07:00), on the pattern's first three
// stops.
const EXACT_PASTE = [
  "Trip\tCentral Station\tMarket Street\tOak & 3rd\tMill Street\tLibrary\tHospital\tRiver Park\tRiverside Terminal",
  "1201\t06:00\t06:03\t06:06\t06:10\t06:14\t06:18\t06:24\t06:28",
  "1203\t07:00\t07:03\t07:06\t07:10\t07:14\t07:18\t07:24\t07:28",
].join("\n");

// 2026-11-02 through 2026-11-30 holds 21 ISO weekdays and Thanksgiving is
// Thursday 2026-11-26, so the reviewed source covers exactly 20 dates.
const FIRST_DATE = "2026-11-02";
const LAST_DATE = "2026-11-30";
const THANKSGIVING = "2026-11-26";

// The seeded `BPS-SCHOOL` pattern ("Central Station → Hospital via Northside
// School", Typical offsets 0/180/360/600/900/1140/1380) carries two listed
// Weekday trips, `BPS_1301` at 06:10 and `BPS_1303` at 07:10, and one
// frequency template, `BPS_1400` at 08:00. These two rows name each listed
// trip exactly once, by the only departure the reader can resolve.
const SCHOOL_PATTERN = "Central Station → Hospital via Northside School";
const SCHOOL_PASTE = [
  "Trip\tCentral Station\tMarket Street\tOak & 3rd\tMill Street\tNorthside School\tLibrary\tHospital",
  "1301\t06:10\t06:13\t06:16\t06:20\t06:25\t06:29\t06:33",
  "1303\t07:10\t07:13\t07:16\t07:20\t07:25\t07:29\t07:33",
].join("\n");

// 2026-12-21 through 2026-12-31 holds nine ISO weekdays, and the seeded
// Christmas Eve exception removes Thursday 2026-12-24, so the feed runs eight
// of them: 21, 22, 23, 25, 28, 29, 30 and 31.
const WINTER_FIRST = "2026-12-21";
const WINTER_LAST = "2026-12-31";
// The four school dates the editor supplies: two the feed runs (22 and 23),
// the date the feed removed (24) and the Saturday no weekday rule would have
// produced (26). A school policy uses exactly these and nothing else.
const WINTER_SCHOOL_DATES = "2026-12-22, 2026-12-23, 2026-12-24, 2026-12-26";

// A column the reader cannot read. Its words are not a time, so the source is
// accepted with the column disclosed rather than read as a departure, and the
// comparison can never read clean while it stands.
const UNREADABLE_PASTE = [
  "Trip\tCentral Station\tMarket Street\tOak & 3rd\tMill Street\tLibrary\tHospital\tRiver Park\tRiverside Terminal\tDispatch",
  "1201\t06:00\t06:03\t06:06\t06:10\t06:14\t06:18\t06:24\t06:28\twhenever the driver is back",
  "1203\t07:00\t07:03\t07:06\t07:10\t07:14\t07:18\t07:24\t07:28\tas posted",
].join("\n");

// The same table with one dispatcher note long enough that the pasted text
// alone passes the 65,536-byte helper ceiling while it stays inside the native
// paste's own 204,800-byte, 500-row and 150-column bounds.
const LONG_NOTE = "dispatcher note ".repeat(2500);
const OVER_CAP_PASTE = [
  "Trip\tCentral Station\tMarket Street\tOak & 3rd\tMill Street\tLibrary\tHospital\tRiver Park\tRiverside Terminal\tDispatcher note",
  `1201\t06:00\t06:03\t06:06\t06:10\t06:14\t06:18\t06:24\t06:28\t${LONG_NOTE}`,
  `1203\t07:00\t07:03\t07:06\t07:10\t07:14\t07:18\t07:24\t07:28\t${LONG_NOTE}`,
].join("\n");

async function capture(page, name) {
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, `${name}.png`),
    fullPage: false,
    animations: "disabled",
  });
}

// The flash is a fixed top-right toast that sits over the helper column. It
// is dismissed through its own control so the capture shows the batch card
// and the panel beside it rather than a toast across the panel header.
async function dismissFlash(page) {
  const dismiss = page.locator('#flash-info button[aria-label="Dismiss message"]');
  if ((await dismiss.count()) > 0) await dismiss.click();
}

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

function pastePath(versionId, routeId) {
  return `/gtfs/${versionId}/routes/${routeId}/schedules/paste`;
}

async function readPaste(page, versionId, text) {
  await page.goto(pastePath(versionId, PASTE_ROUTE));
  await readText(page, text);
}

// Reads the pasted table with the page's own Read control, on whichever
// schedule scope the page currently holds.
async function readText(page, text) {
  await page.fill("#paste-source", text);
  await page.click("#paste-read");
  await expect(page.locator("#paste-review")).toBeVisible();
  await expect(page.locator("#timetable-source-form")).toBeVisible();
}

// The page's own Change schedule drawer, which is how an editor reaches a
// pattern other than the one the paste page resolves for itself.
async function usePattern(page, patternName) {
  await page.click("#paste-scope-open");
  await expect(page.locator("#paste-scope-drawer")).toBeVisible();
  // The drawer labels each option with the pattern's own name and its trip
  // count, so the option is found by its name and its own value is used.
  const value = await page
    .locator("#paste-scope-pattern-field option")
    .filter({ hasText: patternName })
    .first()
    .getAttribute("value");
  await page.selectOption("#paste-scope-pattern-field", value);
  await page.click("#paste-scope-apply");
  await expect(page.locator("#paste-scope-drawer")).toBeHidden();
  await expect(page.locator("#paste-scope-pattern")).toContainText(patternName);
}

// Whether the element the server pushed focus to holds it: acceptance and
// every refusal announce themselves in a live region, so a journey that
// ignored focus would pass on a page a keyboard cannot use.
async function focusIsInside(page, id) {
  return page.evaluate((target) => {
    const el = document.getElementById(target);
    const active = document.activeElement;
    return Boolean(el && (el === active || el.contains(active)));
  }, id);
}

async function fillSource(page, values) {
  await page.fill("#timetable-source-label", values.label ?? "");
  await page.fill("#timetable-source-revision", values.revision ?? "");
  await page.fill("#timetable-source-notes", values.notes ?? "");
  await page.fill(
    "#timetable-source-first-date",
    values.firstDate ?? FIRST_DATE,
  );
  await page.fill("#timetable-source-last-date", values.lastDate ?? LAST_DATE);
  await page.fill("#timetable-source-removed-dates", values.removedDates ?? "");

  // The policy decides whether the school dates field exists, so it goes
  // first and the list is only filled once the control is on the page.
  await page.selectOption(
    "#timetable-source-policy",
    values.policy ?? "weekly",
  );

  if (values.schoolDates !== undefined) {
    await page.fill("#timetable-source-school-dates", values.schoolDates);
  }

  if (values.confirm) {
    await page.check("#timetable-source-confirm");
  } else {
    await page.uncheck("#timetable-source-confirm");
  }
}

test.describe("reviewed source", () => {
  test("source review accepts the reviewed dates and shows their provenance", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      revision: "rev 3",
      notes: "Thanksgiving is not served.",
      removedDates: THANKSGIVING,
      confirm: true,
    });

    await page.click("#timetable-source-accept");

    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "Riverside printed table · rev 3",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "20 service dates",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "in 2026-11-02 – 2026-11-30",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );
    await expect(page.locator("#timetable-source-errors")).toHaveCount(0);
    await expect(page.locator("#timetable-helper-too-large")).toHaveCount(0);

    // The native paste is untouched by any of it.
    await expect(page.locator("#paste-form")).toBeVisible();
    await expect(page.locator("#paste-source-summary")).toContainText(
      "trip rows",
    );
  });

  test("source review keeps an unreviewed school policy unresolved with the input", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    await fillSource(page, {
      notes: "School starts after Thanksgiving.",
      policy: "school",
      confirm: true,
    });

    await page.click("#timetable-source-accept");

    await expect(page.locator("#timetable-source-unresolved")).toContainText(
      "were not supplied, so nothing was assumed",
    );
    await expect(page.locator("#timetable-source-accepted")).toHaveCount(0);
    await expect(page.locator("#timetable-source-notes")).toHaveValue(
      /School starts after/,
    );
    await expect(page.locator("#paste-form")).toBeVisible();

    await page.locator("#timetable-source").scrollIntoViewIfNeeded();
    await capture(page, "source-unresolved-1440");
  });

  test("source review refuses a reversed interval inline and keeps the notes", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    // A date control cannot hold an impossible date, so the browser case is
    // the interval that runs backwards.
    await fillSource(page, {
      lastDate: "2026-10-01",
      notes: "Still here.",
      confirm: true,
    });
    await page.click("#timetable-source-accept");

    await expect(page.locator("#timetable-source-errors")).toContainText(
      "The last date must not precede first_date",
    );
    await expect(page.locator("#timetable-source-last-date")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#timetable-source-accepted")).toHaveCount(0);
    await expect(page.locator("#timetable-source-notes")).toHaveValue(
      /Still here/,
    );
  });

  test("source review releases an accepted source when its notes change", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");
    await expect(page.locator("#timetable-source-accepted")).toBeVisible();

    await page.fill(
      "#timetable-source-notes",
      "Corrected after the holiday list changed.",
    );
    await expect(page.locator("#timetable-source-accepted")).toHaveCount(0);
    await expect(page.locator("#timetable-source-notes")).toHaveValue(
      /Corrected after/,
    );

    // The copied timetable and its review are still exactly as they were.
    await expect(page.locator("#paste-form")).toBeVisible();
    await expect(page.locator("#paste-review")).toBeVisible();
  });

  test("source review fits the accepted state at 1440 and at 320", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      revision: "rev 3",
      notes: "Thanksgiving is not served.",
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.locator("#timetable-source").scrollIntoViewIfNeeded();
    await capture(page, "source-form-1440");

    await page.click("#timetable-source-accept");
    await expect(page.locator("#timetable-source-accepted")).toBeVisible();

    await page
      .locator("#timetable-source")
      .evaluate((el) => el.scrollIntoView({ block: "start" }));
    await capture(page, "source-card-1440");

    await page.locator("#timetable-source").scrollIntoViewIfNeeded();
    await capture(page, "source-accepted-1440");

    await page.setViewportSize({ width: 320, height: 800 });
    await page.locator("#timetable-source").scrollIntoViewIfNeeded();
    await capture(page, "source-accepted-320");

    // The narrow layout must not scroll sideways.
    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth -
        document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});

// Step 9: the comparison is the page's own read-only task, so every journey
// here drives it through `Compare timetable` on the Paste page and never asks
// the helper for it. They run before `native batches` because that journey
// saves real trips on this pattern, which a later comparison would read as
// feed rows the source never named.
test.describe("provider-independent comparison", () => {
  test("compares the supplied school dates with the feed's own holiday exception while the helper is unavailable", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    // The editor supplies the exact school dates, so the source is those four
    // dates and not the interval's weekdays: 2026-12-26 is a Saturday and
    // 2026-12-24 is a date the feed removed.
    await fillSource(page, {
      label: "Winter school sheet",
      revision: "rev 1",
      notes: "Term sheet; Christmas Eve is not run.",
      firstDate: WINTER_FIRST,
      lastDate: WINTER_LAST,
      policy: "school",
      schoolDates: WINTER_SCHOOL_DATES,
      confirm: true,
    });
    await page.click("#timetable-source-accept");

    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "4 service dates",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "in 2026-12-21 – 2026-12-31",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );
    // Nothing is outstanding about a source whose dates were supplied, and
    // acceptance announces itself in the live region it focuses.
    await expect(page.locator("#timetable-source-unresolved")).toHaveCount(0);
    expect(await focusIsInside(page, "timetable-source-state")).toBe(true);

    // The provider is not reachable in this run: the panel's own failure is
    // the scripted 401, and the page's comparison is untouched by it.
    await openHelper(page);
    await page.fill("#agent-composer-input", "Is the provider key still valid?");
    await page.click("#agent-send");
    await expect(page.locator("#agent-entries")).toContainText(
      "The helper is unavailable right now.",
      { timeout: 30_000 },
    );
    await expect(page.locator("#agent-status")).toHaveCount(1);
    await page.click("#agent-panel-close");
    await expect(page.locator("#agent-helper-open")).toBeFocused();

    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "This comparison found differences.",
    );

    // Two mapped rows on the two dates the feed runs and the sheet names (22
    // and 23): four matched pairs. Each mapped row also carries six dates the
    // feed runs and the sheet omits (21, 25, 28, 29, 30, 31) and two it names
    // and the feed does not run (the removed Christmas Eve and the Saturday),
    // so each contributes six missing, two extra and eight date differences;
    // the five unmapped outbound trips add eight missing dates each.
    await expect(page.locator("#timetable-comparison-total-matched")).toHaveText(
      "Matched 4 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-missing")).toHaveText(
      "Missing from the feed 52 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-extra")).toHaveText(
      "Not in the table 4 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-time_mismatch")).toHaveText(
      "Different times 0 source cell, event and date comparisons",
    );
    await expect(page.locator("#timetable-comparison-total-date_mismatch")).toHaveText(
      "Different dates 16 mapped trip and source row date differences",
    );

    // The calculation was complete and nothing was excluded, so this is a
    // difference report rather than an unreadable one — and it is still not
    // clean, because the categories above are not zero.
    await expect(page.locator("#timetable-comparison-unresolved")).toHaveCount(0);
    await expect(page.locator("#timetable-comparison-clean")).toHaveCount(0);

    await dismissFlash(page);
    await page
      .locator("#timetable-comparison")
      .evaluate((el) => el.scrollIntoView({ block: "start" }));
    await capture(page, "comparison-differences-1440");

    await page.setViewportSize({ width: 320, height: 800 });
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.locator("#timetable-comparison").scrollIntoViewIfNeeded();
    await capture(page, "comparison-differences-320");
    await page.setViewportSize({ width: 1440, height: 1000 });

    expect(consoleErrors).toEqual([]);
  });

  test("discloses a frequency template instead of reading it as a match or a difference", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    // The school pattern is not the one this page resolves for itself, so it
    // is reached through the page's own Change schedule drawer.
    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await usePattern(page, SCHOOL_PATTERN);
    await readText(page, SCHOOL_PASTE);

    await fillSource(page, {
      label: "Northside school sheet",
      firstDate: FIRST_DATE,
      lastDate: LAST_DATE,
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "20 service dates",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );

    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();

    // The pattern carries two listed trips and one frequency template. Both
    // listed trips are named, so forty pairs match over the twenty dates the
    // source reviews, and the only feed pairs left over are the two named
    // trips on Thanksgiving, which the feed runs and this source does not.
    // The template is neither: it is disclosed once as an unresolved item and
    // once as an exclusion, so the report can never read clean.
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "This comparison could not be read as a match.",
    );
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "4 differences",
    );
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "1 item(s) remain unresolved",
    );
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "1 item(s) are excluded",
    );
    await expect(page.locator("#timetable-comparison-total-matched")).toHaveText(
      "Matched 40 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-missing")).toHaveText(
      "Missing from the feed 2 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-extra")).toHaveText(
      "Not in the table 0 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-date_mismatch")).toHaveText(
      "Different dates 2 mapped trip and source row date differences",
    );
    await expect(page.locator("#timetable-comparison-unresolved")).toContainText(
      "frequency_template",
    );
    await expect(page.locator("#timetable-comparison-unresolved")).toContainText(
      "BPS_1400",
    );
    await expect(page.locator("#timetable-comparison-clean")).toHaveCount(0);

    await dismissFlash(page);
    await page
      .locator("#timetable-comparison")
      .evaluate((el) => el.scrollIntoView({ block: "start" }));
    await capture(page, "comparison-incomplete-1440");

    await page.setViewportSize({ width: 320, height: 800 });
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.locator("#timetable-comparison").scrollIntoViewIfNeeded();
    await capture(page, "comparison-incomplete-320");

    expect(consoleErrors).toEqual([]);
  });

  test("keeps a column the grammar cannot read disclosed and the comparison honest", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, UNREADABLE_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      firstDate: FIRST_DATE,
      lastDate: LAST_DATE,
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");

    // The two rows still map, so the source is accepted; the dispatch notes
    // are not times, so both rows carry the column as an unresolved item and
    // the accepted card says so instead of dropping the text.
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );
    await expect(page.locator("#timetable-source-unresolved")).toContainText(
      "Row 1, column J holds text the grammar does not read",
    );
    await expect(page.locator("#timetable-source-unresolved")).toContainText(
      "Row 2, column J holds text the grammar does not read",
    );

    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();
    await expect(page.locator("#timetable-comparison-differences")).toContainText(
      "2 item(s) remain unresolved",
    );

    // The numbers are the same November ones the clean table reads: forty
    // pairs match over the twenty reviewed dates and the remaining 107 pairs
    // the feed describes are disclosed, because the unreadable column changed
    // nothing that could be compared.
    await expect(page.locator("#timetable-comparison-total-matched")).toHaveText(
      "Matched 40 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-missing")).toHaveText(
      "Missing from the feed 107 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-unresolved")).toContainText(
      "unsupported_column",
    );
    await expect(page.locator("#timetable-comparison-clean")).toHaveCount(0);

    expect(consoleErrors).toEqual([]);
  });

  test("refuses the helper attachment for an over-cap source and leaves the paste and the comparison alone", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, OVER_CAP_PASTE);

    // The pasted text is 85,000 bytes: past the helper's 65,536-byte ceiling
    // and well inside the native paste's own 204,800-byte bound.
    const bytes = Buffer.byteLength(OVER_CAP_PASTE, "utf8");
    expect(bytes).toBeGreaterThan(65_536);
    expect(bytes).toBeLessThan(204_800);

    await fillSource(page, {
      label: "Riverside printed table with the dispatch notes",
      firstDate: FIRST_DATE,
      lastDate: LAST_DATE,
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");

    // The helper is refused, not the paste: the accepted source, the pasted
    // text and the review are exactly as they were.
    await expect(page.locator("#timetable-helper-too-large")).toBeVisible();
    await expect(page.locator("#timetable-helper-too-large")).toContainText(
      "It is larger than the helper accepts, so nothing was attached.",
    );
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );
    await expect(page.locator("#timetable-source-errors")).toHaveCount(0);
    await expect(page.locator("#paste-form")).toBeVisible();
    await expect(page.locator("#paste-review")).toBeVisible();
    await expect(page.locator("#paste-apply")).toBeVisible();

    // The comparison reads the accepted source rather than the helper's copy
    // of it, so it still answers exactly as the same table without the notes
    // does.
    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();
    await expect(page.locator("#timetable-comparison-total-matched")).toHaveText(
      "Matched 40 trip-date pairs",
    );
    await expect(page.locator("#timetable-comparison-total-missing")).toHaveText(
      "Missing from the feed 107 trip-date pairs",
    );

    expect(consoleErrors).toEqual([]);
  });
});

// The seeded `BROWSER_PASTE` outbound trips run 06:00 through 09:00 on the
// Weekday calendar with the pattern's Typical offsets, so these two rows
// resolve to `BPS_1201` and `BPS_1205` and the review plans them as
// duplicates. "Add anyway" is the page's own decision for that, so the
// journey's save is a real write on the seeded route rather than a
// fixture-only plan.
const BATCH_PASTE = EXACT_PASTE;

// Collects every console error and page error for the length of one test, so
// a capture can never be taken over a broken page.
function watchConsoleErrors(page) {
  const errors = [];
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(String(error)));
  return errors;
}

async function openHelper(page) {
  await page.click("#agent-helper-open");
  await expect(page.locator("#agent-panel")).toBeVisible();
  await expect(page.locator("#agent-composer-input")).toBeFocused();
  // A conversation from an earlier test persists for this user and version.
  await page.click("#agent-new-conversation");
}

// Sends one message and returns the entry id of the batch card that message
// produced. An earlier card can still be on screen offering its own review
// action, so the new card is found by the id that was not there before, never
// by position.
async function prepareBatch(page, message) {
  const before = await page
    .locator('[id^="agent-review-prepared-"]')
    .evaluateAll((els) => els.map((el) => el.id));

  await page.fill("#agent-composer-input", message);
  await page.click("#agent-send");

  let entryId = null;
  await expect
    .poll(
      async () => {
        const now = await page
          .locator('[id^="agent-review-prepared-"]')
          .evaluateAll((els) => els.map((el) => el.id));
        const fresh = now.find(
          (id) => !before.includes(id) && !entryId,
        );
        if (fresh) {
          entryId = fresh.replace("agent-review-prepared-", "");
        }
        return entryId;
      },
      { timeout: 30_000 },
    )
    .not.toBeNull();

  return {
    review: page.locator(`#agent-review-prepared-${entryId}`),
    card: page.locator(`#agent-prepared-${entryId}`),
    entryId,
  };
}



// The totals live outside the streamed witness rows, so their absence is what
// says the report was withdrawn.
function refuteComparisonTotals(page) {
  return page.locator("#timetable-comparison-totals").count().then((n) => n === 0);
}

test.describe("approved comparison", () => {
  test("the comparison states the server's own totals, pages its witnesses and is withdrawn when the source is edited", async ({
    page,
  }) => {
    // No write is performed by this journey: comparing reads the route's feed
    // and the source edit below only changes the reviewed source, so the
    // seeded route is the same one the next run compares.
    test.setTimeout(120_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, EXACT_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      revision: "rev 4",
      notes: "Thanksgiving is not served.",
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );

    // The comparison is the page's own task and reads only the accepted
    // source, so the helper panel is never opened.
    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();

    // The comparison is scoped to the one pattern the accepted source maps, and
    // that pattern carries the seven seeded outbound weekday trips. Each runs
    // on the 21 feed weekdays the interval holds, so the feed describes 147
    // trip-date pairs; the source names two trips on the 20 dates it reviews,
    // which match, and the other 107 pairs are disclosed as missing rather
    // than hidden behind an all-clear. The two named trips on Thanksgiving
    // are part of those 107: the feed runs that date and the source does not.
    await expect(page.locator("#timetable-comparison-total-matched")).toContainText(
      "40",
    );
    await expect(page.locator("#timetable-comparison-total-missing")).toContainText(
      "107",
    );

    // One page holds fifty witnesses and the page says which of the retained
    // sample it is showing, so a bounded sample never reads as all of it.
    await expect(page.locator("#timetable-comparison-rows tr")).toHaveCount(50);
    await expect(page.locator("#timetable-comparison-sample")).toContainText(
      "50 shown on page 1",
    );
    await page.click("#timetable-comparison-next");
    await expect(page.locator("#timetable-comparison-sample")).toContainText(
      "50 shown on page 2",
    );

    // The retained sample is 107 witnesses, so a third page holds the last 7.
    await page.click("#timetable-comparison-next");
    await expect(page.locator("#timetable-comparison-rows tr")).toHaveCount(7);
    await expect(page.locator("#timetable-comparison-next")).toHaveCount(0);

    // Freshness is the server's own re-read of the feed digest. Nothing wrote
    // to this route, so the report stays ready and the page says when it was
    // last checked rather than claiming to be current forever.
    await page.click("#timetable-comparison-freshness");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();
    await expect(page.locator("#timetable-comparison-checked")).toContainText(
      "checked just now",
    );

    // The card sits under the reviewed-source form, so it is scrolled into
    // view before each capture: a shot of the source form alone would not show
    // the totals or a single witness.
    await dismissFlash(page);
    await page.locator("#timetable-comparison").scrollIntoViewIfNeeded();
    await capture(page, "comparison-differences-incomplete-stale-1440");

    // The narrow viewport keeps the totals, the disclosure and the witness
    // table legible rather than pushing them off the page.
    await page.setViewportSize({ width: 320, height: 800 });
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.locator("#timetable-comparison").scrollIntoViewIfNeeded();
    await capture(page, "comparison-differences-incomplete-stale-320");
    await page.setViewportSize({ width: 1440, height: 1000 });

    // Editing the reviewed source invalidates the report on that keystroke:
    // the source is the other half of the comparison, so the numbers are
    // withdrawn rather than left looking current. The stale notices a committed
    // feed change produces are exercised in the ExUnit file, which can commit
    // a trip; this journey writes nothing.
    await page.fill(
      "#timetable-source-notes",
      "Thanksgiving is not served; Friday corrected.",
    );
    await expect(page.locator("#timetable-comparison")).toContainText(
      "Accept the reviewed source above before comparing it with the feed.",
    );
    refuteComparisonTotals(page);

    expect(consoleErrors).toEqual([]);
  });
});

test.describe("native batches", () => {
  test("a prepared batch reviews, saves and leaves the rest of the source unsaved", async ({
    page,
  }) => {
    // Two real saves, two full viewport captures and a refused second calendar
    // on a shared seed.
    test.setTimeout(180_000);
    const consoleErrors = watchConsoleErrors(page);

    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");
    await readPaste(page, versionId, BATCH_PASTE);

    await fillSource(page, {
      label: "Riverside printed table",
      revision: "rev 3",
      notes: "Thanksgiving is not served.",
      removedDates: THANKSGIVING,
      confirm: true,
    });
    await page.click("#timetable-source-accept");
    await expect(page.locator("#timetable-source-accepted")).toContainText(
      "2 mapped rows",
    );

    // The comparison runs first, on this same page, so the save below has a
    // report to move on from: a native write is what makes a report stale.
    await page.click("#timetable-compare");
    await expect(page.locator("#timetable-comparison-differences")).toBeVisible();
    await expect(page.locator("#timetable-comparison-stale")).toHaveCount(0);

    // The panel opens after the source is accepted, because the pack's own
    // precondition is an accepted source attached to this conversation.
    await openHelper(page);
    expect(await bodyFitsViewport(page)).toBe(true);

    const {
      review: first,
      card: firstCard,
      entryId: firstId,
    } = await prepareBatch(page, "Prepare outbound row 1 for this calendar");

    // The card is a proposal with the server's own evidence above the model's
    // sentence, and this pack's action name.
    await expect(first).toHaveText("Review prepared batch");
    await expect(firstCard).toContainText("Ready to review");
    await expect(
      page.locator(`[id^="agent-evidence-${firstId}-"]`).first(),
    ).toBeVisible();
    // Nothing is a batch until its review is opened.
    await expect(page.locator("#timetable-batches")).toHaveCount(0);

    // The colocated `.PasteHelperFocus` hook lives on the page's own
    // persistent wrapper, so it survives the panel closing and reopening over
    // the paste's own review.
    await page.click("#agent-panel-close");
    await expect(page.locator("#agent-helper-open")).toBeFocused();
    await page.click("#agent-helper-open");
    await expect(page.locator("#agent-composer-input")).toBeFocused();
    await expect(first).toBeVisible();

    // Opening it is the host's own review, re-prepared from the accepted
    // source: the batch's single row, the native matrix and the native bar.
    // The panel's transcript is its own scroll region, so the card is
    // scrolled to the middle of it before the click.
    await first.evaluate((el) => el.scrollIntoView({ block: "center" }));
    await first.click();
    await expect(page.locator("#paste-review")).toBeVisible();
    await expect(page.locator("#timetable-batches")).toBeVisible();
    await expect(page.locator(`#timetable-batch-${firstId}`)).toContainText(
      "Under review",
    );
    await expect(page.locator("#timetable-batches-unsaved")).toContainText(
      "2 source rows are still unsaved",
    );
    // The batch's row repeats a seeded feed trip, so the native bar says so
    // rather than inviting a save that would change nothing.
    await expect(page.locator("#paste-apply-status")).toContainText(
      "Nothing to apply",
    );

    // "Add anyway" is the page's own decision for a duplicate row, so the
    // save below is a real write on the seeded route. The batch's own row is
    // the one that is not skipped, so the button is found by its own label
    // rather than by a row number the source happens to use.
    await page.locator("#paste-rows button", { hasText: "Add anyway" }).click();
    await expect(page.locator("#paste-apply")).toContainText("Apply 1 change");
    await page.click("#paste-apply");

    // One batch saved, one source row still unsaved, and the page stays here
    // so the next batch can be prepared from the same source.
    await expect(page.locator(`#timetable-batch-${firstId}`)).toContainText(
      "Saved",
    );
    await expect(page.locator("#timetable-batches-unsaved")).toContainText(
      "1 source row is still unsaved",
    );
    await expect(page.locator("#paste-review")).toBeVisible();
    await expect(page.locator("#timetable-source-accepted")).toBeVisible();

    // The save stands and the card says precisely why the prepared batch is
    // unconfirmed: "Add anyway" is a native edit, so this is the step's
    // edited-input outcome, observed in a real browser.
    await expect(page.locator("#agent-notice")).toContainText(
      "Your edited batch was saved",
    );

    // The flash names the partial save, then the batches card and the panel
    // beside it are captured without it across the panel header.
    await expect(page.locator("#flash-info")).toContainText(
      "1 of this source's rows are still unsaved",
    );

    await page
      .locator("#timetable-batches")
      .evaluate((el) => el.scrollIntoView({ block: "center" }));
    await dismissFlash(page);
    await expect(page.locator("#flash-info")).toHaveCount(0);
    await capture(page, "native-partial-save-1440");

    await page.setViewportSize({ width: 320, height: 800 });
    await page
      .locator("#timetable-batches")
      .evaluate((el) => el.scrollIntoView({ block: "center" }));
    await capture(page, "native-partial-save-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    // At this width the panel replaces the workspace above it, so the card
    // and the notice it produced are captured in their own place.
    await page
      .locator(`#agent-prepared-${firstId}`)
      .evaluate((el) => el.scrollIntoView({ block: "center" }));
    await expect(page.locator("#agent-notice")).toContainText(
      "Your edited batch was saved",
    );
    await capture(page, "native-helper-320");
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.setViewportSize({ width: 1440, height: 1000 });

    // The save above is what makes the comparison out of date: the feed it
    // read has moved on, so the page keeps the numbers beside a notice that
    // says exactly that rather than leaving them looking current.
    await expect(page.locator("#timetable-comparison-stale")).toContainText(
      "You saved a native change after this comparison ran",
    );
    await expect(page.locator("#timetable-comparison-totals")).toBeVisible();
    await page
      .locator("#timetable-comparison")
      .evaluate((el) => el.scrollIntoView({ block: "start" }));
    await capture(page, "comparison-stale-1440");

    await page.setViewportSize({ width: 320, height: 800 });
    expect(await bodyFitsViewport(page)).toBe(true);
    await page.locator("#timetable-comparison").scrollIntoViewIfNeeded();
    await capture(page, "comparison-stale-320");
    await page.setViewportSize({ width: 1440, height: 1000 });

    // A second calendar is a second call and a second confirmation, so a
    // message naming one this route does not run is refused by the pack
    // itself. The refusal rides back to the model as that tool's own result
    // rather than as a sentence the panel prints, so what the page shows is
    // that nothing was prepared: the saved batch stays saved, the second row
    // stays unsaved, and neither is replayed into a batch of its own.
    const preparedBefore = await page
      .locator('[id^="agent-review-prepared-"]')
      .evaluateAll((els) => els.map((el) => el.id));
    await page.fill(
      "#agent-composer-input",
      "Prepare outbound row 2 for calendar CAL_SCHOOL",
    );
    await page.click("#agent-send");
    await expect(page.locator("#agent-entries")).toContainText(
      "Prepare outbound row 2 for calendar CAL_SCHOOL",
      { timeout: 30_000 },
    );
    const refusedTurn = page.locator("#agent-entries article").last();
    await expect(refusedTurn).toContainText("Checked 3 steps", {
      timeout: 30_000,
    });
    await expect(page.locator('[id^="agent-review-prepared-"]')).toHaveCount(
      preparedBefore.length,
    );
    await expect(page.locator('[id^="timetable-batch-"]')).toHaveCount(1);
    await expect(page.locator(`#timetable-batch-${firstId}`)).toContainText(
      "Saved",
    );
    await expect(page.locator("#timetable-batches-unsaved")).toContainText(
      "1 source row is still unsaved",
    );

    // The second batch is prepared from the same accepted source, which the
    // panel still holds, and saves independently.
    const { review: second, entryId: secondId } = await prepareBatch(
      page,
      "Prepare outbound row 2 for this calendar",
    );

    // The first batch's card is still saved and unchanged, and the second
    // batch has not appeared on the page until its own review is opened.
    await expect(page.locator(`#timetable-batch-${firstId}`)).toContainText(
      "Saved",
    );
    await expect(page.locator(`#timetable-batch-${secondId}`)).toHaveCount(0);
    await expect(page.locator("#timetable-batches-unsaved")).toContainText(
      "1 source row is still unsaved",
    );

    await second.evaluate((el) => el.scrollIntoView({ block: "center" }));
    await second.click();
    await expect(page.locator(`#timetable-batch-${secondId}`)).toContainText(
      "Under review",
    );
    await page
      .locator("#paste-rows button", { hasText: "Add anyway" })
      .click();
    await expect(page.locator("#paste-apply")).toContainText("Apply 1 change");

    // Nothing of this source is left unsaved, so the page navigates to
    // Schedules exactly as an ordinary single-batch paste always has.
    await page.click("#paste-apply");
    await expect(page).toHaveURL(/\/schedules\?.*service_id=BPS_WKDY/);
    await expect(page.locator("#flash-info")).toContainText("Added 1 trip");
    await expect(page.locator("#flash-info")).not.toContainText(
      "still unsaved",
    );

    expect(consoleErrors).toEqual([]);
  });
});
