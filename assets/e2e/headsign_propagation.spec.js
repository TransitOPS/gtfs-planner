import { test, expect } from "@playwright/test";
import { logInAs } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Headsign propagation journeys (spec 20).
 *
 * Every journey owns one BROWSER-HS* pattern from `test/support/browser_seed.exs`,
 * so a mutating journey never inherits another's writes: the Details usage line,
 * the read-only review-drawer render, the read-only Riders see column and the
 * read-only Patterns list column read
 * BROWSER-HS1, the inline edit, save
 * and undo drives BROWSER-HS2, the review drawer fixes a typo on BROWSER-HS3,
 * the timing disclosure BROWSER-HS4, and the schedules surface BROWSER-HS5. The
 * continuation trips live on the BROWSER_HEADSIGNS_20 route and share each
 * pattern's block id.
 *
 * The details journey here runs against the wired Details task; the read-only
 * review-drawer render opens through the wired `open_headsign_review` event,
 * and the mutating review journey fixes the typo on BROWSER-HS3.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const CAPTURE_DIR = process.env.HEADSIGN_CAPTURE_DIR;

async function capture(page, name) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`), fullPage: true });
}

// A drawer is a top-layer dialog anchored to the viewport, so a fullPage shot
// leaves it half outside the extended frame; these capture what a user sees.
async function captureViewport(page, name) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
}

// The panel slides in over 300ms (ds-drawer-slide-in), so a capture or a
// coordinate taken at open time freezes it mid-flight; wait for it to sit at
// the viewport's right edge.
async function waitDrawerSettled(page, panelId = "headsign-review-drawer") {
  await expect
    .poll(() =>
      page.evaluate((id) => {
        const panel = document.querySelector(`#${id}`);
        const aside = panel && panel.closest("aside");
        return aside ? aside.getBoundingClientRect().right - window.innerWidth : Number.NaN;
      }, panelId),
    )
    .toBeLessThanOrEqual(1);
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return Boolean(main) && main.classList.contains("phx-connected") && window.liveSocket?.isConnected();
    },
    { timeout: 20000 },
  );
}

async function getVersionId(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

async function openPattern(page, versionId, routeId, patternId, task) {
  await page.goto(`/gtfs/${versionId}/routes/${routeId}/patterns/${patternId}?task=${task}`);
  await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
  await waitForLiveView(page);
}

let versionId;

test.beforeEach(async ({ page }) => {
  await logInAs(page, EDITOR_USER);
  versionId = await getVersionId(page);
});

test("usage line on details", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

  const usage = page.locator("#headsign-usage");
  await expect(usage).toContainText("Used by 5 trips");
  await expect(usage).toContainText("2 show a different headsign");
  await expect(usage.getByText("1 likely typo")).toBeVisible();
  await expect(page.locator("#headsign-usage-review")).toContainText("Review 2 trips");

  await capture(page, "details-hs1-usage-1440");
});

