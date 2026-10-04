import { test, expect } from "@playwright/test";
import { logInAs } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Rider text and stop review helpers (AI-02): the Headsign helper on the pattern
 * page and the two stop helpers on the stops pages.
 *
 * Every case runs the ordinary routes through the normal login against the
 * seeded browser database (`test/support/browser_seed.exs`). Only the provider
 * HTTP boundary is scripted, through `GtfsPlanner.Agents.BrowserOpenRouter`; the
 * page, the panel, the session, the packs and the native editors are the shipped
 * ones. Captures land in the canonical spec evidence folder; override with
 * `AI02_CAPTURE_DIR`.
 *
 * The `headsigns panel` case is read-only on BROWSER-HS1.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const CAPTURE_DIR =
  process.env.AI02_CAPTURE_DIR ||
  "/Users/ryanmahoney/Documents/gtfs-planner/.specs/ai-02-rider-text-and-stop-review/evidence/screenshots";

const DESKTOP = { width: 1440, height: 1000 };
const PHONE = { width: 390, height: 844 };

async function capture(page, folder, name) {
  const dir = resolve(CAPTURE_DIR, folder);
  mkdirSync(dir, { recursive: true });
  await page.screenshot({ path: resolve(dir, `${name}.png`), fullPage: true });
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });

  await page.waitForFunction(
    () => {
      const main = document.querySelector("[data-phx-main]");
      return (
        Boolean(main) &&
        main.classList.contains("phx-connected") &&
        window.liveSocket?.isConnected()
      );
    },
    { timeout: 20000 },
  );
}

async function versionIdFor(page, versionName = "Browser E2E Version") {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

/** The element the browser currently has focus on, by its DOM id. */
function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

/** The document fits the viewport: nothing makes the page scroll sideways. */
function fitsViewport(page) {
  return page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );
}

async function openPattern(page, versionId, routeId, patternId, task) {
  await page.goto(
    `/gtfs/${versionId}/routes/${routeId}/patterns/${patternId}?task=${task}`,
  );
  await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
  await waitForLiveView(page);
}

let versionId;

test.beforeEach(async ({ page }) => {
  await logInAs(page, EDITOR_USER);
  versionId = await versionIdFor(page);
});

test("headsigns panel", async ({ page }) => {
  test.setTimeout(90_000);

  for (const [label, viewport] of [
    ["1440", DESKTOP],
    ["390", PHONE],
  ]) {
    await page.setViewportSize(viewport);
    await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "details");

    // The native Details form is live and the helper is offered, closed.
    await expect(page.locator("#pattern-details-form")).toBeVisible();
    await expect(page.locator("#pattern-details-headsign")).toBeEnabled();
    const open = page.locator("#agent-helper-open");
    await expect(open).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator("#agent-panel")).toHaveCount(0);
    expect(await fitsViewport(page)).toBe(true);
    await capture(page, "headsigns-panel", `closed-${label}`);

    // Opening the panel moves focus to the composer and shows first-use copy.
    await open.click();
    const panel = page.locator("#agent-panel");
    await expect(panel).toBeVisible();
    await expect(open).toHaveAttribute("aria-expanded", "true");
    await expect(panel).toContainText("Headsign helper");
    await expect(panel).toContainText("Pattern Browser Headsign One · Details");
    await expect(panel.locator("#agent-example-1")).toBeVisible();
    await expect(panel.locator("#agent-example-2")).toBeVisible();
    expect(await focusedId(page)).toBe("agent-composer-input");
    expect(await fitsViewport(page)).toBe(true);

    // The native form is still usable with the panel open.
    await expect(page.locator("#pattern-details-headsign")).toBeEnabled();
    await capture(page, "headsigns-panel", `open-${label}`);

    // Closing returns focus to the button that opened it.
    await page.locator("#agent-panel-close").click();
    await expect(panel).toHaveCount(0);
    expect(await focusedId(page)).toBe("agent-helper-open");
  }

  // The helper is offered on Running times with a timing, not on Stops.
  await page.setViewportSize(DESKTOP);
  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "timings");
  await expect(page.locator("#agent-helper-open")).toBeVisible();

  await openPattern(page, versionId, "BROWSER_HEADSIGNS", "BROWSER-HS1", "stops");
  await expect(page.locator("#agent-helper-open")).toHaveCount(0);
});
