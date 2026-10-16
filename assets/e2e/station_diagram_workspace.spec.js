import { test, expect } from "@playwright/test";
import {
  loginAndGoToDiagram,
  openDiagramPanel,
  selectDiagramMode,
  selectSeededDiagramLevel,
} from "./station_diagram_helpers";

test.describe("Station diagram workspace", () => {
  // bin/test-browser e2e/station_diagram_workspace.spec.js --grep "opens and closes"
  test("opens and closes the panel and reclaims the viewport in editing modes", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.emulateMedia({ reducedMotion: "reduce" });
    await loginAndGoToDiagram(page);
    const toggle = page.locator("#diagram-panel-toggle");
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#side-panel")).toBeHidden();

    await openDiagramPanel(page);
    await expect(page.locator("#child-stops-table")).toBeVisible();
    await page.locator("#diagram-panel-close").click();
    await expect(toggle).toBeFocused();
    await expect(page.locator("#side-panel")).toBeHidden();

    for (const mode of ["add", "connect", "map"]) {
      await selectDiagramMode(page, mode);
      await expect(page.locator("#app-header")).toBeHidden();
      const workspace = await page.locator("#diagram-workspace").boundingBox();
      expect(workspace.x).toBe(0);
      expect(workspace.y).toBe(0);
      expect(workspace.width).toBe(1440);
      expect(workspace.height).toBe(900);
    }

    await selectDiagramMode(page, "view");
    await expect(page.locator("#app-header")).toBeVisible();
    const bounds = await page.evaluate(() => {
      const box = selector => document.querySelector(selector).getBoundingClientRect().toJSON();
      return {
        brand: box("#app-brand"), nav: box("#station-sub-nav"),
        title: box("#station-title"), modes: box("#diagram-mode"),
        canvas: box("#workspace-body"), settings: box("#floorplan-settings-trigger"),
        contents: box("#diagram-panel-toggle"), level: box("#level-control"),
        status: box("#diagram-status-bar")
      };
    });
    expect(bounds.brand.x).toBe(bounds.nav.x);
    expect(bounds.modes.x).toBeGreaterThan(bounds.title.right);
    expect(bounds.modes.y).toBeLessThan(bounds.title.bottom);
    expect(bounds.modes.bottom).toBeGreaterThan(bounds.title.y);
    expect(bounds.settings.x).toBe(bounds.canvas.x + 16);
    expect(bounds.contents.right).toBe(bounds.canvas.right - 16);
    expect(bounds.level.y).toBeGreaterThanOrEqual(bounds.status.y);

    await page.locator("#diagram-more-trigger").click();
    await expect(page.locator("#add-level-action")).toBeVisible();
    await expect(page.locator("#edit-level-action")).toBeHidden();
    await page.keyboard.press("Escape");
    await expect(page.locator("#diagram-more-trigger")).toBeFocused();
    await page.locator("#floorplan-settings-trigger").click();
    await expect(page.locator("#edit-level-action")).toBeVisible();
    await page.locator("#edit-level-action").click();
    await expect(page.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "true");
    await page.keyboard.press("Escape");
    await expect(page.locator("#floorplan-settings-trigger")).toBeFocused();
  });

  // bin/test-browser e2e/station_diagram_workspace.spec.js --grep "beneath journal"
  test("drags a point beneath journal markers and keeps the position after reload", async ({ page }) => {
    await loginAndGoToDiagram(page);
    await expect(page.locator('#journal-markers-svg [data-journal-kind="node"]').first()).toBeVisible();
    const point = page.locator('g[data-stop-id]').filter({ has: page.locator('text', { hasText: "Platform B South" }) });
    const original = await point.evaluate(g => ({ x: g.dataset.stopCenterX, y: g.dataset.stopCenterY }));
    const pointId = await point.getAttribute("data-stop-id");

    try {
      const coords = await point.evaluate(g => {
        const matrix = g.ownerSVGElement.getScreenCTM();
        return {
          from: new DOMPoint(+g.dataset.stopCenterX, +g.dataset.stopCenterY).matrixTransform(matrix).toJSON(),
          to: new DOMPoint(+g.dataset.stopCenterX + 5, +g.dataset.stopCenterY + 5).matrixTransform(matrix).toJSON(),
        };
      });
      await page.mouse.move(coords.from.x, coords.from.y);
      await page.mouse.down();
      await page.mouse.move(coords.to.x, coords.to.y, { steps: 5 });
      await expect(point).toHaveClass(/dragging/);
      await page.mouse.up();
      await expect.poll(async () => Number(await point.getAttribute("data-stop-center-x"))).toBeGreaterThan(+original.x + 4);
      const moved = await point.evaluate(g => ({ x: +g.dataset.stopCenterX, y: +g.dataset.stopCenterY }));
      expect(moved.x).toBeCloseTo(+original.x + 5, 0);
      expect(moved.y).toBeCloseTo(+original.y + 5, 0);

      await page.reload();
      await expect.poll(async () => Number(await point.getAttribute("data-stop-center-x"))).toBe(moved.x);
      await expect.poll(async () => Number(await point.getAttribute("data-stop-center-y"))).toBe(moved.y);
    } finally {
      // Restore the shared fixture exactly through the coordinate editor;
      // pointer events round to screen pixels, so a second drag is approximate.
      await page.mouse.up();
      await selectDiagramMode(page, "add");
      await openDiagramPanel(page);
      await page.locator("#keyboard-create-stop").click();
      await page.locator("#enter-reposition-mode").click();
      await page.locator("#reposition-x-input").fill(original.x);
      await page.locator("#reposition-y-input").fill(original.y);
      await page.locator(`#positioned-stop-row-${pointId} button`).click();
      await expect.poll(async () => Number(await point.getAttribute("data-stop-center-x"))).toBe(+original.x);
      await expect.poll(async () => Number(await point.getAttribute("data-stop-center-y"))).toBe(+original.y);
    }
  });

  test("returns focus to the level picker after switching levels", async ({
    page,
  }) => {
    await loginAndGoToDiagram(page);
    await selectSeededDiagramLevel(page, "BROWSER_L2");

    const selected = page.locator('#level-control [data-level-id="BROWSER_L2"]');

    await expect(page.locator("#level-control-trigger")).toBeFocused();
    await expect(selected).toHaveAttribute("aria-current", "true");
    await expect(page.locator("#active-level-name")).toHaveText("Browser Level 2");
    await expect(selected).toBeHidden();
    await expect(
      page.locator('#level-control [aria-current="true"]'),
    ).toHaveCount(1);
  });

  for (const width of [320, 390]) {
    test(`keeps station actions above canvas tools on narrow screens at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await page.emulateMedia({ reducedMotion: "reduce" });
      await loginAndGoToDiagram(page);

      const modes = await page.locator("#diagram-mode").boundingBox();
      expect(modes.x).toBeGreaterThanOrEqual(16);
      expect(modes.x + modes.width).toBeLessThanOrEqual(width - 16);

      await page.locator("#diagram-more-trigger").click();
      await page.locator("#add-level-action").click();
      await expect(page.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "true");
      await page.keyboard.press("Escape");
      await expect(page.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "false");
      await expect(page.locator("#diagram-more-trigger")).toBeFocused();
    });
  }

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
    await openDiagramPanel(page);
    await expect(page.locator("#child-stops-table")).toBeVisible();

    const widths = await page.evaluate(() => ({
      body: document.body.scrollWidth,
      viewport: window.innerWidth,
    }));
    expect(widths.body).toBeLessThanOrEqual(widths.viewport + 2);
  });
});
