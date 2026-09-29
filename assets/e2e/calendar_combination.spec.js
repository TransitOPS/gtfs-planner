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

// A Saturday inside every seeded weekly range: the calendar is seeded relative to the
// agency-local today, so the fixture keeps its own day of the week.
async function nextSaturday(page) {
  return page.evaluate(() => {
    const date = new Date();
    date.setDate(date.getDate() + ((6 - date.getDay() + 7) % 7 || 7));
    return [
      date.getFullYear(),
      String(date.getMonth() + 1).padStart(2, "0"),
      String(date.getDate()).padStart(2, "0"),
    ].join("-");
  });
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
    // projection: the move is the other two calendars' own trips (Saturday 4 + Fall 2), read from
    // the rows rather than carried over from the previous destination.
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
      "6",
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
    // already carries in full. A stored service date is a plain calendar date, so both labels are
    // formatted in UTC: the runner's own zone must not shift the day it names.
    const label = new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
      year: "numeric",
      timeZone: "UTC",
    }).format(new Date(`${iso}T00:00:00Z`));
    const shortLabel = new Intl.DateTimeFormat("en-US", {
      month: "short",
      day: "numeric",
      timeZone: "UTC",
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

      // The sticky footer keeps both actions inside the viewport at every width, so a confirmation
      // never sits below a fold the reviewer cannot reach (AC-24).
      await expect(page.locator("#calendar-combine-footer-note")).toBeVisible();
      for (const action of [
        "#calendar-combine-close",
        "#calendar-combine-apply",
      ]) {
        const actionBox = await page.locator(action).boundingBox();
        expect(actionBox.y).toBeGreaterThanOrEqual(0);
        expect(actionBox.y + actionBox.height).toBeLessThanOrEqual(
          viewport.height + 1,
        );
      }

      // The labelled controls are keyboard reachable: focusing one moves focus into the drawer and
      // the next Tab keeps it there instead of escaping behind the modal.
      await page.locator("#calendar-combine-close").focus();
      await expect(page.locator("#calendar-combine-close")).toBeFocused();
      await page.keyboard.press("Tab");
      expect(
        await page.evaluate(() =>
          document
            .getElementById("calendar-combine-drawer")
            .contains(document.activeElement),
        ),
      ).toBe(true);
      await expect(
        page.locator('input[name="combine[destination_id]"]'),
      ).toHaveCount(2);

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

  test("reviews three moving sources on one destination and states the real block consequence", async ({
    page,
  }) => {
    await openCalendars(page);

    // The seeded three-source shape: the Saturday destination plus the Fall, Sunday and
    // specific-dates sources, whose two block-701 trips only collide once they all run on the
    // destination's dates.
    await openReview(page, [
      "COMBINE_SAT",
      "COMBINE_FALL",
      "COMBINE_SUN",
      "COMBINE_GAMEDAY",
    ]);

    await expect(page.locator("#calendar-combine-subtitle")).toContainText(
      "4 calendars selected",
    );
    await expect(page.locator("#calendar-combine-result-moved")).toHaveText(
      "5",
    );
    await expect(
      page.locator("#calendar-combine-result-sources"),
    ).toContainText("3 calendars");

    // Every retained source keeps its identity and is reachable from the drawer, so the reviewer
    // can go on to delete it deliberately.
    await expect(
      page.locator("#calendar-combine-impacts-retained-COMBINE_SUN"),
    ).toContainText("Open Sunday shuttle");

    // Each source states the dates it gains from the destination, and every one of them is
    // reported as retained rather than deleted.
    for (const serviceId of [
      "COMBINE_FALL",
      "COMBINE_SUN",
      "COMBINE_GAMEDAY",
    ]) {
      await expect(
        page.locator(`#calendar-combine-effects-${serviceId}`),
      ).toContainText("Also run on");
    }
    await expect(page.locator("#calendar-combine-impacts")).toContainText(
      "stays in the list with 0 trips",
    );

    // The block consequence is the concrete producer's, not a client guess: the trips that cannot
    // share a block go to the unassigned pool.
    await expect(page.locator("#calendar-combine-impacts")).toContainText(
      "unassigned pool",
    );
    await expect(
      page.locator("#calendar-combine-impacts-cleared-blocks"),
    ).toContainText("block");

    await closeReview(page);
    await clearSelection(page);
  });

  test("reviews a specific-dates destination and states the exact shape of the stored result", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_SAT", "COMBINE_GAMEDAY"]);

    // The dates-only calendar is the destination, so the result is stored as its own specific
    // dates and the drawer names the weekly alternative instead of inventing a weekly mask.
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
      "4",
    );
    await expect(page.locator("#calendar-combine-result-stored")).toContainText(
      /Stored as \d+ specific dates/,
    );
    await expect(
      page.locator("#calendar-combine-result-dates-only"),
    ).toContainText("stores dates one by one");
    await expect(
      page.locator("#calendar-combine-result-dates-only"),
    ).toContainText("Saturday service");
    await expect(
      page.locator("#calendar-combine-result-sources"),
    ).toContainText("1 calendar");
    await expect(page.locator("#calendar-combine-conflicts")).toHaveCount(0);

    await closeReview(page);
    await clearSelection(page);
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
      page.locator('#calendars-list tr[data-marked]'),
    ).toHaveCount(2);
    await expect(page.locator("#calendar-selection-count")).toHaveCount(0);

    // Dismissing the summary takes the tint with it instead of leaving the rows marked.
    await page.locator("#calendar-combine-success-dismiss").click();
    await expect(success).toHaveCount(0);
    await expect(
      page.locator('#calendars-list tr[data-marked]'),
    ).toHaveCount(0);

    // The result is a persisted one: a real reload of the ordinary route reads the retained source
    // row back from the database with no trips and no summary, and the destination keeps the moved
    // trip (step 22's persisted-reload criterion).
    await page.reload();
    await page.waitForSelector("#calendars-list-container");
    const reloaded = page.locator("#calendars-list tr");
    await expect(
      reloaded
        .filter({ hasText: "COMBINE_SUN" })
        .locator('td[data-label="Trips"]'),
    ).toHaveText("0");
    await expect(
      reloaded
        .filter({ hasText: "COMBINE_SAT" })
        .locator('td[data-label="Trips"]'),
    ).toHaveText("5");
    await expect(
      reloaded
        .filter({ hasText: "COMBINE_SUN" })
        .locator("[data-calendar-link]"),
    ).toBeVisible();
    await expect(page.locator("#calendar-combine-success")).toHaveCount(0);
  });

  test("disables combination while the socket is down and reloads instead of resending", async ({
    page,
  }) => {
    await openCalendars(page);
    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_HOLIDAY"]);

    // Nothing has been confirmed when the page's own socket drops, so the pre-rendered notice says
    // exactly that and the confirmation is disabled until the connection returns (AC-23). The
    // shared dialog hook closes its modal on the same event, which is why the notice lives on the
    // page: the reviewer reads the state there, not behind a closed drawer.
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
    await expect(page.locator("#calendar-combine-drawer")).toBeHidden();
    await expect(page.locator("#calendar-combine-apply")).toBeDisabled();

    await page.evaluate(() => window.liveSocket.connect());

    // Reconnecting re-reads the authoritative list rather than resending anything: the notice is
    // gone, no confirmation was applied, and the prepared review is never presented as a current
    // one - the reviewer selects again against the rows the server just read (AC-23).
    await expect(notice).toBeHidden();
    await expect(page.locator("#calendars-refreshing")).toHaveCount(0);
    await expect(page.locator("#calendars-list-container")).toBeVisible();
    await expect(page.locator("#calendar-combine-success")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-form")).toHaveCount(0);

    // The list still holds the unchanged rows, and an ordinary review opens again on them.
    await expect(
      page
        .locator("#calendars-list tr")
        .filter({ hasText: "COMBINE_HOLIDAY" })
        .locator('td[data-label="Trips"]'),
    ).toHaveText("0");
    await openReview(page, ["COMBINE_WEEKDAY", "COMBINE_HOLIDAY"]);
    await expect(page.locator("#calendar-combine-apply")).toBeVisible();

    await closeReview(page);
    await clearSelection(page);
  });

  // The two journeys below change the seeded version for good, so they run after every journey
  // that reads it.

  test("marks a review stale after the date-change drawer changes a selected calendar", async ({
    page,
    context,
  }) => {
    const versionId = await openCalendars(page);
    await openReview(page, ["COMBINE_SAT", "COMBINE_FALL"]);
    await expect(page.locator("#calendar-combine-result-moved")).toHaveText(
      "2",
    );

    // A second ordinary session changes the source's own dates through the list's pre-existing
    // date-change drawer: the combination UI is installed and the old drawer still changes exactly
    // the day it is given, for the one calendar it is told to change it for (AC-2).
    const other = await context.newPage();
    await other.goto(`/gtfs/${versionId}/calendars`);
    await other.waitForSelector("#calendars-list-container");
    // A second page reaches the drawer through the ordinary route, so its own socket must have
    // connected before the first click lands on the server-rendered DOM.
    await other.waitForSelector("[data-phx-main].phx-connected");
    const changedDate = await nextSaturday(other);
    await other.click("#calendar-date-change");
    await other.waitForSelector("#calendar-date-change-form[data-phx-id]");
    await other.fill("#calendar-date-change-dates-date", changedDate);
    await expect(
      other.locator("#calendar-date-change-remove-COMBINE_FALL input"),
    ).toBeChecked();
    await other.uncheck("#calendar-date-change-remove-COMBINE_SAT input");
    await other.click("#calendar-date-change-review");
    await expect(
      other.locator("#calendar-date-change-review-panel"),
    ).toContainText("Stop Fall shuttle");
    await other.click("#calendar-date-change-apply");
    await expect(other.locator("#calendars-date-change-status")).toContainText(
      "Applied the date change",
      { timeout: 10000 },
    );

    // The committed day is the one the drawer was given, read back through the ordinary editor.
    await other.goto(
      `/gtfs/${versionId}/calendars/show?service_id=COMBINE_FALL`,
    );
    await other.waitForSelector("#calendar-editor");
    await expect(
      other.locator(`#calendar-exception-chips-${changedDate}`),
    ).toContainText("No service");
    await other.close();

    // The prepared review no longer describes the source, so confirming writes nothing and offers
    // the one explicit recovery instead of reusing the old token (AC-23, INV-3).
    await page.locator("#calendar-combine-apply").click();
    const status = page.locator("#calendar-combine-errors");
    await expect(status).toContainText(
      "Saturday service changed after this review was prepared.",
    );
    await expect(status).toContainText(
      "Another editor changed these calendars, so nothing was combined.",
    );
    await expect(page.locator("#calendar-combine-refresh")).toBeVisible();
    await expect(page.locator("#calendar-combine-apply")).toHaveCount(0);
    await expect(page.locator("#calendar-combine-success")).toHaveCount(0);

    // Refreshing is the recovery: the drawer re-reviews the current source, so the day the drawer
    // removed now needs an explicit choice instead of being carried over from the old review.
    await page.locator("#calendar-combine-refresh").click();
    const conflict = page.locator(
      "#calendar-combine-decisions [data-conflict-date]",
    );
    await expect(conflict).toHaveCount(1);
    await expect(conflict).toHaveAttribute("data-conflict-date", changedDate);
    await expect(conflict).toContainText("Fall shuttle has no service");
    await expect(conflict).toContainText("Saturday service runs");
    await expect(page.locator("#calendar-combine-apply")).toBeVisible();

    await closeReview(page);
    await clearSelection(page);
  });

  test("keeps the choices and reports the domain refusal when a selected calendar is deleted", async ({
    page,
    context,
  }) => {
    const versionId = await openCalendars(page);

    // An empty calendar as the destination is a real combination: the two Weekday trips would move
    // into the copy, so the review offers the confirmation.
    await openReview(page, ["COMBINE_WEEKDAY_COPY", "COMBINE_WEEKDAY"]);
    await page
      .locator(
        "#calendar-combine-destination-option-COMBINE_WEEKDAY_COPY input[type=radio]",
      )
      .click();
    await expect(page.locator("#calendar-combine-result-moved")).toHaveText(
      "2",
    );
    await expect(page.locator("#calendar-combine-apply")).toBeVisible();

    // A second session deletes the selected destination, which nothing in the review can undo, so
    // the domain refuses the command and the page repeats that refusal instead of claiming a move.
    const other = await context.newPage();
    await other.goto(
      `/gtfs/${versionId}/calendars/show?service_id=COMBINE_WEEKDAY_COPY`,
    );
    await other.waitForSelector("#calendar-editor");
    await other.waitForSelector("[data-phx-main].phx-connected");
    await expect(other.locator("#calendar-delete")).toBeVisible();
    await other.click("#calendar-delete");
    await other.click("#calendar-review-dialog-confirm");
    await expect(other).toHaveURL(/\/gtfs\/[0-9a-f-]+\/calendars$/);
    await other.close();

    await page.locator("#calendar-combine-apply").click();
    const status = page.locator("#calendar-combine-errors");
    await expect(status).toContainText("Calendars weren’t combined.", {
      timeout: 10000,
    });
    await expect(status).toContainText(
      "COMBINE_WEEKDAY_COPY could not be read",
    );
    await expect(status).toContainText("Your choices are kept");

    // Nothing was written: the source keeps its own trips and the refusal is not a success.
    await expect(page.locator("#calendar-combine-success")).toHaveCount(0);
    await page.reload();
    await page.waitForSelector("#calendars-list-container");
    await expect(
      page
        .locator("#calendars-list tr")
        .filter({ hasText: "COMBINE_WEEKDAY" })
        .locator('td[data-label="Trips"]'),
    ).toHaveText("2");
    await expect(
      page.locator("#calendars-list tr", { hasText: "COMBINE_WEEKDAY_COPY" }),
    ).toHaveCount(0);
  });
});
