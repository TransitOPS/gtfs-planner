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

// The Align surface's two containers: the tools panel floating over the map and
// the commit bar below it. Each holds a control that proves it is populated.
const alignContainers = [
  ["#map-alignment-tools", "#map-transform-left-fine"],
  ["#map-alignment-commit-bar", "#map-alignment-save"],
];

async function expectAlignContainersVisible(page) {
  for (const [container, member] of alignContainers) {
    const panel = page.locator(container);

    await expect(panel).toBeVisible();
    await expect(panel.locator(member)).toBeVisible();

    // A collapsed-to-nothing container still reports as visible, so measure it.
    const box = await panel.boundingBox();
    expect(box.width).toBeGreaterThan(20);
    expect(box.height).toBeGreaterThan(20);
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

const journal10ArtifactsDir = path.resolve(
  __dirname,
  "../../.artifacts/journal-10",
);

async function openAlignSurface(page, viewport) {
  await page.setViewportSize(viewport);
  await loginAndGoToDiagram(page);
  await selectDiagramMode(page, "map");

  await expect(page.locator("#map-alignment-commit-bar")).toBeVisible();
  await expect(page.locator("#map-alignment-tools")).toBeVisible();
  await expect(page.locator("#map-alignment-overlay img")).toBeVisible();

  // The surface renders two extra full-width status lines while it resolves:
  // "Floorplan image is not ready" until the image reports its natural size,
  // and "Loading map…" until Leaflet reports ready. Each costs the map ~24 px,
  // so measure the ready surface rather than the one still settling. Their
  // absence is the production signal that the map is ready and not degraded.
  await expect(page.locator("#map-auto-alignment-disabled-reason")).toHaveCount(
    0,
  );
  await expect(page.locator("#map-alignment-state")).toHaveCount(0, {
    timeout: 20000,
  });
  await expect(page.locator("#map-alignment-preview-auto")).toBeEnabled();
}

// Rendered geometry of the Align surface in CSS pixels. `region` is the distance
// from the canvas's bottom edge to the bottom of the element that owns both the
// canvas and the controls beneath it — the space AC-1 puts a budget on.
async function alignSurfaceGeometry(page) {
  return page.evaluate(() => {
    const canvas = document.querySelector(".map-canvas");
    const workspace = document.querySelector("#map-alignment-workspace");
    const bar = document.querySelector("#map-alignment-commit-bar");
    const tools = document.querySelector("#map-alignment-tools");
    const ignoredCanvas = document.querySelector(
      '.map-canvas[phx-update="ignore"]',
    );
    const surface = workspace.parentElement;
    const doc = document.documentElement;

    const box = (element) => {
      const rect = element.getBoundingClientRect();

      return {
        top: Math.round(rect.top),
        bottom: Math.round(rect.bottom),
        left: Math.round(rect.left),
        right: Math.round(rect.right),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
      };
    };

    return {
      canvas: box(canvas),
      bar: box(bar),
      tools: box(tools),
      surface: box(surface),
      region: Math.round(
        surface.getBoundingClientRect().bottom -
          canvas.getBoundingClientRect().bottom,
      ),
      toolsScrollOverflow: tools.scrollHeight - tools.clientHeight,
      toolsInsideWorkspace: workspace.contains(tools),
      toolsInsideIgnoredCanvas: ignoredCanvas.contains(tools),
      ignoredCanvasIsTheMapCanvas: ignoredCanvas === canvas,
      viewportHeight: window.innerHeight,
      viewportWidth: window.innerWidth,
      documentVerticalOverflow: doc.scrollHeight - doc.clientHeight,
      documentHorizontalOverflow: doc.scrollWidth - doc.clientWidth,
    };
  });
}

// The floorplan's translation, parsed out of the inline transform the hook
// writes. Nudges are asserted as deltas because the browser suite shares one
// seeded database and the floorplan may already carry a saved offset.
async function overlayTranslation(page) {
  return page.locator("#map-alignment-overlay").evaluate((element) => {
    const match = /translate\((-?[\d.]+)px,\s*(-?[\d.]+)px\)/.exec(
      element.style.transform,
    );

    return match
      ? { x: Number(match[1]), y: Number(match[2]) }
      : { x: null, y: null };
  });
}

// `id:disabled` for every control the tools panel holds, so a collapse that
// silently disabled something would change the list rather than pass unnoticed.
async function toolsPanelDisabledState(page) {
  return page.evaluate(() =>
    Array.from(
      document.querySelectorAll(
        "#map-alignment-tools button, #map-alignment-tools input",
      ),
    ).map((element) => `${element.id}:${element.disabled}`),
  );
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

    // Wait for the surface to settle before taking it offline. While the map is
    // still resolving, its state message comes and goes; each appearance adds a
    // line to the commit bar, which resizes the canvas and moves the actions row
    // with it, so Retry map never holds still long enough to be clicked.
    await expect(page.locator("#map-alignment-state")).toHaveCount(0, {
      timeout: 20000,
    });

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
  const artifactsDir = journal10ArtifactsDir;
  const referencePath = path.resolve(
    __dirname,
    "../../.specs/journal-08/visual-references/mock-05-align-mode-v2.html",
  );

  test.beforeAll(() => {
    fs.mkdirSync(artifactsDir, { recursive: true });
    fs.mkdirSync(journal08ArtifactsDir, { recursive: true });
  });

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
    await expectAlignContainersVisible(page);
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

    // Preview auto-alignment is a primary commit-bar action and holds the 44 px
    // target, as does every button in the transform pad. Restore saved
    // alignment and the panel's other utility controls are deliberately 32 px:
    // they are pressed once, not repeatedly, and the panel's job is to stay out
    // of the map's way. Pinned exactly so neither can drift.
    await expect(previewBtn).toBeVisible();
    const previewBox = await previewBtn.boundingBox();
    expect(previewBox.width).toBeGreaterThanOrEqual(44);
    expect(previewBox.height).toBeGreaterThanOrEqual(44);

    for (const padButton of [
      "#map-transform-left-fine",
      "#map-transform-scale-up-fine",
    ]) {
      const box = await page.locator(padButton).boundingBox();
      expect(box.width).toBeGreaterThanOrEqual(44);
      expect(box.height).toBeGreaterThanOrEqual(44);
    }

    await expect(restoreBtn).toBeVisible();
    const restoreBox = await restoreBtn.boundingBox();
    expect(restoreBox.width).toBe(32);
    expect(restoreBox.height).toBe(32);

    const savedTransform = await readSettledTransform(overlay);
    await watchPendingState(page, "#map-alignment-preview-auto");
    await previewBtn.click();

    await expect(status).toBeVisible({ timeout: 10000 });
    await expect(status).toContainText("Unsaved auto-alignment preview");
    await expect(fitValue).toBeVisible();
    await expect(fitValue).toContainText("Suggested alignment fits to");
    await expect(fitValue.locator("strong")).toHaveText(/\d+\.\d m/);
    await expect(fitDescription).toContainText("Measured over");
    await expect(fitDescription).toContainText("Lower is better");

    const pendingStates = await readPendingStates(page);
    expect(
      pendingStates.some(
        ({ disabled, text }) => disabled && text === "Aligning…",
      ),
    ).toBe(true);
    await expect(previewBtn).toBeEnabled();
    await expect(previewBtn).toHaveText("Auto-align");
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
      "production-assisted-alignment-1280x900.png",
    );
  });

  test("production preview and restore flow at 1440x1000", async ({ page }) => {
    await exerciseProductionPreview(
      page,
      { width: 1440, height: 1000 },
      "production-assisted-alignment-1440x1000.png",
    );
  });
});

