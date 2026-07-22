import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loginAndGoToDiagram } from "./station_diagram_helpers.js";

const here = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(here, "../..");
const referenceRoot = resolve(repositoryRoot, ".specs/journal-02/visual-references");
const artifactRoot = resolve(repositoryRoot, ".artifacts/journal-02");

test.use({ viewport: { width: 1440, height: 900 } });

test("renders copied journal references", async ({ page }) => {
  await mkdir(artifactRoot, { recursive: true });

  await page.goto(
    pathToFileURL(resolve(referenceRoot, "mock-03-floorplans-journal-open.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const journalHeading = page.getByRole("heading", { name: "Journal", exact: true }).first();
  const idealRegion = journalHeading.locator(
    'xpath=ancestor::div[contains(@class, "w-[1360px]")][1]',
  );

  await expect(journalHeading).toBeVisible();
  await expect(page.getByRole("button", { name: /Journal/ })).toHaveAttribute(
    "aria-expanded",
    "true",
  );
  await expect(idealRegion.locator('aside[aria-label="Station journal"]')).toBeVisible();
  await idealRegion.screenshot({ path: resolve(artifactRoot, "reference-ideal.png") });

  await page.goto(
    pathToFileURL(resolve(referenceRoot, "mock-04-journal-panel-states.html")).href,
    { waitUntil: "networkidle" },
  );
  await page.evaluate(() => document.fonts.ready);

  const statesRegion = page.getByText("1 · LOADING", { exact: false }).locator(
    'xpath=ancestor::div[contains(@class, "grid-cols-4")][1]',
  );

  await expect(page.getByText("1 · LOADING", { exact: false })).toBeVisible();
  await expect(page.getByText("2 · FIRST-USE EMPTY", { exact: false })).toBeVisible();
  await expect(page.getByText("3 · FILTERED EMPTY", { exact: false })).toBeVisible();
  await expect(page.getByText("4 · ERROR", { exact: false })).toBeVisible();
  await statesRegion.screenshot({ path: resolve(artifactRoot, "reference-states.png") });
});

test("renders production first-use journal panel", async ({ page }) => {
  await mkdir(artifactRoot, { recursive: true });
  await page.emulateMedia({ reducedMotion: "reduce" });
  await loginAndGoToDiagram(page);

  const workspace = page.locator("#diagram-workspace");
  const canvas = page.locator("#diagram-canvas-wrapper");
  const trigger = page.locator("#journal-trigger");

  await expect(trigger).toBeVisible();
  await expect(trigger).toHaveAttribute("aria-expanded", "false");
  await expect(page.locator("#scale-control + #journal-trigger")).toBeVisible();

  const closedCanvasWidth = await canvas.evaluate(
    (element) => element.getBoundingClientRect().width,
  );

  await trigger.click();

  const panel = page.locator("#station-journal-panel");
  await expect(panel).toBeVisible();
  await expect(trigger).toHaveAttribute("aria-expanded", "true");
  await expect(panel.locator("#journal-empty-first-use")).toBeVisible();
  await expect(panel.locator("#journal-filter")).toHaveCount(0);
  await expect(
    workspace.locator(":scope > #station-journal-panel + #diagram-canvas-wrapper"),
  ).toBeVisible();

  const layout = await page.evaluate(() => {
    const panel = document.querySelector("#station-journal-panel");
    const canvas = document.querySelector("#diagram-canvas-wrapper");
    const workspace = document.querySelector("#diagram-workspace");
    const panelStyle = getComputedStyle(panel);

    return {
      panelWidth: panel.getBoundingClientRect().width,
      canvasWidth: canvas.getBoundingClientRect().width,
      panelPosition: panelStyle.position,
      panelTransitionDuration: panelStyle.transitionDuration,
      workspaceOverflow: getComputedStyle(workspace).overflow,
      documentOverflow:
        document.documentElement.scrollWidth - document.documentElement.clientWidth,
    };
  });

  expect(layout.panelWidth).toBe(340);
  expect(layout.canvasWidth).toBeLessThan(closedCanvasWidth - 300);
  expect(["static", "relative"]).toContain(layout.panelPosition);
  expect(layout.panelTransitionDuration).toBe("0s");
  expect(layout.workspaceOverflow).toBe("hidden");
  expect(layout.documentOverflow).toBeLessThanOrEqual(1);
  await expect(page.locator("#floorplan-workspace [data-journal-scrim]")).toHaveCount(0);

  await page.evaluate(() => window.scrollTo(0, 0));
  await expect(page.locator("#app-header")).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  await expect(page.locator("svg[id^='diagram-canvas-']")).toBeVisible();
  await page.screenshot({
    path: resolve(artifactRoot, "production-empty.png"),
    animations: "disabled",
  });
});
