// Settings › Feed details browser journey (EV-4, EV-5; step 6).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The journey is read-only: it opens the page's summary
// and empty states at both required viewports and captures them.
//
// Later steps add their own tagged blocks (`@feed-editor`, `@feed-drafts`,
// `@agencies`) to this file, so the shared helpers live at the top.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport } from "./browser_helpers";

// The Playwright runner starts in `assets/`, so repository-relative paths are
// resolved from the checkout root the way `playwright.config.js` does.
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The two versions `test/support/browser_seed.exs` gives this page its states.
const SUMMARY_VERSION = "Browser Feed Details Version";
const EMPTY_VERSION = "Browser Feed Empty Version";

const DESKTOP = { width: 1280, height: 800 };
const MOBILE = { width: 375, height: 812 };
const VIEWPORTS = [
  { file: "1280", width: DESKTOP.width, height: DESKTOP.height },
  { file: "375", width: MOBILE.width, height: MOBILE.height },
];

// The feature's evidence folder, next to the checkout root. `.specs/` is
// gitignored, so a local run leaves reviewable images behind and CI never
// depends on them.
const CAPTURE_DIR =
  process.env.FEED_DETAILS_CAPTURE_DIR ||
  resolve(REPO_ROOT, ".specs/13-agencies-and-feed-details/evidence/visual/feed-page");

// The drawer block's own evidence folder (EV-7).
const EDITOR_CAPTURE_DIR =
  process.env.FEED_EDITOR_CAPTURE_DIR ||
  resolve(REPO_ROOT, ".specs/13-agencies-and-feed-details/evidence/visual/feed-editor");

// ── shared helpers ─────────────────────────────────────────────────────────

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published versions, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
async function versionId(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const id = await option.getAttribute("data-version-id");
  if (!id) throw new Error(`${name} is missing its version ID`);
  return id;
}

// A click that lands before the LiveView joins is dropped, so an action waits
// for the mounted view first.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected(),
    );
  });
}

async function captureIn(page, testInfo, captureDir, name) {
  await page.screenshot({ path: testInfo.outputPath(`${name}.png`) });

  mkdirSync(captureDir, { recursive: true });
  await page.screenshot({ path: resolve(captureDir, `${name}.png`) });
}

async function capture(page, testInfo, name) {
  await captureIn(page, testInfo, CAPTURE_DIR, name);
}

// One definition-list row's label and value, in the order the page renders them.
async function details(dl) {
  const labels = await dl.locator("dt").allInnerTexts();
  const values = await dl.locator("dd").allInnerTexts();

  return labels.map((label, index) => [label, values[index]]);
}

test.describe("@feed-page", () => {
  for (const viewport of VIEWPORTS) {
    test.describe(`Feed details at ${viewport.width}x${viewport.height}`, () => {
      test.use({ viewport: { width: viewport.width, height: viewport.height } });

      test("shows the stored summary without horizontal scroll", async ({
        page,
      }, testInfo) => {
        await logIn(page);
        await waitForLiveView(page);

        const feedDetailsId = await versionId(page, SUMMARY_VERSION);
        await page.goto(`/gtfs/${feedDetailsId}/settings/feed-details`);
        await page.waitForSelector("#feed-details-summary");
        await waitForLiveView(page);

        // The page is the Feed details page, not a placeholder or an error page.
        await expect(page.locator("h1")).toHaveText("Feed details");
        await expect(page.locator("h1 + p")).toHaveText(
          "Publisher information for this version—not the contact details riders use.",
        );
        await expect(
          page.locator("#settings-nav a[aria-current='page']"),
        ).toHaveText("Feed details");
        await expect(page.locator("#coming-soon-status")).toHaveCount(0);
        await expect(page.locator("#feed-details-empty")).toHaveCount(0);

        await expect(
          page.locator("#feed-details-publisher h2"),
        ).toHaveText("Publisher");
        await expect(page.locator("#feed-details-publisher")).toContainText(
          "Details set",
        );
        await expect(page.locator("#feed-details-validity h2")).toHaveText(
          "Validity and version",
        );
        await expect(page.locator("#feed-details-contact h2")).toHaveText(
          "Technical contact",
        );

        expect(await details(page.locator("#feed-details-publisher dl"))).toEqual(
          [
            ["Name", "Browser Regional Partnership"],
            ["Website", "https://example.test/data"],
            ["Feed language", "English (en)"],
            ["Default language", "English (en)"],
          ],
        );

        expect(await details(page.locator("#feed-details-validity dl"))).toEqual(
          [
            ["Valid from", "Sep 1, 2026"],
            ["Valid through", "Dec 31, 2026"],
            ["Feed version", "2026-autumn"],
          ],
        );

        expect(await details(page.locator("#feed-details-contact dl"))).toEqual(
          [
            ["Email", "data@example.test"],
            ["Website", "https://example.test/data/contact"],
          ],
        );

        // The prototype's aside notes, in order.
        await expect(page.locator("#feed-details-summary aside h2")).toHaveText(
          ["One feed, one publisher", "For data consumers"],
        );
        await expect(
          page.locator("#feed-details-summary aside"),
        ).toContainText(
          "These details are included when this version is exported. Saving does not publish the feed.",
        );
        await expect(
          page.locator("#feed-details-manage-agencies"),
        ).toHaveAttribute("href", `/gtfs/${feedDetailsId}/settings/agencies`);

        expect(await bodyFitsViewport(page)).toBe(true);

        await capture(page, testInfo, `feed-summary-${viewport.file}`);
      });

      test("shows the first-use empty state without horizontal scroll", async ({
        page,
      }, testInfo) => {
        await logIn(page);
        await waitForLiveView(page);

        const emptyId = await versionId(page, EMPTY_VERSION);
        await page.goto(`/gtfs/${emptyId}/settings/feed-details`);
        await page.waitForSelector("#feed-details-empty");
        await waitForLiveView(page);

        await expect(page.locator("h1")).toHaveText("Feed details");
        await expect(page.locator("h1 + p")).toHaveText(
          "Tell journey planners who publishes this dataset and when its information is valid.",
        );
        await expect(page.locator("#feed-details-empty")).toContainText(
          "Introduce your feed",
        );
        await expect(page.locator("#feed-details-empty")).toContainText(
          "Add the publisher, website, and language. Dates and technical contacts help others use your data with confidence.",
        );
        await expect(page.locator("#feed-details-summary")).toHaveCount(0);
        await expect(page.locator("#coming-soon-status")).toHaveCount(0);

        // Step 7's drawer adds the opener to this state.
        await expect(page.locator("#feed-details-set")).toHaveText(
          "Set feed details",
        );

        expect(await bodyFitsViewport(page)).toBe(true);

        await capture(page, testInfo, `feed-empty-${viewport.file}`);
      });
    });
  }

  test("the Settings overview lists Feed details as Available", async ({
    page,
  }) => {
    await logIn(page);
    await waitForLiveView(page);

    const feedDetailsId = await versionId(page, SUMMARY_VERSION);
    await page.goto(`/gtfs/${feedDetailsId}/settings`);
    await page.waitForSelector("#settings-overview");

    const entry = page.locator("#settings-entry-feed_details");

    await expect(entry.locator("a")).toHaveText("Feed details");
    await expect(entry.locator("a")).toHaveAttribute(
      "href",
      `/gtfs/${feedDetailsId}/settings/feed-details`,
    );
    await expect(entry).toContainText("Available");
    await expect(entry).not.toContainText("Coming soon");
  });
});

