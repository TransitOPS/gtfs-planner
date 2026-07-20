import { test, expect } from "@playwright/test";
import { loginAndGoToDiagram, selectDiagramMode } from "./station_diagram_helpers";

test.describe("Station diagram map alignment", () => {
  test("uses one real map composition and keyboard transform controls", async ({ page }) => {
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    const map = page.locator('[phx-hook="MapAlignment"]');
    await expect(map).toBeVisible();
    await expect(page.locator("#map-alignment-leaflet")).toBeVisible();
    await expect(page.locator("#map-alignment-leaflet.leaflet-container")).toHaveCount(1);

    const overlay = page.locator("#map-alignment-overlay");
    const initialTransform = await overlay.getAttribute("style");
    await page.locator("#map-transform-right-fine").focus();
    await page.keyboard.press("Enter");
    await expect(overlay).not.toHaveAttribute("style", initialTransform || "");
  });

  test("reports offline state and provides a retry without adding hidden tab stops", async ({ page }) => {
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await expect(page.locator("#map-alignment-leaflet.leaflet-container")).toBeVisible();
    await page.evaluate(() => window.dispatchEvent(new Event("offline")));
    await expect(page.locator("#map-alignment-retry")).toBeVisible();
    await page.locator("#map-alignment-retry").click();
    await expect(page.locator('[phx-hook="MapAlignment"]')).toBeVisible();

    const ignoredFocusable = await page.locator(
      '[phx-hook="MapAlignment"] [tabindex]:not([tabindex="-1"])',
    ).count();
    expect(ignoredFocusable).toBe(0);
  });
});
