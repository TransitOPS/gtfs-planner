import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { VIEWPORTS, bodyFitsViewport } from "./browser_helpers";
import { loginAndGoToDiagram } from "./station_diagram_helpers";

async function openLevel(page) {
  await page.locator("#diagram-more-trigger").click();
  await page.locator("#edit-level-action").click();
  await expect(page.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "true");
}

test("a concurrent level edit keeps the second editor's draft", async ({ browser, baseURL }) => {
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
    await openLevel(first);
    await openLevel(second);

    await first.locator("#level-form input[name='level_name']").fill("First edit");
    await first.locator("#level-submit").click();
    await expect(first.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "false");

    await second.locator("#level-form input[name='level_name']").fill("Second draft");
    await second.locator("#level-submit").click();
    await expect(second.locator("#level-sidebar-overlay")).toHaveAttribute("data-open", "true");
    await expect(second.locator("#level-outcome")).toContainText(
      "This level changed since you opened it. Your edits are still here.",
    );
    await expect(second.locator("#level-outcome")).toBeFocused();
    await expect(second.locator("#level-form input[name='level_name']")).toHaveValue("Second draft");
    await expect(second.locator("#level-reload")).toBeVisible();
    await expect(second.locator("#level-submit")).toBeEnabled();

    for (const viewport of VIEWPORTS.filter(({ label }) => ["desktop", "320px"].includes(label))) {
      await second.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(second.locator("#level-outcome")).toBeVisible();
      expect(await bodyFitsViewport(second)).toBe(true);

      if (process.env.ARCH_CAPTURE_DIR) {
        mkdirSync(process.env.ARCH_CAPTURE_DIR, { recursive: true });
        const label = viewport.label === "320px" ? "320" : viewport.label;
        await second.screenshot({
          path: resolve(process.env.ARCH_CAPTURE_DIR, `station-level-stale-${label}.png`),
        });
      }
    }

    await second.locator("#level-reload").click();
    await expect(second.locator("#level-outcome")).toHaveCount(0);
    await expect(second.locator("#level-form input[name='level_name']")).toHaveValue("Second draft");
  } finally {
    await firstContext.close();
    await secondContext.close();
  }
});
