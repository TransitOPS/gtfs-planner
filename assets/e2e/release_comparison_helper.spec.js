import { test, expect } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";
import { logInAs } from "./browser_helpers.js";

/**
 * Release comparison journeys on the Export page (step 13).
 *
 * The fixture is the retained exports `ReleaseComparisonFixtures.seed_browser!/2`
 * publishes through the real export storage, each on a version named for what
 * the journey compares. Every expected number is counted by hand over Wed
 * 2026-11-25 and Thu 2026-11-26:
 *
 *   Fall service as exported -> Fall service revised
 *     R1 runs 2 trips on the 25th and 1 on the 26th (trip T2 moves to a service
 *     a calendar exception removes on the 26th): one trip lost. R2 and trip U1
 *     are renamed R2X and U1X with every other field equal: churn, not loss.
 *     Two stops named "Twin" in the candidate leave the earlier one with two
 *     candidates: three unresolved stop matches, so the comparison is incomplete.
 *   Frequency check earlier -> revised: the one trip becomes a non-exact window.
 *   Unchanged service A -> B: identical files.
 *   Large network A -> B: 60 routes, more rows than the helper can hold.
 *   Expiring export: an ordinary file the journey expires itself.
 *
 * Only the OpenRouter HTTP boundary is scripted (it answers from the tool
 * results, never from a fixed sentence about these files). The page, the native
 * coordinator, the storage, the snapshot seam, the panel, the session, the turn
 * and the pack are the shipped ones, and the journey starts at the login form.
 *
 * Captures are written when RELEASE_COMPARISON_CAPTURE_DIR names a directory.
 */

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const HOST_VERSION = "Browser Comparison Host";
const FROM = "2026-11-25";
const TO = "2026-11-26";

const FALL = {
  left: "Fall service as exported",
  right: "Fall service revised",
};
const FREQUENCY = {
  left: "Frequency check earlier",
  right: "Frequency check revised",
};
const UNCHANGED = { left: "Unchanged service A", right: "Unchanged service B" };
const LARGE = { left: "Large network A", right: "Large network B" };
const EXPIRING = "Expiring export";

const VIEWPORTS = [
  { label: "1440", width: 1440, height: 1000 },
  { label: "320", width: 320, height: 800 },
];

const LOSS_QUESTION = "Did we lose any service between these two files?";
const LOSS_ANSWER =
  "R1 lost 1 trip on Thu Nov 26, 2026, from 2 to 1. " +
  "R2 was only renamed R2X: same service under a new identifier, so that is not a loss. " +
  "The comparison is incomplete, so this is not a clean answer.";

const CAPTURE_DIR = process.env.RELEASE_COMPARISON_CAPTURE_DIR;

async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

/** Signs in through the login form and opens the Export page of the host version. */
async function openExport(page, viewport) {
  await page.setViewportSize({
    width: viewport.width,
    height: viewport.height,
  });
  await logInAs(page, EDITOR_USER);
  const versionId = await versionIdFor(page, HOST_VERSION);
  await page.goto(`/gtfs/${versionId}/compare`);
  await page.waitForSelector("[data-phx-main].phx-connected");
  await expect(page.locator("#compare-page")).toBeVisible();
  await expect(page.locator("#export-comparison-form")).toBeVisible();
  return versionId;
}

/** The option of a run selector named for `label`, by what the chooser really lists. */
async function optionValue(page, side, label) {
  const option = page
    .locator(`#comparison-${side} option`)
    .filter({ hasText: label });
  await expect(option).toHaveCount(1);
  return option.getAttribute("value");
}

/** The four values the editor chose, as the form holds them. */
async function chosenValues(page) {
  return page.evaluate(() => {
    const selected = (id) => document.getElementById(id)?.value ?? "";
    return [
      selected("comparison-left"),
      selected("comparison-right"),
      selected("comparison-from"),
      selected("comparison-to"),
    ];
  });
}

/**
 * Chooses both files and the dates through the native form. Each edit re-renders
 * the form, so the whole selection is asserted until one read-back holds all four.
 */