// The mutating Details journey (BROWSER-HS2): edit the headsign, watch the
// inline update box stage the three followers, save without the impact
// dialog, and undo. Each assertion pins the AC-5/6/9/10/17 copy the card's
// verification cases name.
test("edit, save and undo on details", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS2", "details");

  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");

  await capture(page, "details-hs2-details-1440");

  await page.fill("#pattern-details-headsign", "Lincoln City via Depoe Bay");

  const box = page.locator("#headsign-update-box");
  await expect(box).toContainText("Also update 3 trips that show Lincoln City");
  await expect(box).toContainText("2 trips with a different headsign stay as they are.");
  await expect(page.locator("#headsign-update-toggle")).toBeChecked();
  await expect(page.locator("#headsign-warnings")).toHaveCount(0);
  const save = page.locator("#pattern-details-submit");
  await expect(save).toHaveText("Save headsign");
  await expect(page.locator("#pattern-save-status")).toContainText("Saving updates 3 trips");

  await capture(page, "details-hs2-editing-1440");

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("#headsign-update-box")).toBeVisible();
  await capture(page, "details-hs2-editing-390");
  await page.setViewportSize({ width: 1440, height: 900 });

  await save.click();

  // A headsign-only save opens no "Update N trips?" dialog.
  await expect(page.locator("#details-impact-dialog[data-open='true']")).toHaveCount(0);

  const result = page.locator("#headsign-result");
  await expect(result).toContainText("Headsign saved · 3 trips updated");
  await expect(result).toContainText("3 trips now show Lincoln City via Depoe Bay");
  await expect(result).toContainText("Undo headsign change");
  await expect(result).toContainText("Review 2 trips");
  await expect(page.locator("#pattern-details-headsign")).toHaveValue(
    "Lincoln City via Depoe Bay",
  );
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");
  await expect(page.locator("#pattern-save-status")).toContainText("3 trips updated");

  await capture(page, "details-hs2-saved-1440");

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("#headsign-result")).toBeVisible();
  await capture(page, "details-hs2-saved-390");
  await page.setViewportSize({ width: 1440, height: 900 });

  await page.locator("#headsign-undo").click();

  await expect(page.locator("#headsign-result")).toHaveCount(0);
  await expect(page.locator("#pattern-save-status")).toContainText("Headsign change undone");
  await expect(page.locator("#pattern-details-headsign")).toHaveValue("Lincoln City");
  await expect(page.locator("#headsign-usage")).toContainText("Used by 5 trips");
  await expect(page.locator("#headsign-usage")).toContainText("2 show a different headsign");
});

// Read-only render journey: the drawer opens from the usage line's Review link
// and shows the seeded typo and interline groups without touching any trip.
test("review drawer renders", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

  await page.locator("#headsign-usage-review").click();

  const drawer = page.locator("#headsign-review-drawer");
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page);
  await expect(drawer).toContainText("Trips with a different headsign");
  await expect(drawer).toContainText("Lincoln city");
  await expect(drawer).toContainText("Likely typo");
  await expect(drawer).toContainText("Roads End via Lincoln City");
  await expect(drawer).toContainText("Next in block: Route H20 at 10:15 toward Roads End");
  await expect(drawer).toContainText("Change trips");

  await captureViewport(page, "review-hs1-drawer-1440");
});

