import { test, expect } from "@playwright/test";
import { loginAndGoToDiagram, selectDiagramMode } from "./station_diagram_helpers";
import { readPendingStates, watchPendingState } from "./browser_helpers";
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
    await expect(page.locator("#lists-section")).toHaveCount(0);
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

  async function exerciseProductionPreview(page, viewport, artifactName) {
    await page.setViewportSize(viewport);
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    const canvas = page.locator('[phx-hook="MapAlignment"]');
    const previewBtn = page.locator("#map-alignment-preview-auto");
    const restoreBtn = page.locator("#map-alignment-restore-saved");
    const overlay = page.locator("#map-alignment-overlay");
    const status = page.locator("#auto-alignment-status");
    const fitValue = page.locator("#auto-alignment-fit-value");
    const fitDescription = page.locator("#auto-alignment-fit-description");
    const floorplanImage = overlay.locator("img");

    await expect(canvas).toBeVisible();
    const canvasBox = await canvas.boundingBox();
    expect(canvasBox.width).toBeGreaterThan(400);
    expect(canvasBox.height).toBeGreaterThan(200);
    await expect(floorplanImage).toBeVisible();
    await expect
      .poll(() =>
        floorplanImage.evaluate((image) => ({
          width: image.naturalWidth,
          height: image.naturalHeight,
        })),
      )
      .toEqual({ width: 100, height: 80 });

    for (const target of [previewBtn, restoreBtn]) {
      await expect(target).toBeVisible();
      const box = await target.boundingBox();
      expect(box.width).toBeGreaterThanOrEqual(44);
      expect(box.height).toBeGreaterThanOrEqual(44);
    }

    const savedTransform = await overlay.evaluate((element) => element.style.transform);
    expect(savedTransform).toBe("none");
    await watchPendingState(page, "#map-alignment-preview-auto");
    await previewBtn.click();

    await expect(status).toBeVisible({ timeout: 10000 });
    await expect(status).toContainText("Unsaved auto-alignment preview");
    await expect(fitValue).toBeVisible();
    await expect(fitValue).toContainText("Estimated fit error");
    await expect(fitValue.locator("strong")).toHaveText(/\d+\.\d m/);
    await expect(fitDescription).toContainText("RMSE measures the typical anchor mismatch");

    const pendingStates = await readPendingStates(page);
    expect(
      pendingStates.some(
        ({ disabled, text }) => disabled && text === "Previewing…",
      ),
    ).toBe(true);
    await expect(previewBtn).toBeEnabled();
    await expect(previewBtn).toHaveText("Preview auto-alignment");
    await expect
      .poll(() =>
        previewBtn.evaluate((element) =>
          element.classList.contains("phx-click-loading"),
        ),
      )
      .toBe(false);

    await expect
      .poll(() => overlay.evaluate((element) => element.style.transform))
      .not.toBe(savedTransform);

    const statusZIndex = await status.evaluate((element) =>
      Number.parseInt(window.getComputedStyle(element).zIndex, 10),
    );
    expect(statusZIndex).toBeGreaterThan(5);

    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth >
        document.documentElement.clientWidth,
    );
    expect(overflow).toBe(false);

    await page.evaluate(() => window.scrollTo({ top: 0, left: 0, behavior: "instant" }));
    await previewBtn.evaluate((element) => element.blur());
    await page.mouse.move(8, 8);
    await previewBtn.evaluate((element) =>
      Promise.all(element.getAnimations().map((animation) => animation.finished)),
    );
    fs.mkdirSync(artifactsDir, { recursive: true });
    await page.screenshot({
      path: path.join(artifactsDir, artifactName),
      fullPage: true,
    });

    await restoreBtn.click();
    await expect(status).not.toBeVisible();
    await expect
      .poll(() => overlay.evaluate((element) => element.style.transform))
      .toBe("none");
  }

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
    await exerciseProductionPreview(
      page,
      { width: 1280, height: 900 },
      "production-assisted-alignment-1280.png",
    );
  });

  test("production preview and restore flow at 1440x1000", async ({ page }) => {
    await exerciseProductionPreview(
      page,
      { width: 1440, height: 1000 },
      "production-assisted-alignment-1440.png",
    );
  });

  test("controls are keyboard reachable in focus order", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    const precedingControl = page.locator("#map-transform-scale-up-coarse");
    await precedingControl.click();
    await expect(precedingControl).toBeFocused();

    await page.keyboard.press("Tab");
    await expect(page.locator("#map-alignment-restore-saved")).toBeFocused();

    await page.keyboard.press("Tab");
    await expect(page.locator("#map-alignment-preview-auto")).toBeFocused();
  });
});
