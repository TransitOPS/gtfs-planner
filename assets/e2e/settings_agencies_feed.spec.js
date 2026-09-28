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

async function capture(page, testInfo, name) {
  await page.screenshot({ path: testInfo.outputPath(`${name}.png`) });

  mkdirSync(CAPTURE_DIR, { recursive: true });
  await page.screenshot({ path: resolve(CAPTURE_DIR, `${name}.png`) });
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

        // The drawer that creates the row arrives in a later step, so no action
        // is offered yet.
        await expect(page.locator("#feed-details-empty button")).toHaveCount(0);

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
