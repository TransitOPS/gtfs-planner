import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { VIEWPORTS, bodyFitsViewport } from "./browser_helpers";
import { loginAndGoToDiagram } from "./station_diagram_helpers";

const targetStop = "BROWSER_STOP_A";

async function openStop(page) {
  const row = page.locator(`#child-stops-table li:has-text('${targetStop}')`);
  await expect(row).toBeVisible();
  await row.locator("button[phx-click='edit_child_stop']").click();
  await expect(page.locator("#child-stop-drawer-overlay")).toHaveAttribute("data-open", "true");
}

test("a concurrent stop edit keeps the second editor's typed name", async ({ browser }) => {
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
    await openStop(first);
    await openStop(second);

    await first.locator("#child-stop-form input[name='stop_name']").fill("First editor's name");
    await first.locator("#child-stop-submit").click();
    await expect(first.locator("#child-stop-drawer-overlay")).toHaveAttribute("data-open", "false");

    await second.locator("#child-stop-form input[name='stop_name']").fill("Second editor's draft");
    await second.locator("#child-stop-submit").click();

    await expect(second.locator("#child-stop-outcome")).toContainText(
      "This stop changed since you opened it. Your edits are still here.",
    );
    await expect(second.locator("#child-stop-form input[name='stop_name']")).toHaveValue(
      "Second editor's draft",
    );
    await expect(second.locator("#child-stop-reload")).toBeVisible();
    await expect(second.locator("#child-stop-submit")).toBeEnabled();

    for (const viewport of VIEWPORTS.filter(({ label }) => ["desktop", "320px"].includes(label))) {
      await second.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(second.locator("#child-stop-outcome")).toBeVisible();
      expect(await bodyFitsViewport(second)).toBe(true);

      if (process.env.ARCH_CAPTURE_DIR) {
        mkdirSync(process.env.ARCH_CAPTURE_DIR, { recursive: true });
        await second.screenshot({
          path: resolve(process.env.ARCH_CAPTURE_DIR, `station-stop-stale-${viewport.label}.png`),
        });
      }
    }
  } finally {
    await firstContext.close();
    await secondContext.close();
  }
});
