import { test, expect } from "@playwright/test";
import {
  loginAndGoToDiagram,
  selectDiagramMode,
} from "./station_diagram_helpers";

test.describe("Station diagram workspace", () => {
  test("keeps context and explicit focus boundaries at tablet width", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 768, height: 1024 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await loginAndGoToDiagram(page);

    await expect(page.locator("#app-header")).toBeVisible();
    await expect(page.locator("#station-sub-nav")).toBeVisible();
    await expect(page.locator("#diagram-action-strip")).toBeVisible();
    await expect(page.locator("#floorplan-workspace-heading")).toBeAttached();
    await expect(page.locator("#floorplan-workspace")).toHaveAttribute(
      "aria-labelledby",
      "floorplan-workspace-heading",
    );

    const viewRadio = page.locator('#diagram-mode input[value="view"]');
    await viewRadio.focus();
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#diagram-mode input:focus")).toHaveCount(1);
    await expect(page.locator("#floorplan-workspace")).not.toBeFocused();

    const skipToFloorplan = page.locator("#skip-to-floorplan");
    await skipToFloorplan.focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#floorplan-workspace")).toBeFocused();

    await selectDiagramMode(page, "add");
    await expect(page.locator("#diagram-page")).toHaveAttribute(
      "data-immersive",
      "true",
    );
    await expect(page.locator("#diagram-action-strip")).toBeVisible();

    await selectDiagramMode(page, "view");
    await expect(page.locator("#diagram-page")).not.toHaveAttribute(
      "data-immersive",
      "true",
    );
    await expect(viewRadio).toBeChecked();
  });

  test("remains usable at desktop width and 200 percent browser zoom", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await page.evaluate(() => {
      document.body.style.zoom = "2";
    });

    await expect(page.locator("#station-sub-nav")).toBeVisible();
    await expect(page.locator("#diagram-workspace")).toBeVisible();
    await expect(page.locator("#child-stops-table")).toBeVisible();

    const widths = await page.evaluate(() => ({
      body: document.body.scrollWidth,
      viewport: window.innerWidth,
    }));
    expect(widths.body).toBeLessThanOrEqual(widths.viewport + 2);
  });
});
