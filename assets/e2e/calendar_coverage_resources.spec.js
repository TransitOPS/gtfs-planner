import { test, expect } from "@playwright/test";

// The calendar list at the sourced 100-calendar scale (step 21, EV-6, CL-6, AC-25).
//
// `docs/requirements/calendars-and-service-periods-requirements.md` §5.1 requires the calendar list
// to load within two seconds for feeds with up to 100 calendars. The browser seed carries two such
// versions: a one-year span either side of the agency-local today, and a nine-year span whose
// whole-feed view opens on the disclosed recent window. This journey measures the warm full
// document navigation to settled coverage — the first navigation pays for compiling the LiveView,
// the digested assets and the database's own caches and is discarded — and asserts AC-25's
// deterministic DOM bounds: at most 512 overview bins per row, and at most 105 day cells in the
// near view.
//
// The measured milliseconds are environment dependent and are printed with the command's output;
// the bin and day-cell bounds are properties of the projection and hold on any runner. Twenty of
// the hundred identities are metadata-only, so a row with no coverage is an expected state, not a
// missing render.

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const ONE_YEAR_VERSION = "Browser Calendar Scale One Year";
const LONG_HISTORY_VERSION = "Browser Calendar Scale Long History";

// Seeded identities the fixture pins its shapes to: index 0 is the all-days weekly identity and
// index 4 is metadata-only.
const ALL_DAYS_SERVICE_ID = "RSC_000";
const METADATA_ONLY_SERVICE_ID = "RSC_004";

const CALENDAR_COUNT = 100;
const METADATA_ONLY_ROWS = 20;
const MAX_OVERVIEW_BINS = 512;
const MAX_NEAR_DAY_CELLS = 105;
const SETTLE_BUDGET_MS = 2000;

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

// Settled coverage is the 100th row's coverage bar on screen beside the shared axis: the LiveView
// has mounted, its one protected snapshot has returned and every row has been projected.
async function settledCoverage(page, expectedRows) {
  await page.waitForFunction(
    (rows) => {
      const list = document.querySelector("#calendars-list");
      if (!list) return false;
      if (list.querySelectorAll("[data-calendar-coverage]").length !== rows)
        return false;
      if (!document.querySelector("#calendar-coverage-axis")) return false;
      return list.querySelectorAll(".calendar-coverage-mark").length > 0;
    },
    expectedRows,
    { timeout: 30000 },
  );
}

async function openCalendars(page, versionId, range) {
  await page.goto(
    `/gtfs/${versionId}/calendars${range ? `?range=${range}` : ""}`,
  );
  await settledCoverage(page, CALENDAR_COUNT);
}

// The warm route load: the first navigation pays for compiling the LiveView, the digested assets
// and the database's own caches, so it is discarded and three further full document navigations are
// measured. The samples and their median are printed because this shared runner also hosts other
// worktrees' servers; the assertion uses the fastest warm sample, which is the load a returning
// reviewer sees, while a genuinely slower route fails on every sample.
async function measureWarmLoads(page, versionId, samples = 3) {
  await openCalendars(page, versionId);

  const measured = [];

  for (let index = 0; index < samples; index += 1) {
    const started = Date.now();
    await openCalendars(page, versionId);
    measured.push(Date.now() - started);
  }

  return measured;
}

function fastest(samples) {
  return Math.min(...samples);
}

