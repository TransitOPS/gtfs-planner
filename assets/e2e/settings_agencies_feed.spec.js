// Settings › Feed details browser journey (EV-4, EV-5; step 6).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The journey is read-only: it opens the page's summary
// and empty states at both required viewports and captures them.
//
// Later steps add their own tagged blocks (`@feed-editor`, `@feed-drafts`,
// `@agencies-list`) to this file, so the shared helpers live at the top.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport, readPendingStates, watchPendingState } from "./browser_helpers";

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

// The unsaved-draft block's own evidence folder (EV-9).
const DRAFT_CAPTURE_DIR =
  process.env.FEED_DRAFTS_CAPTURE_DIR ||
  resolve(REPO_ROOT, ".specs/13-agencies-and-feed-details/evidence/visual/feed-drafts");

// The two versions `test/support/browser_seed.exs` gives the Agencies list its
// states: three agencies that share a timezone, and two that disagree.
const AGENCIES_VERSION = "Browser Agencies Version";
const MIXED_TIMEZONE_VERSION = "Browser Mixed Timezone Version";

// The Agencies list block's own evidence folder (EV-17).
const AGENCIES_CAPTURE_DIR =
  process.env.AGENCIES_CAPTURE_DIR ||
  resolve(REPO_ROOT, ".specs/13-agencies-and-feed-details/evidence/visual/agencies-list");

// The version timezone drawer block's own evidence folder (EV-19).
const TIMEZONE_CAPTURE_DIR =
  process.env.AGENCIES_TIMEZONE_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/agencies-timezone",
  );

// The version `browser_seed.exs` creates with neither agencies nor routes, so
// the create block starts from the empty state (EV-20, EV-21).
const NO_AGENCY_VERSION = "Browser No Agency Version";

// The create drawer block's own evidence folder (EV-21).
const CREATE_CAPTURE_DIR =
  process.env.AGENCIES_CREATE_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/agencies-create",
  );

// The edit drawer block's own evidence folder (EV-23).
const EDIT_CAPTURE_DIR =
  process.env.AGENCIES_EDIT_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/agencies-edit",
  );

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
// for the mounted view first. `liveSocket.main` is the view bound to this page,
// and its `isConnected()` is the channel's `canPush()`: true only once the view
// has joined, unlike the socket's own flag, which is true before that.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.main?.isConnected?.(),
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