async function chooseFiles(page, pair, window = { from: FROM, to: TO }) {
  const [left, right] = await Promise.all([
    optionValue(page, "left", pair.left),
    optionValue(page, "right", pair.right),
  ]);

  await expect(async () => {
    await page.locator("#comparison-left").selectOption(left);
    await page.locator("#comparison-right").selectOption(right);
    await page.locator("#comparison-from").fill(window.from);
    await page.locator("#comparison-to").fill(window.to);
    expect(await chosenValues(page)).toEqual([
      left,
      right,
      window.from,
      window.to,
    ]);
  }).toPass({ timeout: 20_000 });

  return [left, right, window.from, window.to];
}

/** Starts the comparison with the keyboard-reachable button and waits for the band. */
async function compare(page, pair) {
  await chooseFiles(page, pair);
  await page.locator("#comparison-start").click();

  // Starting moves focus to the status title, so a keyboard reader lands on the state.
  await expect(page.locator("#comparison-status-title")).toBeFocused();

  await expect(page.locator("#comparison-status-title")).toHaveText(
    "Comparison finished",
    {
      timeout: 60_000,
    },
  );
  await expect(page.locator("#comparison-results")).toBeVisible();
}

function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

async function openHelper(page) {
  await page.locator("#comparison-helper-open").focus();
  await page.keyboard.press("Enter");

  await expect(page.locator("#agent-panel")).toBeVisible();
  await expect(page.locator("#agent-composer-input")).toBeVisible();

  // Opening the panel moves focus into the composer, so the question can be
  // typed without reaching for the mouse.
  await expect.poll(() => focusedId(page)).toBe("agent-composer-input");

  // The same person on the same comparison shares one conversation, so an
  // earlier journey's transcript may still be there. Every journey starts its own.
  await page.locator("#agent-new-conversation").focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#agent-first-conversation")).toBeVisible();
  await expect(page.locator("#agent-entries article")).toHaveCount(0);
  await expect.poll(() => focusedId(page)).toBe("agent-composer-input");
}

/** Types into the focused composer and sends with the keyboard shortcut. */
async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-composer-input").press("Control+Enter");
}

/** The document and the panel fit the viewport. */
async function fitsWidth(page) {
  return page.evaluate(() => {
    const page = document.querySelector("#compare-page");
    const panel = document.querySelector("#agent-panel");
    return (
      page.scrollWidth <= page.clientWidth + 1 &&
      (panel === null || panel.scrollWidth <= panel.clientWidth + 1)
    );
  });
}

/** One element at its own size, for a card too tall for the panel's scroll area. */
async function captureElement(locator, name, viewport) {
  if (!CAPTURE_DIR) return;

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await locator.screenshot({
    path: resolve(CAPTURE_DIR, `${name}-${viewport.label}.png`),
  });
}

async function capture(page, name, viewport, region = null) {
  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    await page.screenshot({
      path: resolve(CAPTURE_DIR, `${name}-${viewport.label}.png`),
      fullPage: true,
    });

    // The page is long, so the region the state is about is captured at its own
    // size as well, which is the one that can be read at 320px.
    if (region) {
      await page.locator(region).screenshot({
        path: resolve(CAPTURE_DIR, `${name}-region-${viewport.label}.png`),
      });
    }
  }

  await exportCapture(page, name, viewport);
}

// The export-UX capture surface this package's step 16 owns. Nothing is written
// unless EXPORT_UX_CAPTURE_DIR names a directory.
const EXPORT_UX_CAPTURE_DIR = process.env.EXPORT_UX_CAPTURE_DIR;

async function exportCapture(page, name, viewport) {
  if (!EXPORT_UX_CAPTURE_DIR) return;

  mkdirSync(EXPORT_UX_CAPTURE_DIR, { recursive: true });
  await page.screenshot({
    path: resolve(EXPORT_UX_CAPTURE_DIR, `${name}-${viewport.label}.png`),
    fullPage: true,
  });
}

