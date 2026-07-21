import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VIEWPORTS = [
  { label: "320", width: 320, height: 568 },
  { label: "375", width: 375, height: 812 },
  { label: "768", width: 768, height: 1024 },
  { label: "1024", width: 1024, height: 900 },
  { label: "wide", width: 1440, height: 1000 },
  // A 640px CSS viewport exercises the responsive layout at 200% zoom of a
  // 1280px-wide device without relying on browser-specific zoom APIs.
  { label: "200-percent", width: 640, height: 400 },
];

async function logIn(page) {
  await page.goto("/users/log_in");

  if (await page.locator('input[name="user[email]"]').count()) {
    await page.fill('input[name="user[email]"]', USER.email);
    await page.fill('input[name="user[password]"]', USER.password);
    await page.getByRole("button", { name: "Log in" }).click();
    await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
  }
}

async function openRoute(page, route) {
  await logIn(page);
  await page.locator(`#app-header a[href$='/${route}']`).first().click();
  await page.waitForURL(new RegExp(`/gtfs/[^/]+/${route}$`));
  await page.locator(`#gtfs-${route}-form`).waitFor({ state: "visible" });
}

async function expectNoHorizontalOverflow(page) {
  expect(await bodyFitsViewport(page), "page must fit its viewport").toBe(true);
}

async function expectKeyboardAccess(page, selector, { visible = true } = {}) {
  const control = page.locator(selector);
  await control.focus();
  await expect(control).toBeFocused();
  if (visible) await expect(control).toBeVisible();
  if (!visible) await page.evaluate(() => document.activeElement?.blur());
}

async function expectMinimumTargetSize(page, selector) {
  const box = await page.locator(selector).boundingBox();
  expect(box, `${selector} must have a rendered bounding box`).not.toBeNull();
  expect(box.width, `${selector} must be at least 44px wide`).toBeGreaterThanOrEqual(44);
  expect(box.height, `${selector} must be at least 44px tall`).toBeGreaterThanOrEqual(44);
}

test.describe("durable import and export browser journeys", () => {
  test("import and export stay usable across responsive and zoomed layouts", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.emulateMedia({ reducedMotion: "reduce" });

    for (const viewport of VIEWPORTS) {
      await page.setViewportSize(viewport);
      await openRoute(page, "import");

      await expect(page.locator("#gtfs-import-form")).toBeVisible();
      await expect(page.locator("#diff-upload-form")).toBeVisible();
      await expect(page.locator("#gtfs-import-upload-label")).toHaveText("GTFS files");
      await expect(page.locator("#diff-upload-label")).toHaveText("Station data files");
      await expect(page.locator("#gtfs-import-submit")).toBeDisabled();
      await expect(page.locator("#diff-compute-btn")).toBeDisabled();
      await expectKeyboardAccess(page, "#gtfs-import-version-name");
      await expectKeyboardAccess(page, "#diff-upload-input input", { visible: false });
      await expectMinimumTargetSize(page, "#diff-upload label:has(#diff-upload-input)");
      await expectNoHorizontalOverflow(page);

      await page.screenshot({
        path: `test-results/import-export-import-${viewport.label}.png`,
        fullPage: true,
      });

      await openRoute(page, "export");
      await expect(page.locator("#gtfs-export-form")).toBeVisible();
      await expect(page.locator("#export-workspace")).toBeVisible();
      await expect(page.locator("#export-inventory")).toBeVisible();
      await expect(page.locator("#export-download-link")).toBeVisible();
      await expectKeyboardAccess(page, "#export-type-full");
      await expectKeyboardAccess(page, "#start-export");
      await expectMinimumTargetSize(page, "#export-download-link");

      await page.locator("#export-type-pathways").check();
      await expect(page.locator("#export-type-pathways")).toBeChecked();
      await expect(page.locator("#export-type-full")).not.toBeChecked();
      await expectNoHorizontalOverflow(page);

      await page.screenshot({
        path: `test-results/import-export-export-${viewport.label}.png`,
        fullPage: true,
      });
    }
  });

  test("ready export reconnects and downloads through an attachment response", async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openRoute(page, "export");
    const downloadLink = page.locator("#export-download-link");

    await expect(downloadLink).toBeVisible();
    await expect(downloadLink).toHaveAttribute("href", /\/export-runs\/[^/]+\/download$/);
    await page.reload();
    await expect(downloadLink).toBeVisible();

    const responsePromise = page.waitForResponse(
      (response) =>
        /\/export-runs\/[^/]+\/download$/.test(new URL(response.url()).pathname),
    );
    const downloadPromise = page.waitForEvent("download");
    await downloadLink.click();
    const [response, download] = await Promise.all([responsePromise, downloadPromise]);

    expect(response.status()).toBe(200);
    expect(await response.headerValue("content-type")).toMatch(/^application\/zip(?:;|$)/);
    expect(await response.headerValue("content-disposition")).toMatch(/^attachment; filename=/);
    expect(await download.suggestedFilename()).toBe("browser-current-export.zip");
    await expect(page.locator("[phx-hook='DownloadHook']")).toHaveCount(0);
    expect(await page.content()).not.toContain("data:application/zip;base64,");
  });
});