// Settings › Feed details unsaved drafts (EV-9; step 8).
//
// One journey on the version this block owns. It changes one field, then asks
// the three questions AC-6 answers in a real browser: does the drawer say the
// draft is unsaved, does Escape on that draft ask before discarding rather than
// closing, and does a reload raise the browser's own leave-page prompt. Nothing
// is ever saved, so the seeded row stays as prepared: the journey ends by
// discarding and reading the stored value back.
test.describe("@feed-drafts", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("shows the unsaved state, asks before discarding and warns on reload", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const summaryId = await versionId(page, SUMMARY_VERSION);
    await page.goto(`/gtfs/${summaryId}/settings/feed-details`);
    await page.waitForSelector("#feed-details-summary");
    await waitForLiveView(page);

    await page.click("#feed-details-edit");

    const overlay = page.locator("#feed-details-drawer-overlay");
    const discard = page.locator("#feed-details-discard");
    const guard = page.locator("#feed-details-unsaved-guard");
    const publisherName = page.locator("#feed_info_feed_publisher_name");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#feed-details-unsaved")).toHaveCount(0);
    await expect(guard).toHaveAttribute("data-dirty", "false");

    await publisherName.fill("Browser Regional Partnership draft");

    // The draft is named in the drawer header and armed in the hidden hook.
    await expect(page.locator("#feed-details-unsaved")).toHaveText(
      "Unsaved changes",
    );
    await expect(guard).toHaveAttribute("data-dirty", "true");
    await expect(page.locator("#feed-details-drawer-close")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DRAFT_CAPTURE_DIR, "feed-draft-1280");

    // Escape reaches the drawer's dismiss control through OverlayDialog, which
    // sends the close event that asks about the draft.
    await page.keyboard.press("Escape");

    await expect(discard).toBeVisible();
    await expect(discard).toHaveAttribute("role", "alertdialog");
    await expect(page.locator("#feed-details-discard-title")).toHaveText(
      "Discard unsaved changes?",
    );
    await expect(page.locator("#feed-details-discard-body")).toHaveText(
      "Your edits will be lost. The saved details stay unchanged.",
    );
    await expect(page.locator("#feed-details-discard-cancel")).toHaveText(
      "Keep editing",
    );
    await expect(page.locator("#feed-details-discard-confirm")).toHaveText(
      "Discard changes",
    );
    await expect(page.locator("#feed-details-discard-cancel")).toBeFocused();
    // The question is the topmost surface: the drawer stays behind it.
    await expect(overlay).toHaveAttribute("data-open", "true");
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DRAFT_CAPTURE_DIR, "feed-draft-discard-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    // The phone drawer keeps its own close control and its own dirty label, and
    // the question stays inside the 375 layout viewport (AC-30).
    await expect(page.locator("#feed-details-unsaved")).toBeVisible();
    await expect(page.locator("#feed-details-drawer-close")).toBeVisible();
    await expect(page.locator("#feed-details-discard-cancel")).toBeVisible();
    await expect(page.locator("#feed-details-discard-confirm")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DRAFT_CAPTURE_DIR, "feed-draft-discard-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // Keep editing keeps the draft, and the drawer still knows it is dirty.
    await page.click("#feed-details-discard-cancel");

    await expect(discard).toHaveCount(0);
    await expect(publisherName).toHaveValue("Browser Regional Partnership draft");
    await expect(guard).toHaveAttribute("data-dirty", "true");

    // A reload with a changed draft raises the browser's leave-page prompt. The
    // prompt is browser chrome, so it is asserted through the dialog event
    // rather than captured. Dismissing it cancels the navigation, which leaves
    // the editor and the draft in place.
    const dialogPromise = page.waitForEvent("dialog");
    // Dismissing the prompt cancels the navigation, so Playwright's reload never
    // finishes: the short timeout keeps this journey from waiting the default
    // 30 s for a navigation that is deliberately not happening.
    const reload = page.reload({ timeout: 5_000 }).catch(() => undefined);
    const leaveDialog = await dialogPromise;

    expect(leaveDialog.type()).toBe("beforeunload");
    await leaveDialog.dismiss();
    await reload;

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(publisherName).toHaveValue("Browser Regional Partnership draft");

    // Discarding is the only way out of the draft, and it writes nothing: the
    // summary shows the stored publisher name again.
    await page.click("#feed-details-drawer-close");

    await expect(discard).toBeVisible();
    await page.click("#feed-details-discard-confirm");

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#feed-details-unsaved")).toHaveCount(0);
    await expect(guard).toHaveAttribute("data-dirty", "false");
    await expect(page.locator("#feed-details-summary")).toBeVisible();
    await expect(page.locator("#feed-details-publisher dl")).toContainText(
      "Browser Regional Partnership",
    );
    await expect(page.locator("#feed-details-publisher dl")).not.toContainText(
      "draft",
    );
  });
});