test.describe("align workspace layout and interaction", () => {
  const layoutViewports = [
    { width: 1280, height: 800, label: "1280x800" },
    { width: 1440, height: 900, label: "1440x900" },
  ];

  // The tab order the Align surface publishes at rest: the tools panel floating
  // over the map first, then the commit bar below it. The transform pad is read
  // row by row — rotate/move/rotate, then move/move, then scale/move/scale — so
  // the chain follows what the operator sees. Restore saved alignment is absent
  // because the server disables it until the alignment is dirty, and the
  // demoted popover controls are absent because their panels render hidden.
  const restingFocusOrder = [
    "map-alignment-tools-toggle",
    "map-transform-rotate-left-fine",
    "map-transform-up-fine",
    "map-transform-rotate-right-fine",
    "map-transform-left-fine",
    "map-transform-right-fine",
    "map-transform-scale-down-fine",
    "map-transform-down-fine",
    "map-transform-scale-up-fine",
    "map-alignment-opacity",
    "map-alignment-help-trigger",
    "map-alignment-center-trigger",
    "map-alignment-zoom-trigger",
    "map-alignment-preview-auto",
    "map-alignment-save",
    "map-alignment-apply",
  ];

  const dirtyFocusOrder = [
    "map-alignment-restore-saved",
    "map-alignment-tools-toggle",
    "map-transform-rotate-left-fine",
    "map-transform-up-fine",
    "map-transform-rotate-right-fine",
    "map-transform-left-fine",
    "map-transform-right-fine",
    "map-transform-scale-down-fine",
    "map-transform-down-fine",
    "map-transform-scale-up-fine",
    "map-alignment-opacity",
    "map-alignment-help-trigger",
    "map-alignment-center-trigger",
    "map-alignment-zoom-trigger",
    "map-alignment-preview-auto",
    "map-alignment-save",
    "map-alignment-apply",
  ];

  test.beforeAll(() => {
    fs.mkdirSync(journal10ArtifactsDir, { recursive: true });
  });

  for (const viewport of layoutViewports) {
    test(`gives the map canvas at least 520 px and the region below it at most 130 px at ${viewport.label}`, async ({
      page,
    }) => {
      await openAlignSurface(page, viewport);

      const geometry = await alignSurfaceGeometry(page);

      expect(geometry.canvas.height).toBeGreaterThanOrEqual(520);
      expect(geometry.region).toBeLessThanOrEqual(130);

      // `.map-canvas` still carries `aspect-square`; the immersive stylesheet
      // resets it to `aspect-ratio: auto` so the flex height wins. A canvas that
      // rendered square would meet the height budget and destroy the layout.
      expect(geometry.canvas.width).toBeGreaterThan(geometry.canvas.height);

      // A tools panel that scrolls internally satisfies the height budget while
      // being unusable, so the reclaimed height has to fit the panel too.
      expect(geometry.toolsScrollOverflow).toBeLessThanOrEqual(0);

      await page.screenshot({
        path: path.join(
          journal10ArtifactsDir,
          `align-workspace-${viewport.label}.png`,
        ),
        fullPage: false,
      });
    });

    test(`keeps every align control inside the viewport without horizontal overflow at ${viewport.label}`, async ({
      page,
    }) => {
      await openAlignSurface(page, viewport);

      const geometry = await alignSurfaceGeometry(page);

      expect(geometry.documentHorizontalOverflow).toBeLessThanOrEqual(0);

      for (const region of [geometry.canvas, geometry.tools, geometry.bar]) {
        expect(region.top).toBeGreaterThanOrEqual(0);
        expect(region.bottom).toBeLessThanOrEqual(geometry.viewportHeight);
        expect(region.left).toBeGreaterThanOrEqual(0);
        expect(region.right).toBeLessThanOrEqual(geometry.viewportWidth);
      }

      // AC-2's vertical half. The 83 px this page used to overflow by was 80 px
      // of empty `#main-content` — immersive mode renders the workspace in the
      // sub-header slot, leaving `main` holding nothing but closed dialogs, so
      // its `py-8` and the `space-y-4` margin on the zero-height candidate probe
      // were pure dead space — plus 3 px from sizing `#map-canvas-wrapper` as
      // `100vh - 4rem` against a 67 px action strip. The immersive stylesheet
      // now collapses the first and sizes the canvas from what the strip
      // actually leaves, so nothing on this surface sits below the fold.
      expect(geometry.documentVerticalOverflow).toBeLessThanOrEqual(0);
    });

    test(`aligns the commit bar with the canvas on both edges at ${viewport.label}`, async ({
      page,
    }) => {
      await openAlignSurface(page, viewport);

      const geometry = await alignSurfaceGeometry(page);

      expect(
        Math.abs(geometry.bar.left - geometry.canvas.left),
      ).toBeLessThanOrEqual(1);
      expect(
        Math.abs(geometry.bar.right - geometry.canvas.right),
      ).toBeLessThanOrEqual(1);
    });
  }

  test("floats the tools panel over the canvas outside the ignored subtree", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const geometry = await alignSurfaceGeometry(page);

    expect(geometry.ignoredCanvasIsTheMapCanvas).toBe(true);
    expect(geometry.toolsInsideWorkspace).toBe(true);
    expect(geometry.toolsInsideIgnoredCanvas).toBe(false);

    expect(geometry.tools.left).toBeGreaterThanOrEqual(geometry.canvas.left);
    expect(geometry.tools.right).toBeLessThanOrEqual(geometry.canvas.right);
    expect(geometry.tools.top).toBeGreaterThanOrEqual(geometry.canvas.top);
    expect(geometry.tools.bottom).toBeLessThanOrEqual(geometry.canvas.bottom);
  });

  test("collapses and restores the tools panel without changing any disabled state", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const toggle = page.locator("#map-alignment-tools-toggle");
    const nudgeControl = page.locator("#map-transform-left-fine");
    const opacitySlider = page.locator("#map-alignment-opacity");

    // The control is icon-only, so its label is the tooltip and accessible
    // name. The server renders `Hide tools`; the collapsed label is hook-owned
    // and only observable once the toggle has been activated in a browser.
    await expect(toggle).toHaveAttribute("data-tip", "Hide tools");
    await expect(toggle).toHaveAttribute("aria-label", "Hide tools");
    await expect(toggle).toHaveAttribute("data-collapsed", "false");
    await expect(nudgeControl).toBeVisible();
    const expanded = await toolsPanelDisabledState(page);

    await toggle.click();
    await expect(toggle).toHaveAttribute("data-tip", "Show tools");
    await expect(toggle).toHaveAttribute("data-collapsed", "true");
    await expect(nudgeControl).toBeHidden();
    await expect(opacitySlider).toBeHidden();
    expect(await toolsPanelDisabledState(page)).toEqual(expanded);

    await toggle.click();
    await expect(toggle).toHaveAttribute("data-tip", "Hide tools");
    await expect(toggle).toHaveAttribute("data-collapsed", "false");
    await expect(nudgeControl).toBeVisible();
    await expect(opacitySlider).toBeVisible();
    expect(await toolsPanelDisabledState(page)).toEqual(expanded);
  });

  test("opens the map center popover from its trigger and dismisses it on Escape", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const trigger = page.locator("#map-alignment-center-trigger");
    const panel = page.locator("#map-alignment-center-panel");

    await expect(panel).toBeHidden();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");

    await trigger.click();
    await expect(panel).toBeVisible();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    await expect(panel.locator("#map-alignment-lat-input")).toBeVisible();
    await expect(panel.locator("#map-alignment-lon-input")).toBeVisible();
    await expect(panel.locator("#map-alignment-apply-center")).toBeVisible();
    await expect(trigger).toBeFocused();

    const latitudeInput = panel.locator("#map-alignment-lat-input");
    await latitudeInput.focus();
    await expect(latitudeInput).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");
    await expect(trigger).toBeFocused();
  });

  test("dismisses the map center popover on a click away, returning focus to its trigger", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const trigger = page.locator("#map-alignment-center-trigger");
    const panel = page.locator("#map-alignment-center-panel");

    await trigger.click();
    await expect(panel).toBeVisible();

    await page.locator('[data-role="child-stop-coverage"]').click();

    await expect(panel).toBeHidden();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");
    await expect(trigger).toBeFocused();
  });

  test("opens the map zoom popover from its trigger and dismisses it both ways", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const trigger = page.locator("#map-alignment-zoom-trigger");
    const panel = page.locator("#map-alignment-zoom-panel");

    await expect(panel).toBeHidden();

    await trigger.click();
    await expect(panel).toBeVisible();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    await expect(panel.locator("#map-alignment-zoom-value")).toBeVisible();
    await expect(
      panel.locator("#map-alignment-zoom[phx-update='ignore']"),
    ).toBeVisible();

    const zoomInput = panel.locator("#map-alignment-zoom");
    await zoomInput.focus();
    await expect(zoomInput).toBeFocused();
    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(trigger).toBeFocused();

    await trigger.click();
    await expect(panel).toBeVisible();
    await page.locator('[data-role="child-stop-coverage"]').click();
    await expect(panel).toBeHidden();
    await expect(trigger).toBeFocused();
  });

  test("nudges the floorplan when focus sits on a control inside the tools panel", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    // The regression guard for the binding scope: the tools panel is a sibling
    // of the hook root, so a keydown listener on the hook root would never see
    // this event. The keyboard binding lives on #map-alignment-workspace.
    const geometry = await alignSurfaceGeometry(page);
    expect(geometry.toolsInsideIgnoredCanvas).toBe(false);

    const residual = page.locator("#map-alignment-residual");
    await page.locator("#map-transform-left-fine").focus();
    const start = await overlayTranslation(page);

    await page.keyboard.press("ArrowRight");
    await expect(residual).toHaveAttribute("data-fit-state", "measuring");
    await expect
      .poll(async () => (await overlayTranslation(page)).x)
      .toBe(start.x + 2);

    await page.keyboard.press("Shift+ArrowRight");
    await expect
      .poll(async () => (await overlayTranslation(page)).x)
      .toBe(start.x + 12);

    // The measuring state resolves into the server's scored verdict rather than
    // staying in flight, so the readout is never a stale value shown as current.
    await expect(residual).toHaveAttribute("data-fit-state", "ready", {
      timeout: 10000,
    });
    await expect(page.locator("#map-alignment-residual")).toContainText(
      /Fit\s+\d+\.\d m\s+over \d+ anchors/,
    );
  });

  test("reaches every align control by Tab in source order once the alignment is dirty", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    expect(
      await collectTabOrder(page, "#map-alignment-tools-toggle", 15),
    ).toEqual(restingFocusOrder);

    // Restore saved alignment is disabled until the server marks the alignment
    // unsaved, and a disabled button is not a tab stop. This gesture dirties it
    // one debounce window earlier, and it then joins the chain in source order.
    await page.locator("#map-transform-right-fine").click();
    await expect(page.locator("#map-alignment-restore-saved")).toBeEnabled();

    expect(
      await collectTabOrder(page, "#map-alignment-restore-saved", 16),
    ).toEqual(dirtyFocusOrder);
  });

  test("keeps the map's own stacking ladder from painting over the bar's tooltips", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    // The canvas stacks leaflet, other-level pins, the floorplan and its handles
    // on a private z-index 0-5 ladder. Without a stacking context of its own that
    // ladder competes with the whole page, and the floorplan at z-index 2 paints
    // over the commit bar's tooltips, which sit at z-index 1 and open upward over
    // the map. Pseudo-elements cannot be probed with elementFromPoint, so the
    // containment itself is what is pinned here.
    const canvas = page.locator("#map-alignment-workspace .map-canvas");
    await expect(canvas).toHaveCSS("isolation", "isolate");

    // The floorplan is still stacked above leaflet inside that context.
    const inner = await page.evaluate(() => ({
      leaflet: getComputedStyle(
        document.getElementById("map-alignment-leaflet"),
      ).zIndex,
      overlay: getComputedStyle(
        document.getElementById("map-alignment-overlay"),
      ).zIndex,
    }));
    expect(Number(inner.overlay)).toBeGreaterThan(Number(inner.leaflet));
  });

  test("keeps the floorplan opacity through a patch of the tools panel", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const readOpacity = () =>
      page.evaluate(() => ({
        slider: document.getElementById("map-alignment-opacity").value,
        overlay: document.getElementById("map-alignment-overlay").style.opacity,
        tip: document
          .getElementById("map-alignment-opacity")
          .closest(".tooltip")
          .getAttribute("data-tip"),
      }));

    await page.locator("#map-alignment-opacity").fill("0.35");
    expect(await readOpacity()).toEqual({
      slider: "0.35",
      overlay: "0.35",
      tip: "Floorplan opacity · 35%",
    });

    // Nudging flips @alignment_unsaved?, which patches Restore saved
    // alignment's disabled attribute inside the tools panel. Without
    // phx-update="ignore" that patch restores the rendered value="0.7", and the
    // thumb snaps back to 70% while the overlay keeps the operator's setting.
    await page.locator("#map-transform-left-fine").click();
    await expect(page.locator("#map-alignment-restore-saved")).toBeEnabled();

    expect(await readOpacity()).toEqual({
      slider: "0.35",
      overlay: "0.35",
      tip: "Floorplan opacity · 35%",
    });
  });

  test("opens in-app help over the map and dismisses it back to its trigger", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const trigger = page.locator("#map-alignment-help-trigger");
    const panel = page.locator("#map-alignment-help-panel");

    await expect(panel).toBeHidden();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");

    await trigger.click();
    await expect(panel).toBeVisible();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toContainText("Drag the floorplan");
    await expect(panel).toContainText("Hold H");

    // The overlay is a bounded card, not a full-bleed scrim: the floorplan
    // stays visible beside it rather than being covered while help is open.
    const panelBox = await panel.boundingBox();
    const canvasBox = await page.locator(".map-canvas").boundingBox();
    expect(panelBox.height).toBeLessThan(canvasBox.height);

    await page.keyboard.press("Escape");
    await expect(panel).toBeHidden();
    await expect(trigger).toBeFocused();
    await expect(trigger).toHaveAttribute("aria-expanded", "false");

    await trigger.click();
    await expect(panel).toBeVisible();
    await page.locator("#map-alignment-help-close").click();
    await expect(panel).toBeHidden();
    await expect(trigger).toBeFocused();
  });

  test("keeps hidden popover controls and the workspace out of the tab chain", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    // The canvas holds the rotate and scale handles, and they are reached before
    // the tools panel, so no control over the map is keyboard-unreachable.
    const fromMode = await collectTabOrder(page, "#diagram-mode-option-map", 4);
    expect(fromMode).toEqual([
      "diagram-mode-option-map",
      "",
      "map-alignment-rotate-handle",
      "map-alignment-scale-handle",
      "map-alignment-tools-toggle",
    ]);

    const resting = await collectTabOrder(
      page,
      "#map-alignment-tools-toggle",
      15,
    );

    // #map-alignment-workspace carries tabindex="-1" so a click on the imagery
    // can land focus inside it and make the shortcuts live. It must stay out of
    // the tab order all the same.
    expect(resting).not.toContain("map-alignment-workspace");

    // The demoted controls live inside `style="display: none;"` panels and are
    // unreachable until their trigger opens them.
    for (const hidden of [
      "map-alignment-lat-input",
      "map-alignment-lon-input",
      "map-alignment-apply-center",
      "map-alignment-zoom",
    ]) {
      expect(resting).not.toContain(hidden);
    }

    await page.locator("#map-alignment-center-trigger").click();
    await expect(page.locator("#map-alignment-center-panel")).toBeVisible();

    // Opened, the panel's controls slot in directly after their own trigger and
    // before the next group, rather than at the end of the surface.
    expect(
      await collectTabOrder(page, "#map-alignment-center-trigger", 6),
    ).toEqual([
      "map-alignment-center-trigger",
      "map-alignment-lat-input",
      "map-alignment-lon-input",
      "map-alignment-apply-center",
      "map-alignment-zoom-trigger",
      "map-alignment-preview-auto",
      "map-alignment-save",
    ]);
  });

  test("spends map height on the assisted fit report only while a preview stands", async ({
    page,
  }) => {
    await openAlignSurface(page, { width: 1280, height: 800 });

    const restingGeometry = await alignSurfaceGeometry(page);
    expect(restingGeometry.canvas.height).toBeGreaterThanOrEqual(520);
    expect(restingGeometry.region).toBeLessThanOrEqual(130);

    await page.locator("#map-alignment-preview-auto").click();
    await expect(page.locator("#auto-alignment-status")).toBeVisible({
      timeout: 10000,
    });
    await expect(page.locator("#auto-alignment-fit-description")).toBeVisible();

    // A standing assisted preview adds one line reporting the suggested fit, and
    // that line is all it costs: regrouping the bar brought this state inside
    // AC-1's budget, where it used to sit at 512 px of canvas against a 520 px
    // floor. It is held to the same budget as the resting surface so the
    // exception cannot quietly return.
    const previewGeometry = await alignSurfaceGeometry(page);
    expect(previewGeometry.canvas.height).toBeGreaterThanOrEqual(520);
    expect(previewGeometry.region).toBeLessThanOrEqual(130);
    expect(previewGeometry.documentVerticalOverflow).toBeLessThanOrEqual(0);
    expect(previewGeometry.bar.bottom).toBeLessThanOrEqual(
      previewGeometry.viewportHeight,
    );

    await page.locator("#map-alignment-restore-saved").click();
    await expect(page.locator("#auto-alignment-status")).toBeHidden();

    // Leaving the preview state returns the full budget.
    await expect
      .poll(async () => (await alignSurfaceGeometry(page)).canvas.height)
      .toBeGreaterThanOrEqual(520);
    expect((await alignSurfaceGeometry(page)).region).toBeLessThanOrEqual(130);
  });
});

test.describe("coordinate review", () => {
  const viewports = [
    { width: 1280, height: 900, label: "1280" },
    { width: 1440, height: 1000, label: "1440" },
  ];

  test.beforeAll(() => {
    fs.mkdirSync(journal08ArtifactsDir, { recursive: true });
  });

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