// The mutating review journey (BROWSER-HS3): the exceptions drawer fixes the
// likely typo — Escape returns focus to the opener, Select likely typo stages
// one trip, Change writes it under the per-trip fence, the done callout offers
// Undo, and Undo restores the seeded value through the page's confirmation.
test("exceptions drawer fixes a typo", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS3", "details");

  const usage = page.locator("#headsign-usage");
  await expect(usage).toContainText("Used by 5 trips");
  await expect(usage).toContainText("2 show a different headsign");

  await capture(page, "review-hs3-details-1440");

  await page.locator("#headsign-usage-review").click();

  const drawer = page.locator("#headsign-review-drawer");
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page);
  await expect(drawer).toContainText("Trips with a different headsign");
  await expect(drawer).toContainText("3 of 5 trips show");
  await expect(drawer).toContainText("Lincoln city");
  await expect(drawer).toContainText("Likely typo");
  await expect(drawer).toContainText("Roads End via Lincoln City");

  const apply = page.locator("#headsign-review-drawer-apply");
  await expect(apply).toContainText("Change trips");
  await expect(apply).toBeDisabled();

  await captureViewport(page, "review-hs3-drawer-1440");

  // Escape closes the drawer and focus returns to the opener button.
  await page.keyboard.press("Escape");
  await expect(drawer).toHaveCount(0);
  await expect(page.locator("#headsign-usage-review")).toBeFocused();

  await page.locator("#headsign-usage-review").click();
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page);
  await expect(drawer).toContainText("Lincoln city");

  await page.locator("#headsign-review-drawer-select-typos").click();
  await expect(apply).toContainText("Change 1 trip to Lincoln City");
  await expect(apply).toBeEnabled();

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(drawer).toBeVisible();
  await captureViewport(page, "review-hs3-drawer-390");
  await page.setViewportSize({ width: 1440, height: 900 });

  await apply.click();

  const done = page.locator("#headsign-review-drawer-done");
  await expect(done).toContainText("1 trip now shows Lincoln City");
  await expect(done).toContainText("1 trip kept a different headsign");
  await expect(page.locator("#headsign-review-drawer-undo")).toBeVisible();

  await captureViewport(page, "review-hs3-done-1440");

  // The usage behind the drawer reloaded with the write.
  await expect(usage).toContainText("1 shows a different headsign");

  // The done callout's Undo restores the seeded typo and closes the drawer
  // onto the page's confirmation.
  await page.locator("#headsign-review-drawer-undo").click();
  await expect(drawer).toHaveCount(0);
  await expect(page.locator("#pattern-save-status")).toContainText("Headsign change undone");
  await expect(usage).toContainText("Used by 5 trips");
  await expect(usage).toContainText("2 show a different headsign");

  // Change mode, from the inline update box: the followers start checked and
  // Escape hands focus back to the box's review button. Nothing is written.
  await page.fill("#pattern-details-headsign", "Lincoln City via Depoe Bay");
  await page.locator("#headsign-update-review").click();
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page);
  await expect(drawer).toContainText("Trips the new headsign reaches");
  await expect(drawer).toContainText("Preview · not saved");
  await expect(drawer).toContainText("Show Lincoln City");
  await expect(page.locator("#headsign-review-drawer-group-0-toggle")).toBeChecked();

  await captureViewport(page, "review-hs3-change-1440");

  await page.keyboard.press("Escape");
  await expect(drawer).toHaveCount(0);
  await expect(page.locator("#headsign-update-review")).toBeFocused();
});

// The timing disclosure journey (BROWSER-HS4): the closed summary names the
// pattern's value with the differ count and Change, opening shows the field
// with the timing's usage line, and editing stages the update box against the
// timing's effective default. Nothing is saved — the ExUnit suite owns the
// timing save semantics on the same wiring.
test("timing headsign disclosure", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS4", "timings");

  const disclosure = page.locator("#timing-headsign-disclosure");
  const summary = page.locator("#timing-headsign-summary");
  await expect(summary).toContainText("Headsign:");
  await expect(summary).toContainText("Lincoln City");
  await expect(summary).toContainText("from the pattern");
  await expect(summary).toContainText("Change");
  await expect(summary).toContainText("2 of 5 trips differ");
  await expect(disclosure).not.toHaveAttribute("open");

  await capture(page, "times-hs4-closed-1440");

  await summary.click();
  await expect(disclosure).toHaveAttribute("open");
  await expect(page.locator("#timing-headsign")).toHaveValue("");
  await expect(page.locator("#timing-headsign-form")).toContainText("Headsign for Weekday base");
  await expect(page.locator("#timing-headsign-help")).toContainText(
    "Leave blank to use the pattern’s headsign, Lincoln City",
  );

  const usage = page.locator("#timing-headsign-usage");
  await expect(usage).toContainText("Used by 5 trips");
  await expect(usage).toContainText("2 show a different headsign");
  await expect(usage).toContainText("1 likely typo");
  await expect(page.locator("#timing-headsign-usage-review")).toContainText("Review 2 trips");

  await capture(page, "times-hs4-open-1440");

  // Editing stages the update box against the timing's effective default and
  // names the narrower save in the bar.
  await page.fill("#timing-headsign", "Lincoln City via Taft High");
  const box = page.locator("#timing-headsign-update-box");
  await expect(box).toContainText("Also update 3 trips that show Lincoln City");
  await expect(page.locator("#timing-headsign-update-toggle")).toBeChecked();
  await expect(page.locator("#timing-save")).toHaveText("Save headsign");
  await expect(page.locator("#pattern-save-status")).toContainText("Saving updates 3 trips");

  await capture(page, "times-hs4-box-1440");

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(disclosure).toHaveAttribute("open");
  await expect(box).toBeVisible();
  await capture(page, "times-hs4-open-390");
  await page.setViewportSize({ width: 1440, height: 900 });

  // Returning the field to the stored value brings the usage line back; the
  // staged edit itself survives as a padded save, as with the row cells.
  await page.fill("#timing-headsign", "Lincoln City");
  await expect(usage).toBeVisible();
  await expect(box).toHaveCount(0);
});

