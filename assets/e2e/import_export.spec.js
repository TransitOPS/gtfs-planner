import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VIEWPORTS = [
  { label: "320", width: 320, height: 568 },
  { label: "375", width: 375, height: 812 },
  { label: "768", width: 768, height: 1024 },
  { label: "1024", width: 1024, height: 900 },
  { label: "wide", width: 1440, height: 1000 },
  // A 640px CSS viewport exercises the responsive layout at 200% zoom of a
  // 1280px-wide device without relying on browser-specific zoom APIs.
  { label: "200-percent", width: 640, height: 400 },
];

async function logIn(page) {
  await page.goto("/users/log_in");

  if (await page.locator('input[name="user[email]"]').count()) {
    await page.fill('input[name="user[email]"]', USER.email);
    await page.fill('input[name="user[password]"]', USER.password);
    await page.getByRole("button", { name: "Log in" }).click();
    await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
  }
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return (
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected()
    );
  });
}

async function setLiveUploadFiles(page, inputSelector, entriesSelector, file) {
  const input = page.locator(inputSelector);
  const entries = page.locator(entriesSelector);
  let lastError;

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await waitForLiveView(page);
    await expect(input).toHaveAttribute("data-phx-upload-ref", /.+/);
    await input.setInputFiles(file);

    try {
      await expect(entries).toContainText(file.name, { timeout: 5_000 });
      return;
    } catch (error) {
      lastError = error;
    }
  }

  throw lastError;
}

async function openRoute(page, route, { authenticate = true } = {}) {
  if (authenticate) await logIn(page);
  // The header's GTFS area owns Export and Import; its two pages are the bar's
  // tabs, so the journey enters through the task link and then the tab.
  await page.locator("#main-navigation #nav-gtfs").click();
  await page.waitForURL(/\/gtfs\/[^/]+\/export$/);
  await page.locator(`#gtfs-tab-${route}`).click();
  await page.waitForURL(new RegExp(`/gtfs/[^/]+/${route}$`));
  // Import shows a review in progress in place of its forms, so its page, not
  // its feed form, is what says the route has loaded.
  const ready = route === "import" ? "#import-page" : `#gtfs-${route}-form`;
  await page.locator(ready).waitFor({ state: "visible" });
  await waitForLiveView(page);
}

// Import shows one workflow at a time; choosing station changes reveals its form.
async function chooseStationChanges(page) {
  await page.locator("#import-source-station").check();
  await expect(page.locator("#diff-upload-form")).toBeVisible();
}

async function selectVersion(page, name) {
  const trigger = page.locator("#gtfs-version-trigger");
  if ((await trigger.textContent()).includes(name)) return;

  await trigger.click();
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });
  const versionId = await option.getAttribute("data-version-id");
  await Promise.all([
    page.waitForURL(new RegExp(`/gtfs/${versionId}/`), {
      waitUntil: "networkidle",
    }),
    option.click(),
  ]);
  await waitForLiveView(page);
  await expect(page.locator("#gtfs-version-trigger")).toContainText(name);
}

async function expectNoHorizontalOverflow(page) {
  expect(await bodyFitsViewport(page), "page must fit its viewport").toBe(true);
}

async function expectKeyboardAccess(page, selector, { visible = true } = {}) {
  const control = page.locator(selector);
  await control.focus();
  await expect(control).toBeFocused();
  if (visible) await expect(control).toBeVisible();
  if (!visible) await page.evaluate(() => document.activeElement?.blur());
}

async function expectMinimumTargetSize(page, selector) {
  const box = await page.locator(selector).boundingBox();
  expect(box, `${selector} must have a rendered bounding box`).not.toBeNull();
  expect(
    box.width,
    `${selector} must be at least 44px wide`,
  ).toBeGreaterThanOrEqual(44);
  expect(
    box.height,
    `${selector} must be at least 44px tall`,
  ).toBeGreaterThanOrEqual(44);
}

