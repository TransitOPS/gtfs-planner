import { test, expect } from "@playwright/test";
import { existsSync, mkdirSync } from "node:fs";
import { resolve } from "node:path";

import { bodyFitsViewport, logInAs } from "./browser_helpers.js";

// The publication journeys, on the ordinary application `bin/test-browser`
// starts: the Export page's review, the alert editor's publication card and the
// organization's published-feeds page. Every step goes through the production
// routes and the production commands; the only substitute is the final HTTP
// transport, which is the loopback object-store boundary, so no test asserts a
// mocked domain result.
//
// `@static`, `@alerts` and `@settings` run with publishing configured against
// that boundary, which is the state where addresses and receipts exist.
// `@disabled` needs the same application booted with nothing configured; the
// command is in `.specs/24-feed-publishing/evidence/qa-scenarios.md` and the
// cases are skipped when the run has publishing on.

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// Captures land in the feature package when the checkout has one, and fall back
// to Playwright's own output folder otherwise, so the suite never writes outside
// the project. `.specs/` is gitignored, so a worktree run sets PUB_FEATURE_DIR.
const FEATURE_DIR =
  process.env.PUB_FEATURE_DIR ||
  resolve(import.meta.dirname, "../../.specs/24-feed-publishing");
const CAPTURE_DIR = resolve(FEATURE_DIR, "evidence/screenshots");
const CAPTURES_ENABLED = existsSync(CAPTURE_DIR);

// The three alerts the publication card is asserted against, by the wording the
// seed gives them.
const CONFIRMED_ALERT = "Route 12 delays of up to 20 minutes";
const SCHEDULED_ALERT = "Harbor Street stop closed for road works";
const REFERENCE_GONE_ALERT = "Old Depot Road stop closed";

const DESKTOP = { width: 1280, height: 900 };
const NARROW = { width: 320, height: 800 };

async function shot(page, name, { fullPage = true } = {}) {
  if (!CAPTURES_ENABLED) return;

  await page.screenshot({
    path: resolve(CAPTURE_DIR, `step-021-${name}.png`),
    fullPage,
  });
}

// The shared export-UX capture surface for this feature. Nothing is written
// unless EXPORT_UX_CAPTURE_DIR names a directory.
const EXPORT_UX_CAPTURE_DIR = process.env.EXPORT_UX_CAPTURE_DIR;

async function exportCapture(page, name, viewport) {
  if (!EXPORT_UX_CAPTURE_DIR) return;

  mkdirSync(EXPORT_UX_CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(EXPORT_UX_CAPTURE_DIR, `${name}-${viewport.label}.png`),
    fullPage: true,
  });
}

// A ready file's Publish action is one item in the row's own more-actions menu,
// which opens the row-bound publication drawer.
async function openPublishDrawer(page, filename) {
  const row = page
    .locator("tbody[id^='export-file-']")
    .filter({ hasText: filename })
    .first();
  await expect(row).toBeVisible();

  const rowId = await row.getAttribute("id");
  await row.locator(`#${rowId}-menu summary`).click();

  const publish = row.locator(`#${rowId}-publish`);
  await publish.click();
  await expect(page.locator("#publish-drawer")).toBeVisible();
}

// The organization's default published version is the one the seed backdates its
// other versions behind, so the task link names the export page this journey
// uses without the test knowing an id.
async function exportPage(page, query = "") {
  await page.goto("/");
  await page.waitForSelector("#main-navigation");
  const href = await page
    .locator("#main-navigation a[href$='/export'], #main-navigation a[href*='/export?']")
    .first()
    .getAttribute("href");

  await page.goto(`${href}${query}`);
  await page.waitForSelector("#export-page");

  // The opener is a `phx-click` control: a click before the socket joins is
  // dropped, so every journey waits for the connected frame first.
  await page.waitForSelector("[data-phx-main].phx-connected");

  return href.split("?")[0];
}

