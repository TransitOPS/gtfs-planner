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
  "/Users/ryanmahoney/Documents/gtfs-planner/.specs/ai-04-timetable-assistance/evidence/captures";

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
  await page.fill("#paste-source", text);
  await page.click("#paste-read");
  await expect(page.locator("#paste-review")).toBeVisible();
  await expect(page.locator("#timetable-source-form")).toBeVisible();
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

test.describe("native batches", () => {
  test("a prepared batch reviews, saves and leaves the rest of the source unsaved", async ({
    page,
  }) => {
    // Two real saves and two full viewport captures on a shared seed.
    test.setTimeout(120_000);
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