test.describe("durable import and export browser journeys", () => {
  test("real diff compute reconnects, applies, exports, reconnects, and downloads", async ({
    page,
  }, testInfo) => {
    test.setTimeout(120_000);
    await openRoute(page, "import");
    await selectVersion(page, "Browser E2E Version");
    const attempt = `${Date.now()}-${testInfo.retry}`;
    const resetDiff = page.locator("#diff-reset-btn");

    // A review left over from an earlier run opens on its own; start over so
    // the upload form is showing.
    if (await resetDiff.count()) {
      await resetDiff.click();
      await expect(resetDiff).toHaveCount(0);
    }

    await chooseStationChanges(page);

    await setLiveUploadFiles(
      page,
      "#diff-upload-input input",
      "#diff-upload-entries",
      {
        name: "levels.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(
          "level_id,level_index,level_name\n" +
            Array.from(
              { length: 20 },
              (_, index) =>
                `BROWSER_APPLY_${attempt}_${index},${index + 2}.0,Browser Apply Level ${attempt}-${index}\n`,
            ).join(""),
        ),
      },
    );
    await expect(page.locator("#diff-compute-btn")).toBeEnabled();
    await page.locator("#diff-compute-btn").click();
    await expect(
      page.locator("#diff-run-state, #diff-decisions").first(),
    ).toBeVisible();

    await page.context().setOffline(true);
    await page.waitForFunction(() => !window.liveSocket?.isConnected());
    await page.context().setOffline(false);
    await page.reload();
    await waitForLiveView(page);

    const firstDecision = page
      .locator("#diff-decisions [data-review-row]")
      .first();
    await expect(firstDecision).toBeVisible();
    const conflictFilter = page.locator("#diff-filter-conflict");
    const conflictCount = Number(
      (await conflictFilter.textContent()).match(/\d+/)?.[0] ?? "0",
    );
    await conflictFilter.click();

    if (conflictCount === 0) {
      await expect(page.locator("#diff-decisions-empty")).toBeVisible();
    } else {
      await expect(
        page.locator("#diff-decisions [data-review-row]").first(),
      ).toBeVisible();
    }

    await page.locator("#diff-filter-all").click();
    await expect(firstDecision).toBeVisible();
    await page
      .locator("button[phx-click='approve-all'][phx-value-action='add']")
      .click();
    await expect(page.locator("#diff-apply-btn")).toBeEnabled();
    await page.locator("#diff-apply-btn").click();
    await expect(
      page.locator("#diff-run-state[data-state='applying']"),
    ).toBeVisible();

    await page.evaluate(() => window.liveSocket.disconnect());
    await page.waitForFunction(() => !window.liveSocket?.isConnected());
    await page.reload();
    // A finished review no longer takes over the page, so completion shows as
    // the run no longer applying, whether the page reopens on its result or on
    // the feed form.
    await expect(page.locator("#import-page")).toBeVisible();
    await expect(
      page.locator("#diff-run-state[data-state='applying']"),
    ).toHaveCount(0, { timeout: 30_000 });

    await openRoute(page, "export");
    await selectVersion(page, "Browser E2E Version");
    const oldDownloadHref = await page
      .locator("#export-download-link")
      .getAttribute("href");
    await page.locator("#start-export").click();
    await expect
      .poll(() => page.locator("#export-download-link").getAttribute("href"))
      .not.toBe(oldDownloadHref);
    await page.reload();
    await expect(page.locator("#export-download-link")).toBeVisible({
      timeout: 30_000,
    });
    await expect(page.locator("#export-download-link")).not.toHaveAttribute(
      "href",
      oldDownloadHref,
    );

    const responsePromise = page.waitForResponse((response) =>
      /\/export-runs\/[^/]+\/download$/.test(new URL(response.url()).pathname),
    );
    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const [response, download] = await Promise.all([
      responsePromise,
      downloadPromise,
    ]);

    expect(response.status()).toBe(200);
    expect(await response.headerValue("content-disposition")).toMatch(
      /^attachment; filename=/,
    );
    expect(download.suggestedFilename()).toMatch(/\.zip$/);
    await expect(page.locator("[phx-hook='DownloadHook']")).toHaveCount(0);
  });

  test("check feed launches a persisted run and exposes its result and history", async ({
    page,
  }) => {
    await openRoute(page, "export");
    // openRoute ends by following the Export tab to the page it is already on,
    // so the view can still remount once after it reports connected.
    await expect(async () => {
      await expectKeyboardAccess(page, "#run-validation");
    }).toPass({ timeout: 10_000 });

    await page.locator("#run-validation").click();

    await expect(page.locator("#mobility-summary-metrics")).toBeVisible();
    await expect(page.locator("#check-verdict")).toContainText(
      "Review the 1 warning.",
    );
    await expect(page.locator("#recent-checks")).toBeVisible();

    const resultLink = page.locator("#view-validation-results");
    const resultHref = await resultLink.getAttribute("href");
    // Recent checks lists the newest run first, and it is this run.
    await expect(
      page.locator("#recent-checks a", { hasText: "Feed check" }).first(),
    ).toHaveAttribute("href", resultHref);
    await resultLink.click();
    await page.waitForURL(new RegExp("/gtfs/[^/]+/validation/[^/]+$"));
    await expect(page.locator("#validation-summary")).toBeVisible();
    await expect(
      page.getByText("No validation issues found!", { exact: true }),
    ).toBeVisible();
  });

  test("partial review retries and pending review cancels truthfully", async ({
    page,
  }) => {
    await openRoute(page, "import");
    await selectVersion(page, "Browser Partial Retry Version");
    await expect(page.locator("#diff-run-state")).toContainText(
      "Some changes need attention",
    );
    await page.locator("#diff-retry-btn").click();
    await expect(page.locator("#diff-reset-btn")).toBeVisible({
      timeout: 30_000,
    });

    await selectVersion(page, "Browser Cancel Version");
    await expect(page.locator("#diff-cancel-btn")).toBeVisible();
    await page.locator("#diff-cancel-btn").click();
    await expect(page.locator("#diff-run-state")).toContainText(
      "The review was cancelled",
    );
    await expect(page.locator("#diff-retry-btn")).toBeVisible();
  });

  test("long uploads, warnings, and diagnostics remain accessible at 320px", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 320, height: 568 });
    await openRoute(page, "import");

    const longFilename =
      "regional-transit-accessibility-update-2026-final-review.zip";
    await setLiveUploadFiles(
      page,
      "#gtfs-import-upload-input input",
      "#gtfs-import-upload-entries",
      {
        name: longFilename,
        mimeType: "application/zip",
        buffer: Buffer.from("browser upload fixture"),
      },
    );
    await expect(
      page.locator(`#gtfs-import-upload-entries [title='${longFilename}']`),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: `Remove ${longFilename}` }),
    ).toBeVisible();
    await expectNoHorizontalOverflow(page);

    await openRoute(page, "export");
    await selectVersion(page, "Catalog Routes Only Version");
    await expect(page.locator("#export-warning-panel")).toBeVisible();
    await expect(page.locator("#export-warning-panel")).toContainText(
      "browser_preflight_warning",
    );
    await expect(page.locator("#export-warning-panel")).toContainText(
      "route-reference-",
    );
    await expectNoHorizontalOverflow(page);
  });

  test("import and export stay usable across responsive and zoomed layouts", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openRoute(page, "import");
    await selectVersion(page, "Catalog Routes Only Version");

    for (const [index, viewport] of VIEWPORTS.entries()) {
      await page.setViewportSize(viewport);
      if (index > 0) await openRoute(page, "import", { authenticate: false });

      // A complete feed is chosen first; the station form waits, hidden.
      await expect(page.locator("#gtfs-import-form")).toBeVisible();
      await expect(page.locator("#diff-upload-form")).toBeHidden();
      await expect(page.locator("#gtfs-import-upload-label")).toHaveText(
        "Feed files",
      );
      await expect(page.locator("#gtfs-import-submit")).toBeDisabled();
      await expectKeyboardAccess(page, "#gtfs-import-version-name");
      await expectMinimumTargetSize(
        page,
        "#gtfs-import-upload label:has(#gtfs-import-upload-input)",
      );
      await expectNoHorizontalOverflow(page);

      await page.screenshot({
        path: `test-results/import-export-import-${viewport.label}.png`,
        fullPage: true,
      });

      await chooseStationChanges(page);
      await expect(page.locator("#gtfs-import-form")).toBeHidden();
      await expect(page.locator("#diff-upload-label")).toHaveText(
        "Station data files",
      );
      await expect(page.locator("#diff-compute-btn")).toBeDisabled();
      await expectKeyboardAccess(page, "#diff-upload-input input", {
        visible: false,
      });
      await expectMinimumTargetSize(
        page,
        "#diff-upload label:has(#diff-upload-input)",
      );
      await expectNoHorizontalOverflow(page);

      await openRoute(page, "export", { authenticate: false });
      await expect(page.locator("#gtfs-export-form")).toBeVisible();
      await expect(page.locator("#export-workspace")).toBeVisible();
      await page.locator("#export-files summary").click();
      await expect(page.locator("#export-inventory")).toBeVisible();
      await expect(page.locator("#export-download-link")).toBeVisible();
      await expectKeyboardAccess(page, "#export-type-full");
      await expectKeyboardAccess(page, "#start-export");
      await expectMinimumTargetSize(page, "#export-download-link");

      await page.locator("#export-type-pathways").check();
      await expect(page.locator("#export-type-pathways")).toBeChecked();
      await expect(page.locator("#export-type-full")).not.toBeChecked();
      await expectNoHorizontalOverflow(page);

      await page.screenshot({
        path: `test-results/import-export-export-${viewport.label}.png`,
        fullPage: true,
      });
    }
  });

  test("ready export reconnects and downloads through an attachment response", async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openRoute(page, "export");
    await selectVersion(page, "Catalog Routes Only Version");
    const downloadLink = page.locator("#export-download-link");

    await expect(downloadLink).toBeVisible();
    await expect(downloadLink).toHaveAttribute(
      "href",
      /\/export-runs\/[^/]+\/download$/,
    );
    await page.reload();
    await expect(downloadLink).toBeVisible();

    const responsePromise = page.waitForResponse((response) =>
      /\/export-runs\/[^/]+\/download$/.test(new URL(response.url()).pathname),
    );
    const downloadPromise = page.waitForEvent("download");
    await downloadLink.click();
    const [response, download] = await Promise.all([
      responsePromise,
      downloadPromise,
    ]);

    expect(response.status()).toBe(200);
    expect(await response.headerValue("content-type")).toMatch(
      /^application\/zip(?:;|$)/,
    );
    expect(await response.headerValue("content-disposition")).toMatch(
      /^attachment; filename=/,
    );
    expect(await download.suggestedFilename()).toBe(
      "browser-current-export.zip",
    );
    await expect(page.locator("[phx-hook='DownloadHook']")).toHaveCount(0);
    expect(await page.content()).not.toContain("data:application/zip;base64,");
  });
});
