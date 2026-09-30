import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { VIEWPORTS, bodyFitsViewport } from "./browser_helpers";
import { loginAndGoToDiagram } from "./station_diagram_helpers";

async function openPathway(page) {
  await page.locator("#panel-tab-pathways").click();
  const row = page.locator("#pathways-table li").filter({ hasText: "BROWSER_PW_ELEVATOR" });
  await expect(row).toBeVisible();
  await row.locator("button[phx-click='edit_pathway']").click();
  await expect(page.locator("#pathway-drawer-overlay")).toHaveAttribute("data-open", "true");
}

test("a concurrent pathway edit keeps the second editor's travel time", async ({ browser }) => {
  const firstContext = await browser.newContext();
  const secondContext = await browser.newContext();
  const first = await firstContext.newPage();
  const second = await secondContext.newPage();

  try {
    const desktop = VIEWPORTS.find(({ label }) => label === "desktop");
    await first.setViewportSize({ width: desktop.width, height: desktop.height });
    await second.setViewportSize({ width: desktop.width, height: desktop.height });
    await loginAndGoToDiagram(first);
    await loginAndGoToDiagram(second);
    await openPathway(first);
    await openPathway(second);

    await first.locator("#pathway-form input[name='traversal_time']").fill("71");
    await first.locator("#pathway-submit").click();
    await expect(first.locator("#pathway-drawer-overlay")).toHaveAttribute("data-open", "false");

    await second.locator("#pathway-form input[name='traversal_time']").fill("83");
    await second.locator("#pathway-submit").click();

    await expect(second.locator("#pathway-drawer-overlay")).toHaveAttribute("data-open", "true");
    await expect(second.locator("#pathway-outcome")).toContainText(
      "This pathway changed since you opened it. Your edits are still here.",
    );
    await expect(second.locator("#pathway-outcome")).toBeFocused();
    await expect(second.locator("#pathway-form input[name='traversal_time']")).toHaveValue("83");
    await expect(second.locator("#pathway-reload")).toBeVisible();
    await expect(second.locator("#pathway-submit")).toBeEnabled();
    await second.locator("#pathway-form input[name='traversal_time']").fill("84");
    await expect(second.locator("#pathway-outcome")).toContainText(
      "This pathway changed since you opened it. Your edits are still here.",
    );

    for (const viewport of VIEWPORTS.filter(({ label }) => ["desktop", "320px"].includes(label))) {
      await second.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(second.locator("#pathway-outcome")).toBeVisible();
      expect(await bodyFitsViewport(second)).toBe(true);

      if (process.env.ARCH_CAPTURE_DIR) {
        mkdirSync(process.env.ARCH_CAPTURE_DIR, { recursive: true });
        const label = viewport.label === "320px" ? "320" : viewport.label;
        await second.screenshot({
          path: resolve(process.env.ARCH_CAPTURE_DIR, `station-pathway-stale-${label}.png`),
        });
      }
    }

    await second.locator("#pathway-reload").click();
    await expect(second.locator("#pathway-outcome")).toHaveCount(0);
    await expect(second.locator("#pathway-form input[name='traversal_time']")).toHaveValue("84");
  } finally {
    await firstContext.close();
    await secondContext.close();
  }
});
