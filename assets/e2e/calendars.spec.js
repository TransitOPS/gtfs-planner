import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const SEEDED_NAMES = [
  "Every day service",
  "Legacy service",
  "Metadata only",
  "Odd service id",
  "School days",
  "Unused calendar",
];

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

async function expectRows(page, names, timeout = 8000) {
  await expect.poll(() => rowNames(page), { timeout }).toEqual(names);
  await expect(page.locator("#calendars-list tr")).toHaveCount(names.length);
}

async function rowNames(page) {
  const names = await page
    .locator("#calendars-list tr td:first-child a")
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

      // Semantic table with the reference's five columns.
      const table = page.locator("#calendars-list-container table");
      await expect(table).toBeVisible();
      await expect(table.locator("thead th")).toHaveText([
        /Calendar/,
        "Regular days",
        /Service dates/,
        "Trips",
        "Status",
      ]);

      expect(await rowNames(page)).toEqual(SEEDED_NAMES);

      // Count strip, agency-local today, and the feed-gap callout.
      await expect(
        page.locator("#calendar-counts-item-calendars"),
      ).toContainText("6");
      await expect(
        page.locator("#calendar-counts-item-run-today"),
      ).toContainText("1");
      await expect(page.locator("#calendars-today")).toContainText("Today ·");
      await expect(page.locator("#calendars-feed-gap")).toBeVisible();

      // Status presentation comes from the real computed summaries.
      const rows = await page.locator("#calendars-list tr").allTextContents();
      const statusText = rows.join(" | ");
      expect(statusText).toContain("Runs today");
      expect(statusText).toContain("Ended");
      expect(statusText).toContain("No service");
      expect(statusText).toContain("Ends in 10 days");
      expect(statusText).toContain("Ends in 5 days");
      expect(statusText).toContain("Not used by trips");

      // Grouped trip usage is numeric and right-aligned in its own column.
      const dailyRow = page.locator("#calendars-list tr", {
        hasText: "Every day service",
      });
      await expect(dailyRow.locator("td").nth(3)).toHaveText("3");
      await expect(
        page
          .locator("#calendars-list tr", { hasText: "School days" })
          .locator("td")
          .nth(3),
      ).toHaveText("2");
      await expect(
        page
          .locator("#calendars-list tr", { hasText: "Legacy service" })
          .locator("td")
          .nth(3),
      ).toHaveText("1");

      // Detail links keep URI-encoded service IDs.
      const oddLink = page
        .locator("#calendars-list tr", { hasText: "Odd service id" })
        .locator("td")
        .first()
        .locator("a");
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
    await expect(page.locator("#result-count")).toHaveText("1 of 6 calendars");

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
    await expect(page.locator("#result-count")).toHaveText("0 of 6 calendars");
    await page.click("#calendars-clear-filters");
    await expect(page.locator("#calendars-list tr")).toHaveCount(6, {
      timeout: 5000,
    });

    // Status filters with the documented allowlist.
    await page.selectOption("#calendar-status", "ended");
    await expectRows(page, ["Legacy service"]);

    await page.selectOption("#calendar-status", "active_today");
    await expectRows(page, ["Every day service"]);

    await page.selectOption("#calendar-status", "active_period");
    await expectRows(page, [
      "Every day service",
      "School days",
      "Unused calendar",
    ]);

    await page.selectOption("#calendar-status", "unused");
    await expectRows(page, [
      "Metadata only",
      "Odd service id",
      "Unused calendar",
    ]);

    await page.selectOption("#calendar-status", "all");
    await expectRows(page, SEEDED_NAMES);

    // The URL carries the state, and reloading it reproduces the list.
    await page.fill("#calendar-search", "service");
    await page.selectOption("#calendar-status", "all");
    await expectRows(page, [
      "Every day service",
      "Legacy service",
      "Odd service id",
    ]);
    expect(page.url()).toContain("search=service");

    await page.reload();
    await page.waitForSelector("#calendars-list-container");
    await expect(page.locator("#calendar-search")).toHaveValue("service");
    await expectRows(page, [
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
      hasText: "Service dates",
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
      "No calendars yet",
    );
    await expect(page.locator("#calendars-list-container")).toHaveCount(0);
    await expect(page.locator("#calendars-unavailable")).toHaveCount(0);
    await expect(page.locator("#calendars-create")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/calendars/new`,
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

// The reference groups duplication and deletion behind the "Calendar actions"
// disclosure; opening it is a state change, not an assertion, so the journey can
// reach the actions deterministically.
async function openCalendarActions(page) {
  await page.evaluate(() => {
    const disclosure = Array.from(
      document.querySelectorAll("#calendar-editor details"),
    ).find((element) =>
      (element.querySelector("summary")?.textContent || "").includes(
        "Calendar actions",
      ),
    );

    if (disclosure) disclosure.open = true;
  });
  await expect(page.locator("#calendar-delete")).toBeVisible();
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
  test("creates a weekly calendar from the list, previews three months and deletes it", async ({
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
    await expect(page.locator("#calendar-usage")).toContainText("0 trips");

    // Three months of the real derived preview, with symbols, text and a legend.
    await expect(page.locator("#months table")).toHaveCount(3);
    await expect(page.locator("#months-legend")).toContainText(
      "Regular service",
    );
    await expect(page.locator("#months-legend")).toContainText(
      "Service removed",
    );
    await expect(page.locator("#months-legend")).toContainText("Service added");
    await expect(page.locator("#months-legend")).toContainText(
      "No service scheduled",
    );
    await expect(page.locator("#periods-timeline")).toBeVisible();

    // Keyboard month navigation moves the window one month.
    const firstTitle = await page.locator("#months h3").first().innerText();
    await page.locator("#months").focus();
    await page.keyboard.press("ArrowRight");
    await expect
      .poll(() => page.locator("#months h3").first().innerText(), {
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
    await openCalendarActions(page);
    await page.click("#calendar-delete");
    await expect(page.locator("#calendar-review-dialog")).toBeVisible();
    await page.click("#calendar-review-dialog-confirm");
    await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
    await expect(
      page.locator("#calendars-list tr", { hasText: "Browser editor journey" }),
    ).toHaveCount(0);
    await expect(page.locator("#calendars-list tr")).toHaveCount(6);
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
      "Add this service date?",
    );
    await page.click("#calendar-review-dialog-cancel");
    await expect(page.locator("#calendar-review-dialog")).toBeHidden();
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toHaveCount(0);

    await page.click("#calendar-add-date");
    await page.click("#calendar-review-dialog-confirm");
    await expect(page.locator("#calendar-status")).toContainText(
      "date changes were stored",
      {
        timeout: 8000,
      },
    );
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toBeVisible();
    await expect(page.locator(`#month-cell-${outside}`)).toHaveAttribute(
      "aria-label",
      /Service added/,
    );

    // Restore the fixture state.
    await page.click(`#calendar-exception-chips-remove-${outside}`);
    await expect(page.locator("#calendar-status")).toContainText(
      "date changes were removed",
      {
        timeout: 8000,
      },
    );
    await expect(
      page.locator(`#calendar-exception-chips-${outside}`),
    ).toHaveCount(0);

    // A dirty schedule asks before an independent action, and Escape returns focus.
    await page.fill("#calendar-name", "Renamed without saving");
    await openCalendarActions(page);
    await page.click("#calendar-delete");
    await expect(page.locator("#calendar-dirty-dialog")).toBeVisible();
    await expect(page.locator("#calendar-dirty-dialog")).toContainText(
      "unsaved schedule changes",
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
    await openCalendarActions(page);
    await page.click("#calendar-delete");
    await page.click("#calendar-dirty-dialog-confirm");
    await expect(page.locator("#calendar-review-dialog")).toBeVisible();
    await expect(page.locator("#calendar-review-dialog")).toContainText(
      "Delete CAL_UNUSED?",
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
      "can’t be blank",
    );
    await expect(page.locator("#calendar-name")).toHaveAttribute(
      "aria-invalid",
      "true",
    );

    await openEditorFor(page, versionId, "CAL_DAILY");
    await openCalendarActions(page);
    await page.click("#calendar-delete");

    await expect(page.locator("#calendar-delete-blocked")).toBeVisible();
    await expect(page.locator("#calendar-delete-blocked")).toContainText(
      "3 trips",
    );
    await expect(page.locator("#calendar-delete-blocked a")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/routes/CAL_ROUTE`,
    );
    await expect(page.locator("#calendar-review-dialog")).toBeHidden();
    await expect(page.locator("#calendar-name")).toHaveValue(
      "Every day service",
    );
  });
});

// ---- Cross-calendar date change drawer (step 7) ----------------------------

async function waitForDrawerReady(page) {
  await page.waitForSelector("#calendar-date-change-form[data-phx-id]", {
    timeout: 15000,
  });
}

test.describe("cross-calendar date change drawer", () => {
  test("reviews and applies one atomic date change for several calendars at both desktop viewports", async ({
    page,
  }) => {
    await page.setViewportSize(VIEWPORTS[0]);
    const versionId = await openCalendars(page);

    // A Friday inside CAL_SCHOOL's range and clear of the seeded date changes.
    const serviceDate = isoDate(nextFriday(shiftDays(new Date(), 4)));

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
      await page.uncheck("#calendar-date-change-remove-CAL_UNUSED input");
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
      ).toContainText("rows change across");

      await page.click("#calendar-date-change-apply");
      await expect(page.locator("#calendars-date-change-status")).toContainText(
        "Applied the date change",
        { timeout: 10000 },
      );
      await expect(page.locator("#calendar-date-change-drawer")).toBeHidden();

      // The committed rows survive a real reload through the editor surfaces.
      await openEditorFor(page, versionId, "CAL_SCHOOL");
      await expect(
        page.locator(`#calendar-exception-chips-${serviceDate}`),
      ).toBeVisible();
      await expect(
        page.locator(`#calendar-exception-chips-${serviceDate}`),
      ).toContainText("Service removed");

      await openEditorFor(page, versionId, "CAL_UNUSED");
      await expect(
        page.locator(`#calendar-exception-chips-${serviceDate}`),
      ).toBeVisible();
      await expect(
        page.locator(`#calendar-exception-chips-${serviceDate}`),
      ).toContainText("Service added");

      // Restore the fixture state through the same reviewed command.
      await page.click(`#calendar-exception-chips-remove-${serviceDate}`);
      await expect(page.locator("#calendar-status")).toContainText(
        "date changes were removed",
        {
          timeout: 10000,
        },
      );
      await openEditorFor(page, versionId, "CAL_SCHOOL");
      await page.click(`#calendar-exception-chips-remove-${serviceDate}`);
      await expect(page.locator("#calendar-status")).toContainText(
        "date changes were removed",
        {
          timeout: 10000,
        },
      );

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
  await page.uncheck("#calendar-date-change-remove-CAL_UNUSED input");
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
    await expect(other.locator(`#calendar-exception-chips-${date}`)).toContainText("Service removed");
    await other.click(`#calendar-exception-chips-remove-${date}`);
    await expect(other.locator("#calendar-status")).toContainText("date changes were removed");
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