// The alert editor is reached the way an editor reaches it: from the alert list,
// on the tab that lists it. The list renders one tab at a time and gives every
// row an id that names the alert, in a table on desktop and a card at narrow
// widths, so the row's own id is the identity - not the wording inside it.
const ALERT_ROWS = "[id^='alert-row-'], [id^='alert-card-']";

async function alertIdFor(page, header, tab = "current") {
  await page.goto(`/alerts?tab=${tab}`);
  await page.waitForSelector("#alerts-page");

  const rows = header
    ? page.locator(ALERT_ROWS).filter({ hasText: header })
    : page.locator(ALERT_ROWS);

  const rowId = await rows.first().getAttribute("id");

  return rowId.replace(/^alert-(row|card)-/, "");
}

async function openReview(page, alertId) {
  await page.goto(`/alerts/${alertId}?mode=form&step=review`);
  await page.waitForSelector("#alert-review");
  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.waitForTimeout(300);
}

test.describe.configure({ timeout: 120_000 });

test.beforeEach(async ({ page }) => {
  await logInAs(page, EDITOR);
});

test.describe("static publication @static", () => {
  test("a ready file offers Publish beside Download and reviews exactly that file", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    await exportPage(page);

    // The opener sits in the run's own action row, inside its more-actions menu.
    const fullRow = page
      .locator("tbody[id^='export-file-']")
      .filter({ hasText: "browser-full.zip" })
      .first();
    await expect(fullRow).toBeVisible();
    await expect(fullRow.locator("[id$='-download']")).toBeVisible();

    const fullRowId = await fullRow.getAttribute("id");
    await fullRow.locator(`#${fullRowId}-menu summary`).click();
    const opener = fullRow.locator(`#${fullRowId}-publish`);
    await expect(opener).toBeVisible();

    // Keyboard operation: the action is reachable from the keyboard and opens
    // the review when it is activated, not only when it is clicked.
    await opener.focus();
    await expect(opener).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#publish-drawer")).toBeVisible();
    const review = page.locator("#feed-publish-review");
    await expect(review).toBeVisible();

    // The review is the server's own answer about this file: its permanent
    // address, the emitted profile, the reviewed hash, the check report and the
    // disclosed inventory.
    await expect(page.locator("#feed-publish-url")).toContainText(
      "/browser-test/static/gtfs.zip",
    );
    await expect(page.locator("#feed-publish-report")).toContainText("0 errors");
    await expect(page.locator("#feed-publish-inventory")).toContainText("routes.txt");
    await expect(page.locator("#feed-publish-inventory")).toContainText("agency.txt");

    // One primary action, and no error count to confirm on a clean report.
    await expect(page.locator("#feed-publish-confirm")).toBeVisible();
    await expect(page.locator("#feed-publish-confirm-errors")).toHaveCount(0);

    await shot(page, "static-review-1280");
  });

  test("publishing the reviewed file records durable intent @static", async ({ page }) => {
    await page.setViewportSize(NARROW);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await exportPage(page);

    await expect(bodyFitsViewport(page)).resolves.toBe(true);

    await openPublishDrawer(page, "browser-full.zip");
    await expect(page.locator("#feed-publish-review")).toBeVisible();

    for (const viewport of [
      { label: "1440", width: 1440, height: 1000 },
      { label: "320", width: 320, height: 800 },
    ]) {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(bodyFitsViewport(page)).resolves.toBe(true);
      await exportCapture(page, "publish-review", viewport);
    }

    await page.setViewportSize(NARROW);

    // Keyboard: the primary action is a submit control in the review's own form.
    await page.locator("#feed-publish-confirm").focus();
    await page.keyboard.press("Enter");

    // The review is answered with the page's durable-intent confirmation.
    await expect(page.locator("#feed-publish-review")).toHaveCount(0);
    await expect(page.locator("#export-toast-text")).toContainText(
      "queued for publication",
    );

    await shot(page, "static-published-320");
  });

  test("a check with errors refuses the publish until the count is confirmed @static", async ({
    page,
  }) => {
    await page.setViewportSize(DESKTOP);
    await exportPage(page, "?type=pathways");

    await openPublishDrawer(page, "browser-pathways.zip");
    const review = page.locator("#feed-publish-review");
    await expect(review).toBeVisible();

    // This file's check reported errors, so the review asks for a count-aware
    // confirmation before it will queue anything.
    await expect(page.locator("#feed-publish-report")).toContainText("3 errors");
    const consent = page.locator("#feed-publish-confirm-errors");
    await expect(consent).toBeVisible();
    await expect(consent).not.toBeChecked();

    await page.locator("#feed-publish-confirm").click();

    // Refused: the review stays open with its own numbers, the refusal names the
    // count, and the control keeps the answer the operator gave it.
    await expect(page.locator("#feed-publish-refusal")).toContainText(
      "Confirm the check report first",
    );
    await expect(page.locator("#feed-publish-refusal")).toContainText("3 errors");
    await expect(review).toBeVisible();

    await shot(page, "static-consent-1280");

    // The tick is the operator's own answer, and it carries the same review to
    // acceptance.
    await consent.check();
    await page.locator("#feed-publish-confirm").click();
    await expect(review).toHaveCount(0);
  });
});

