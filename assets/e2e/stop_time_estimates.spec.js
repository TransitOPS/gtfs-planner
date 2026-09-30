import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Stop-time interpolation journey (spec 23, step 16).
 *
 * One Playwright journey across the four surfaces that share the
 * `StopTimeEstimator` core: Running times fills staged estimates between
 * timepoints, Export defaults decides what exported files carry, Export
 * names the handling with counts, and Schedules previews the export
 * estimates read-only. Records come from `test/support/browser_seed.exs`:
 *
 *   BROWSER_INTERP_FILL — five stops with coordinates, a "Weekday" timing
 *     and a linked trip. The Running times journey adds its own blank
 *     timing per viewport, times its first and last stops, and fills the
 *     middle.
 *   BROWSER_INTERP_IMPORT — the same five stops with an imported custom
 *     trip (BROWSER_INTERP_C1) whose middle stop times are blank, so Export
 *     defaults, Export and Schedules all have gaps to estimate.
 *
 * Both routes live in the backdated "Browser Interp Version", so no other
 * spec's counts move. Export defaults are organization-wide: the journey
 * toggles "Leave them blank", saves, then toggles back and saves, leaving
 * the estimate-on default in place.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Interp Version";
const FILL_ROUTE = "BROWSER_INTERP_FILL";
const FILL_PATTERN = "BROWSER-INTERP-FILL";
const IMPORT_ROUTE = "BROWSER_INTERP_IMPORT";
const IMPORT_PATTERN = "BROWSER-INTERP-IMPORT";

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "390x844", width: 390, height: 844 },
];

const CAPTURE_DIR = process.env.INTERP23_CAPTURES;

