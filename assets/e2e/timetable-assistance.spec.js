import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Timetable assistance (AI-04) step 3: the reviewed-source controls on the
 * existing Paste page.
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
