import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return (
      main &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected()
    );
  });
}

async function logInAndOpenImport(page) {
  await page.goto("/users/log_in");

  if (await page.locator('input[name="user[email]"]').count()) {
    await page.fill('input[name="user[email]"]', USER.email);
    await page.fill('input[name="user[password]"]', USER.password);
    await page.getByRole("button", { name: "Log in" }).click();
    await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
  }

  await page.locator("#app-header a[href$='/import']").first().click();
  await page.waitForURL(/\/gtfs\/[^/]+\/import$/);
  await page.waitForSelector("#gtfs-import-upload");
  await waitForLiveView(page);
}

async function selectVersion(page, name) {
  const trigger = page.locator("#gtfs-version-trigger");
  if ((await trigger.textContent()).includes(name)) return;

  await trigger.click();
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });
  const versionId = await option.getAttribute("data-version-id");

  await Promise.all([
    page.waitForURL(new RegExp(`/gtfs/${versionId}/import$`)),
    option.click(),
  ]);
  await waitForLiveView(page);
  await expect(trigger).toContainText(name);
}

test("import upload presentation stays usable at desktop and mobile widths", async ({
  page,
}) => {
  for (const viewport of [
    { name: "desktop", width: 1280, height: 900 },
    { name: "mobile", width: 375, height: 812 },
  ]) {
    await page.setViewportSize(viewport);
    await logInAndOpenImport(page);

    const fullUpload = page.locator("#gtfs-import-upload");
    const diffUpload = page.locator("#diff-upload");

    await expect(fullUpload).toHaveAttribute("data-upload-state", "idle");
    await expect(diffUpload).toHaveAttribute("data-upload-state", "idle");
    await expect(page.locator("#gtfs-import-submit")).toBeDisabled();
    await expect(page.locator("#diff-compute-btn")).toBeDisabled();

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: `test-results/import-upload-${viewport.name}.png`,
      fullPage: true,
    });

  }
});

test("durable diff review remains readable at desktop and mobile widths", async ({ page }) => {
  for (const viewport of [
    {
      name: "desktop",
      width: 1280,
      height: 900,
      version: "Catalog Empty Version",
    },
    {
      name: "mobile",
      width: 375,
      height: 812,
      version: "Catalog Routes Only Version",
    },
  ]) {
    await page.setViewportSize(viewport);
    await logInAndOpenImport(page);
    await selectVersion(page, viewport.version);

    await page.locator("#diff-upload-input input").setInputFiles({
      name: "levels.txt",
      mimeType: "text/plain",
      buffer: Buffer.from("level_id,level_index,level_name\nVISUAL,1.0,Visual Review"),
    });

    await page.locator("#diff-compute-btn").click();
    await page.locator("#diff-decisions [data-version-diff-row]").waitFor();

    await expect(page.locator("#diff-decisions")).toBeVisible();
    await expect(page.getByRole("button", { name: "Approve", exact: true })).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);

    await page.screenshot({
      path: `test-results/import-diff-${viewport.name}.png`,
      fullPage: true,
    });
  }
});