// Viewport captures for transient dialogs, full-page captures for task
// surfaces: a fixed dialog is laid out against the viewport, so a full-page
// capture would composite it over unrelated page content.
async function capture(page, name, { fullPage = true } = {}) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });

  if (!fullPage) {
    await page.waitForTimeout(300);
    await page.screenshot({
      path: resolve(CAPTURE_DIR, `${name}.png`),
      fullPage: false,
      animations: "disabled",
    });
    return;
  }

  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`), fullPage });
}

// An already authenticated session is redirected away from the login page, so
// the form is only filled when it is actually rendered.
async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function collectPageErrors(page) {
  const problems = [];
  const tileFailures = [];
  page.on("pageerror", (error) => problems.push(`pageerror: ${error.message}`));
  page.on("response", (response) => {
    if (response.status() < 400) return;
    const path = new URL(response.url()).pathname;
    // Street tiles come from the Geoapify proxy, which answers 500 without
    // an API key (CI and isolated runs included). The maps degrade to their
    // vectors, so tile failures ride along separately instead of failing the
    // gate; anything else the server refuses is a real problem.
    if (path.startsWith("/map/tiles/")) {
      tileFailures.push(`${response.status()} ${path}`);
    } else {
      problems.push(`response: ${response.status()} ${path}`);
    }
  });
  page.on("console", (message) => {
    if (message.type() === "error") problems.push(`console: ${message.text()}`);
  });
  return { problems, tileFailures };
}

// Waits for the LiveView root to report itself connected, so an interaction is
// never clicked into a server-rendered page that has not been hydrated yet.
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

let versionId;
let collector;

test.beforeEach(async ({ page }) => {
  collector = collectPageErrors(page);
  await logIn(page);
  versionId = await versionIdFor(page, VERSION_NAME);
});

test.afterEach(() => {
  const resourceErrors = (collector.problems ?? []).filter((problem) =>
    problem.startsWith("console: Failed to load resource"),
  );
  const other = (collector.problems ?? []).filter(
    (problem) => !problem.startsWith("console: Failed to load resource"),
  );
  expect(other, "browser reported errors").toEqual([]);
  // Every failed resource load must be covered by an observed tile-proxy
  // failure above; anything else (a missing bundle, a refused endpoint) is
  // unattributed and fails the journey.
  expect(
    resourceErrors.length,
    `unattributed resource errors (tiles failed: ${collector.tileFailures.length})`,
  ).toBeLessThanOrEqual(collector.tileFailures.length);
});

for (const viewport of VIEWPORTS) {
  test(`running times fill stages, fills and saves estimates at ${viewport.label}`, async ({
    page,
  }) => {
    test.setTimeout(180_000);
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    const timingName = `Fill journey ${viewport.label}`;

    await page.goto(
      `/gtfs/${versionId}/routes/${FILL_ROUTE}/patterns/${FILL_PATTERN}?task=timings`,
    );
    await page.waitForSelector("#pattern-editor-content", { timeout: 15000 });
    await waitForLiveView(page);

    // A new timing starts blank: every row reads zero with no timepoints, so
    // the journey times the anchors and clears the middle itself.
    await page.locator("#timing-add").click();
    await expect(page.locator('#timing-dialog[data-open="true"]')).toBeVisible();
    await page.fill("#timing-name", timingName);
    await page.locator("#timing-dialog-confirm").click();
    await expect(page.locator('#timing-dialog[data-open="true"]')).toBeHidden();
    await expect(page.locator("#status")).toContainText("Timing added.");
    await page.selectOption("#timing-select", { label: `${timingName} · 0 trips` });
    await expect(page.locator("#timing-arrival-1")).toHaveValue("00:00");

    // Time the first and last stops and clear the middle: rows 2-4 are the
    // non-timepoint gaps the fill estimates.
    await page.locator("#timing-timepoint-1").check();
    await page.locator("#timing-timepoint-5").check();
    await page.fill("#timing-arrival-1", "00:00");
    await page.fill("#timing-departure-1", "00:00");
    await page.fill("#timing-arrival-5", "10:00");
    await page.fill("#timing-departure-5", "10:00");

    for (const position of [2, 3, 4]) {
      await page.locator(`#timing-timepoint-${position}`).uncheck();
      await page.fill(`#timing-arrival-${position}`, "");
      await page.fill(`#timing-departure-${position}`, "");
    }

    await expect(page.locator("#timing-blank-note")).toBeVisible();

    // Fill opens the preview panel; applying stages three estimates.
    await page.locator("#timing-fill").click();
    await expect(page.locator("#fill-panel")).toBeVisible();
    await expect(page.locator("#fill-summary")).toBeVisible();
    await expect(page.locator("#fill-apply")).toContainText("Fill 3 stops");
    await capture(page, `interp-fill-panel-${viewport.label}`);
    await page.locator("#fill-apply").click();
    await expect(page.locator("#fill-panel")).toBeHidden();

    const filled = [];
    for (const position of [2, 3, 4]) {
      const arrival = page.locator(`#timing-arrival-${position}`);
      const departure = page.locator(`#timing-departure-${position}`);
      await expect(arrival).not.toHaveValue("");
      await expect(departure).not.toHaveValue("");
      await expect(page.locator(`#timing-row-${position}`)).toContainText("Estimated");
      filled.push([await arrival.inputValue(), await departure.inputValue()]);
    }

    // Saving persists the staged estimates through the normal timing save;
    // the new timing has no trips, so no review dialog stands in the way.
    await page.locator("#timing-save").click();
    await expect(page.locator("#status")).toContainText("Changes saved in this version.");

    for (const [index, position] of [2, 3, 4].entries()) {
      await expect(page.locator(`#timing-arrival-${position}`)).toHaveValue(filled[index][0]);
      await expect(page.locator(`#timing-departure-${position}`)).toHaveValue(filled[index][1]);
    }

    await capture(page, `interp-running-times-${viewport.label}`);
    expect(await bodyFitsViewport(page), "running times overflows").toBe(true);
  });

  test(`export defaults explain and persist the estimate choice at ${viewport.label}`, async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    await page.goto(`/gtfs/${versionId}/settings/export-defaults`);
    await waitForLiveView(page);
    await expect(page.locator("#estimate-missing-times-estimate")).toBeChecked();

    // The impact block counts this version's gaps once the async summary
    // lands: one imported trip with blanks, estimated along the straight
    // line between its stops.
    await expect(page.locator("#missing-impact-loading")).toBeHidden({ timeout: 20000 });
    await expect(page.locator("#export-defaults-impact")).toContainText(
      `In ${VERSION_NAME}`,
    );
    await expect(page.locator("#missing-impact-routes")).toContainText(
      "IX · Browser Interp Imported",
    );
    await expect(page.locator("#missing-impact-routes")).toContainText(
      "Straight line, no path",
    );
    await expect(page.locator("#missing-times-consequence")).toHaveCount(0);
    await capture(page, `interp-export-defaults-${viewport.label}`);

    // Leaving the times blank names its consequence before anything saves.
    await page.locator("#estimate-missing-times-blank").check();
    await expect(page.locator("#missing-times-consequence")).toContainText(
      "leaves 4 times blank",
    );
    await page.locator('#export-defaults-form button[type="submit"]').click();
    await expect(page.getByText("Export defaults saved.")).toBeVisible();
    await expect(page.locator("#missing-times-consequence")).toHaveCount(0);
    await expect(page.locator("#export-defaults-impact")).toContainText(
      "leaves",
    );

    // Toggling back restores the estimate-on default the journey started
    // from, so the shared organization row is unchanged when it leaves.
    await page.locator("#estimate-missing-times-estimate").check();
    await expect(page.locator("#missing-times-consequence")).toContainText("estimates");
    await page.locator('#export-defaults-form button[type="submit"]').click();
    await expect(page.getByText("Export defaults saved.")).toBeVisible();
    await expect(page.locator("#estimate-missing-times-estimate")).toBeChecked();
    await expect(page.locator("#missing-times-consequence")).toHaveCount(0);

    expect(await bodyFitsViewport(page), "export defaults overflows").toBe(true);
  });

  test(`export names the missing-times handling with counts at ${viewport.label}`, async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    await page.goto(`/gtfs/${versionId}/export`);
    await waitForLiveView(page);
    await expect(page.locator("#export-missing-times-loading")).toBeHidden({ timeout: 20000 });
    await expect(page.locator("#export-missing-times")).toContainText(
      "Missing stop times: estimated.",
    );
    await expect(page.locator("#export-missing-times")).toContainText("1 trip");

    await capture(page, `interp-export-${viewport.label}`);
    expect(await bodyFitsViewport(page), "export overflows").toBe(true);
  });

  test(`schedules preview the imported trip's estimates at ${viewport.label}`, async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    await page.goto(`/gtfs/${versionId}/routes/${IMPORT_ROUTE}/schedules?stops=all`);
    await waitForLiveView(page);

    // The imported trip's blank middle stops render in italics with the
    // estimate title; nothing is saved into the trip.
    const estimated = page.locator('span.italic[title^="Estimated when exported:"]');
    await expect(estimated.first()).toBeVisible();
    await expect(estimated).toHaveCount(2);
    await expect(page.locator(`#section-${IMPORT_PATTERN}-estimate-note`)).toContainText(
      "italics",
    );

    await capture(page, `interp-schedules-${viewport.label}`);
    expect(await bodyFitsViewport(page), "schedules overflows").toBe(true);
  });
}
