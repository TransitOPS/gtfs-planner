import { test, expect } from "@playwright/test";
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

test("version-diff row remains readable and operable at desktop and mobile widths", async ({
  page,
}) => {
  await logIn(page);

  for (const viewport of [
    { name: "desktop", width: 1280, height: 900 },
    { name: "mobile", width: 375, height: 812 },
  ]) {
    await page.setViewportSize(viewport);
    await page.goto("/design/tables");
    await page.waitForSelector("#ds-version-diff-row-demo [data-version-diff-row]");

    const row = page.locator("#ds-version-diff-row-demo [data-version-diff-row]");
    const action = page.locator("#ds-version-diff-row-action");
    const disclosure = row.locator("summary");

    await expect(row).toContainText("Changed");
    await expect(row).toContainText("Approved");
    await expect(row).toContainText("Latitude");
    await expect(action).toHaveCSS("min-height", "44px");
    const layout = await page.locator("#ds-version-diff-row-demo").evaluate((el) => ({
      clientWidth: el.clientWidth,
      scrollWidth: el.scrollWidth,
    }));
    expect(layout.scrollWidth).toBeLessThanOrEqual(layout.clientWidth);

    await disclosure.focus();
    await page.keyboard.press("Enter");
    await expect(row.locator("details")).not.toHaveAttribute("open", "");
    await page.keyboard.press("Space");
    await expect(row.locator("details")).toHaveAttribute("open", "");

    await page.screenshot({
      path: `test-results/version-diff-row-${viewport.name}.png`,
      fullPage: true,
    });
  }
});