// The Riders see column (read-only, BROWSER-HS1): row 3's stop headsign is
// bold with "Set at this stop" on the info tint, other rows show the pattern
// default muted, and the last row shows "Last stop · none". Nothing is saved —
// the ExUnit suite owns the column's rendering contracts.
test("riders see column", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "timings");

  await expect(page.locator("#timing-table")).toContainText("Riders see");
  await expect(page.locator("#timing-table")).toContainText("headsign at this stop");

  await expect(page.locator("#timing-riders-3")).toContainText("Lincoln City Transit Center");
  await expect(page.locator("#timing-riders-3")).toContainText("Set at this stop");
  await expect(page.locator("#timing-riders-3")).toHaveClass(/bg-info-bg\/60/);
  await expect(page.locator("#timing-riders-1")).toContainText("Lincoln City");
  await expect(page.locator("#timing-riders-4")).toContainText("Last stop · none");

  await capture(page, "times-stop-headsign-1440");

  // At 390 px the column rides the table's stacked cards, so every value stays
  // readable without horizontal scrolling.
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.locator("#timing-riders-3")).toBeVisible();
  await expect(page.locator("#timing-riders-3")).toContainText("Lincoln City Transit Center");
  await expect(page.locator("#timing-riders-4")).toContainText("Last stop · none");
  await capture(page, "times-stop-headsign-390");
});

// The Patterns list column (read-only, BROWSER-HS1): the Headsign header sits
// after Pattern and the BROWSER-HS1 row shows the pattern default with the
// differ count and the typo warning. Only BROWSER-HS1 is asserted — the same
// list also carries HS2–HS5, which the other journeys mutate. Nothing is saved.
test("patterns list headsign column", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(`/gtfs/${versionId}/routes/BROWSER_HEADSIGNS/patterns`);
  await page.waitForSelector("#pattern-headsign-BROWSER-HS1", { timeout: 15000 });
  await waitForLiveView(page);

  const header = await page.locator("#patterns-table thead").textContent();
  expect(header).toMatch(/Pattern\s+Headsign\s+Use on this route/);

  const cell = page.locator("#pattern-headsign-BROWSER-HS1");
  await expect(cell).toContainText("Lincoln City");
  await expect(cell).toContainText("2 trips differ · 1 likely typo");
  await expect(cell.locator(".hero-exclamation-triangle")).toBeVisible();

  await capture(page, "patterns-headsign-1440");

  // At 390 px the cell is a full-width card block with its visible label, so
  // the value and the count stay readable without horizontal scrolling.
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(cell).toBeVisible();
  await expect(cell).toContainText("Headsign");
  await expect(cell).toContainText("Lincoln City");
  await expect(cell).toContainText("2 trips differ · 1 likely typo");
  await capture(page, "patterns-headsign-390");
});