// Settings › Agencies list (EV-16, EV-17; step 15).
//
// The list page the Settings › Agencies tab now opens instead of its Coming soon
// placeholder. Read-only journeys over the two versions the seed gives this block:
// "Browser Agencies Version" (Harbor Shuttle 2, North Coast Transit 5, Riverside
// Community Transport 0 routes, all America/New_York) and "Browser Mixed Timezone
// Version" (America/New_York and America/Chicago). Captures land in this block's
// own evidence folder as `agencies-1280.png`, `agencies-375.png` and
// `agencies-mixed-1280.png`.
test.describe("@agencies-list", () => {
  for (const viewport of VIEWPORTS) {
    test.describe(`Agencies at ${viewport.width}x${viewport.height}`, () => {
      test.use({ viewport: { width: viewport.width, height: viewport.height } });

      test("lists the agencies, hosts, zones and route counts", async ({
        page,
      }, testInfo) => {
        await logIn(page);
        await waitForLiveView(page);

        const agenciesId = await versionId(page, AGENCIES_VERSION);
        await page.goto(`/gtfs/${agenciesId}/settings/agencies`);
        await page.waitForSelector("#agencies");
        await waitForLiveView(page);

        // The literal route wins over the section route, so this is the list page.
        await expect(page.locator("h1")).toHaveText("Agencies");
        await expect(page.locator("h1 + p")).toHaveText(
          "Manage the public identity and contact details of your transit providers.",
        );
        await expect(
          page.locator("#settings-nav a[aria-current='page']"),
        ).toHaveText("Agencies");
        await expect(page.locator("#coming-soon-status")).toHaveCount(0);
        await expect(page.locator("#agencies-empty")).toHaveCount(0);

        const rows = page.locator("#agencies tr");
        await expect(rows).toHaveCount(3);

        const cells = await rows.evaluateAll((elements) =>
          elements.map((row) =>
            Array.from(row.querySelectorAll("td")).map((cell) =>
              cell.innerText.replace(/\s+/g, " ").trim(),
            ),
          ),
        );

        expect(cells.map((row) => row[0])).toEqual([
          "Harbor Shuttle harbor.example",
          "North Coast Transit northcoast.example",
          "Riverside Community Transport riverside.example",
        ]);
        expect(cells.map((row) => row[1])).toEqual([
          "America/New_York",
          "America/New_York",
          "America/New_York",
        ]);
        expect(cells.map((row) => row[2])).toEqual(["2 →", "5 →", "0 →"]);

        // One timezone for the version, so no callout and no row needs review.
        await expect(page.locator("#agencies-timezone-band")).toContainText(
          "One timezone for this version",
        );
        await expect(page.locator("#agencies-timezone-band")).toContainText(
          "America/New_York · Used by all agencies and their schedules.",
        );
        await expect(page.locator("#agencies-timezone-callout")).toHaveCount(0);

        await expect(
          page.getByRole("link", { name: "View 5 routes for North Coast Transit" }),
        ).toHaveAttribute("href", `/gtfs/${agenciesId}/routes?agency_id=NCT`);

        expect(await bodyFitsViewport(page)).toBe(true);

        await captureIn(
          page,
          testInfo,
          AGENCIES_CAPTURE_DIR,
          `agencies-${viewport.file}`,
        );
      });
    });
  }

  test.describe("sorting and count links", () => {
    test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

    test("sorts by route count and follows a count link to the filtered list", async ({
      page,
    }) => {
      await logIn(page);
      await waitForLiveView(page);

      const agenciesId = await versionId(page, AGENCIES_VERSION);
      await page.goto(`/gtfs/${agenciesId}/settings/agencies`);
      await page.waitForSelector("#agencies");
      await waitForLiveView(page);

      const routesHeader = page
        .locator("#agencies-container thead th")
        .nth(2);
      const firstRow = page.locator("#agencies tr").first();

      await expect(routesHeader).toHaveAttribute("aria-sort", "none");

      await routesHeader.getByRole("button").click();
      await expect(routesHeader).toHaveAttribute("aria-sort", "ascending");
      await expect(firstRow).toContainText("Riverside Community Transport");

      await routesHeader.getByRole("button").click();
      await expect(routesHeader).toHaveAttribute("aria-sort", "descending");
      await expect(firstRow).toContainText("North Coast Transit");

      await page
        .getByRole("link", { name: "View 5 routes for North Coast Transit" })
        .click();
      await page.waitForURL(new RegExp(`/gtfs/${agenciesId}/routes\\?agency_id=NCT$`));
      await waitForLiveView(page);

      // The link really filters: only the five North Coast Transit routes remain.
      await expect(page.locator("#routes tr")).toHaveCount(5);
      await expect(
        page.locator("#routes tr td[data-label='Route ID']").first(),
      ).toContainText("NCT_");
    });
  });

  test.describe("mixed timezones", () => {
    test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

    test("names the disagreement, flags the rows and captures the state", async ({
      page,
    }, testInfo) => {
      await logIn(page);
      await waitForLiveView(page);

      const mixedId = await versionId(page, MIXED_TIMEZONE_VERSION);
      await page.goto(`/gtfs/${mixedId}/settings/agencies`);
      await page.waitForSelector("#agencies");
      await waitForLiveView(page);

      const callout = page.locator("#agencies-timezone-callout");

      await expect(callout).toContainText("Agencies use different timezones");
      await expect(callout).toContainText(
        "Choose one timezone for this version. Calendars use UTC until then.",
      );
      await expect(page.locator("#agencies-timezone-band")).toContainText(
        "Needs review",
      );

      // The list keeps both agencies, each with its own zone and a row flag.
      const rows = page.locator("#agencies tr");
      await expect(rows).toHaveCount(2);

      await expect(rows.nth(0)).toContainText("Lakefront Transit");
      await expect(rows.nth(0).locator("td[data-label='Timezone']")).toContainText(
        "America/Chicago",
      );
      await expect(rows.nth(1)).toContainText("North Coast Transit");
      await expect(rows.nth(1).locator("td[data-label='Timezone']")).toContainText(
        "America/New_York",
      );

      for (const index of [0, 1]) {
        await expect(
          rows.nth(index).locator("td[data-label='Timezone']"),
        ).toContainText("Needs review");
      }

      expect(await bodyFitsViewport(page)).toBe(true);

      await captureIn(
        page,
        testInfo,
        AGENCIES_CAPTURE_DIR,
        "agencies-mixed-1280",
      );
    });
  });
});

