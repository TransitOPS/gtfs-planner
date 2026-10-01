import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { bodyFitsViewport, logInAs, VIEWPORTS } from "./browser_helpers";

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

for (const label of ["desktop", "320px"]) {
  const viewport = VIEWPORTS.find((entry) => entry.label === label);

  test(`garage address search states at ${label}`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await logInAs(page, EDITOR);

    const version = page
      .locator("#gtfs-version-panel [data-version-option]")
      .filter({ hasText: "Browser E2E Version" });
    await expect(version).toHaveCount(1);
    const versionId = await version.getAttribute("data-version-id");
    await page.goto(`/gtfs/${versionId}/settings/garages`);
    await page.locator("[data-phx-main].phx-connected").waitFor();

    await page.locator("#add-garage, #add-garage-empty").click();
    await expect(page.locator("#garage-drawer-overlay")).toHaveAttribute("data-open", "true");
    const address = page.locator("#garage-address input[type='text']");
    // Focusing the input pushes a focus event whose reply sets the input's text
    // to the component's last known text. Typing before that reply lands is
    // overwritten, so the case lets the round trip finish first, as a person's
    // first keystroke does.
    await address.focus();
    await expect(address).not.toHaveClass(/phx-focus-loading/);
    // The browser geocoding adapter holds this query until zz-release runs.
    await address.fill("zz-slow");
    await expect(page.locator("#garage-address-search-status")).toHaveText("Searching addresses…");
    await expect(page.locator("#garage-address-search-status")).toBeVisible();
    await expect(address).toHaveValue("zz-slow");
    expect(await bodyFitsViewport(page)).toBe(true);
    await capture(page, `garage-address-searching-${label}`);
    await expect(page.locator("#garage-address-search-status")).toHaveText("Searching addresses…");

    await address.fill("zz-release");
    await expect(page.locator("#garage-address-search-status")).toHaveText("No matching addresses");

    await address.fill("zz-fail");
    await expect(page.locator("#garage-address-search-status")).toContainText(
      "Address search is unavailable.",
    );
    await expect(page.locator("#garage-address-retry")).toBeVisible();
    await expect(page.locator("#garage-address-retry")).toHaveAttribute("type", "button");
    await expect(address).toHaveValue("zz-fail");
    expect(await bodyFitsViewport(page)).toBe(true);
    await capture(page, `garage-address-failed-${label}`);
    await expect(page.locator("#garage-address-search-status")).toContainText(
      "Address search is unavailable.",
    );

    await page.locator("#garage-address-retry").click();
    await expect(page.locator("#garage-address-search-status")).toContainText(
      "Address search is unavailable.",
    );
    await expect(address).toHaveValue("zz-fail");
  });
}

async function capture(page, name) {
  const dir = process.env.ARCH_CAPTURE_DIR;
  if (!dir) return;

  mkdirSync(dir, { recursive: true });
  await page.screenshot({
    path: resolve(dir, `${name}.png`),
    animations: "disabled",
  });
}
