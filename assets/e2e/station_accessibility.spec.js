/**
 * Station accessibility validation views — browser journeys & visual captures
 * (Spec 45, Step 5).
 *
 * Fixtures come from `test/support/browser_seed.exs` under "Browser E2E Version":
 *   - ACCESSIBILITY_SMALL_STATION ("Riverside Square"): 3 levels, 3 entrances
 *     (2 step-free + 1 inaccessible), unpaid/paid mezzanine separated by mode-6
 *     fare gates (one near-threshold 0.90 m), 2 platforms (1 confirmed,
 *     1 unverified triggering :flag_mismatch), 2 sole-link elevators (one
 *     modeled as a 2-row directional pair per CR-M1), 1 measured barrier ramp
 *     (max_slope 0.11), and 2 unverified walkways missing min_width (grouped
 *     :unknown_data).
 *   - ACCESSIBILITY_TRANSFER_CENTER ("Harbor Transfer Center"): 4 levels,
 *     9 entrances (7 step-free across 3 structural groups + 2 inaccessible),
 *     9 platforms across 3 GTFS routes (Red Line, Blue Line, Commuter Rail),
 *     4-walkway verified concourse corridor chain, multi-landing pairwise
 *     elevator + sole-link & backup elevators, near-threshold ramp & gate,
 *     measured barrier ramp, and grouped unverified walkways.
 *
 * Assertions stay strictly behavioral (navigation URLs, LiveView state
 * transitions, keyboard focus, bodyFitsViewport, absence of excluded columns,
 * zero console/page errors); visual layout and contrast are inspected on the
 * PNG captures written to CAPTURE_DIR.
 */
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";
import { bodyFitsViewport, logInAs } from "./browser_helpers";

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const SMALL_STATION = "ACCESSIBILITY_SMALL_STATION";
const TRANSFER_CENTER = "ACCESSIBILITY_TRANSFER_CENTER";

const EXCLUDED_TERMS = [
  "Outage feed",
  "Last verified",
  "Blueprint only",
  "Field visit",
  "Not in outage feed",
];

const CAPTURE_DIR = process.env.CAPTURE_DIR || null;

function trackErrors(page) {
  const errors = [];
  page.on("pageerror", (err) => errors.push(`pageerror: ${err.message}`));
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      errors.push(`console.error: ${msg.text()}`);
    }
  });
  return errors;
}

async function saveCapture(page, filename) {
  if (!CAPTURE_DIR) return;
  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(CAPTURE_DIR, filename),
    fullPage: true,
    animations: "disabled",
  });
}

async function waitForLiveSocket(page) {
  await page.waitForFunction(
    () => window.liveSocket && window.liveSocket.isConnected(),
    null,
    { timeout: 20000 },
  );
}

async function seededVersionId(page) {
  await page.waitForSelector("#gtfs-version-switcher", { timeout: 20000 });

  const id = await page.evaluate(() => {
    const option = Array.from(
      document.querySelectorAll("[data-version-option]"),
    ).find((button) =>
      button.textContent.trim().startsWith("Browser E2E Version"),
    );
    return option ? option.dataset.versionId : null;
  });

  if (!id) {
    throw new Error("Browser E2E Version is missing from the version switcher");
  }
  return id;
}

async function waitForAccessibilityReady(page) {
  await page.waitForSelector(
    '#station-accessibility-page[data-derived-state="ready"]',
    { timeout: 20000 },
  );
  await waitForLiveSocket(page);
}

async function waitForDrawerOpen(page, drawerId) {
  await page.waitForFunction(
    (id) =>
      document.getElementById(`${id}-overlay`)?.getAttribute("data-open") ===
      "true",
    drawerId,
    { timeout: 20000 },
  );
}

