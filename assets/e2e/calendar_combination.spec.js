import { test, expect } from "@playwright/test";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Calendar Combine";
const DETAILS_VERSION_NAME = "Browser Calendar Details";

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

async function openCalendars(page, versionName = VERSION_NAME) {
  const versionId = await versionIdFor(page, versionName);
  await page.goto(`/gtfs/${versionId}/calendars`);
  await page.waitForSelector("#calendars-list-container", { timeout: 15000 });
  return versionId;
}

async function selectCalendar(page, serviceId) {
  await page.locator(`#calendar-select-${serviceId}`).click();
  await expect(page.locator(`#calendar-select-${serviceId}`)).toBeChecked();
}

async function openReview(page, serviceIds) {
  for (const serviceId of serviceIds) await selectCalendar(page, serviceId);

  await page.locator("#calendar-combine-open").click();
  await expect(
    page.locator("#calendar-combine-drawer-overlay"),
  ).toHaveAttribute("data-open", "true");
  await expect(page.locator("#calendar-combine-form")).toBeVisible();
}

async function closeReview(page) {
  await page.locator("#calendar-combine-close").click();
  await expect(page.locator("#calendar-combine-form")).toHaveCount(0);
}

async function clearSelection(page) {
  await page.locator("#calendar-clear-selection").click();
  await expect(page.locator("#calendar-selection-count")).toHaveCount(0);
}

