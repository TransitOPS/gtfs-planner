import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { VIEWPORTS, bodyFitsViewport } from "./browser_helpers";
import { loginAndGoToDiagram } from "./station_diagram_helpers";

test("a stop ID changed by another editor refreshes the naming preview", async ({ browser, baseURL }) => {
  const firstContext = await browser.newContext({ baseURL });
  const secondContext = await browser.newContext({ baseURL });
  const first = await firstContext.newPage();
  const second = await secondContext.newPage();

  try {
    const desktop = VIEWPORTS.find(({ label }) => label === "desktop");
    await first.setViewportSize({ width: desktop.width, height: desktop.height });
    await second.setViewportSize({ width: desktop.width, height: desktop.height });
    await loginAndGoToDiagram(first);
    await loginAndGoToDiagram(second);

    await first.locator("#diagram-more-trigger").click();
    await first.locator("#apply-naming-action").click();
    await expect(first.locator("#naming-drawer-overlay")).toHaveAttribute("data-open", "true");
    await expect(first.locator("#naming-row-BROWSER_STOP_A")).toBeVisible();

    const stopRow = second.locator("#child-stops-table li").filter({ hasText: "BROWSER_STOP_A" });
    await expect(stopRow).toBeVisible();
    await stopRow.locator("button[phx-click='edit_child_stop']").click();
    await expect(second.locator("#child-stop-drawer-overlay")).toHaveAttribute("data-open", "true");
    await second.locator("#child-stop-form input[name='stop_id']").fill("BROWSER_STOP_A_RENAMED");
    await second.locator("#child-stop-submit").click();
    await expect(second.locator("#child-stop-drawer-overlay")).toHaveAttribute("data-open", "false");
    await expect(second.locator("#child-stops-table")).toContainText("BROWSER_STOP_A_RENAMED");

    await first.locator("#apply-naming-convention").click();
    await expect(first.locator("#naming-outcome")).toContainText(
      "Stop IDs changed since this preview. Review the new preview before applying.",
    );
    await expect(first.locator("#naming-outcome")).toBeFocused();
    await expect(first.locator("#naming-row-BROWSER_STOP_A_RENAMED")).toBeVisible();
    await expect(first.locator("#naming-row-BROWSER_STOP_A")).toHaveCount(0);
    await expect(first.locator("#apply-naming-convention")).toBeEnabled();

    for (const viewport of VIEWPORTS.filter(({ label }) => ["desktop", "320px"].includes(label))) {
      await first.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(first.locator("#naming-outcome")).toBeVisible();
      expect(await bodyFitsViewport(first)).toBe(true);

      if (process.env.ARCH_CAPTURE_DIR) {
        mkdirSync(process.env.ARCH_CAPTURE_DIR, { recursive: true });
        const label = viewport.label === "320px" ? "320" : viewport.label;
        await first.screenshot({
          path: resolve(process.env.ARCH_CAPTURE_DIR, `station-naming-stale-${label}.png`),
        });
      }
    }
  } finally {
    await firstContext.close();
    await secondContext.close();
  }
});
