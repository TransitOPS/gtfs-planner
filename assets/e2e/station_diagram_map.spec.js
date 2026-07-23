import { test, expect } from "@playwright/test";
import { loginAndGoToDiagram, selectDiagramMode } from "./station_diagram_helpers";
import { pathToFileURL, fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

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

test.describe("assisted alignment", () => {
  const artifactsDir = path.resolve(__dirname, "../../.artifacts/journal-07");
  const referencePath = path.resolve(
    __dirname,
    "../../.specs/journal-07/visual-references/mock-05-align-mode-v2.html",
  );

  test("renders the copied reference and captures the assisted alignment region", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(pathToFileURL(referencePath).href);

    const fieldset = page.locator("fieldset").filter({ hasText: "Assisted alignment" });
    await expect(fieldset).toBeVisible();
    await expect(page.locator("text=Unsaved auto-alignment preview")).toBeVisible();

    fs.mkdirSync(artifactsDir, { recursive: true });

    await page.screenshot({
      path: path.join(artifactsDir, "reference-assisted-alignment.png"),
      fullPage: false,
    });
  });

  test("production preview and restore flow at 1280x900", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await expect(page.locator("#map-alignment-preview-auto")).toBeVisible();
    await expect(page.locator("#map-alignment-restore-saved")).toBeVisible();

    const previewBtn = page.locator("#map-alignment-preview-auto");
    const box = await previewBtn.boundingBox();
    expect(box.height).toBeGreaterThanOrEqual(44);

    await previewBtn.click();
    await expect(page.locator("#auto-alignment-status")).toBeVisible({ timeout: 10000 });
    await expect(page.locator("#auto-alignment-status")).toContainText(
      "Unsaved auto-alignment preview",
    );

    const restoreBtn = page.locator("#map-alignment-restore-saved");
    const restoreBox = await restoreBtn.boundingBox();
    expect(restoreBox.height).toBeGreaterThanOrEqual(44);

    await restoreBtn.click();
    await expect(page.locator("#auto-alignment-status")).not.toBeVisible();

    fs.mkdirSync(artifactsDir, { recursive: true });
    await page.screenshot({
      path: path.join(artifactsDir, "production-assisted-alignment-1280.png"),
      fullPage: false,
    });
  });

  test("production preview and restore flow at 1440x1000", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await expect(page.locator("#map-alignment-preview-auto")).toBeVisible();

    await page.locator("#map-alignment-preview-auto").click();
    await expect(page.locator("#auto-alignment-status")).toBeVisible({ timeout: 10000 });

    const overflow = await page.evaluate(() => {
      return document.documentElement.scrollWidth > document.documentElement.clientWidth;
    });
    expect(overflow).toBe(false);

    await page.locator("#map-alignment-restore-saved").click();
    await expect(page.locator("#auto-alignment-status")).not.toBeVisible();

    fs.mkdirSync(artifactsDir, { recursive: true });
    await page.screenshot({
      path: path.join(artifactsDir, "production-assisted-alignment-1440.png"),
      fullPage: false,
    });
  });

  test("controls are keyboard reachable in focus order", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await page.locator("#map-alignment-preview-auto").focus();
    await expect(page.locator("#map-alignment-preview-auto")).toBeFocused();

    await page.locator("#map-alignment-restore-saved").focus();
    await expect(page.locator("#map-alignment-restore-saved")).toBeFocused();
  });
});