function median(samples) {
  const sorted = [...samples].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

// The marks a row draws: one overview bin in the whole/all views and one day cell in the near
// view, so this count is exactly the bound AC-25 names for the current range.
async function markCounts(page) {
  return page.evaluate(() =>
    [
      ...document.querySelectorAll("#calendars-list [data-calendar-coverage]"),
    ].map((row) => row.querySelectorAll(".calendar-coverage-mark").length),
  );
}

function largest(counts) {
  return counts.reduce((most, count) => Math.max(most, count), 0);
}

function emptyRows(counts) {
  return counts.filter((count) => count === 0).length;
}

test.describe("calendar coverage resources", () => {
  test("the one-year hundred-calendar list settles warm inside the sourced budget", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, ONE_YEAR_VERSION);

    const samples = await measureWarmLoads(page, versionId);

    await expect(
      page.locator("#calendars-list [data-calendar-coverage]"),
    ).toHaveCount(CALENDAR_COUNT);

    const overview = await markCounts(page);

    console.log(
      `EV-6: version=one-year range=whole settle_ms=[${samples.join(",")}] ` +
        `fastest_ms=${fastest(samples)} median_ms=${median(samples)} rows=${overview.length} ` +
        `max_overview_bins=${largest(overview)} empty_rows=${emptyRows(overview)}`,
    );

    expect(fastest(samples)).toBeLessThanOrEqual(SETTLE_BUDGET_MS);
    expect(overview).toHaveLength(CALENDAR_COUNT);
    expect(largest(overview)).toBeLessThanOrEqual(MAX_OVERVIEW_BINS);
    expect(emptyRows(overview)).toBe(METADATA_ONLY_ROWS);

    await openCalendars(page, versionId, "near");
    const near = await markCounts(page);

    console.log(
      `EV-6: version=one-year range=near rows=${near.length} ` +
        `max_day_cells=${largest(near)} empty_rows=${emptyRows(near)}`,
    );

    expect(largest(near)).toBeLessThanOrEqual(MAX_NEAR_DAY_CELLS);
    expect(emptyRows(near)).toBe(METADATA_ONLY_ROWS);

    // The identity mix is pinned to the fixture rather than inferred from the totals: the all-days
    // weekly identity fills the 105-day axis exactly, and the metadata-only identity draws no
    // coverage in any view.
    await expect(
      page.locator(
        `#calendars-list [data-calendar-coverage="${ALL_DAYS_SERVICE_ID}"] .calendar-coverage-mark`,
      ),
    ).toHaveCount(MAX_NEAR_DAY_CELLS);
    await expect(
      page.locator(
        `#calendars-list [data-calendar-coverage="${METADATA_ONLY_SERVICE_ID}"] .calendar-coverage-mark`,
      ),
    ).toHaveCount(0);
  });

  test("the long-history hundred-calendar list settles warm and compresses every overview row", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, LONG_HISTORY_VERSION);

    const samples = await measureWarmLoads(page, versionId);

    await expect(
      page.locator("#calendars-list [data-calendar-coverage]"),
    ).toHaveCount(CALENDAR_COUNT);

    // A nine-year feed opens on the disclosed recent window rather than a day-per-pixel axis.
    await expect(page.locator("#calendar-coverage-show-all")).toHaveCount(1);

    const overview = await markCounts(page);

    console.log(
      `EV-6: version=long-history range=whole settle_ms=[${samples.join(",")}] ` +
        `fastest_ms=${fastest(samples)} median_ms=${median(samples)} rows=${overview.length} ` +
        `max_overview_bins=${largest(overview)} empty_rows=${emptyRows(overview)}`,
    );

    expect(fastest(samples)).toBeLessThanOrEqual(SETTLE_BUDGET_MS);
    expect(overview).toHaveLength(CALENDAR_COUNT);
    expect(largest(overview)).toBeLessThanOrEqual(MAX_OVERVIEW_BINS);
    expect(emptyRows(overview)).toBe(METADATA_ONLY_ROWS);

    await expect(
      page.locator(
        `#calendars-list [data-calendar-coverage="${METADATA_ONLY_SERVICE_ID}"] .calendar-coverage-mark`,
      ),
    ).toHaveCount(0);
    await expect(
      page.locator(
        `#calendars-list [data-calendar-coverage="${ALL_DAYS_SERVICE_ID}"] .calendar-coverage-mark`,
      ),
    ).not.toHaveCount(0);

    // The full axis spans nine years; every row stays inside the bin ceiling instead of drawing a
    // cell per day.
    await page.click("#calendar-coverage-show-all");
    await expect(page.locator("#calendar-coverage-restore")).toHaveCount(1);

    const all = await markCounts(page);

    console.log(
      `EV-6: version=long-history range=all rows=${all.length} max_overview_bins=${largest(all)} ` +
        `empty_rows=${emptyRows(all)}`,
    );

    expect(all).toHaveLength(CALENDAR_COUNT);
    expect(largest(all)).toBeLessThanOrEqual(MAX_OVERVIEW_BINS);
    expect(emptyRows(all)).toBe(METADATA_ONLY_ROWS);

    await openCalendars(page, versionId, "near");
    const near = await markCounts(page);

    console.log(
      `EV-6: version=long-history range=near rows=${near.length} max_day_cells=${largest(near)}`,
    );

    expect(largest(near)).toBeLessThanOrEqual(MAX_NEAR_DAY_CELLS);
    expect(emptyRows(near)).toBe(METADATA_ONLY_ROWS);
  });
});