/**
 * Expires one seeded retained export in the journey's own throwaway database, so
 * the page has listed a file that is no longer retained when the comparison
 * starts. The write is refused unless the target is a loopback test database.
 */
function expireRetainedExport(versionName) {
  const databaseUrl = process.env.GTFS_PLANNER_TEST_DATABASE_URL;
  if (!databaseUrl)
    throw new Error("The browser stack did not name its test database.");

  const parsed = new URL(databaseUrl);
  const database = decodeURIComponent(parsed.pathname.slice(1));
  const loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].includes(
    parsed.hostname,
  );

  if (
    !loopback ||
    !(database === "test" || database.startsWith("gtfs_planner_exunit"))
  ) {
    throw new Error(
      "Refusing to expire a retained export outside a loopback test database.",
    );
  }
  if (!/^[A-Za-z0-9 ]+$/.test(versionName))
    throw new Error("Unexpected version name.");

  const updated = execFileSync(
    "psql",
    [
      "-X",
      "--no-psqlrc",
      "-v",
      "ON_ERROR_STOP=1",
      "--tuples-only",
      "--no-align",
      "--dbname",
      databaseUrl,
      "-c",
      `UPDATE gtfs_export_runs SET artifact_expires_at = now() - interval '1 hour' ` +
        `WHERE version_name = '${versionName}' AND state = 'ready'`,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 10_000 },
  );

  return updated;
}