// Settings › Agencies version timezone (EV-18, EV-19; step 16).
//
// The drawer the band's Change timezone action and the callout's Resolve
// timezones action open: choose a zone, review what it rewrites, acknowledge and
// apply. The journey runs on "Browser Mixed Timezone Version" (North Coast
// Transit America/New_York, Lakefront Transit America/Chicago, one route each)
// and applies America/Chicago, so the band resolves afterwards.
//
// Declared last on purpose: this block mutates the version the `@agencies-list`
// block reads earlier in the same file, and the suite runs one worker with no
// retries, so the declared order is the seeding order (CR-10).
//
// Captures land in this block's own evidence folder as
// `timezone-choose-{1280,375}.png`, `timezone-review-{1280,375}.png`,
// `timezone-ack-error-1280.png` and `timezone-applied-1280.png`.
test.describe("@agencies-timezone", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("resolves a mixed-timezone version through choose, review and apply", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const mixedId = await versionId(page, MIXED_TIMEZONE_VERSION);
    await page.goto(`/gtfs/${mixedId}/settings/agencies`);
    await page.waitForSelector("#agencies");
    await waitForLiveView(page);

    const overlay = page.locator("#agency-timezone-drawer-overlay");
    const zone = page.locator("#agency-timezone-zone");

    // The unresolved version explains itself and offers the resolve action.
    await expect(page.locator("#agencies-timezone-callout")).toContainText(
      "Agencies use different timezones",
    );

    await page.click("#agencies-resolve-timezones");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-timezone-drawer-title")).toHaveText(
      "Resolve agency timezones",
    );

    // The choose step: a blank zone, the accepted names in the datalist, and the
    // agencies the change rewrites.
    await expect(zone).toHaveValue("");
    await expect(zone).toHaveAttribute("list", "agency-timezone-zone-zones");
    await expect(zone).toHaveAttribute("autocomplete", "off");
    await expect(
      page.locator("#agency-timezone-zone-zones option[value='America/New_York']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#agency-timezone-zone-zones option[value='Not/a_zone']"),
    ).toHaveCount(0);
    await expect(page.locator("#agency-timezone-impact")).toContainText(
      `This affects every agency in ${MIXED_TIMEZONE_VERSION}`,
    );
    await expect(page.locator("#agency-timezone-current li")).toHaveCount(2);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-choose-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-choose-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // A zone the catalog does not hold marks the field and opens no review.
    await zone.fill("Not/a_zone");
    await page.locator("#agency-timezone-review").click();

    await expect(page.locator("#agency-timezone-zone-error")).toContainText(
      "Choose a valid timezone, such as America/New_York.",
    );
    await expect(page.locator("#agency-timezone-review-form")).toHaveCount(0);
    await expect(zone).toHaveValue("Not/a_zone");

    await zone.fill("America/Chicago");
    await page.locator("#agency-timezone-review").click();

    // The review names every agency, the zone it holds now, the zone it will
    // hold and the routes it operates.
    await expect(page.locator("#agency-timezone-drawer-title")).toHaveText(
      "Review timezone change",
    );
    await expect(page.locator("#agency-timezone-review-summary")).toContainText(
      "2 agencies will use America/Chicago",
    );
    await expect(page.locator("#agency-timezone-review-summary")).toContainText(
      `Only ${MIXED_TIMEZONE_VERSION} changes. Other versions keep their current timezone.`,
    );

    const reviewRows = page.locator("#agency-timezone-review-list li");

    await expect(reviewRows).toHaveCount(2);
    await expect(reviewRows.nth(0)).toContainText(
      "Lakefront Transit America/Chicago → America/Chicago 1 route",
    );
    await expect(reviewRows.nth(1)).toContainText(
      "North Coast Transit America/New_York → America/Chicago 2 routes",
    );
    await expect(page.locator("#agency-timezone-not-converted")).toContainText(
      "Route and trip clock times are not converted. Check calendars, schedules, and overnight service after this change.",
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-review-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-timezone-apply")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-review-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // Applying without the acknowledgement writes nothing: the drawer names the
    // missing confirmation and lands focus on the checkbox.
    await watchPendingState(page, "#agency-timezone-apply");
    await page.locator("#agency-timezone-apply").click();

    const pendingStates = await readPendingStates(page);

    expect(
      pendingStates.some((state) => state.disabled && state.text === "Applying…"),
    ).toBe(true);

    await expect(page.locator("#agency-timezone-ack-error")).toContainText(
      "Confirm that the selected timezone is used by these schedules before applying it.",
    );
    await expect(page.locator("#agency-timezone-ack")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#agency-timezone-ack")).toBeFocused();
    await expect(page.locator("#agency-timezone-review-form")).toHaveCount(1);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-ack-error-1280");

    // The acknowledged apply rewrites every agency and reloads the band.
    await page.check("#agency-timezone-ack");
    await page.locator("#agency-timezone-apply").click();

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      "Timezone updated for 2 agencies. Review affected schedules before exporting.",
    );
    await expect(page.locator("#agencies-timezone-callout")).toHaveCount(0);
    await expect(page.locator("#agencies-timezone-band")).toContainText(
      "America/Chicago · Used by all agencies and their schedules.",
    );

    const zones = await page
      .locator("#agencies tr td[data-label='Timezone']")
      .allInnerTexts();

    expect(zones.map((cell) => cell.trim())).toEqual([
      "America/Chicago",
      "America/Chicago",
    ]);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, TIMEZONE_CAPTURE_DIR, "timezone-applied-1280");
  });
});

