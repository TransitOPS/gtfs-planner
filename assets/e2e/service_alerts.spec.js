import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

// The Alerts list, as spec 30's step 13 renders it: the four tabs with their
// counts, the table, and the first-use panel an organization with no alerts
// gets (AC-14). Nothing here looks for a publication state or action, because
// saving an alert never publishes one in this package (R2, CR-1).

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The browser journey signs in as the editor seeded by
// test/support/browser_seed.exs, whose organization also carries a Pathways
// Studio editor and no alerts of its own: the first-use panel's own subject.
const EMPTY_EDITOR = {
  email: "pathways-editor@gtfs-planner.test",
  password: "PathwaysEditor123!",
};

const ALERTS_VERSION = "Browser Alerts Version";

// The canonical feature package (with its reference and evidence folder) lives
// in the primary repository checkout; the `.specs/` workspace is gitignored, so
// a checkout without it falls back to Playwright's own output folder instead of
// writing outside the project.
const FEATURE_DIR =
  process.env.ALERTS_FEATURE_DIR ||
  "/Users/ryanmahoney/Documents/gtfs-planner/.specs/30-service-alerts";
const EVIDENCE_DIR = path.join(FEATURE_DIR, "evidence/captures/production");
const REFERENCE_PATH = path.join(FEATURE_DIR, "references/alerts-prototype.html");

const DESKTOP = { label: "1440", width: 1440, height: 900 };
const NARROW = { label: "320", width: 320, height: 740 };

function capturePath(testInfo, name) {
  return fs.existsSync(EVIDENCE_DIR)
    ? path.join(EVIDENCE_DIR, name)
    : testInfo.outputPath(name);
}

async function logIn(page, account = EDITOR) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', account.email);
  await page.fill('input[name="user[password]"]', account.password);
  await page.getByRole("button", { name: "Log in" }).click();
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

async function openAlerts(page, account = EDITOR) {
  await logIn(page, account);
  const versionId = await versionIdFor(page, ALERTS_VERSION);
  await page.goto(`/gtfs/${versionId}/alerts`);
  await page.waitForSelector(
    "#alerts-first-use, #alerts-list, #alerts-tab-empty-current",
    { timeout: 15000 },
  );
  return versionId;
}

async function openFirstUseAlerts(page) {
  await logIn(page, EMPTY_EDITOR);
  const versionId = await versionIdFor(page, "Browser Pathways Version");
  await page.goto(`/gtfs/${versionId}/alerts`);
  await page.waitForSelector("#alerts-first-use", { timeout: 15000 });
  return versionId;
}

async function fitsViewport(page) {
  return page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );
}

// The prototype state this view is compared against. The reference file lives
// in the gitignored `.specs/` workspace, so a checkout without it skips the
// reference capture rather than failing.
async function captureReference(page, testInfo, state, width) {
  if (!fs.existsSync(REFERENCE_PATH)) return;

  const reference = `file://${REFERENCE_PATH}?state=${state}`;
  await page.goto(reference);
  await page.waitForLoadState("load");

  await page.screenshot({
    path: capturePath(testInfo, `list-ref-${state}-${width}.png`),
    fullPage: false,
  });
}

test.describe("alerts list", () => {
  test("the seeded current tab lists alerts with counts at both widths @list", async ({
    page,
  }, testInfo) => {
    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await openAlerts(page);

      await expect(page.locator("#alerts-page")).toBeVisible();
      await expect(page.locator("#alerts-tabs")).toBeVisible();

      for (const tab of ["current", "upcoming", "in_progress", "past"]) {
        await expect(page.locator(`#alerts-tab-${tab}`)).toBeVisible();
      }

      await expect(page.locator("#create-alert")).toBeVisible();

      const currentCount = Number(
        await page.locator("#alerts-tab-current").getAttribute("data-count"),
      );
      await expect(page.locator("#alerts-tab-current")).toHaveAttribute(
        "aria-selected",
        "true",
      );

      if (currentCount > 0) {
        await expect(page.locator("#alerts-list")).toBeVisible();
        await expect(
          page.locator("#alerts tbody tr[id^='alert-row-']").first(),
        ).toBeVisible();
      }

      // The publication states and actions this package removed must not appear.
      const body = await page.locator("#alerts-page").innerText();
      for (const word of ["Live", "Scheduled", "Ended", "End alert"]) {
        expect(body).not.toContain(word);
      }

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `list-live-${viewport.label}.png`),
        fullPage: false,
      });

      await captureReference(page, testInfo, "list-live", viewport.label);
    }
  });

  test("an empty tab says what belongs in it @list", async ({ page }, testInfo) => {
    await page.setViewportSize(DESKTOP);
    await openAlerts(page);

    await page.locator("#alerts-tab-past").click();
    await page.waitForURL(/tab=past/);
    await page.waitForSelector("#alerts-tab-empty-past");

    await expect(page.locator("#alerts-tab-empty-past")).toContainText(
      "No earlier alerts",
    );
    await expect(page.locator("#alerts-first-use")).toHaveCount(0);

    expect(await fitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, `list-tab-empty-1440.png`),
      fullPage: false,
    });
  });

  test("an organization with no alerts gets the first-use panel @list", async ({
    page,
  }, testInfo) => {
    for (const viewport of [DESKTOP, NARROW]) {
      await page.setViewportSize(viewport);
      await openFirstUseAlerts(page);

      await expect(page.locator("#alerts-first-use")).toBeVisible();
      await expect(page.locator("#alerts-first-use")).toContainText(
        "No alerts yet",
      );
      await expect(page.locator("#create-alert-first-use")).toContainText(
        "Create alert",
      );
      await expect(page.locator("#alerts-list")).toHaveCount(0);
      await expect(page.locator("#main-navigation #nav-alerts")).toBeVisible();

      expect(await fitsViewport(page)).toBe(true);

      await page.screenshot({
        path: capturePath(testInfo, `list-empty-${viewport.label}.png`),
        fullPage: false,
      });

      await captureReference(page, testInfo, "list-empty", viewport.label);
    }
  });
});