test.describe("loss and churn, and what could not be compared (A35)", () => {
  for (const viewport of VIEWPORTS) {
    test(`separates a lost trip from a renamed route at ${viewport.width}x${viewport.height}`, async ({
      page,
    }) => {
      test.setTimeout(120_000);

      await openExport(page, viewport);

      // Nothing to ask about before a comparison, and the native export controls are live.
      await expect(page.locator("#comparison-helper-open")).toHaveCount(0);
      await expect(page.locator("#export-helper-mode")).toHaveCount(0);
      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect(page.locator("#comparison-start")).toBeEnabled();

      await compare(page, FALL);

      // The native result: hand-counted (2+1+1+1) - (2+2+1+1) = -1 on both counts.
      await expect(page.locator("#comparison-scheduled-delta")).toHaveText(
        "-1",
      );
      await expect(page.locator("#comparison-exact-delta")).toHaveText("-1");
      await expect(page.locator("#comparison-rows")).toContainText("R1 → R1");
      await expect(page.locator("#comparison-rows")).toContainText(
        "Trip count changed",
      );
      await expect(page.locator("#comparison-rows")).toContainText("trips -1");
      await expect(page.locator("#comparison-structural")).toContainText(
        "Renamed route",
      );
      await expect(page.locator("#comparison-structural")).toContainText(
        "Renamed trip",
      );
      await expect(page.locator("#comparison-structural")).toContainText(
        "Same identifier, but its service dates changed between the two files.",
      );
      await expect(page.locator("#comparison-structural")).not.toContainText(
        "new in the candidate file",
      );
      await expect(
        page.locator("#comparison-unresolved-rows > div"),
      ).toHaveCount(3);
      await expect(page.locator("#comparison-completeness")).toContainText(
        "Incomplete for this window",
      );

      // The helper is offered beside the finished result and never opened for the person.
      await expect(page.locator("#comparison-helper-entry")).toContainText(
        "Ask about this comparison",
      );
      await expect(page.locator("#comparison-helper-open")).toHaveAttribute(
        "aria-expanded",
        "false",
      );
      await expect(page.locator("#agent-panel")).toHaveCount(0);
      expect(await fitsWidth(page)).toBe(true);
      await capture(
        page,
        "comparison-ready",
        viewport,
        "#comparison-helper-entry",
      );

      await openHelper(page);
      await ask(page, LOSS_QUESTION);

      // The answer is stated from what the tools returned: the loss and the rename.
      await expect(page.locator("#agent-prose-2")).toContainText(LOSS_ANSWER, {
        timeout: 30_000,
      });

      // The cards are the server's own numbers, and the prose sits beside them.
      const summary = page.locator("#agent-evidence-2-1");
      await expect(summary).toHaveAttribute(
        "data-evidence-kind",
        "export_comparison",
      );
      await expect(summary).toHaveAttribute(
        "data-evidence-completeness",
        "incomplete",
      );
      await expect(summary).toContainText("Exact departures");
      await expect(summary).toContainText("-1");
      await expect(summary).toContainText("4 of 4");

      const differences = page.locator("#agent-evidence-2-2");
      await expect(differences).toHaveAttribute(
        "data-evidence-kind",
        "export_comparison_differences",
      );
      await expect(differences).toContainText("4 differences");

      // The one resource is this comparison, linked to this Export page only.
      const versionId = await versionIdFor(page, HOST_VERSION);
      await expect(summary.locator("a")).toHaveCount(1);
      await expect(summary.locator("a")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/export`,
      );
      await expect(
        page.locator("#agent-entries a[href*='/routes/']"),
      ).toHaveCount(0);

      expect(await fitsWidth(page)).toBe(true);
      // The transcript is pinned to the newest message, so the evidence card the
      // answer rests on is scrolled back into the capture.
      await summary.scrollIntoViewIfNeeded();
      await capture(page, "helper-answer", viewport, "#agent-panel");
      await captureElement(summary, "helper-evidence-card", viewport);

      // A second question reads the unresolved matches and claims no loss for them.
      await ask(page, "Which stops look alike?");
      await expect(page.locator("#agent-prose-4")).toContainText(
        "3 stop matches are unresolved",
        {
          timeout: 30_000,
        },
      );
      await expect(page.locator("#agent-evidence-4-1")).toHaveAttribute(
        "data-evidence-kind",
        "export_comparison_unresolved",
      );

      // The helper changed nothing on the page behind it.
      await expect(page.locator("#comparison-exact-delta")).toHaveText("-1");
      await expect(page.locator("#comparison-start")).toBeEnabled();

      // The keyboard closes the panel and returns to the page's Open helper button.
      await page.locator("#agent-panel-close").focus();
      await page.keyboard.press("Enter");
      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect.poll(() => focusedId(page)).toBe("agent-helper-open");
      await expect(page.locator("#comparison-results")).toBeVisible();
    });
  }

  test("a total the comparison could not measure is never given as a number", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const viewport = VIEWPORTS[0];

    await openExport(page, viewport);
    await compare(page, FREQUENCY);

    // The candidate's trip is a non-exact window, so no departure total can be proven.
    await expect(page.locator("#comparison-totals-unknown")).toContainText(
      "was not measured",
    );
    await expect(page.locator("#comparison-total-reasons")).toContainText(
      "frequency windows rather than exact departures",
    );
    await expect(page.locator("#comparison-exact-delta")).toHaveCount(0);
    await expect(page.locator("#comparison-completeness")).toContainText(
      "Incomplete for this window",
    );
    await expect(page.locator("#comparison-rows")).toContainText(
      "Frequency changed",
    );
    await capture(page, "unknown-frequency", viewport);

    await openHelper(page);
    await ask(page, "What is the total change in departures?");

    await expect(page.locator("#agent-prose-2")).toContainText(
      "I can't give a total change in departures: it was not measured. " +
        "A route states frequency windows rather than exact departures. " +
        "The candidate file has rows that could not be read.",
      { timeout: 30_000 },
    );

    const card = page.locator("#agent-evidence-2-1");
    await expect(card).toHaveAttribute(
      "data-evidence-completeness",
      "incomplete",
    );
    await expect(card).toContainText("not measured");
    await expect(card).not.toContainText("no change");
    await card.scrollIntoViewIfNeeded();
    await capture(page, "unknown-frequency-helper", viewport, "#agent-panel");
  });

  test("two identical files are a complete comparison with nothing to report", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const viewport = VIEWPORTS[0];

    await openExport(page, viewport);
    await compare(page, UNCHANGED);

    // A complete comparison with nothing to report is its own state card, not
    // the result card with empty sections.
    await expect(page.locator("#comparison-nochange")).toContainText(
      "No differences",
    );
    await expect(page.locator("#comparison-nochange")).toContainText(
      "Riders get the same service",
    );
    await expect(page.locator("#comparison-result")).toHaveCount(0);
    await capture(page, "no-difference", viewport);

    await openHelper(page);
    await ask(page, "Did anything change between these files?");

    await expect(page.locator("#agent-prose-2")).toContainText(
      "Nothing changed in service, and the comparison is complete.",
      { timeout: 30_000 },
    );
    await expect(page.locator("#agent-evidence-2-1")).toHaveAttribute(
      "data-evidence-completeness",
      "complete",
    );
  });

  test("an expired baseline is refused, the drafts stay, and the page keeps working", async ({
    page,
  }) => {
    test.setTimeout(120_000);
    const viewport = VIEWPORTS[0];

    await openExport(page, viewport);

    // The page lists the file while it is retained, then the retention ends.
    const chosen = await chooseFiles(page, {
      left: EXPIRING,
      right: FALL.right,
    });
    expireRetainedExport(EXPIRING);

    await page.locator("#comparison-start").click();

    await expect(page.locator("#comparison-status-title")).toHaveText(
      "The comparison couldn’t finish",
      { timeout: 30_000 },
    );
    await expect(page.locator("#comparison-notice")).toHaveText(
      "Those exports aren’t available to compare.",
    );

    // Nothing was compared, so no result and no helper exist, and no zero was invented.
    await expect(page.locator("#comparison-results")).toHaveCount(0);
    await expect(page.locator("#comparison-helper-open")).toHaveCount(0);
    await expect(page.locator("#comparison-exact-delta")).toHaveCount(0);

    // The editor's choices and the native export controls are untouched.
    expect(await chosenValues(page)).toEqual(chosen);
    await expect(page.locator("#comparison-start")).toBeEnabled();
    await expect(page.locator("#comparison-close")).toBeVisible();
    await capture(page, "expired-baseline", viewport);

    // A retained pair still compares on the same page.
    await page.locator("#comparison-close").click();
    await compare(page, UNCHANGED);
    await expect(page.locator("#comparison-nochange")).toContainText(
      "No differences",
    );
  });
});

test.describe("helper limits, failure and replacement", () => {
  for (const viewport of VIEWPORTS) {
    test(`a comparison too large for the helper keeps the native result at ${viewport.width}x${viewport.height}`, async ({
      page,
    }) => {
      test.setTimeout(120_000);

      await openExport(page, viewport);
      await compare(page, LARGE);

      // The helper is refused and says why; the comparison is not.
      const notice = page.locator("#comparison-helper-notice");
      await expect(notice).toContainText("more rows than the helper can hold");
      await expect(notice).toHaveAttribute("role", "status");
      await expect(page.locator("#comparison-helper-open")).toHaveCount(0);
      await expect(page.locator("#agent-panel")).toHaveCount(0);

      await expect(page.locator("#comparison-nochange")).toContainText(
        "No differences",
      );
      await expect(page.locator("#comparison-scope-form")).toBeVisible();
      expect(await fitsWidth(page)).toBe(true);
      await capture(
        page,
        "scope-refusal",
        viewport,
        "#comparison-helper-entry",
      );

      // The way out is the explicit scope form, reachable by keyboard.
      await page.locator("#comparison-helper-narrow").focus();
      await page.keyboard.press("Enter");
      await expect.poll(() => focusedId(page)).toBe("comparison-scope-routes");

      await page
        .locator("#comparison-scope-routes")
        .selectOption(["M001/M001"]);
      await page.locator("#comparison-scope-dates").selectOption([FROM]);
      await page.locator("#comparison-share-scope").click();

      await expect(page.locator("#comparison-scope-applied")).toBeVisible();
      await expect(page.locator("#comparison-helper-notice")).toHaveCount(0);
      await expect(page.locator("#comparison-helper-open")).toBeVisible();

      await openHelper(page);
      await expect(page.locator("#agent-panel")).toContainText(
        "narrowed comparison",
      );

      await ask(page, LOSS_QUESTION);
      await expect(page.locator("#agent-prose-2")).toContainText(
        "No service loss was found.",
        {
          timeout: 30_000,
        },
      );

      // The narrowed card counts only the selection, never the whole comparison.
      const summary = page.locator("#agent-evidence-2-1");
      await expect(summary).toContainText("1 of 1");
      await expect(summary).toContainText("no change");
      expect(await fitsWidth(page)).toBe(true);
      await summary.scrollIntoViewIfNeeded();
      await capture(page, "scope-narrowed", viewport, "#agent-panel");
      await captureElement(summary, "scope-narrowed-evidence-card", viewport);
    });

    test(`a provider failure and a replaced selection keep the native controls at ${viewport.width}x${viewport.height}`, async ({
      page,
    }) => {
      test.setTimeout(120_000);

      await openExport(page, viewport);
      const chosen = await chooseFiles(page, FALL);
      await page.locator("#comparison-start").click();
      await expect(page.locator("#comparison-status-title")).toHaveText(
        "Comparison finished",
        {
          timeout: 60_000,
        },
      );

      await openHelper(page);
      await ask(page, "Is the provider reachable?");

      // A real provider failure: the entry fails, Retry is offered, no card claims a count.
      await expect(page.locator("#agent-retry-2")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.locator("#agent-panel")).toContainText("Unavailable");
      await expect(
        page.locator("#agent-panel [data-evidence-kind]"),
      ).toHaveCount(0);

      // The native result, the chosen files and every export control are untouched.
      // Below the desktop breakpoint the open panel stands in for the page (the
      // Export layout for every helper), so the result is attached there and
      // visible again once the panel closes.
      await expect(page.locator("#comparison-exact-delta")).toHaveText("-1");
      await expect(page.locator("#comparison-results")).toBeAttached();
      await expect(page.locator("#comparison-start")).toBeEnabled();
      expect(await chosenValues(page)).toEqual(chosen);
      expect(await fitsWidth(page)).toBe(true);
      await capture(page, "provider-failure", viewport, "#agent-panel");

      // Retry stays available and changes nothing behind the panel.
      await page.locator("#agent-retry-2").click();
      await expect(page.locator("#agent-retry-2")).toBeVisible({
        timeout: 30_000,
      });
      await expect(page.locator("#comparison-exact-delta")).toHaveText("-1");

      // Closing the panel keeps the result, and reopening reaches the same conversation.
      await page.locator("#agent-panel-close").click();
      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect.poll(() => focusedId(page)).toBe("agent-helper-open");
      await expect(page.locator("#comparison-results")).toBeVisible();

      await page.locator("#agent-helper-open").click();
      await expect(page.locator("#agent-panel")).toBeVisible();
      await expect(page.locator("#agent-retry-2")).toBeVisible();

      // Choosing other files replaces the context: the helper and the result go,
      // while the editor's new choice stays on the form and the export controls
      // work. A phone shows the panel instead of the form, so it closes first.
      if (viewport.width < 1024) {
        await page.locator("#agent-panel-close").click();
        await expect(page.locator("#agent-panel")).toHaveCount(0);
      }
      const other = await optionValue(page, "right", UNCHANGED.right);
      await page.locator("#comparison-right").selectOption(other);

      await expect(page.locator("#agent-panel")).toHaveCount(0);
      await expect(page.locator("#comparison-helper-open")).toHaveCount(0);
      await expect(page.locator("#export-helper-mode")).toHaveCount(0);
      await expect(page.locator("#comparison-results")).toHaveCount(0);
      expect((await chosenValues(page))[1]).toBe(other);
      await expect(page.locator("#comparison-start")).toBeEnabled();
    });
  }
});