// The Schedules headsign facts (read-only, BROWSER-HS5): the timetable shows
// "To …" only for trips that don't follow the default — the typo trip in
// warning ink, the interline trip muted — and the trip drawer's note explains
// the field and fills the default through Use Lincoln City. Nothing is saved:
// the drawers close through Cancel, and the ExUnit suite owns the note
// variants this seed can't show.
test("schedules headsign facts", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  // The trips run on the BROWSER_PATTERN_SERVICE calendar, so the journey pins
  // it in the URL; a missing filter lands on the first calendar, which has no
  // trips on this route.
  await page.goto(
    `/gtfs/${versionId}/routes/BROWSER_HEADSIGNS/schedules?service_id=BROWSER_PATTERN_SERVICE`,
  );
  await page.waitForSelector("#trip-BROWSER_HS5_T4-headsign", { timeout: 15000 });
  await waitForLiveView(page);

  const typoLine = page.locator("#trip-BROWSER_HS5_T4-headsign");
  await expect(typoLine).toContainText("To Lincoln city");
  await expect(typoLine).toHaveClass(/text-warning-fg/);

  const interlineLine = page.locator("#trip-BROWSER_HS5_T5-headsign");
  await expect(interlineLine).toContainText("To Roads End via Lincoln City");
  await expect(interlineLine).toHaveClass(/text-muted/);

  // Trips that follow the default show nothing under their timing.
  expect(await page.locator("#trip-BROWSER_HS5_T1-headsign").count()).toBe(0);

  await capture(page, "sched-hs5-1440");

  // The typo trip's drawer: the warning note with the Use default button.
  await page.locator("#trip-BROWSER_HS5_T4-edit").click();
  const drawer = page.locator("#trip-drawer");
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page, "trip-drawer");

  const note = page.locator("#trip-headsign-note");
  await expect(note).toContainText(
    "Differs from the pattern’s headsign, Lincoln City, only in capital letters or spacing.",
  );
  await expect(note).toContainText("Riders may see both spellings.");
  const useDefault = page.locator("#trip-headsign-note-use-default");
  await expect(useDefault).toHaveText("Use Lincoln City");
  await note.scrollIntoViewIfNeeded();

  await captureViewport(page, "sched-trip-case-1440");

  // Use default fills the field and the note flips to the same-as confirmation.
  await useDefault.click();
  await expect(page.locator("#trip-headsign")).toHaveValue("Lincoln City");
  await expect(note).toContainText(
    "Same as the pattern’s headsign. Changing that headsign can update this trip.",
  );

  await captureViewport(page, "sched-trip-same-1440");

  await page.locator("#trip-drawer-cancel").click();
  await expect(page.locator("#trip-drawer-form")).toHaveCount(0);

  // The interline trip's drawer: the info note that names the kept value, with
  // the same Use default button.
  await page.locator("#trip-BROWSER_HS5_T5-edit").click();
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page, "trip-drawer");
  await expect(note).toContainText(
    "This trip shows Roads End via Lincoln City instead of the pattern’s headsign, Lincoln City.",
  );
  await expect(note).toContainText(
    "When that headsign changes later, this trip keeps Roads End via Lincoln City.",
  );
  await expect(useDefault).toHaveText("Use Lincoln City");
  await note.scrollIntoViewIfNeeded();

  await captureViewport(page, "sched-trip-interline-1440");

  await page.locator("#trip-drawer-cancel").click();
  await expect(page.locator("#trip-drawer-form")).toHaveCount(0);

  // At 390 px the To-line rides the timing cell without clipping, and the
  // drawer's warning note stays readable with its button.
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(typoLine).toBeVisible();
  await expect(typoLine).toContainText("To Lincoln city");
  await typoLine.scrollIntoViewIfNeeded();
  await capture(page, "sched-hs5-390");

  await page.locator("#trip-BROWSER_HS5_T4-edit").click();
  await expect(drawer).toBeVisible();
  await waitDrawerSettled(page, "trip-drawer");
  await expect(note).toContainText("Differs from the pattern’s headsign, Lincoln City");
  await expect(useDefault).toBeVisible();
  await note.scrollIntoViewIfNeeded();
  await captureViewport(page, "sched-trip-case-390");

  await page.locator("#trip-drawer-cancel").click();
  await expect(page.locator("#trip-drawer-form")).toHaveCount(0);
});