test.describe("calendar combination", () => {
  test.beforeEach(async ({ page }) => {
    await logIn(page);
  });

  test("selects exact service IDs, keeps the selection across sort and range, and prunes on a filter", async ({
    page,
  }) => {
    await openCalendars(page);

    // Nothing is selected, so only the select-all control is offered.
    await expect(page.locator("#calendar-selection-count")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-open")).toHaveCount(0);
    await expect(page.locator("#calendar-selection-hint")).toContainText(
      "two or more",
    );

    await selectCalendar(page, "COMBINE_SAT");
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "1 calendar selected",
    );
    await expect(page.locator("#calendar-combine-hint")).toContainText(
      "Select one more calendar to combine.",
    );
    await expect(page.locator("#calendar-combine-open")).toBeDisabled();

    await selectCalendar(page, "COMBINE_FALL");
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "2 calendars selected",
    );
    await expect(page.locator("#calendar-combine-open")).toBeEnabled();

    // The selected row is tinted, which is the only per-row selection affordance.
    const tint = await page.evaluate(() => {
      const row = document.querySelector(
        '#calendars-list tr:has(input[data-calendar-selected="true"])',
      );
      return row ? getComputedStyle(row).backgroundColor : null;
    });
    expect(tint).not.toBeNull();
    expect(tint).not.toBe("rgba(0, 0, 0, 0)");

    // Sorting and the timeline range are views of the same list, so the selection survives.
    await page
      .locator('#calendars-list-container thead th:has-text("Calendar") button')
      .click();
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "2 calendars selected",
    );

    await page.locator("#calendar-coverage-range-near").click();
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "2 calendars selected",
    );

    // A filter change prunes the selection to the rows it still shows, and the pruned identity is
    // not restored when the filter is removed.
    await page.locator("#calendar-search").fill("Fall");
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "1 calendar selected",
    );
    await expect(page.locator("#calendar-select-COMBINE_SAT")).toHaveCount(0);
    await expect(page.locator("#calendar-select-COMBINE_FALL")).toBeChecked();

    await page.locator("#calendar-search").fill("");
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "1 calendar selected",
    );
    await expect(
      page.locator("#calendar-select-COMBINE_SAT"),
    ).not.toBeChecked();

    // Select all targets every matching selectable row, and clears when they all are selected.
    await page.locator("#calendar-select-all").click();
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "7 calendars selected",
    );
    await page.locator("#calendar-select-all").click();
    await expect(page.locator("#calendar-selection-count")).toHaveCount(0);
  });

  test("opens the reviewed combination from normal list selection and changes nothing", async ({
    page,
  }) => {
    const versionId = await openCalendars(page);
    const rowsBefore = await page
      .locator("#calendars-list [data-calendar-link]")
      .allTextContents();
    const tripsBefore = await page
      .locator('#calendars-list td[data-label="Trips"]')
      .allTextContents();

    await openReview(page, ["COMBINE_SAT", "COMBINE_FALL", "COMBINE_GAMEDAY"]);

    // The drawer is the reference's wide review surface and states the reviewed facts.
    const drawer = page.locator("#calendar-combine-drawer");
    const box = await drawer.boundingBox();
    expect(box.width).toBeLessThanOrEqual(760);
    await expect(page.locator("#calendar-combine-subtitle")).toContainText(
      "3 calendars selected",
    );

    await expect(
      page.locator(
        "#calendar-combine-destination-option-COMBINE_SAT input[type=radio]",
      ),
    ).toBeChecked();
    await expect(page.locator("#calendar-combine-result-moved")).toHaveText(
      "4",
    );
    await expect(
      page.locator("#calendar-combine-result-sources"),
    ).toContainText("calendar");
    await expect(page.locator("#calendar-combine-result-stored")).toContainText(
      "Stored as",
    );
    await expect(
      page.locator("#calendar-combine-result-no-new-dates"),
    ).toContainText("every date comes from a selected calendar");

    // The per-calendar consequences and the real block and transfer findings are the producer's.
    await expect(page.locator("#calendar-combine-effects")).toContainText(
      "Fall shuttle",
    );
    await expect(page.locator("#calendar-combine-effects")).toContainText(
      "Also run on",
    );
    await expect(page.locator("#calendar-combine-impacts")).toContainText(
      "leave block CB701",
    );
    await expect(page.locator("#calendar-combine-impacts")).toContainText(
      "in-seat transfer",
    );
    await expect(page.locator("#calendar-combine-impacts")).toContainText(
      "stays in the list with 0 trips",
    );
    await expect(page.locator("#calendar-combine-footer-note")).toContainText(
      "Nothing changes until you combine.",
    );
    await expect(page.locator("#calendar-combine-conflicts")).toHaveCount(0);

    // Changing the destination re-reviews against the real command instead of reusing the first
    // projection.
    await page
      .locator(
        "#calendar-combine-destination-option-COMBINE_GAMEDAY input[type=radio]",
      )
      .click();
    await expect(
      page.locator(
        "#calendar-combine-destination-option-COMBINE_GAMEDAY input[type=radio]",
      ),
    ).toBeChecked();
    await expect(page.locator("#calendar-combine-result-moved")).toHaveText(
      "2",
    );

    await closeReview(page);
    await clearSelection(page);

    await page.goto(`/gtfs/${versionId}/calendars`);
    await page.waitForSelector("#calendars-list-container");
    await expect(
      page.locator("#calendars-list [data-calendar-link]"),
    ).toHaveText(rowsBefore);
    await expect(
      page.locator('#calendars-list td[data-label="Trips"]'),
    ).toHaveText(tripsBefore);
  });

  test("offers the conflict decisions with no default and offers Close when nothing changes", async ({
    page,
  }) => {
    await openCalendars(page);

    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_HOLIDAY"]);

    await expect(page.locator("#calendar-combine-result")).toContainText(
      "Almost ready.",
    );

    // One fieldset per exact conflict group, both decisions offered as labelled radios and
    // nothing checked until the reviewer chooses (AC-7, AC-22).
    const conflict = page.locator(
      "#calendar-combine-decisions [data-conflict-date]",
    );
    await expect(conflict).toHaveCount(1);
    await expect(conflict).toContainText("Holiday weekdays has no service");
    await expect(conflict).toContainText("Weekday service runs");
    await expect(conflict.locator("input[type=radio]")).toHaveCount(2);
    await expect(conflict.locator("input[type=radio]:checked")).toHaveCount(0);
    await expect(
      conflict.locator('input[value="no_service"]'),
    ).not.toHaveAttribute("aria-invalid", "true");
    await expect(page.locator("#calendar-combine-errors")).toHaveCount(0);
    await expect(
      page.locator("#calendar-combine-result-upcoming"),
    ).toContainText("after your choice");

    await closeReview(page);
    await clearSelection(page);

    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_WEEKDAY_COPY"]);

    const result = page.locator("#calendar-combine-result");
    await expect(result).toContainText("Nothing changes.");
    await expect(result).toContainText("already runs on all of its dates");
    await expect(page.locator("#calendar-combine-footer-note")).toHaveText(
      "Nothing to combine.",
    );
    await expect(page.locator("#calendar-combine-close")).toBeVisible();
    await expect(page.locator("#calendar-combine-apply")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-impacts")).toHaveCount(0);
  });

  test("refuses an unanswered conflict, then re-reviews each choice", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_HOLIDAY"]);

    const conflict = page.locator(
      "#calendar-combine-decisions [data-conflict-date]",
    );
    const iso = await conflict.getAttribute("data-conflict-date");
    // The summary names the date in full; the marked group states the short form its own legend
    // already carries in full.
    const label = new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
    }).format(new Date(`${iso}T00:00:00Z`));
    const shortLabel = new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
    }).format(new Date(`${iso}T00:00:00Z`));

    // Both options name the trips they affect; neither is defaulted.
    await expect(conflict).toContainText("No service");
    await expect(conflict).toContainText("Run all trips");
    await expect(conflict).toContainText(
      "2 trips from Weekday service stop running.",
    );
    await expect(conflict).toContainText("No trips change.");

    // The submission stays available and refuses: it announces the missing choice, marks the group
    // and focuses that group's first option instead of combining anything.
    await page.locator("#calendar-combine-apply").click();
    await expect(page.locator("#calendar-combine-errors")).toContainText(
      "Calendars not combined yet.",
    );
    await expect(page.locator("#calendar-combine-errors")).toContainText(label);
    await expect(conflict).toHaveAttribute("data-conflict-unanswered", "true");
    await expect(conflict).toContainText(
      `Choose what happens on ${shortLabel}.`,
    );

    const invalid = conflict.locator(
      'input[value="no_service"][aria-invalid="true"]',
    );
    await expect(invalid).toHaveCount(1);
    await expect(invalid).toBeFocused();

    // No service drops exactly that date from the destination's own trips.
    await conflict.locator('input[value="no_service"]').click();
    await expect(conflict.locator('input[value="no_service"]')).toBeChecked();
    await expect(page.locator("#calendar-combine-effects")).toContainText(
      `Stop running on ${label}`,
    );
    await expect(page.locator("#calendar-combine-errors")).toHaveCount(0);

    // Running the date is the opposite decision: the destination keeps running it, and a source
    // whose trips are already zero changes nothing at all.
    await conflict.locator('input[value="run"]').click();
    await expect(conflict.locator('input[value="run"]')).toBeChecked();
    await expect(page.locator("#calendar-combine-effects")).not.toContainText(
      "Stop running on",
    );
    await expect(page.locator("#calendar-combine-result")).toContainText(
      "Nothing changes.",
    );

    // Keeping the other calendar discards the answer instead of carrying it into a review whose
    // conflict belongs to different calendars (AC-22).
    await page
      .locator(
        "#calendar-combine-destination-option-COMBINE_HOLIDAY input[type=radio]",
      )
      .click();
    await expect(
      page.locator(
        "#calendar-combine-destination-option-COMBINE_HOLIDAY input[type=radio]",
      ),
    ).toBeChecked();
    await expect(conflict.locator("input[type=radio]:checked")).toHaveCount(0);

    await closeReview(page);
    await clearSelection(page);
  });

  test("warns when a moving calendar would gain many upcoming dates", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_SAT", "COMBINE_WEEKDAY", "COMBINE_SUN"]);

    const moving = page.locator("#calendar-combine-effects-COMBINE_WEEKDAY");
    await expect(moving).toContainText("Also run on");
    await expect(moving).toContainText(
      "If these trips should keep their own dates, don't combine.",
    );
    await expect(page.locator("#calendar-combine-effects")).toContainText(
      "don't combine",
    );

    const staying = page.locator("#calendar-combine-effects-COMBINE_SAT");
    await expect(staying).not.toContainText("don't combine");

    await closeReview(page);
    await clearSelection(page);
  });

  test("keeps the selection surface reachable and overflow-free at narrow widths", async ({
    page,
  }) => {
    for (const viewport of [
      { width: 1440, height: 900 },
      { width: 1024, height: 900 },
      { width: 390, height: 844 },
      { width: 320, height: 800 },
    ]) {
      await page.setViewportSize(viewport);
      await openCalendars(page);
      await openReview(page, ["COMBINE_SAT", "COMBINE_FALL"]);

      const box = await page.locator("#calendar-combine-drawer").boundingBox();
      const expected = Math.min(viewport.width, 760);
      expect(box.width).toBeLessThanOrEqual(expected + 1);
      expect(box.width).toBeGreaterThanOrEqual(expected - 1);

      // The sticky footer stays inside the viewport and the page never scrolls sideways.
      const close = await page.locator("#calendar-combine-close").boundingBox();
      expect(close.y + close.height).toBeLessThanOrEqual(viewport.height + 1);

      const fits = await page.evaluate(
        () => document.body.scrollWidth <= window.innerWidth,
      );
      expect(fits).toBe(true);

      await closeReview(page);
      await clearSelection(page);
    }
  });

  test("withdraws combination while a retained range needs repair", async ({
    page,
  }) => {
    await openCalendars(page, DETAILS_VERSION_NAME);

    // The unreadable identity keeps its row and its repair callout, and its checkbox cannot be
    // used.
    await expect(
      page.locator("#calendar-select-DETAIL_REVERSED"),
    ).toBeDisabled();
    await expect(page.locator("#calendar-combine-unavailable")).toContainText(
      "Combining is unavailable",
    );

    await selectCalendar(page, "DETAIL_SCHOOL");
    await selectCalendar(page, "DETAIL_DATES");

    await expect(page.locator("#calendar-combine-unavailable")).toContainText(
      "Combining is unavailable",
    );
    await expect(page.locator("#calendar-combine-open")).toBeDisabled();

    await page.locator("#calendar-combine-open").click({ force: true });
    await expect(page.locator("#calendar-combine-form")).toHaveCount(0);
  });

  test("clears the selection when the version changes", async ({ page }) => {
    await openCalendars(page);
    await selectCalendar(page, "COMBINE_SAT");
    await expect(page.locator("#calendar-selection-count")).toHaveText(
      "1 calendar selected",
    );

    await page.locator("#gtfs-version-trigger").click();
    await page
      .locator("#gtfs-version-panel [data-version-option]")
      .filter({ hasText: DETAILS_VERSION_NAME })
      .click();

    await page.waitForURL(/\/gtfs\/[0-9a-f-]+\/calendars/);
    await page.waitForSelector("#calendars-list-container");
    await expect(page.locator("#calendar-selection-count")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-form")).toHaveCount(0);
  });

  // The two journeys below confirm a combination, so they run last: a real confirmation changes the
  // seeded version the journeys above read.

  test("combines a reviewed pair once and announces the move", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_SAT", "COMBINE_SUN"]);

    await expect(
      page.locator(
        "#calendar-combine-destination-option-COMBINE_SAT input[type=radio]",
      ),
    ).toBeChecked();

    await page.locator("#calendar-combine-apply").click();

    // The confirmed success closes the drawer and states exactly what moved, where it went and
    // which source stays behind (AC-24).
    await expect(page.locator("#calendar-combine-form")).toHaveCount(0);

    const success = page.locator("#calendar-combine-success");
    await expect(success).toHaveAttribute("data-combine-success", "combined");
    await expect(success).toContainText("Combined into Saturday service.");
    await expect(success).toContainText(
      "1 trip moved from Sunday shuttle, which stays in the list with 0 trips.",
    );

    // The list is reloaded from the authoritative rows: the source keeps its identity with no
    // trips, the destination holds the moved one, and both affected rows are tinted.
    const rows = page.locator("#calendars-list tr");
    await expect(
      rows.filter({ hasText: "COMBINE_SUN" }).locator('td[data-label="Trips"]'),
    ).toHaveText("0");
    await expect(
      rows.filter({ hasText: "COMBINE_SAT" }).locator('td[data-label="Trips"]'),
    ).toHaveText("5");
    await expect(
      page.locator('#calendars-list tr[class*="bg-success/10"]'),
    ).toHaveCount(2);
    await expect(page.locator("#calendar-selection-count")).toHaveCount(0);

    // Dismissing the summary takes the tint with it instead of leaving the rows marked.
    await page.locator("#calendar-combine-success-dismiss").click();
    await expect(success).toHaveCount(0);
    await expect(
      page.locator('#calendars-list tr[class*="bg-success/10"]'),
    ).toHaveCount(0);
  });

  test("disables combination while the socket is down and reloads instead of resending", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_HOLIDAY"]);

    // Nothing has been confirmed when the page's own socket drops, so the pre-rendered notice says
    // exactly that and the confirmation is disabled until the connection returns (AC-23).
    await page.evaluate(() => window.liveSocket.disconnect());

    const notice = page.locator("#calendar-combine-connection");
    await expect(notice).toBeVisible();
    await expect(
      notice.locator('[data-combine-connection="idle"]'),
    ).toBeVisible();
    await expect(
      notice.locator('[data-combine-connection="idle"]'),
    ).toContainText("Nothing has been sent, and your choices are kept.");
    await expect(
      notice.locator('[data-combine-connection="dispatched"]'),
    ).toBeHidden();
    await expect(page.locator("#calendar-combine-apply")).toBeDisabled();
    await expect(page.locator("#calendar-combine-close")).toBeDisabled();

    await page.evaluate(() => window.liveSocket.connect());

    // Reconnecting reloads the authoritative list, hides the notice and leaves the enabled state to
    // the server. The page never resends the confirmation on its own: the review is still the one
    // the reviewer prepared, and its answer was not recorded anywhere.
    await expect(notice).toBeHidden();
    await expect(page.locator("#calendars-refreshing")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-close")).toBeEnabled();
    await expect(page.locator("#calendar-combine-form")).toBeVisible();

    await closeReview(page);
    await clearSelection(page);
  });
});
