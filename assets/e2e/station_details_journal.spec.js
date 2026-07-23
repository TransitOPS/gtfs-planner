import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(here, "../..");
const artifactRoot = resolve(repositoryRoot, ".artifacts/journal-05");

const DIAGRAM_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

async function loginAndGoToDetails(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', DIAGRAM_USER.email);
  await page.fill('input[name="user[password]"]', DIAGRAM_USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL("**/");

  const diagramVersion = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: "Browser E2E Version" });
  await expect(diagramVersion).toHaveCount(1);

  const versionId = await diagramVersion.getAttribute("data-version-id");
  if (!versionId)
    throw new Error("Browser E2E Version is missing its version ID");

  await page.goto(`/gtfs/${versionId}/stops`);
  await page.waitForURL("**/stops");

  const stationRow = page.locator("tr:has-text('BROWSER_STATION')");
  await expect(stationRow).toBeVisible();
  await stationRow.getByRole("link").first().click();
  await page.waitForURL("**/stops/**");
}

async function expectMinimumTargetSize(locator) {
  const box = await locator.boundingBox();
  expect(box, "control must have a rendered bounding box").not.toBeNull();
  expect(
    box.width,
    "control must be at least 44px wide",
  ).toBeGreaterThanOrEqual(44);
  expect(
    box.height,
    "control must be at least 44px tall",
  ).toBeGreaterThanOrEqual(44);
}

test.describe("Station Details Journal Summary", () => {
  test.beforeAll(async () => {
    await mkdir(artifactRoot, { recursive: true });
  });

  test("production preserves the reference Journal hierarchy at marker 7", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await loginAndGoToDetails(page);

    const journalSection = page.locator("#station-journal-summary");
    await expect(journalSection).toBeVisible({ timeout: 10_000 });
    await expect(
      journalSection.getByRole("heading", { name: "Journal" }),
    ).toBeVisible();

    const followsPathways = await journalSection.evaluate((journal) => {
      const pathways = document.querySelector(
        "#pathways-table, #pathways-empty, #pathways-unavailable",
      );

      return Boolean(
        pathways &&
        pathways.compareDocumentPosition(journal) &
          Node.DOCUMENT_POSITION_FOLLOWING,
      );
    });
    expect(followsPathways).toBe(true);

    await journalSection.screenshot({
      path: resolve(artifactRoot, "reference-contract-details-journal.png"),
    });
  });

  test("production desktop shows journal summary with counts and rows", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });

    await loginAndGoToDetails(page);

    const journalSummary = page.locator("#station-journal-summary");
    await expect(journalSummary).toBeVisible({ timeout: 10_000 });

    await expect(page.locator("#station-journal-open-count")).toBeVisible();
    await expect(page.locator("#station-journal-closed-count")).toBeVisible();
    await expect(page.locator("#station-journal-summary-list")).toBeVisible();

    const entries = page.locator('[data-role="journal-summary-entry"]');
    await expect(entries).not.toHaveCount(0);
    await expect(entries.filter({ hasText: "Closed" })).not.toHaveCount(0);

    const footerLink = page.locator("#journal-footer-link");
    await expect(footerLink).toBeVisible();
    await expect(footerLink).toHaveAttribute(
      "href",
      /\/diagram\?journal=open$/,
    );
    await expectMinimumTargetSize(footerLink);

    const refresh = page.locator("#journal-summary-refresh");
    await expect(refresh).toBeVisible();
    await expectMinimumTargetSize(refresh);
    await refresh.focus();
    await expect(refresh).toBeFocused();
    await refresh.click();
    await expect(refresh).toBeFocused();
    await expect(page.locator("#station-journal-open-count")).toBeVisible();
    await expect(page.locator("#station-journal-summary-list")).toBeVisible();

    await journalSummary.screenshot({
      path: resolve(artifactRoot, "production-details-journal-desktop.png"),
    });
  });

  test("summary row opens and focuses its scoped Floorplans journal entry", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 900 });

    await loginAndGoToDetails(page);

    const rowLink = page.locator('[data-role="journal-summary-entry"]').first();
    await expect(rowLink).toBeVisible({ timeout: 10_000 });

    const rowId = await rowLink.getAttribute("id");
    const href = await rowLink.getAttribute("href");
    if (!rowId || !href)
      throw new Error("Journal summary row is missing its scoped link");

    const entryId = new URL(href, page.url()).searchParams.get("entry_id");
    if (!entryId) throw new Error("Journal summary row is missing entry_id");

    await rowLink.click();
    await page.waitForURL(/\/diagram$/);

    await expect(page.locator("#station-journal-panel")).toBeVisible();
    await expect(page.locator(`#journal-entries-${entryId}`)).toBeVisible();
    await expect(page.locator(`#journal-entries-${entryId}`)).toBeFocused();
    expect(page.url()).not.toContain("journal=open");
  });

  test("production mobile shows journal without horizontal overflow", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 390, height: 844 });

    await loginAndGoToDetails(page);

    const journalSummary = page.locator("#station-journal-summary");
    await expect(journalSummary).toBeVisible({ timeout: 10_000 });

    const overflow = await page.evaluate(() => {
      return (
        document.documentElement.scrollWidth >
        document.documentElement.clientWidth
      );
    });
    expect(overflow).toBe(false);

    const footerLink = page.locator("#journal-footer-link");
    await expect(footerLink).toBeVisible();

    await journalSummary.screenshot({
      path: resolve(artifactRoot, "production-details-journal-mobile.png"),
    });
  });

  test("journal links are keyboard operable", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });

    await loginAndGoToDetails(page);

    const journalSummary = page.locator("#station-journal-summary");
    await expect(journalSummary).toBeVisible({ timeout: 10_000 });

    const footerLink = page.locator("#journal-footer-link");
    await footerLink.focus();
    await expect(footerLink).toBeFocused();

    const href = await footerLink.getAttribute("href");
    expect(href).toContain("/diagram?journal=open");

    const rowLink = page.locator('[data-role="journal-summary-entry"]').first();
    await rowLink.focus();
    await expect(rowLink).toBeFocused();

    const rowHref = await rowLink.getAttribute("href");
    expect(rowHref).toContain("journal=open&entry_id=");
  });
});