test.describe("Station accessibility validation views", () => {
  test("small station Report -> Accessibility (Network & Validation) -> Floorplans & Report stop drawer", async ({
    page,
  }) => {
    const errors = trackErrors(page);
    await page.setViewportSize({ width: 1280, height: 900 });

    await logInAs(page, EDITOR);
    const versionId = await seededVersionId(page);

    // 1. Start on Station Report 2 and follow the accessibility CTA
    await page.goto(`/gtfs/${versionId}/stops/${SMALL_STATION}/report`);
    await page.waitForSelector("#report2-reachability-connectivity", {
      timeout: 20000,
    });
    await waitForLiveSocket(page);

    const cta = page.locator("#station-report-accessibility-link");
    await expect(cta).toHaveCount(1);
    await cta.click();

    await page.waitForURL(
      new RegExp(`/gtfs/${versionId}/stops/${SMALL_STATION}/report/accessibility`),
      { timeout: 20000 },
    );
    await waitForAccessibilityReady(page);

    // 2. Network view loads with Rider routes active
    await expect(page.locator("#accessibility-view-switcher")).toHaveCount(1);
    await expect(page.locator("#view-switch-network")).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(page.locator("#tab-rider-routes")).toHaveAttribute(
      "aria-selected",
      "true",
    );
    await expect(page.locator("#accessibility-schematic-svg")).toHaveCount(1);
    await expect(page.locator("#network-access-matrix-table")).toHaveCount(1);
    await expect(page.locator("#network-elevator-dependency-card")).toHaveCount(
      1,
    );

    expect(
      await bodyFitsViewport(page),
      "small station Rider routes overflows horizontally at 1280px",
    ).toBe(true);

    await saveCapture(page, "small-rider-1280.png");

    // 3. Keyboard Tab/Enter operates the view switcher and Rider routes / Validation tabs
    await page.locator("#view-switch-network").focus();
    await page.keyboard.press("Tab");
    await expect(page.locator("#view-switch-impact")).toBeFocused();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#accessibility-impact-view", {
      timeout: 15000,
    });
    await expect(page.locator("#view-switch-impact")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await page.locator("#view-switch-network").focus();
    await page.keyboard.press("Enter");
    await page.waitForSelector("#accessibility-network-view", {
      timeout: 15000,
    });

    await page.locator("#tab-rider-routes").focus();
    await page.keyboard.press("Tab");
    await expect(page.locator("#tab-validation")).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#tab-validation")).toHaveAttribute(
      "aria-selected",
      "true",
    );
    await page.waitForSelector("#validation-confidence-card", {
      timeout: 15000,
    });
    await expect(page.locator("#confidence-edge-completeness")).toHaveCount(1);
    await expect(page.locator("#validation-issues-card")).toHaveCount(1);

    // 4. Toggle all 4 highlight checkboxes and verify schematic updates
    const barriersBox = page.locator("#highlight-barriers");
    const unknownBox = page.locator("#highlight-unknown-data");
    const nearBox = page.locator("#highlight-near-threshold");
    const singleElBox = page.locator("#highlight-single-elevator");

    await expect(barriersBox).not.toBeChecked();
    await expect(unknownBox).toBeChecked();
    await expect(nearBox).toBeChecked();
    await expect(singleElBox).toBeChecked();

    // Check Barriers -> barrier ramp appears in SVG
    await barriersBox.click();
    await expect(barriersBox).toBeChecked();
    await expect(
      page.locator("#schematic-edge-ACC_SM_PW_BARRIER_RAMP"),
    ).toHaveCount(1);

    // Toggle the remaining 3 off and back on
    for (const box of [unknownBox, nearBox, singleElBox]) {
      await box.click();
      await expect(box).not.toBeChecked();
      await box.click();
      await expect(box).toBeChecked();
    }

    // Restore default Validation layer set (Unknown data, Near threshold,
    // Single-elevator routes checked; Barriers unchecked) for visual captures
    await barriersBox.click();
    await expect(barriersBox).not.toBeChecked();
    await expect(
      page.locator("#schematic-edge-ACC_SM_PW_BARRIER_RAMP"),
    ).toHaveCount(0);

    expect(
      await bodyFitsViewport(page),
      "small station Validation overflows horizontally at 1280px",
    ).toBe(true);
    await saveCapture(page, "small-validation-1280.png");

    // 5. Narrow mobile viewport fit + capture
    await page.setViewportSize({ width: 390, height: 844 });
    expect(
      await bodyFitsViewport(page),
      "small station Validation overflows horizontally at 390px",
    ).toBe(true);
    await saveCapture(page, "small-validation-390.png");

    // 6. Floorplans deep-link opens pathway edit drawer and clears edit_pathway_id
    await page.setViewportSize({ width: 1280, height: 900 });
    const pathwayIssueLink = page
      .locator('#validation-issues-card a[href*="/diagram"]')
      .first();
    await expect(pathwayIssueLink).toHaveCount(1);
    await pathwayIssueLink.click();

    await page.waitForURL(
      new RegExp(`/gtfs/${versionId}/stops/${SMALL_STATION}/diagram`),
      { timeout: 20000 },
    );
    await waitForDrawerOpen(page, "pathway-drawer");
    await page.waitForFunction(
      () => !new URLSearchParams(window.location.search).has("edit_pathway_id"),
      null,
      { timeout: 15000 },
    );

    // 7. Report 2 deep-link on :flag_mismatch issue opens stop edit drawer
    await page.goto(
      `/gtfs/${versionId}/stops/${SMALL_STATION}/report/accessibility?tab=validation`,
    );
    await waitForAccessibilityReady(page);
    await page.waitForSelector("#validation-issues-card", { timeout: 15000 });

    const flagMismatchLink = page
      .locator(
        '#validation-issues-card li[data-issue-kind="flag_mismatch"] a[href*="/report"]',
      )
      .first();
    await expect(flagMismatchLink).toHaveCount(1);
    await flagMismatchLink.click();

    await page.waitForURL(
      new RegExp(`/gtfs/${versionId}/stops/${SMALL_STATION}/report`),
      { timeout: 20000 },
    );
    await waitForDrawerOpen(page, "report-entity-drawer");
    await expect(page.locator("#report-stop-edit-form")).toHaveCount(1);

    expect(errors, `unexpected browser errors: ${errors.join("; ")}`).toEqual(
      [],
    );
  });

  test("large transfer center normalizes to Impact & routes, expands corridor, drills down matrix, and links to Floorplans", async ({
    page,
  }) => {
    const errors = trackErrors(page);
    await page.setViewportSize({ width: 1280, height: 900 });

    await logInAs(page, EDITOR);
    const versionId = await seededVersionId(page);

    // 1. Requesting ?view=network on a large station normalizes to Impact & routes only
    await page.goto(
      `/gtfs/${versionId}/stops/${TRANSFER_CENTER}/report/accessibility?view=network`,
    );
    await waitForAccessibilityReady(page);

    await expect(page.locator("#accessibility-impact-view")).toHaveCount(1);
    await expect(page.locator("#accessibility-view-switcher")).toHaveCount(0);
    await expect(page.locator("#accessibility-network-view")).toHaveCount(0);

    // 2. Verify 4 KPI tiles
    await expect(page.locator("#kpi-step-free-entrances")).toHaveCount(1);
    await expect(page.locator("#kpi-confirmed-pairs")).toHaveCount(1);
    await expect(page.locator("#kpi-unverified-pairs")).toHaveCount(1);
    await expect(page.locator("#kpi-sole-elevators")).toHaveCount(1);

    // 3. Collapsed verified corridor expands to show constituent Floorplans links and collapses again
    const corridorToggle = page
      .locator('#route-stepper button[id^="corridor-toggle-"]')
      .first();
    await expect(corridorToggle).toHaveCount(1);
    await expect(corridorToggle).toHaveAttribute("aria-expanded", "false");

    await corridorToggle.click();
    await expect(corridorToggle).toHaveAttribute("aria-expanded", "true");
    const corridorLinks = page.locator(
      '#route-stepper ul[id^="corridor-steps-"] a[id^="stepper-edit-"]',
    );
    expect(await corridorLinks.count()).toBeGreaterThanOrEqual(3);

    await corridorToggle.click();
    await expect(corridorToggle).toHaveAttribute("aria-expanded", "false");

    // 4. Switch routes via quick-select pills (selecting moves that pill to front)
    const pills = page.locator("#route-selector-pills button");
    expect(await pills.count()).toBeGreaterThanOrEqual(2);
    const firstPillId = await pills.first().getAttribute("id");
    const secondPillId = await pills.nth(1).getAttribute("id");
    expect(firstPillId).toBeTruthy();
    expect(secondPillId).toBeTruthy();

    await page.locator(`#${secondPillId}`).click();
    await expect(page.locator(`#${secondPillId}`)).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    // Return to the first pill so the captured default route shows the collapsed corridor
    await page.locator(`#${firstPillId}`).click();
    await expect(page.locator(`#${firstPillId}`)).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    await expect(corridorToggle).toHaveCount(1);

    // 5. Ranked issues, grouped matrix drill-down, and keyboard activation on matrix cell
    await expect(page.locator("#impact-issues-card")).toHaveCount(1);
    await expect(page.locator("#grouped-access-matrix-table")).toHaveCount(1);

    const firstMatrixCell = page
      .locator('#grouped-access-matrix-table button[id^="group-cell-"]')
      .first();
    await firstMatrixCell.focus();
    await expect(firstMatrixCell).toBeFocused();
    await page.keyboard.press("Enter");

    await page.waitForSelector("#grouped-matrix-drilldown", { timeout: 15000 });
    const inspectBtn = page
      .locator('#grouped-matrix-drilldown button[id^="drilldown-inspect-"]')
      .first();
    await expect(inspectBtn).toHaveCount(1);
    await inspectBtn.click();
    await expect(page.locator("#route-stepper")).toHaveCount(1);

    // Close drill-down and re-select the first pill for a clean transfer-center capture
    await page.locator("#close-cell-drilldown").click();
    await expect(page.locator("#grouped-matrix-drilldown")).toHaveCount(0);
    await page.locator(`#${firstPillId}`).click();
    await expect(page.locator(`#${firstPillId}`)).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    // 6. Strictly 3-column Elevator dependency table
    const elevatorHeaders = await page
      .locator("#elevator-dependency-table thead th")
      .allTextContents();
    expect(elevatorHeaders.map((h) => h.trim())).toEqual([
      "Elevator",
      "Connects",
      "Sole link for",
    ]);

    // 7. Zero excluded outage-feed or verification-provenance terms on the page
    const bodyText = await page.evaluate(() => document.body.innerText);
    for (const term of EXCLUDED_TERMS) {
      expect(
        bodyText.toLowerCase().includes(term.toLowerCase()),
        `excluded prototype term "${term}" appeared on the page`,
      ).toBe(false);
    }

    // 8. Desktop & mobile viewport fit + visual captures
    expect(
      await bodyFitsViewport(page),
      "transfer center Impact & routes overflows horizontally at 1280px",
    ).toBe(true);
    await saveCapture(page, "transfer-impact-1280.png");

    await page.setViewportSize({ width: 390, height: 844 });
    expect(
      await bodyFitsViewport(page),
      "transfer center Impact & routes overflows horizontally at 390px",
    ).toBe(true);
    await saveCapture(page, "transfer-impact-390.png");

    // 9. Floorplans deep-link from a route step opens pathway drawer and clears param
    await page.setViewportSize({ width: 1280, height: 900 });
    const stepLink = page
      .locator('#route-stepper a[id^="stepper-edit-"]')
      .first();
    await expect(stepLink).toHaveCount(1);
    await stepLink.click();

    await page.waitForURL(
      new RegExp(`/gtfs/${versionId}/stops/${TRANSFER_CENTER}/diagram`),
      { timeout: 20000 },
    );
    await waitForDrawerOpen(page, "pathway-drawer");
    await page.waitForFunction(
      () => !new URLSearchParams(window.location.search).has("edit_pathway_id"),
      null,
      { timeout: 15000 },
    );

    expect(errors, `unexpected browser errors: ${errors.join("; ")}`).toEqual(
      [],
    );
  });
});
