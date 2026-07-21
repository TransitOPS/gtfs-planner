import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

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
