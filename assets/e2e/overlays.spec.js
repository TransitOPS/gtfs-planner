import { test, expect } from "@playwright/test";

const TEST_USER = {
  email: "browser-test@gtfs-planner.test",
  password: "BrowserTest123!",
};

test("authenticates and opens the normative overlays page", async ({ page }) => {
  // --- Login through the real rendered form ---
  await page.goto("/users/log_in");

  await page.fill('input[name="user[email]"]', TEST_USER.email);
  await page.fill('input[name="user[password]"]', TEST_USER.password);
  await page.locator('button:has-text("Log in")').click();

  // After login, redirect to the authenticated dashboard
  await page.waitForURL("**/");

  // --- Navigate to the production overlays page ---
  await page.goto("/design/overlays");
  await page.waitForSelector("#ds-page-overlays");

  const demoBlock = page.locator("#ds-drawer-demo");
  await expect(demoBlock).toBeVisible();

  // --- Open the drawer ---
  await page.locator('button[phx-click="open_drawer"]').click();

  const overlay = page.locator("#ds-demo-drawer-overlay");
  await overlay.waitFor({ state: "visible" });

  // The hook has called showModal() — browser-owned open property is true
  await expect(overlay).toHaveJSProperty("open", true);

  // --- LiveView patch preserves browser-owned open ---
  // Clicking "Delete route" inside the open drawer fires a phx-click event.
  // The server re-renders, and phx-mounted={JS.ignore_attributes("open")}
  // prevents LiveView from clearing the browser-set open attribute.
  await page.locator('button[phx-click="open_confirm"]').click();

  const confirmDialog = page.locator("#ds-demo-confirm-overlay");
  await confirmDialog.waitFor({ state: "visible" });

  // Drawer dialog is still open after the LiveView patch
  await expect(overlay).toHaveJSProperty("open", true);
  await expect(confirmDialog).toHaveJSProperty("open", true);

  // --- Complete the nested confirmation (success path) ---
  await page.locator('button[phx-click="confirm_success"]').click();

  // Success message appears inside the still-open drawer
  await expect(page.locator("#ds-confirm-result")).toBeVisible();

  // Confirmation closed; drawer remains open
  await expect(overlay).toHaveJSProperty("open", true);

  // INV-006: nested success focus stays in the active modal branch
  await expect(page.locator("#ds-confirm-result")).toBeFocused();

  // --- Close the drawer through the production control ---
  await page.locator("#ds-demo-drawer-close").click();

  // Drawer element invisible after close
  await expect(overlay).not.toBeVisible();
});
