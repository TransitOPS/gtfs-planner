import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', USER.email);
  await page.fill('input[name="user[password]"]', USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function openExport(page) {
  await page.locator("#main-navigation #nav-gtfs").click();
  await page.waitForURL(/\/gtfs\/[^/]+\/export$/);
  await expect(page.locator("#export-files-card")).toBeVisible();
}

async function selectVersion(page, name) {
  const trigger = page.locator("#gtfs-version-trigger");
  if ((await trigger.textContent()).includes(name)) return;

  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });
  const versionId = await option.getAttribute("data-version-id");

  await page.goto(`/gtfs/${versionId}/export`);
  await expect(page.locator("#export-files-card")).toBeVisible();
}

async function capture(page, name) {
  if (!process.env.EXPORT_UX_CAPTURE_DIR) return;

  mkdirSync(process.env.EXPORT_UX_CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(process.env.EXPORT_UX_CAPTURE_DIR, `${name}.png`),
    fullPage: true,
  });
}

async function expectContainedFilesTable(page) {
  expect(await bodyFitsViewport(page), "document must fit the viewport").toBe(
    true,
  );

  const dimensions = await page
    .locator("#export-files-scroll")
    .evaluate((el) => {
      const bounds = el.getBoundingClientRect();
      return {
        clientWidth: el.clientWidth,
        scrollWidth: el.scrollWidth,
        left: bounds.left,
        right: bounds.right,
        viewport: window.innerWidth,
        document: document.documentElement.scrollWidth,
      };
    });

  expect(dimensions.document).toBeLessThanOrEqual(dimensions.viewport);
  expect(dimensions.left).toBeGreaterThanOrEqual(0);
  expect(dimensions.right).toBeLessThanOrEqual(dimensions.viewport);
  expect(dimensions.scrollWidth).toBeGreaterThan(dimensions.clientWidth);
}

test("Files empty and finished states match the reference and contain their table at 320px", async ({
  page,
}) => {
  test.setTimeout(120_000);
  await logIn(page);
  await openExport(page);
  await selectVersion(page, "Browser Fare Zones Version");

  await expect(
    page.locator("#export-files-empty .hero-document"),
  ).toBeVisible();
  await expect(page.locator("#export-files-rows")).toHaveCount(0);
  await capture(page, "step-013-fix-files-empty-1440");

  await page.setViewportSize({ width: 320, height: 800 });
  expect(await bodyFitsViewport(page)).toBe(true);
  await capture(page, "step-013-fix-files-empty-320");

  await page.locator("#start-export").click();
  await expect(page.locator("#export-finished")).toBeVisible({
    timeout: 30_000,
  });
  await expect(
    page.locator("#export-finished .hero-check-circle"),
  ).toBeVisible();
  await expect(page.locator("#export-download-link.btn-primary")).toBeVisible();
  await expect(
    page.locator(
      "#export-finished-dismiss[aria-label='Dismiss finished export']",
    ),
  ).toBeVisible();
  await expectContainedFilesTable(page);
  await capture(page, "step-013-fix-files-finished-320");

  await page.setViewportSize({ width: 1440, height: 1000 });
  expect(await bodyFitsViewport(page)).toBe(true);
  await capture(page, "step-013-fix-files-finished-1440");
});