// Settings › Agencies create drawer (EV-20, EV-21; step 17).
//
// The drawer the header's Create agency action and the empty state's Create
// first agency action open. The first journey runs on "Browser No Agency
// Version" (no agencies, no routes) and creates "North Coast Transit" with the
// drawer's own schedule timezone field; the second runs on "Browser Agencies
// Version" (North Coast Transit 5, Harbor Shuttle 2, Riverside Community
// Transport 0 routes) and creates "Browser Coastal Ferry", which takes the
// version zone instead of a field.
//
// Declared last on purpose: the second journey adds an agency to the version the
// `@agencies-list` block reads earlier in the same file, and the suite runs one
// worker with no retries, so the declared order is the seeding order (CR-10).
//
// Captures land in this block's own evidence folder as
// `create-first-{1280,375}.png`, `create-validation-1280.png`,
// `create-saved-1280.png`, `create-later-{1280,375}.png` and
// `create-later-saved-1280.png`.
test.describe("@agencies-create", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("creates the first agency with its own schedule timezone field", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const noAgencyId = await versionId(page, NO_AGENCY_VERSION);
    await page.goto(`/gtfs/${noAgencyId}/settings/agencies`);
    await page.waitForSelector("#agencies-empty");
    await waitForLiveView(page);

    const overlay = page.locator("#agency-drawer-overlay");
    const timezone = page.locator("#agency-form_agency_timezone");

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#agencies-empty")).toContainText("Give your service a name");
    await expect(page.locator("#agencies")).toHaveCount(0);

    await page.click("#agencies-create-first");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-drawer-title")).toHaveText("Create agency");

    // The first agency decides the version zone, so it is the one form with the
    // timezone field — the shared control, with the accepted names behind it.
    await expect(timezone).toBeVisible();
    await expect(timezone).toHaveAttribute("list", "agency-form_agency_timezone-zones");
    await expect(timezone).toHaveAttribute("autocomplete", "off");
    await expect(
      page.locator("#agency-form_agency_timezone-zones option[value='America/Chicago']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#agency-form_agency_timezone-zones option[value='Not/a_zone']"),
    ).toHaveCount(0);
    await expect(page.locator("#agency-zone-callout")).toHaveCount(0);

    // Identity, then rider contact, in the prototype's order.
    await expect(page.locator("#agency-form label .label")).toHaveText([
      "Agency name",
      "Website",
      "Schedule timezone",
      "Language (optional)",
      "Phone (optional)",
      "Email (optional)",
      "Fare website (optional)",
    ]);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-first-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-save")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-first-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // A refused value is marked on its field and creates nothing.
    await page.fill("#agency-form_agency_name", "North Coast Transit");
    await page.fill("#agency-form_agency_url", "www.example.com");
    await page.fill("#agency-form_agency_timezone", "America/Chicago");
    await page.click("#agency-save");

    await expect(page.locator("#agency-form_agency_url-error")).toContainText(
      "must be a full web address starting with https:// or http://",
    );
    await expect(page.locator("#agency-form_agency_url")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#agency-form_agency_url")).toBeFocused();

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-validation-1280");

    // The corrected save creates the agency and reloads the page behind it.
    await page.fill("#agency-form_agency_url", "https://northcoast.example");
    await watchPendingState(page, "#agency-save");
    await page.click("#agency-save");

    const pendingStates = await readPendingStates(page);

    expect(
      pendingStates.some((state) => state.disabled && state.text === "Creating…"),
    ).toBe(true);

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText("North Coast Transit created.");
    await expect(page.locator("#agencies-empty")).toHaveCount(0);

    const rows = page.locator("#agencies tr");

    await expect(rows).toHaveCount(1);
    await expect(rows.nth(0)).toContainText("North Coast Transit");
    await expect(rows.nth(0)).toContainText("northcoast.example");
    await expect(rows.nth(0).locator("td[data-label='Timezone']")).toContainText(
      "America/Chicago",
    );
    await expect(page.locator("#agencies-create")).toBeVisible();

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-saved-1280");
  });

  test("creates a later agency with the version zone instead of a field", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const agenciesId = await versionId(page, AGENCIES_VERSION);
    await page.goto(`/gtfs/${agenciesId}/settings/agencies`);
    await page.waitForSelector("#agencies");
    await waitForLiveView(page);

    const overlay = page.locator("#agency-drawer-overlay");
    const callout = page.locator("#agency-zone-callout");

    await expect(page.locator("#agencies tr")).toHaveCount(3);
    await page.click("#agencies-create");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-drawer-title")).toHaveText("Create agency");

    // The version holds one zone, so a later agency is told which one it takes
    // rather than being offered a second field (R2, AC-12).
    await expect(page.locator("#agency-form_agency_timezone")).toHaveCount(0);
    await expect(page.locator("#agency-form_agency_timezone-zones")).toHaveCount(0);
    await expect(callout).toContainText("America/New_York");
    await expect(callout).toContainText(
      "Schedule timezone for this version. To update every agency together, use Change timezone on the agency list.",
    );

    await expect(page.locator("#agency-form label .label")).toHaveText([
      "Agency name",
      "Website",
      "Language (optional)",
      "Phone (optional)",
      "Email (optional)",
      "Fare website (optional)",
    ]);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-later-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-save")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-later-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.fill("#agency-form_agency_name", "Browser Coastal Ferry");
    await page.fill("#agency-form_agency_url", "https://coastal.example");
    await page.click("#agency-save");

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      "Browser Coastal Ferry created.",
    );

    const rows = page.locator("#agencies tr");

    await expect(rows).toHaveCount(4);

    // The list sorts by name, and the new agency's name sorts first.
    await expect(rows.nth(0)).toContainText("Browser Coastal Ferry");
    await expect(rows.nth(0)).toContainText("coastal.example");

    const zones = await page
      .locator("#agencies tr td[data-label='Timezone']")
      .allInnerTexts();

    expect(zones.map((cell) => cell.trim())).toEqual([
      "America/New_York",
      "America/New_York",
      "America/New_York",
      "America/New_York",
    ]);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, CREATE_CAPTURE_DIR, "create-later-saved-1280");
  });
});

