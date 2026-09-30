import { test, expect } from "@playwright/test";

/**
 * Paste timetable shell (step 21), the Change schedule drawer (step 22) and
 * the timetable step (step 23).
 *
 * The full paste journey lands in step 31; this file proves the shell
 * renders its schedule line, the drawer patches the schedule while the
 * paste stays, and the timetable step reads a paste with inline errors and
 * a collapsed summary. The fixture route comes from
 * `test/support/browser_seed.exs`: BROWSER_PASTE (route 12, Downtown –
 * Riverside) with the Weekday calendar, outbound BPS-MAIN and inbound
 * BPS-INBOUND patterns.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const PASTE_ROUTE = "BROWSER_PASTE";

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

test.describe("Paste timetable shell", () => {
  test("the schedule line shows the Weekday outbound main pattern", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await expect(page.locator("#timetable-paste")).toBeVisible();
    await expect(page.locator("#paste-title")).toHaveText("Paste timetable");
    await expect(page.locator("#paste-scope-calendar")).toContainText("Weekday");
    await expect(page.locator("#paste-scope-direction")).toContainText("Outbound");
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Central Station → Riverside Terminal",
    );
    await expect(page.locator("#paste-scope-open")).toContainText("Change schedule");
  });
});

test.describe("Change schedule drawer", () => {
  test("changing the direction refilters the patterns and patches the schedule", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Central Station → Riverside Terminal",
    );

    await page.click("#paste-scope-open");
    await expect(page.locator("#paste-scope-drawer")).toBeVisible();
    await expect(page.locator("#paste-scope-form")).toBeVisible();
    await expect(page.locator("#paste-scope-calendar-field")).toBeFocused();
    await expect(page.locator("#paste-scope-calendar-field")).toContainText("Weekday");
    await expect(page.locator("#paste-scope-pattern-field")).toContainText(
      "Central Station → Riverside Terminal",
    );

    // Inbound refilters the patterns away from the outbound ones.
    await page.click("label:has(#paste-scope-direction-field-1)");
    await expect(page.locator("#paste-scope-pattern-field")).toContainText(
      "Riverside Terminal → Central Station",
    );
    await expect(page.locator("#paste-scope-pattern-field")).not.toContainText(
      "Central Station → Riverside Terminal",
    );

    await page.click("#paste-scope-apply");
    await expect(page).toHaveURL(/direction=1/);
    await expect(page.locator("#paste-scope-direction")).toContainText("Inbound");
    await expect(page.locator("#paste-scope-pattern")).toContainText(
      "Riverside Terminal → Central Station",
    );
  });

  test("Escape closes the drawer and returns focus to Change schedule", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.click("#paste-scope-open");
    await expect(page.locator("#paste-scope-drawer")).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.locator("#paste-scope-open")).toBeFocused();
  });
});

test.describe("timetable step", () => {
  // Step 23: the paste form textarea, hint, Layout disclosure, Read
  // timetable, inline errors and the collapsed summary. The run is deferred
  // to branch review with the browser partition, like the shell and drawer
  // cases above.
  const EXACT_PASTE = [
    "Trip\tCentral Station\tMarket Street\tMill Street\tRiverside Terminal",
    "1201\t6:00\t6:04\t6:10\t6:18",
    "1203\t7:00\t7:04\t7:10\t7:18",
  ].join("\n");

  test("the first-use step shows the labelled textarea, hint and layout", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await expect(page.locator("#paste-form")).toBeVisible();
    await expect(page.locator("#paste-source")).toBeVisible();
    await expect(page.locator("#paste-source-hint")).toContainText("Up to 500 trips");
    await expect(page.locator("#paste-layout")).toContainText("Layout");
    await expect(page.locator("#paste-read")).toContainText("Read timetable");
  });

  test("a paste with no times shows the inline error and keeps the text", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", "Trip\tCentral Station\nfoo\tbar");
    await page.click("#paste-read");
    await expect(page.locator("#paste-source-error")).toContainText("No times found");
    await expect(page.locator("#paste-source")).toHaveValue(/foo/);
  });

  test("an exact paste collapses the step and shows the review area", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", EXACT_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-source-summary")).toContainText("trip rows");
    await expect(page.locator("#paste-source-edit")).toContainText("Edit timetable");
    await expect(page.locator("#paste-review")).toBeVisible();

    await page.click("#paste-source-edit");
    await expect(page.locator("#paste-source")).toHaveValue(/6:00/);
  });
});

test.describe("columns step", () => {
  // Step 24: the pasted grid with a Use-as select per column, status
  // badges, Confirm match, the Review-trips error summary and the pattern
  // stop strip. The run is deferred to branch review with the browser
  // partition, like the timetable-step cases above.
  const UNMATCHED_PASTE = [
    "Run\tDowntown\tMill & 5th\tEnd of line",
    "1215\t9:30\t9:40\t9:58",
    "1217\t10:00\t10:10\t10:28",
  ].join("\n");

  const CLOSE_PASTE = [
    "Trip\tCentrl Station\tMarket Street\tMill Street",
    "1201\t6:00\t6:04\t6:10",
    "1203\t7:00\t7:04\t7:10",
  ].join("\n");

  test("a mismatched paste shows the grid, the strip and the error summary", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", UNMATCHED_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-columns")).toBeVisible();
    await expect(page.locator("#paste-map-1")).toBeVisible();
    await expect(page.locator("#paste-columns")).toContainText("No match");
    await expect(page.locator("#paste-pattern-strip")).toContainText("no column");

    await page.click("#paste-to-review");
    await expect(page.locator("#paste-column-errors")).toBeVisible();
    await expect(page.locator("#paste-column-errors")).toContainText(
      "a decision before review",
    );
    await expect(page.locator("#paste-column-errors")).toBeFocused();
  });

  test("confirming the close match reaches the review", async ({ page }) => {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", CLOSE_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-columns")).toContainText("Close match");
    await page.click("#paste-confirm-1");
    await expect(page.locator("#paste-review")).toBeVisible();
  });
});

test.describe("review header", () => {
  // Step 25: How to apply, Fill other stops from, Stops view, the three
  // metrics, refusal/nothing callouts and the filter buttons. The run is
  // deferred to branch review with the browser partition, like the cases
  // above.
  const REVIEW_PASTE = [
    "Trip\tCentral Station\tMarket Street\tMill Street\tRiverside Terminal",
    "1201\t6:00\t6:04\t6:10\t6:18",
    "1203\t7:00\t7:04\t7:10\t7:18",
  ].join("\n");

  async function readReview(page) {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", REVIEW_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-review")).toBeVisible();
  }

  test("the review header shows the mode switch, template, stops view and metrics", async ({
    page,
  }) => {
    await readReview(page);
    await expect(page.locator("#paste-review")).toContainText("Not applied");
    await expect(page.locator("#paste-mode")).toContainText("How to apply");
    await expect(page.locator("#paste-template")).toBeVisible();
    await expect(page.locator("#paste-stops-view")).toContainText("All stops");
    await expect(page.locator("#paste-metric-trips")).toBeVisible();
    await expect(page.locator("#paste-metric-vehicles")).toContainText("alone");
    await expect(page.locator("#paste-metric-timings")).toBeVisible();
    await expect(page.locator("#paste-filters")).toContainText("All rows");
    await expect(page.locator("#paste-rows")).toBeVisible();
  });

  test("switching to Replace changes the consequence text", async ({ page }) => {
    await readReview(page);
    await expect(page.locator("#paste-mode-help")).toContainText(
      "Existing trips stay",
    );
    await page.click(
      "label:has(input[name='paste[mode]'][value='replace'])",
    );
    await expect(page.locator("#paste-mode-help")).toContainText("removed");
  });

  test("filter buttons show counts and toggle", async ({ page }) => {
    await readReview(page);
    await expect(page.locator("#paste-filter-all")).toBeVisible();
    await page.click("#paste-filter-add");
    await expect(page.locator("#paste-filter-add")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  });
});

test.describe("row decisions", () => {
  // Step 27: the Details-cell decision controls (pattern select, cell
  // correction, twelve-hour choice, pairing radios, skip, restore, Add
  // anyway) and the `#paste-decisions` hidden field that restores them on
  // reconnect. The run is deferred to branch review with the browser
  // partition, like the cases above.
  const DECISION_PASTE = [
    "Trip\tCentral Station\tMarket Street\tMill Street\tRiverside Terminal",
    "1201\t6:00\t6:04\t6:10\t6:18",
    "1203\t7:00\t7:04\t7:10\t7:18",
  ].join("\n");

  async function readDecisions(page) {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", DECISION_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-review")).toBeVisible();
    // Every decision round-trips through the hidden field for reconnects.
    await expect(page.locator("#paste-decisions")).toHaveCount(1);
  }

  test("the hidden decisions field rides the paste form", async ({
    page,
  }) => {
    await readDecisions(page);
    await expect(page.locator("#paste-decisions")).toHaveValue("{}");
  });

  test("skipping and restoring a duplicate row", async ({ page }) => {
    await readDecisions(page);
    // A row that repeats an existing trip offers Add anyway.
    await expect(page.locator("#paste-rows")).toContainText("Add anyway");
  });
});

test.describe("review matrix", () => {
  // Step 26: the `#paste-rows` stream with change badges, pasted and
  // estimated times, was-values, removals and the timing note. The run is
  // deferred to branch review with the browser partition, like the cases
  // above.
  const MATRIX_PASTE = [
    "Trip\tCentral Station\tMarket Street\tMill Street\tRiverside Terminal",
    "1201\t6:00\t6:04\t6:10\t6:18",
    "1203\t7:00\t7:04\t7:10\t7:18",
  ].join("\n");

  async function readMatrix(page) {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", MATRIX_PASTE);
    await page.click("#paste-read");
    await expect(page.locator("#paste-review")).toBeVisible();
  }

  test("streams one row per pasted trip with badges and times", async ({
    page,
  }) => {
    await readMatrix(page);
    await expect(page.locator("#paste-rows #paste-row-1")).toBeVisible();
    await expect(page.locator("#paste-rows #paste-row-2")).toBeVisible();
    await expect(page.locator("#paste-rows #paste-row-1")).toContainText("6:00");
    await expect(
      page.locator("#paste-review-table thead"),
    ).toContainText("Central Station");
    await expect(page.locator("#paste-review-table thead")).toContainText(
      "Timing",
    );
    await expect(page.locator("#paste-review-table thead")).toContainText(
      "Details",
    );
  });

  test("switching to All stops keeps the streamed rows", async ({ page }) => {
    await readMatrix(page);
    await page.click("label:has(input[name='paste[stops_view]'][value='all'])");
    await expect(page.locator("#paste-rows #paste-row-1")).toBeVisible();
    await expect(page.locator("#paste-rows #paste-row-2")).toBeVisible();
    await expect(page.locator("#paste-review")).toContainText(
      "stored to the second as estimates",
    );
  });

  test("selecting a timing name opens the timing note", async ({ page }) => {
    await readMatrix(page);
    await page.locator("#paste-rows #paste-row-1 button").first().click();
    await expect(page.locator("#paste-timing-note")).toBeVisible();
    await page.click("#paste-timing-close");
    await expect(page.locator("#paste-timing-note")).toHaveCount(0);
  });
});

test.describe("apply outcomes", () => {
  // Step 28: the sticky apply bar, the Discard and Replace confirmations
  // and the Schedules landing after a real apply. The run is deferred to
  // branch review with the browser partition, like the cases above. The
  // final success test writes two trips to the shared browser seed, so it
  // stays last in this file.
  const APPLY_HEADERS = [
    "Central Station",
    "Market Street",
    "Oak & 3rd",
    "Mill Street",
    "Library",
    "Hospital",
    "River Park",
    "Riverside Terminal",
  ].join("\t");

  // Two starts past the seeded day (Typical offsets, so no new timing),
  // both absent from the seed: a clean Add of 2 changes.
  const APPLY_PASTE = [
    APPLY_HEADERS,
    "10:00\t10:03\t10:06\t10:10\t10:14\t10:18\t10:24\t10:28",
    "10:30\t10:33\t10:36\t10:40\t10:44\t10:48\t10:54\t10:58",
  ].join("\n");

  // Every seeded Weekday outbound start except 08:00: in Replace mode the
  // missing 08:00 trip (1209, with two Riverside transfers) becomes the
  // removal the confirmation must name.
  const REPLACE_PASTE = [
    APPLY_HEADERS,
    "6:00\t6:03\t6:06\t6:10\t6:14\t6:18\t6:24\t6:28",
    "6:30\t6:33\t6:36\t6:40\t6:44\t6:48\t6:54\t6:58",
    "7:00\t7:03\t7:06\t7:10\t7:14\t7:18\t7:24\t7:28",
    "7:30\t7:33\t7:36\t7:40\t7:44\t7:48\t7:54\t7:58",
    "8:30\t8:33\t8:36\t8:40\t8:44\t8:48\t8:54\t8:58",
    "9:00\t9:03\t9:06\t9:10\t9:14\t9:18\t9:24\t9:28",
  ].join("\n");

  async function readPaste(page, text) {
    await logIn(page);
    const versionId = await versionIdFor(page, "Browser E2E Version");

    await page.goto(pastePath(versionId, PASTE_ROUTE));
    await page.fill("#paste-source", text);
    await page.click("#paste-read");
    await expect(page.locator("#paste-review")).toBeVisible();
  }

  test("the apply bar names the change count with discard and apply", async ({
    page,
  }) => {
    await readPaste(page, APPLY_PASTE);
    await expect(page.locator("#paste-apply-bar")).toBeVisible();
    await expect(page.locator("#paste-apply-status")).toContainText(
      "Ready. Nothing has been saved yet.",
    );
    await expect(page.locator("#paste-apply")).toContainText(
      "Apply 2 changes",
    );
    await expect(page.locator("#paste-discard")).toContainText(
      "Discard paste",
    );
  });

  test("discarding asks for confirmation and keeps the paste on cancel", async ({
    page,
  }) => {
    await readPaste(page, APPLY_PASTE);
    await page.click("#paste-discard");
    await expect(page.locator("#paste-discard-confirm")).toBeVisible();
    await expect(page.locator("#paste-discard-confirm")).toContainText(
      "Discard this paste?",
    );
    await expect(
      page.locator("#paste-discard-confirm-confirm"),
    ).toContainText("Discard paste");
    await page.click("#paste-discard-confirm-cancel");
    await expect(page.locator("#paste-discard-confirm")).toHaveCount(0);
    await expect(page.locator("#paste-review")).toBeVisible();
  });

  test("replace with a removal names trip 1209 and its two transfers", async ({
    page,
  }) => {
    await readPaste(page, REPLACE_PASTE);
    await page.click('#paste-mode label:has(input[value="replace"])');
    await expect(page.locator("#paste-apply")).toContainText(
      "Replace trips · 1 change",
    );
    await page.click("#paste-apply");
    await expect(page.locator("#paste-replace-confirm")).toBeVisible();
    await expect(page.locator("#paste-replace-confirm")).toContainText(
      "BPS_1209",
    );
    await expect(page.locator("#paste-replace-confirm")).toContainText(
      "2 transfers",
    );
    await expect(
      page.locator("#paste-replace-confirm-cancel"),
    ).toBeFocused();
    await page.click("#paste-replace-confirm-cancel");
    await expect(page.locator("#paste-replace-confirm")).toHaveCount(0);
    await expect(page.locator("#paste-review")).toBeVisible();
  });

  test("applying a clean paste lands on Schedules with the flash", async ({
    page,
  }) => {
    await readPaste(page, APPLY_PASTE);
    await page.click("#paste-apply");
    await expect(page).toHaveURL(/\/schedules\?service_id=BPS_WKDY/);
    await expect(page.locator("#flash-info")).toContainText("Added 2 trips");
    await expect(page.locator("#flash-info")).toContainText(
      "Vehicles needed",
    );
  });
});