test.describe("alert publication @alerts", () => {
  test("a served date appears only for the alert the manifest confirmed", async ({ page }) => {
    await page.setViewportSize(DESKTOP);

    // Confirmed by the served manifest: the card reports the date it was served.
    await openReview(page, await alertIdFor(page, CONFIRMED_ALERT));
    await expect(page.locator("#alert-publication-status")).toBeVisible();
    await expect(page.locator("#alert-publication-date")).toContainText(
      "Reflected in the public feed",
    );

    // Accepted for a notice that has not begun: accepted, and no served date.
    // A planned notice is listed on its own tab.
    await openReview(page, await alertIdFor(page, SCHEDULED_ALERT, "upcoming"));
    await expect(page.locator("#alert-publication-status")).toBeVisible();
    await expect(page.locator("#alert-publication-date")).toContainText(
      "No confirmed publication yet",
    );
    await expect(page.locator("#alert-publish-checkbox")).not.toBeChecked();

    // A checked Save accepts the revision the editor is holding: the consent
    // control becomes a republish control because the alert now has an accepted
    // revision, the notice is still scheduled rather than served, and the date
    // still waits for the manifest.
    await page.locator("#alert-publish-checkbox").check();
    await page.locator("#save-alert").click();
    await expect(page.locator("#review-publication-form")).toContainText(
      "Republish these changes",
    );
    await expect(page.locator("#alert-publication-status")).toContainText("Scheduled");
    await expect(page.locator("#alert-publication-date")).toContainText(
      "No confirmed publication yet",
    );

    await shot(page, "alerts-accepted-1280");
  });

  test("a refused checked save keeps the operator's intent @alerts", async ({ page }) => {
    await page.setViewportSize(NARROW);

    // The draft the seed leaves unfinished is the alert on the In progress tab.
    await openReview(page, await alertIdFor(page, null, "in_progress"));

    const consent = page.locator("#alert-publish-checkbox");
    await consent.scrollIntoViewIfNeeded();
    await consent.check();
    await page.locator("#save-alert").click();

    // The refusal lists the questions still unanswered, the review stays open,
    // and the tick the operator gave it survives the refusal.
    // The refusal lists the questions still unanswered, and the consent the
    // operator gave survives it.
    await expect(page.locator("#alert-editor")).toContainText("Choose at least one route.");
    await expect(page.locator("#alert-editor")).toContainText(
      "Write the headline riders will see.",
    );
    await expect(consent).toBeChecked();

    await shot(page, "alerts-refused-320");
  });
});

