import { test, expect } from "@playwright/test";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Feed-quality helper journeys for the Validation Result and Export pages (step 10).
 *
 * The fixture is the Browser Feed Quality Version seeded by
 * `test/support/browser_seed.exs`: one completed MobilityData report stored as a
 * historical wrapper whose own length is 1 while the embedded upstream total is
 * 170 with three retained WARNING samples. The scripted stand-in
 * (`test/support/agents/browser_open_router.ex`) asks about the same run
 * through `GtfsPlanner.Agents.BrowserFeedQuality`, so a card that drifted from
 * the stored report fails here.
 *
 * Only the model HTTP boundary is scripted; the page, the panel, the facade,
 * the session, the turn loop, the registered pack and the Evidence reads are
 * the shipped ones.
 */

const __dirname = dirname(fileURLToPath(import.meta.url));
const EVIDENCE_DIR = resolve(
  __dirname,
  "../../.specs/ai-03-validation-and-export/evidence/ev-10",
);

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Feed Quality Version";
const RUN_ID = "f1f1f1f1-0000-4000-8000-000000000001";

const VIEWPORTS = [
  { label: "desktop", width: 1440, height: 1000 },
  { label: "mobile", width: 320, height: 800 },
];

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"), {
    timeout: 60_000,
  });
}

/**
 * The panel's Open helper button posts a LiveView event, which is lost before
 * the socket connects. Wait for the connection, click, and allow one retry for
 * a slow first paint.
 */
async function waitForLiveView(page) {
  // The socket can report connected before the page's own view has joined, and
  // an event clicked in that window is lost. Wait for the mounted root and let
  // the join settle before any interaction.
  await page.waitForFunction(
    () =>
      window.liveSocket &&
      window.liveSocket.isConnected() &&
      document.querySelector("[data-phx-main]"),
    null,
    { timeout: 15_000 },
  );
  await page.waitForTimeout(250);
}

/** Navigates and waits for the LiveView socket, so the first click is live. */
async function openPage(page, url) {
  await page.goto(url);
  await waitForLiveView(page);
}

async function versionIdFor(page, versionName = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

async function openHelper(page, { keyboard = false } = {}) {
  const button = page.locator("#agent-helper-open");
  await expect(button).toBeVisible();
  await waitForLiveView(page);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    if (keyboard && attempt === 0) {
      await button.focus();
      await page.keyboard.press("Enter");
    } else {
      await button.click();
    }

    try {
      await expect(page.locator("#agent-panel")).toBeVisible({ timeout: 10_000 });
      return;
    } catch (error) {
      if (attempt === 1) throw error;
    }
  }
}

async function ask(page, message) {
  await page.locator("#agent-composer-input").fill(message);
  await page.locator("#agent-send").click();
}

async function capture(page, name) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const target = resolve(EVIDENCE_DIR, `${name}.png`);
  await page.screenshot({ path: target, fullPage: false, animations: "disabled" });
  return target;
}

test.describe("the Validation Result helper", () => {
  for (const viewport of VIEWPORTS) {
    test(`keeps 170 stored findings with 3 retained samples at ${viewport.width}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await logIn(page);
      const versionId = await versionIdFor(page);

      await openPage(page, `/gtfs/${versionId}/validation/${RUN_ID}`);
      await expect(page.locator("#feed-quality-evidence")).toBeVisible();

      // The stored total and the retained samples are the report's own numbers,
      // and the unmapped samples stay visible as evidence.
      await expect(page.locator("#feed-quality-samples")).toContainText("170");
      await expect(page.locator("#feed-quality-samples")).toContainText("3");
      await expect(page.locator("#feed-quality-unmapped")).toBeVisible();
      await expect(page.locator("#feed-quality-provenance")).toBeVisible();

      // Keyboard opening is the journey's entry: focus the button and press Enter.
      await openHelper(page, { keyboard: true });
      await ask(page, "What did the last check find?");

      await expect(
        page.locator("#agent-entry-2 [data-evidence-kind='validation_findings']"),
      ).toBeVisible({ timeout: 15_000 });

      const card = page.locator("#agent-evidence-2-1");
      await expect(card).toContainText("170");
      await expect(card).toContainText("gtfs_feed_quality");

      // The helper's prose cannot replace the server's count.
      await expect(page.locator("#agent-prose-2")).toContainText("stored total is 170");

      // The native Inspect target is the only approval a finding can get.
      if (viewport.width >= 1024) {
        // The workspace stays visible beside the open panel.
        await page.locator("#feed-quality-inspect-0").click();
        await expect(page.locator("#agent-notice")).toContainText("approved for navigation");
      } else {
        // At phone width the open panel replaces the workspace: close it,
        // approve the target, then reopen. The approval resets the panel's
        // source, so the old transcript cannot reappear.
        await page.locator("#agent-panel-close").click();
        await page.locator("#feed-quality-inspect-0").click();
        await openHelper(page);
        await expect(page.locator("#agent-entry-2")).toHaveCount(0);
      }

      const capturePath = await capture(page, `validation-${viewport.label}`);
      await testInfo.attach(`validation-${viewport.label}`, {
        path: capturePath,
        contentType: "image/png",
      });
    });
  }
});

test.describe("the Export helper", () => {
  for (const viewport of VIEWPORTS) {
    test(`Review options selects the prepared type at ${viewport.width}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await logIn(page);
      const versionId = await versionIdFor(page);

      await openPage(page, `/gtfs/${versionId}/export`);
      await expect(page.locator("#feed-quality-evidence")).toBeVisible();

      // No artifact exists for this seed, so the section states the domain's
      // honest unavailable relationship before the helper is asked.
      await expect(page.locator("#feed-quality-relationship")).toContainText(
        "This export selection is not available.",
      );

      await openHelper(page);
      await ask(page, "Prepare the Pathways export for me.");

      await expect(page.locator("#agent-prepared-2")).toBeVisible({ timeout: 15_000 });
      await expect(page.locator("#agent-review-prepared-2")).toContainText("Review options");

      await page.locator("#agent-review-prepared-2").click();

      // The page's own native patch owns the selected type.
      await expect(page).toHaveURL(new RegExp(`type=pathways`));
      await expect(page.locator("#export-type-pathways")).toBeChecked();

      const capturePath = await capture(page, `export-${viewport.label}`);
      await testInfo.attach(`export-${viewport.label}`, {
        path: capturePath,
        contentType: "image/png",
      });
    });
  }

  test("a provider failure and a stale source keep the native form", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await logIn(page);
    const versionId = await versionIdFor(page);

    await openPage(page, `/gtfs/${versionId}/export`);
    await openHelper(page);
    await ask(page, "Is the provider reachable?");

    // The failure is announced with Retry, and the native export form is intact.
    await expect(page.getByRole("button", { name: "Retry request" })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.locator("#gtfs-export-form")).toBeVisible();

    // A source refresh (native type change) is a fresh page load: the
    // provider-independent section stays, the panel starts closed, and the
    // conversation that answered about the old source cannot reappear.
    await openPage(page, `/gtfs/${versionId}/export?type=operations`);
    await expect(page.locator("#feed-quality-evidence")).toBeVisible();
    await openHelper(page);
    await expect(page.locator("#agent-entry-2")).toHaveCount(0);

    const capturePath = await capture(page, "stale-source-desktop");
    expect(readFileSync(capturePath).length).toBeGreaterThan(0);
  });
});
