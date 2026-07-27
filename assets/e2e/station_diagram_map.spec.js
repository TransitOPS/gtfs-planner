import { test, expect } from "@playwright/test";
import {
  loginAndGoToDiagram,
  selectDiagramMode,
} from "./station_diagram_helpers";
import { readPendingStates, watchPendingState } from "./browser_helpers";
import { pathToFileURL, fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const journal08ArtifactsDir = path.resolve(
  __dirname,
  "../../.artifacts/journal-08",
);
const reviewReferencePath = path.resolve(
  __dirname,
  "../../.specs/journal-08/visual-references/mock-05-align-mode-v2.html",
);

async function readSettledTransform(overlay) {
  return overlay.evaluate(
    (element) =>
      new Promise((resolve, reject) => {
        const stableWindowMs = 700;
        const timeoutMs = 5000;
        const startedAt = performance.now();
        let lastTransform = element.style.transform;
        let stableSince = startedAt;

        const observe = (now) => {
          const transform = element.style.transform;

          if (transform !== lastTransform) {
            lastTransform = transform;
            stableSince = now;
          }

          if (now - stableSince >= stableWindowMs) {
            resolve(transform);
          } else if (now - startedAt >= timeoutMs) {
            reject(new Error("overlay transform did not settle"));
          } else {
            requestAnimationFrame(observe);
          }
        };

        requestAnimationFrame(observe);
      }),
  );
}

// The Align control strip's five groups, each captioned by a visible <legend>.
const controlGroupLegends = [
  "Map center",
  "Floorplan transform",
  "Assisted alignment",
  "Layers",
  "Save and apply",
];

async function expectControlGroupLegendsVisible(page) {
  for (const legend of controlGroupLegends) {
    const caption = page
      .locator("fieldset > legend")
      .filter({ hasText: legend });

    await expect(caption).toBeVisible();

    // A visually-hidden legend still reports as visible, so measure it: the
    // sr-only idiom collapses to a 1px box.
    const box = await caption.boundingBox();
    expect(box.width).toBeGreaterThan(20);
  }
}

// Records document.activeElement.id at the starting control and after each Tab.
async function collectTabOrder(page, startSelector, steps) {
  await page.locator(startSelector).focus();

  const order = [await page.evaluate(() => document.activeElement?.id ?? "")];

  for (let step = 0; step < steps; step += 1) {
    await page.keyboard.press("Tab");
    order.push(await page.evaluate(() => document.activeElement?.id ?? ""));
  }

  return order;
}

async function coordinateReviewTableMetrics(page) {
  return page.evaluate(() => {
    const body = document.querySelector("#coordinate-review-dialog-body");
    const scroller = document.querySelector(
      "#coordinate-review-table-scroller",
    );
    const table = document.querySelector("#coordinate-review-table");

    if (!body || !scroller || !table) {
      throw new Error("coordinate review table geometry is unavailable");
    }

    const tolerance = 1;
    const bodyRect = body.getBoundingClientRect();
    const scrollerRect = scroller.getBoundingClientRect();
    const edgeCells = Array.from(
      table.querySelectorAll("tr > :first-child, tr > :last-child"),
    );

    return {
      bodyOverflow: body.scrollWidth - body.clientWidth,
      scrollerOverflow: scroller.scrollWidth - scroller.clientWidth,
      scrollerContained:
        scrollerRect.left >= bodyRect.left - tolerance &&
        scrollerRect.right <= bodyRect.right + tolerance,
      edgeCellsVisible: edgeCells.every((cell) => {
        const rect = cell.getBoundingClientRect();

        return (
          rect.left >= scrollerRect.left - tolerance &&
          rect.right <= scrollerRect.right + tolerance
        );
      }),
    };
  });
}

test.describe("Station diagram map alignment", () => {
  test("uses one real map composition and keyboard transform controls", async ({
    page,
  }) => {
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    const map = page.locator('[phx-hook="MapAlignment"]');
    await expect(map).toBeVisible();
    await expect(page.locator("#lists-section")).toHaveCount(0);
    await expect(page.locator("#map-alignment-leaflet")).toBeVisible();
    await expect(
      page.locator("#map-alignment-leaflet.leaflet-container"),
    ).toHaveCount(1);

    const overlay = page.locator("#map-alignment-overlay");
    const initialTransform = await overlay.getAttribute("style");
    await page.locator("#map-transform-right-fine").focus();
    await page.keyboard.press("Enter");
    await expect(overlay).not.toHaveAttribute("style", initialTransform || "");
  });

  test("reports offline state and provides a retry without adding hidden tab stops", async ({
    page,
  }) => {
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await expect(
      page.locator("#map-alignment-leaflet.leaflet-container"),
    ).toBeVisible();
    await page.evaluate(() => window.dispatchEvent(new Event("offline")));
    await expect(page.locator("#map-alignment-retry")).toBeVisible();
    await page.locator("#map-alignment-retry").click();
    await expect(page.locator('[phx-hook="MapAlignment"]')).toBeVisible();

    const ignoredFocusable = await page
      .locator('[phx-hook="MapAlignment"] [tabindex]:not([tabindex="-1"])')
      .count();
    expect(ignoredFocusable).toBe(0);
  });
});

test.describe("assisted alignment", () => {
  const artifactsDir = path.resolve(__dirname, "../../.artifacts/journal-09");
  const referencePath = path.resolve(
    __dirname,
    "../../.specs/journal-08/visual-references/mock-05-align-mode-v2.html",
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
    await expectControlGroupLegendsVisible(page);
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

    const savedTransform = await readSettledTransform(overlay);
    await watchPendingState(page, "#map-alignment-preview-auto");
    await previewBtn.click();

    await expect(status).toBeVisible({ timeout: 10000 });
    await expect(status).toContainText("Unsaved auto-alignment preview");
    await expect(fitValue).toBeVisible();
    await expect(fitValue).toContainText("Estimated fit error");
    await expect(fitValue.locator("strong")).toHaveText(/\d+\.\d m/);
    await expect(fitDescription).toContainText(
      "RMSE measures the typical anchor mismatch",
    );

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

    await page.evaluate(() =>
      window.scrollTo({ top: 0, left: 0, behavior: "instant" }),
    );
    await previewBtn.evaluate((element) => element.blur());
    await page.mouse.move(8, 8);
    await previewBtn.evaluate((element) =>
      Promise.all(
        element.getAnimations().map((animation) => animation.finished),
      ),
    );
    fs.mkdirSync(artifactsDir, { recursive: true });
    await page.screenshot({
      path: path.join(artifactsDir, artifactName),
      fullPage: true,
    });

    // Applying an assisted preview moves the floorplan off its saved position,
    // so the hook reports `unsaved: true` one debounce window later even though
    // it was not an operator gesture. Restore saved alignment therefore becomes
    // available without one, and an operator gesture afterwards keeps it so.
    await expect(restoreBtn).toBeEnabled();
    await page.locator("#map-transform-right-fine").click();
    await expect(restoreBtn).toBeEnabled();

    await restoreBtn.click();
    await expect(status).not.toBeVisible();
    await expect
      .poll(() => overlay.evaluate((element) => element.style.transform))
      .toBe(savedTransform);
  }

  test("renders the copied reference and captures the assisted alignment region", async ({
    page,
  }) => {
    // The mock lives under the gitignored .specs/ workspace, so the suite skips
    // rather than fails when that workspace is absent (as the coordinate-review
    // reference test already does).
    test.skip(!fs.existsSync(referencePath), "reference file not present");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(pathToFileURL(referencePath).href);

    const fieldset = page
      .locator("fieldset")
      .filter({ hasText: "Assisted alignment" });
    await expect(fieldset).toBeVisible();
    await expect(
      page.locator("text=Unsaved auto-alignment preview"),
    ).toBeVisible();

    fs.mkdirSync(journal08ArtifactsDir, { recursive: true });

    await page.screenshot({
      path: path.join(
        journal08ArtifactsDir,
        "reference-assisted-alignment.png",
      ),
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

    const precedingControl = page.locator("#map-transform-scale-up-fine");
    await precedingControl.click();
    await expect(precedingControl).toBeFocused();

    // Restore saved alignment is disabled until the server marks the alignment
    // unsaved, and a disabled button is not a tab stop. The click above is the
    // operator gesture that dirties it, one debounce window earlier.
    await expect(page.locator("#map-alignment-restore-saved")).toBeEnabled();
    await precedingControl.focus();

    await page.keyboard.press("Tab");
    await expect(page.locator("#map-alignment-restore-saved")).toBeFocused();

    await page.keyboard.press("Tab");
    await expect(page.locator("#map-alignment-preview-auto")).toBeFocused();
  });

  test("keyboard focus walks the control groups in source order", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    // Dirty the alignment so Restore saved alignment is a tab stop at all.
    await page.locator("#map-transform-right-fine").click();
    await expect(page.locator("#map-alignment-restore-saved")).toBeEnabled();

    const focusOrder = await collectTabOrder(
      page,
      "#map-alignment-lat-input",
      24,
    );

    // One marker per group, asserted as relative order rather than adjacency:
    // the Move pad contributes four consecutive stops and each group holds
    // several focusable controls.
    const markers = [
      "map-alignment-lat-input",
      "map-alignment-lon-input",
      "map-alignment-apply-center",
      "map-alignment-restore-saved",
      "map-alignment-preview-auto",
      "map-alignment-opacity",
      "map-alignment-save",
    ];
    expect(focusOrder.filter((id) => markers.includes(id))).toEqual(markers);

    // The transform pad is reached between Center map and Restore saved alignment.
    const transformStop = focusOrder.findIndex((id) =>
      id.startsWith("map-transform-"),
    );
    expect(transformStop).toBeGreaterThan(
      focusOrder.indexOf("map-alignment-apply-center"),
    );
    expect(transformStop).toBeLessThan(
      focusOrder.indexOf("map-alignment-restore-saved"),
    );

    // No unidentified tab stop is introduced between the first and last control.
    const stripStops = focusOrder.slice(
      0,
      focusOrder.indexOf("map-alignment-save") + 1,
    );
    expect(stripStops.filter((id) => id === "")).toEqual([]);
  });
});

test.describe("coordinate review", () => {
  const viewports = [
    { width: 1280, height: 900, label: "1280" },
    { width: 1440, height: 1000, label: "1440" },
  ];

  // Wait for the review dialog to open and its body table to render rows.
  async function openReviewDialog(page) {
    const applyBtn = page.locator("#map-alignment-apply");
    await expect(applyBtn).toBeEnabled();
    await applyBtn.click();

    const dialog = page.locator("#coordinate-review-dialog");
    await expect(dialog).toBeVisible({ timeout: 10000 });
    await expect(
      page.locator("#coordinate-review-table tbody tr").first(),
    ).toBeVisible();
    return dialog;
  }

  for (const viewport of viewports) {
    test(`renders the copied reference at ${viewport.label} and captures the review state`, async ({
      page,
    }) => {
      test.skip(
        !fs.existsSync(reviewReferencePath),
        "reference file not present",
      );
      await page.setViewportSize(viewport);
      await page.goto(pathToFileURL(reviewReferencePath).href);

      const review = page.locator('[role="alertdialog"]');
      await expect(review).toBeVisible();
      await expect(review).toContainText("Update coordinates for");
      await expect(review).toContainText("reverted as one batch");
      await expect(review.locator("table thead tr")).toContainText("Stop");
      await expect(review.locator("table thead tr")).toContainText("Change");

      fs.mkdirSync(journal08ArtifactsDir, { recursive: true });
      await page.screenshot({
        path: path.join(
          journal08ArtifactsDir,
          `reference-coordinate-review-${viewport.label}.png`,
        ),
        fullPage: false,
      });
    });

    test(`production review dialog opens, focuses Cancel, renders rows, and fits ${viewport.label}`, async ({
      page,
    }) => {
      await page.setViewportSize(viewport);
      await loginAndGoToDiagram(page);
      await selectDiagramMode(page, "map");

      const overlay = page.locator("#map-alignment-overlay");
      await expect(overlay).toBeVisible();

      // Make a real transform adjustment so the seeded coordinates no longer
      // match the displayed transform, guaranteeing review rows.
      await page.locator("#map-transform-right-fine").focus();
      await page.keyboard.press("Enter");

      const dialog = await openReviewDialog(page);

      // Cancel receives initial focus (cancel-first).
      await expect(
        page.locator("#coordinate-review-dialog-cancel"),
      ).toBeFocused();

      // Every rendered current/new cell carries either a complete six-decimal
      // coordinate pair or the explicit missing-coordinate pair.
      const rowCount = await page
        .locator("#coordinate-review-table tbody tr")
        .count();
      expect(rowCount).toBeGreaterThan(0);

      const coordinateCells = await page
        .locator(
          "#coordinate-review-table tbody td:nth-child(2), #coordinate-review-table tbody td:nth-child(3)",
        )
        .allTextContents();
      expect(coordinateCells).toHaveLength(rowCount * 2);

      for (const coordinatePair of coordinateCells) {
        expect(coordinatePair.trim()).toMatch(
          /^(?:-?\d+\.\d{6}, -?\d+\.\d{6}|—, —)$/,
        );
      }

      // The consequence and recovery copy are present (DC-5).
      await expect(dialog).toContainText("cannot be reverted as one batch");

      // The nested table stays inside the scroll-bounded dialog body, and the
      // first/last cells are fully visible at the initial scroll position.
      const tableMetrics = await coordinateReviewTableMetrics(page);
      expect(tableMetrics.bodyOverflow).toBeLessThanOrEqual(0);
      expect(tableMetrics.scrollerOverflow).toBeLessThanOrEqual(0);
      expect(tableMetrics.scrollerContained).toBe(true);
      expect(tableMetrics.edgeCellsVisible).toBe(true);

      const dialogPanel = page.locator("#coordinate-review-dialog > div > div");
      await dialogPanel.evaluate(async (element) => {
        await Promise.all(
          element.getAnimations().map((animation) => animation.finished),
        );
      });
      await expect(dialogPanel).toHaveCSS("opacity", "1");

      fs.mkdirSync(journal08ArtifactsDir, { recursive: true });
      await page.screenshot({
        path: path.join(
          journal08ArtifactsDir,
          `production-coordinate-review-${viewport.label}.png`,
        ),
        fullPage: true,
      });

      // Cancel closes the dialog and returns focus to the trigger.
      await page.locator("#coordinate-review-dialog-cancel").click();
      await expect(dialog).not.toBeVisible();
      await expect(page.locator("#map-alignment-apply")).toBeFocused();
    });
  }

  test("immediate review consumes the prior invalidation while a later transform closes it", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    const transformControl = page.locator("#map-transform-right-fine");
    await transformControl.focus();
    await page.keyboard.press("Enter");

    const dialog = await openReviewDialog(page);

    // Stay open beyond the 400 ms debounce window from the reviewed mutation.
    await page.waitForTimeout(500);
    await expect(dialog).toBeVisible();

    // A mutation made after the review opens starts a fresh invalidation window.
    await transformControl.dispatchEvent("click");
    await expect(dialog).not.toBeVisible({ timeout: 10000 });
    await expect(page.locator("#coordinate-review-status")).toContainText(
      "The alignment changed — review again.",
    );
  });

  test("confirm exposes immediate pending feedback then succeeds", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await loginAndGoToDiagram(page);
    await selectDiagramMode(page, "map");

    await page.locator("#map-transform-right-fine").focus();
    await page.keyboard.press("Enter");

    await openReviewDialog(page);

    const confirmBtn = page.locator("#coordinate-review-dialog-confirm");
    await watchPendingState(page, "#coordinate-review-dialog-confirm");
    await confirmBtn.click();

    const pendingStates = await readPendingStates(page);
    expect(pendingStates.some(({ disabled }) => disabled)).toBe(true);

    // The success flash refreshes the surface and closes the dialog.
    await expect(page.locator("#coordinate-review-dialog")).not.toBeVisible({
      timeout: 10000,
    });
  });

  test("a real two-tab stale apply closes with retry copy and no partial writes", async ({
    browser,
  }) => {
    const pageA = await browser.newPage();
    const pageB = await browser.newPage();

    try {
      await pageA.setViewportSize({ width: 1280, height: 900 });
      await pageB.setViewportSize({ width: 1280, height: 900 });

      await loginAndGoToDiagram(pageA);
      await loginAndGoToDiagram(pageB);
      await selectDiagramMode(pageA, "map");
      await selectDiagramMode(pageB, "map");

      // Both tabs adjust the transform and open their reviews before either
      // applies, so the second apply hits a stale fingerprint.
      for (const page of [pageA, pageB]) {
        await page.locator("#map-transform-right-fine").focus();
        await page.keyboard.press("Enter");
        await openReviewDialog(page);
      }

      // Tab A applies first.
      await pageA.locator("#coordinate-review-dialog-confirm").click();
      await expect(pageA.locator("#coordinate-review-dialog")).not.toBeVisible({
        timeout: 10000,
      });

      // Tab B applies second: the server fingerprint no longer matches.
      await pageB.locator("#coordinate-review-dialog-confirm").click();
      await expect(pageB.locator("#coordinate-review-dialog")).not.toBeVisible({
        timeout: 10000,
      });
      // The retry status is announced.
      await expect(pageB.locator("#coordinate-review-status")).toContainText(
        /review the coordinate changes again/i,
      );
    } finally {
      await pageA.close();
      await pageB.close();
    }
  });
});