test.describe("organization publication status @settings", () => {
  test("each channel reports its own address, source receipt and refresh", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await page.goto("/settings/published-feeds");
    await page.waitForSelector("#published-feeds");

    // One row per channel that serves a file, each with its own permanent
    // address and its own frozen source receipt.
    await expect(page.locator("#feed-status-full")).toContainText("Full feed");
    await expect(page.locator("#feed-url-full")).toContainText("/static/gtfs.zip");
    await expect(page.locator("#feed-source-full")).toContainText("browser-full.zip");
    await expect(page.locator("#feed-served-at-full")).toContainText("2026-10-02");

    await expect(page.locator("#feed-url-pathways")).toContainText(
      "/static/pathways.zip",
    );

    // A channel a previous publication left failed reports the row's own error;
    // the flex channel carries that state because no journey publishes it.
    await expect(page.locator("#feed-status-flex")).toContainText("Publication failed");
    await expect(page.locator("#feed-status-flex")).toContainText(
      "the public manifest belongs to another owner",
    );

    // The last refresh the application observed is reported as its own fact.
    await expect(page.locator("#feed-refresh-age")).toContainText("Last checked");

    // Keyboard: the copy control is a labelled button the keyboard can reach and
    // activate, and the page announces what happened rather than staying silent.
    const copy = page.locator("#feed-copy-full");
    await expect(copy).toBeVisible();
    await copy.focus();
    await expect(copy).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator("#feed-copy-notice")).toContainText(/copied/);
    await expect(page.locator("#feed-copy-notice")).not.toBeEmpty();

    await shot(page, "settings-live-1280");
  });

  test("an outstanding alert removal is reported at both widths @settings", async ({ page }) => {
    await page.setViewportSize(NARROW);
    await page.goto("/settings/published-feeds");
    await page.waitForSelector("#published-feeds");

    expect(await bodyFitsViewport(page)).toBe(true);

    // The delete is saved and the rider feed has not confirmed it: the alert is
    // gone from every alert list and still reported here.
    await expect(page.locator("#feed-pending-removals")).toBeVisible();
    await expect(page.locator("#feed-pending-removals")).toContainText(
      "still being removed",
    );
    await expect(page.locator("#feed-pending-removals")).toContainText(
      "harvest fair",
    );

    await expect(page.locator("#feed-url-full")).toBeVisible();
    await shot(page, "settings-pending-320");
  });
});

test.describe("publishing turned off @disabled", () => {
  // These need the same application started with nothing configured:
  // `GTFS_PUBLISH_TEST_DISABLED=true bin/test-browser e2e/feed_publishing.spec.js --grep @disabled`.
  // Publishing is configured for every other case in this file, so the boot that
  // runs them cannot also be the boot that proves this state.
  test.skip(
    process.env.GTFS_PUBLISH_TEST_DISABLED !== "true",
    "needs the disabled boot",
  );

  test("the history stays readable and the links go @disabled", async ({ page }) => {
    await page.setViewportSize(DESKTOP);
    await page.goto("/settings/published-feeds");
    await page.waitForSelector("#published-feeds");

    await expect(page.locator("#feed-status-disabled")).toContainText(
      "Publishing is turned off",
    );

    // What the organization already published is kept exactly as it was, and the
    // address and its control are hidden rather than offered as a dead link.
    await expect(page.locator("#feed-status-full")).toContainText("Published");
    await expect(page.locator("#feed-source-full")).toContainText("browser-full.zip");
    await expect(page.locator("#feed-refresh-age")).toContainText("Last checked");
    await expect(page.locator("#feed-copy-full")).toHaveCount(0);
    await expect(page.locator("#feed-url-full")).toHaveCount(0);

    await shot(page, "settings-disabled-1280");
  });

  test("the alert editor reports the read-only state instead @disabled", async ({ page }) => {
    await page.setViewportSize(NARROW);

    await openReview(page, await alertIdFor(page, CONFIRMED_ALERT));

    await expect(page.locator("#alert-publication-disabled")).toContainText(
      "Publishing is turned off",
    );
    await expect(page.locator("#review-publication-form")).toHaveCount(0);
    await expect(page.locator("#alert-publish-checkbox")).toHaveCount(0);

    await shot(page, "alerts-disabled-320");
  });
});
