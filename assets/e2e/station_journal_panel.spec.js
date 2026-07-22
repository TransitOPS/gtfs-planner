import { test, expect } from "@playwright/test";
import { mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

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