// Settings › Feed details drawer (EV-7; step 7).
//
// One journey on the version this block owns: open the creating drawer, capture
// it at both required widths, save a value the editor changeset refuses, correct
// it, and save again into the summary. The drawer stays open through the failed
// save, so the second capture shows the corrected drawer rather than a saved
// page.
test.describe("@feed-editor", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("sets feed details, corrects a URL error, saves, and captures the drawer", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const emptyId = await versionId(page, EMPTY_VERSION);
    await page.goto(`/gtfs/${emptyId}/settings/feed-details`);
    await page.waitForSelector("#feed-details-empty");
    await waitForLiveView(page);

    await page.click("#feed-details-set");

    const overlay = page.locator("#feed-details-drawer-overlay");
    const drawer = page.locator("#feed-details-drawer");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#feed-details-drawer-title")).toHaveText(
      "Set feed details",
    );
    await expect(drawer).toContainText(
      "Describe the publisher and validity of this entire dataset. Optional fields are marked.",
    );
    await expect(drawer.locator("legend")).toHaveText([
      "Publisher",
      "Validity and version",
      "Technical contact",
    ]);
    await expect(page.locator("#feed-details-use-date-label")).toHaveText(
      "Use date label",
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, EDITOR_CAPTURE_DIR, "feed-drawer-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    expect(await bodyFitsViewport(page)).toBe(true);
    await expect(
      page.locator("#feed-details-form button[type='submit']"),
    ).toBeVisible();
    await captureIn(page, testInfo, EDITOR_CAPTURE_DIR, "feed-drawer-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // A field the editor has not touched stays quiet while the touched one
    // reports itself: the client marks untouched inputs as unused.
    await page.fill("#feed_info_feed_publisher_url", "www.example.com");
    await expect(page.locator("#feed_info_feed_publisher_url-error")).toContainText(
      "must be a full web address",
    );
    await expect(page.locator("#feed_info_feed_publisher_name-error")).toHaveCount(0);
    await expect(page.locator("#feed-details-form-error")).toHaveCount(0);

    await page.fill("#feed_info_feed_publisher_name", "Browser Regional Partnership");
    await page.selectOption("#feed_info_feed_lang", "en");
    await page.locator("#feed-details-form button[type='submit']").click();

    // The refused value marks its own field and writes nothing.
    await expect(page.locator("#feed_info_feed_publisher_url-error")).toContainText(
      "must be a full web address",
    );
    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#feed-details-form-error")).toContainText(
      "Nothing was saved. Check the highlighted fields.",
    );

    await page.fill("#feed_info_feed_publisher_url", "https://example.test/data");
    await page.locator("#feed-details-form button[type='submit']").click();

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#feed-details-summary")).toBeVisible();
    await expect(page.locator("#feed-details-publisher dl")).toContainText(
      "Browser Regional Partnership",
    );
    await expect(page.locator("#flash-info")).toContainText(
      "Feed details saved.",
    );
    await expect(page.locator("#feed-details-edit")).toBeVisible();
  });
});