// Settings › Agencies edit drawer (EV-22, EV-23; step 18).
//
// The drawer a list row's name opens: the read-only identity box, the version
// zone note, the stored values and the save. The journey edits Harbor Shuttle's
// phone on "Browser Agencies Version" and captures the drawer at both required
// viewports, then the saved state.
//
// Declared last on purpose: it mutates the seeded version the `@agencies-list`
// block reads earlier in the same file, and the suite runs one worker with no
// retries, so the declared order is the seeding order (CR-10). Only the phone
// changes, so the earlier name, host, zone and route-count readings stay true.
//
// Captures land in this block's own evidence folder as `edit-drawer-{1280,375}.png`
// and `edit-saved-1280.png`.
test.describe("@agencies-edit", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("edits an agency's phone in its drawer", async ({ page }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const agenciesId = await versionId(page, AGENCIES_VERSION);
    await page.goto(`/gtfs/${agenciesId}/settings/agencies`);
    await page.waitForSelector("#agencies");
    await waitForLiveView(page);

    // The name is the row's own button, so the journey opens the agency it names
    // rather than the row at an index.
    const row = page.locator("#agencies tr").filter({ hasText: "Harbor Shuttle" });
    const open = row.locator("button[id^='agency-open-']");

    await expect(open).toHaveText("Harbor Shuttle");
    await open.click();

    const overlay = page.locator("#agency-drawer-overlay");

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-drawer-title")).toHaveText("Harbor Shuttle");
    await expect(page.locator("#agency-identity")).toContainText("Agency ID");
    await expect(page.locator("#agency-identity")).toContainText("HBR");
    await expect(page.locator("#agency-identity")).toContainText(
      "Preserved in imports and exports",
    );

    // The version zone is a note, not a second zone field, and the ID is a fact
    // rather than an input (AC-15).
    await expect(page.locator("#agency-form_agency_timezone")).toHaveCount(0);
    await expect(page.locator("#agency-zone-callout")).toContainText(
      "America/New_York",
    );
    await expect(page.locator("#agency-form_agency_name")).toHaveValue(
      "Harbor Shuttle",
    );
    await expect(page.locator("#agency-form_agency_url")).toHaveValue(
      "https://harbor.example",
    );
    await expect(page.locator("#agency-save")).toHaveText("Save changes");
    await expect(page.locator("#agency-cancel")).toHaveText("Cancel");

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, EDIT_CAPTURE_DIR, "edit-drawer-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-save")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, EDIT_CAPTURE_DIR, "edit-drawer-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.fill("#agency-form_agency_phone", "(212) 555-RIDE");
    await watchPendingState(page, "#agency-save");
    await page.click("#agency-save");

    const pendingStates = await readPendingStates(page);

    expect(
      pendingStates.some((state) => state.disabled && state.text === "Saving…"),
    ).toBe(true);

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText("Changes saved.");

    // Reopening reads the stored row back, so the phone the journey typed is the
    // one the page now holds.
    await row.locator("button[id^='agency-open-']").click();

    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-form_agency_phone")).toHaveValue(
      "(212) 555-RIDE",
    );
    await expect(page.locator("#agency-unsaved")).toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, EDIT_CAPTURE_DIR, "edit-saved-1280");
  });
});
