// Settings › Feed details browser journey (EV-4, EV-5; step 6).
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0)
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

// The version `browser_seed.exs` seeds with the delete flow's three agencies:
// "Browser Alpha" holds two routes, "Browser Beta" receives them, and "Browser
// Gamma" has no routes but is named by the fare attribute F-BROWSER (EV-24,
// EV-25).
const AGENCY_DELETE_VERSION = "Browser Agency Delete Version";

// The shared version whose one agency is the last one, so its Delete agency
// action cannot be used (AC-19).
const SINGLE_AGENCY_VERSION = "Browser E2E Version";

// The New route drawer block's own evidence folder (EV-27).
const NEW_ROUTE_CAPTURE_DIR =
  process.env.ROUTES_NEW_ROUTE_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/routes-new-route",
  );

// The Routes onboarding's two versions (EV-29; step 21). Nothing else reads
// them: "Browser Onboarding Version" starts with neither agencies nor routes,
// and "Browser Unassigned Routes Version" holds two routes that carry no
// agency.
const ONBOARDING_VERSION = "Browser Onboarding Version";
const UNASSIGNED_ROUTES_VERSION = "Browser Unassigned Routes Version";

// The Routes onboarding block's own evidence folder (EV-29).
const ONBOARDING_CAPTURE_DIR =
  process.env.ROUTES_ONBOARDING_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/routes-onboarding",
  );

// The delete block's own evidence folder (EV-25).
const DELETE_CAPTURE_DIR =
  process.env.AGENCIES_DELETE_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/agencies-delete",
  );

// The import findings block's own evidence folder (EV-31; step 22).
const IMPORT_FINDINGS_CAPTURE_DIR =
  process.env.IMPORT_FINDINGS_CAPTURE_DIR ||
  resolve(
    REPO_ROOT,
    ".specs/13-agencies-and-feed-details/evidence/visual/import-findings",
  );

// The version whose import page the findings block opens. The upload publishes a
// new, uniquely named version of its own, so no seeded version is mutated
// (CR-10). The Import page opens on Station changes when the version's latest
// change run is unfinished, which the pathway evolutions journeys leave on
// Browser E2E Version on purpose, so the block opens a version no change run
// belongs to.
const IMPORT_VERSION = "Browser Feed Details Version";

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

// `ds-drawer-slide-in` (assets/css/app.css) moves the panel 100% of its width
// over 300ms with a forwards fill, so a capture taken while it runs shows a
// drawer still hanging off the right edge. Settle the panel's own animations
// first, the way `admin_design_contracts.spec.js` does.
async function settleDrawer(page, selector) {
  await page
    .locator(selector)
    .evaluate((el) =>
      Promise.all(el.getAnimations({ subtree: true }).map((a) => a.finished)),
    );
}

// The upload channel joins asynchronously, so a file selection that lands before
// it is ready is dropped. Retry the way `import_export.spec.js` does until every
// chosen file appears in the entry list.
async function setImportFiles(page, files) {
  const input = page.locator("#gtfs-import-upload-input input");
  const entries = page.locator("#gtfs-import-upload-entries");

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await waitForLiveView(page);
    await expect(input).toHaveAttribute("data-phx-upload-ref", /.+/);
    await input.setInputFiles(files);

    try {
      for (const file of files) {
        await expect(entries).toContainText(file.name, { timeout: 5_000 });
      }

      return;
    } catch (error) {
      if (attempt === 3) throw error;
    }
  }
}

// One definition-list row's label and value, in the order the page renders them.
// A Feed details row's `dt` also carries a hint, so the label is read on its own.
async function details(dl) {
  const labels = await dl.locator("[data-role='field-label']").allInnerTexts();
  const values = await dl.locator("[data-role='field-value']").allInnerTexts();

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
        await expect(page.locator("h1 + p")).toContainText(
          "Tell trip planners who publishes this schedule, how long it’s valid and who to contact about the data.",
        );
        await expect(page.locator("#feed-details-scope")).toHaveText(
          `Applies to ${SUMMARY_VERSION} only. Each version keeps its own feed details.`,
        );
        // The page returns to Settings by a link, not the tab bar.
        await expect(page.locator("#settings-nav")).toHaveCount(0);
        await expect(page.locator("#settings-back")).toHaveAttribute(
          "href",
          `/gtfs/${feedDetailsId}/settings`,
        );
        await expect(page.locator("#coming-soon-status")).toHaveCount(0);
        await expect(page.locator("#feed-details-empty")).toHaveCount(0);

        await expect(
          page.locator("#feed-details-publisher h2"),
        ).toHaveText("Publisher");
        await expect(page.locator("#feed-details-validity h2")).toHaveText(
          "Dates and version",
        );
        await expect(page.locator("#feed-details-contact h2")).toHaveText(
          "Data contact",
        );

        expect(await details(page.locator("#feed-details-publisher dl"))).toEqual(
          [
            ["Publisher name", "Browser Regional Partnership"],
            ["Publisher website", "https://example.test/data"],
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
            ["Contact email", "data@example.test"],
            ["Contact website", "https://example.test/data/contact"],
          ],
        );

        // The related notes, in order, each with its way onward.
        await expect(page.locator("#feed-details-aside h2")).toHaveText([
          "Rider contact lives on agencies",
          "Saving doesn’t publish",
        ]);
        await expect(page.locator("#feed-details-aside")).toContainText(
          "These details are included when this version is exported.",
        );
        await expect(
          page.locator("#feed-details-manage-agencies"),
        ).toHaveAttribute("href", `/gtfs/${feedDetailsId}/settings/agencies`);
        await expect(
          page.locator("#feed-details-go-to-export"),
        ).toHaveAttribute("href", `/gtfs/${feedDetailsId}/export`);

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
        await expect(page.locator("h1 + p")).toContainText(
          "Tell trip planners who publishes this schedule, how long it’s valid and who to contact about the data.",
        );
        await expect(page.locator("#feed-details-empty")).toContainText(
          "No feed details yet",
        );
        await expect(page.locator("#feed-details-empty")).toContainText(
          "You can export without them, but data checkers flag the missing file.",
        );
        await expect(page.locator("#feed-details-summary")).toHaveCount(0);
        await expect(page.locator("#coming-soon-status")).toHaveCount(0);

        // Step 7's drawer adds the opener to this state.
        await expect(page.locator("#feed-details-set")).toHaveText(
          "Set up feed details",
        );
        await expect(page.locator("#feed-details-aside")).toBeVisible();

        expect(await bodyFitsViewport(page)).toBe(true);

        await capture(page, testInfo, `feed-empty-${viewport.file}`);
      });
    });
  }

  test("the Settings overview lists Feed details as a working page", async ({
    page,
  }) => {
    await logIn(page);
    await waitForLiveView(page);

    const feedDetailsId = await versionId(page, SUMMARY_VERSION);
    await page.goto(`/gtfs/${feedDetailsId}/settings`);
    await page.waitForSelector("#settings-overview");

    const entry = page.locator("#settings-entry-feed_details");

    await expect(entry.locator("#settings-entry-feed_details-title")).toHaveText(
      "Feed details",
    );
    await expect(entry.locator("a")).toHaveAttribute(
      "href",
      `/gtfs/${feedDetailsId}/settings/feed-details`,
    );
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
      "Set up feed details",
    );
    await expect(drawer).toContainText(
      "These details describe your whole schedule dataset, not one agency. Fields marked optional can stay blank.",
    );
    await expect(drawer.locator("legend")).toHaveText([
      "Publisher",
      "Dates and version",
      "Data contact",
    ]);
    await expect(page.locator("#feed-details-use-date-label")).toHaveText(
      "Use today’s date",
    );
    // The drawer opens on its first field.
    await expect(page.locator("#feed_info_feed_publisher_name")).toBeFocused();

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
      "Enter a full web address",
    );
    await expect(page.locator("#feed_info_feed_publisher_name-error")).toHaveCount(0);
    await expect(page.locator("#feed-details-form-error")).toHaveCount(0);

    await page.fill("#feed_info_feed_publisher_name", "Browser Regional Partnership");
    await page.selectOption("#feed_info_feed_lang", "en");
    await page.locator("#feed-details-form button[type='submit']").click();

    // The refused value marks its own field and writes nothing.
    await expect(page.locator("#feed_info_feed_publisher_url-error")).toContainText(
      "Enter a full web address",
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
        await expect(page.locator("h1 + p")).toContainText(
          "The organizations that run your routes, as riders see them in trip planners.",
        );
        await expect(page.locator("#agencies-scope")).toContainText(
          `Applies to ${AGENCIES_VERSION} only. Each version keeps its own agencies.`,
        );

        // The way back to the Settings overview replaces the section tab bar.
        await expect(page.locator("#settings-back")).toHaveText("Settings");
        await expect(page.locator("#settings-back")).toHaveAttribute(
          "href",
          `/gtfs/${agenciesId}/settings`,
        );
        await expect(page.locator("#settings-nav")).toHaveCount(0);
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
          "No contact details",
          "No contact details",
          "No contact details",
        ]);
        expect(cells.map((row) => row[2])).toEqual([
          "2 routes",
          "5 routes",
          "0 routes",
        ]);

        // One timezone is a fact about the version: the panel names it, the table
        // has no Timezone column, no callout appears and no row needs review.
        await expect(page.locator("#agencies-timezone-band")).toContainText(
          "Schedule timezone",
        );
        await expect(page.locator("#agencies-timezone-value")).toHaveText(
          "America/New_York",
        );
        await expect(page.locator("#agencies-timezone-band")).toContainText(
          "Every agency in this version shares it.",
        );
        await expect(page.locator("#agencies td[data-label='Timezone']")).toHaveCount(0);
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
      // The Route ID cell is the row's last column (routes_live.ex renders no
      // data-label on desktop table cells).
      await expect(page.locator("#routes tr")).toHaveCount(5);
      await expect(page.locator("#routes tr td:last-child").first()).toContainText(
        "NCT_",
      );
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
      "North Coast Transit America/New_York → America/Chicago 1 route",
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
    await expect(page.locator("#agencies-timezone-value")).toHaveText("America/Chicago");
    await expect(page.locator("#agencies-timezone-band")).toContainText(
      "Every agency in this version shares it.",
    );

    // The zones agree, so the Timezone column and its row flags are gone.
    await expect(page.locator("#agencies td[data-label='Timezone']")).toHaveCount(0);
    await expect(page.locator("#agencies")).not.toContainText("Needs review");

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

    // One agency reads as a summary, with its timezone in the panel beside it.
    await expect(page.locator("#agencies")).toHaveCount(0);
    await expect(page.locator("#agency-summary-name")).toHaveText("North Coast Transit");
    await expect(page.locator("#agency-summary-website")).toContainText(
      "northcoast.example",
    );
    await expect(page.locator("#agencies-timezone-value")).toHaveText("America/Chicago");
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

    // Every agency shares the version zone, so the table has no Timezone column.
    await expect(page.locator("#agencies td[data-label='Timezone']")).toHaveCount(0);
    await expect(page.locator("#agencies-timezone-value")).toHaveText("America/New_York");

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

// Declared last on purpose: it is the only block that mutates the seeded
// "Browser Agency Delete Version", and the suite runs one worker with no
// retries, so the declared order is the seeding order (CR-10). The last-agency
// reading on the shared "Browser E2E Version" opens a drawer and changes
// nothing.
//
// Captures land in this block's own evidence folder as
// `delete-blocked-{1280,375}.png`, `delete-review-{1280,375}.png` and
// `delete-disabled-1280.png`.
test.describe("@agencies-delete", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("blocks the fare-referenced agency, deletes Alpha into Beta and shows the last agency", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const deleteVersion = await versionId(page, AGENCY_DELETE_VERSION);
    await page.goto(`/gtfs/${deleteVersion}/settings/agencies`);
    await page.waitForSelector("#agencies");
    await waitForLiveView(page);

    const overlay = page.locator("#agency-drawer-overlay");

    // Browser Gamma is named by F-BROWSER, so the deletion is refused with the
    // reference the editor has to resolve first (AC-21).
    const gamma = page.locator("#agencies tr").filter({ hasText: "Browser Gamma" });
    await gamma.locator("button[id^='agency-open-']").click();
    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-delete")).toBeEnabled();
    await page.click("#agency-delete");
    await expect(page.locator("#agency-delete-choose")).toBeVisible();
    await page.click("#agency-delete-review-submit");
    await expect(page.locator("#agency-delete-blocked")).toContainText(
      "cannot be deleted yet",
    );
    await expect(page.locator("#agency-delete-blocked")).toContainText("F-BROWSER");
    await expect(page.locator("#agency-delete-back-to-agency")).toHaveText(
      "Back to agency",
    );
    await expect(page.locator("#agency-delete-close")).toHaveText("Close");
    await expect(page.locator("#agency-delete-apply")).toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DELETE_CAPTURE_DIR, "delete-blocked-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-delete-blocked")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DELETE_CAPTURE_DIR, "delete-blocked-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.click("#agency-delete-close");
    await expect(overlay).toHaveAttribute("data-open", "false");

    // Browser Alpha has two routes, so its deletion needs the receiving agency
    // and reviews exactly the routes that will move (AC-20).
    const alpha = page.locator("#agencies tr").filter({ hasText: "Browser Alpha" });
    await alpha.locator("button[id^='agency-open-']").click();
    await expect(overlay).toHaveAttribute("data-open", "true");
    await page.click("#agency-delete");
    await expect(page.locator("#agency-delete-choose")).toContainText("Move routes to");
    await expect(page.locator("#agency-delete-form_target_id")).toBeVisible();
    await page.selectOption("#agency-delete-form_target_id", { label: "Browser Beta" });
    await page.click("#agency-delete-review-submit");
    await expect(page.locator("#agency-delete-review")).toContainText(
      "Browser Alpha will be deleted",
    );
    await expect(page.locator("#agency-delete-review")).toContainText(
      "2 routes will move to Browser Beta. No routes will be deleted.",
    );
    await expect(page.locator("#agency-delete-routes li")).toHaveCount(2);
    await expect(page.locator("#agency-delete-apply")).toHaveText(
      "Move routes and delete",
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DELETE_CAPTURE_DIR, "delete-review-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#agency-delete-apply")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DELETE_CAPTURE_DIR, "delete-review-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await watchPendingState(page, "#agency-delete-apply");
    await page.click("#agency-delete-apply");

    const pendingStates = await readPendingStates(page);

    expect(
      pendingStates.some((state) => state.disabled && state.text === "Deleting…"),
    ).toBe(true);

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      "Browser Alpha deleted. 2 routes moved to Browser Beta.",
    );
    await expect(page.locator("#agencies")).not.toContainText("Browser Alpha");
    await expect(page.locator("#agencies")).toContainText("Browser Beta");

    // The version whose one agency is the last one offers the action but cannot
    // use it, and says why (AC-19).
    const soloVersion = await versionId(page, SINGLE_AGENCY_VERSION);
    await page.goto(`/gtfs/${soloVersion}/settings/agencies`);
    await page.waitForSelector("#agency-summary");
    await waitForLiveView(page);

    await page.locator("#agency-summary button[id^='agency-open-']").click();
    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#agency-delete")).toBeDisabled();
    await expect(page.locator("#agency-delete-reason")).toHaveText(
      "This is the last agency in the version and can't be deleted.",
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, DELETE_CAPTURE_DIR, "delete-disabled-1280");
  });
});

// The New route drawer's required, preselected Agency field and the route it
// creates through the version-locked context call (EV-27; step 20).
//
// Declared last on purpose: it adds one route to the same seeded "Browser
// Agencies Version" the `@agencies-list` block reads its route counts from, and
// the suite runs one worker with no retries, so the declared order is the
// seeding order (CR-10). The route ID carries a timestamp so a repeat run
// against a database that was not reset cannot collide with this one.
//
// Captures land in this block's own evidence folder as
// `new-route-drawer-{1280,375}.png` and `new-route-created-1280.png`.
test.describe("@routes-new-route", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("creates a route from the agency-filtered list with the agency preselected", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    const agenciesId = await versionId(page, AGENCIES_VERSION);
    await page.goto(`/gtfs/${agenciesId}/routes?agency_id=HBR`);
    await page.waitForSelector("#routes");
    await waitForLiveView(page);

    // Harbor Shuttle's two seeded routes are the baseline this journey adds one
    // to, and the filter is really applied. The Route ID cell is the row's
    // last column (routes_live.ex renders no data-label on desktop table
    // cells).
    await expect(page.locator("#routes tr")).toHaveCount(2);
    await expect(page.locator("#routes tr td:last-child").first()).toContainText(
      "HBR_",
    );

    await page.click("#new-route-trigger");

    const overlay = page.locator("#new-route-drawer-overlay");

    await expect(overlay).toHaveAttribute("data-open", "true");

    // `ds-drawer-slide-in` (assets/css/app.css) moves the panel 100% of its
    // width over 300ms with a forwards fill, so a capture taken while it runs
    // shows a drawer still hanging off the right edge. Settle the panel's own
    // animations first, the way `admin_design_contracts.spec.js` does.
    await page
      .locator("#new-route-drawer")
      .evaluate((el) =>
        Promise.all(el.getAnimations({ subtree: true }).map((a) => a.finished)),
      );

    // The Agency field is present, plainly labelled, and already set to the
    // agency the list is filtered to, with no blank choice left (AC-23).
    await expect(page.locator("#route_agency_id")).toHaveValue("HBR");
    await expect(page.locator("#route_agency_id")).toBeVisible();
    await expect(page.locator("#new-route-form-panel")).not.toContainText(
      "Agency (optional)",
    );
    await expect(page.locator('#route_agency_id option[value=""]')).toHaveCount(0);
    await expect(page.locator("#route_agency_id-help")).toContainText(
      "agency_id — the agency that operates this route.",
    );

    const routeId = `E2E-${Date.now()}`;

    await page.fill("#route_route_id", routeId);
    await page.fill("#route_route_long_name", "Filtered preselect journey");
    await page.selectOption("#route_route_type", { label: "Bus" });

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, NEW_ROUTE_CAPTURE_DIR, "new-route-drawer-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#route_agency_id")).toBeVisible();
    await expect(page.locator("#new-route-submit")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, NEW_ROUTE_CAPTURE_DIR, "new-route-drawer-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await watchPendingState(page, "#new-route-submit");
    await page.click("#new-route-submit");

    const pendingStates = await readPendingStates(page);

    expect(
      pendingStates.some((state) => state.disabled && state.text === "Creating…"),
    ).toBe(true);

    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      `Route ${routeId} created.`,
    );

    // The filtered catalog reloads with the new route, so the created row is the
    // one this journey asked for.
    await expect(page.locator("#routes tr")).toHaveCount(3);
    await expect(page.locator("#routes")).toContainText(routeId);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, NEW_ROUTE_CAPTURE_DIR, "new-route-created-1280");

    // Read the stored route back through the Agencies page's own count: the
    // route carries the agency the drawer preselected (R4).
    await page.goto(`/gtfs/${agenciesId}/settings/agencies`);
    await page.waitForSelector("#agencies");
    await waitForLiveView(page);

    await expect(
      page.getByRole("link", { name: "View 3 routes for Harbor Shuttle" }),
    ).toBeVisible();
  });
});

// The first-agency onboarding on the Routes page: set up the version's first
// agency, create the first route with it selected, and assign existing
// unassigned routes to a new agency (EV-29; step 21).
//
// Declared last: it mutates only the two versions seeded for it ("Browser
// Onboarding Version" and "Browser Unassigned Routes Version"), which no other
// block reads, and the suite runs one worker with no retries (CR-10). Both
// journeys need `bin/test-browser` to have seeded a new database, because both
// create the only agency their version gets: a repeat run against a database
// that was not recreated starts from a version that already has one.
//
// Captures land in this block's own evidence folder as
// `onboarding-{1280,375}.png`, `agency-drawer-{1280,375}.png`,
// `new-route-drawer-{1280,375}.png`, `first-route-created-1280.png`,
// `no-agency-callout-{1280,375}.png` and `assigned-1280.png`.
test.describe("@routes-onboarding", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("sets up the first agency, creates its first route, and assigns existing routes", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    await waitForLiveView(page);

    // ── Who operates this service? ──
    const onboardingId = await versionId(page, ONBOARDING_VERSION);
    await page.goto(`/gtfs/${onboardingId}/routes`);
    await page.waitForSelector("#routes-agency-onboarding");
    await waitForLiveView(page);

    const onboarding = page.locator("#routes-agency-onboarding");

    await expect(onboarding).toContainText("Before your first route");
    await expect(onboarding).toContainText("Who operates this service?");
    await expect(onboarding).toContainText(
      "Journey planners need an agency name, website, and timezone.",
    );
    await expect(page.locator("#routes-onboarding-import")).toHaveAttribute(
      "href",
      `/gtfs/${onboardingId}/import`,
    );
    // The agency is the primary action here, so Create route steps back.
    await expect(page.locator("#new-route-trigger")).toHaveClass(/btn-outline/);
    await expect(page.locator("#routes-first-use-empty")).toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "onboarding-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    // The filter panel fills the first screen at this width, so the capture has
    // to bring the onboarding itself into view to record the changed state.
    await page.locator("#routes-agency-onboarding").scrollIntoViewIfNeeded();
    await expect(page.locator("#routes-set-up-agency")).toBeInViewport();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "onboarding-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    // ── Set up your agency, with the first agency's own timezone field ──
    await page.click("#routes-set-up-agency");

    const agencyOverlay = page.locator("#routes-agency-drawer-overlay");

    await expect(agencyOverlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#routes-agency-drawer-title")).toHaveText(
      "Set up your agency",
    );
    await expect(page.locator("#routes-agency-form_agency_timezone")).toBeVisible();
    await expect(page.locator("#routes-agency-drawer-scope")).toContainText(
      "Browser Onboarding Version",
    );
    await settleDrawer(page, "#routes-agency-drawer");

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "agency-drawer-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#routes-agency-form_agency_timezone")).toBeVisible();
    await expect(page.locator("#routes-agency-save")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "agency-drawer-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.fill("#routes-agency-form_agency_name", "Browser Onboarding Transit");
    await page.fill("#routes-agency-form_agency_url", "https://onboarding.example");
    await page.fill("#routes-agency-form_agency_timezone", "America/Chicago");
    await page.click("#routes-agency-save");

    await expect(agencyOverlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      "Browser Onboarding Transit created.",
    );

    // ── The New route drawer, already set to the agency just created ──
    const routeOverlay = page.locator("#new-route-drawer-overlay");

    await expect(routeOverlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#route_agency_id")).toHaveValue(
      "browser_onboarding_transit",
    );
    await expect(page.locator('#route_agency_id option[value=""]')).toHaveCount(0);
    await settleDrawer(page, "#new-route-drawer");

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "new-route-drawer-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await expect(page.locator("#route_agency_id")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "new-route-drawer-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.fill("#route_route_id", "E2E-1");
    await page.fill("#route_route_long_name", "Onboarding journey route");
    await page.selectOption("#route_route_type", { label: "Bus" });
    await page.click("#new-route-submit");

    await expect(routeOverlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText("Route E2E-1 created.");
    await expect(page.locator("#routes")).toContainText("E2E-1");

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "first-route-created-1280");

    // ── N imported routes need a provider ──
    const unassignedId = await versionId(page, UNASSIGNED_ROUTES_VERSION);
    await page.goto(`/gtfs/${unassignedId}/routes`);
    await page.waitForSelector("#routes-no-agency");
    await waitForLiveView(page);

    const callout = page.locator("#routes-no-agency");

    await expect(callout).toContainText("These routes have no agency");
    await expect(callout).toContainText(
      "Set up the agency that operates them. Creating it assigns it to all 2 routes.",
    );
    await expect(page.locator("#routes tr")).toHaveCount(2);
    await expect(page.locator("#routes-agency-onboarding")).toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "no-agency-callout-1280");

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await page.locator("#routes-no-agency").scrollIntoViewIfNeeded();
    await expect(page.locator("#routes-set-up-agency")).toBeInViewport();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "no-agency-callout-375");
    await page.setViewportSize({ width: DESKTOP.width, height: DESKTOP.height });

    await page.click("#routes-set-up-agency");
    await expect(agencyOverlay).toHaveAttribute("data-open", "true");
    await page.fill("#routes-agency-form_agency_name", "Browser Assigned Transit");
    await page.fill("#routes-agency-form_agency_url", "https://assigned.example");
    await page.fill("#routes-agency-form_agency_timezone", "America/Chicago");
    await page.click("#routes-agency-save");

    await expect(agencyOverlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#flash-info")).toContainText(
      "Browser Assigned Transit created. 2 routes now use it.",
    );
    // The routes were assigned in place: the callout is gone, the catalog is
    // unchanged and no route drawer opened (AC-25).
    await expect(page.locator("#routes-no-agency")).toHaveCount(0);
    await expect(routeOverlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#routes tr")).toHaveCount(2);

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(page, testInfo, ONBOARDING_CAPTURE_DIR, "assigned-1280");
  });
});

//
// Declared last: it imports a feed of its own into a new uniquely named version
// from the Browser Feed Details Version's import page, so it reads and writes no seeded
// version's agencies or routes (CR-10). It needs the `bin/test-browser` seed for
// the seeded login and version panel, not for the import itself.
//
// Captures land in this block's own evidence folder as
// `import-findings-{1280,375}.png`.
test.describe("@import-findings", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("imports a feed with no agency and shows the new version's finding", async ({
    page,
  }, testInfo) => {
    test.setTimeout(180_000);

    await logIn(page);
    await waitForLiveView(page);

    const importStartId = await versionId(page, IMPORT_VERSION);
    await page.goto(`/gtfs/${importStartId}/import`);
    await page.waitForSelector("#gtfs-import-form");
    await waitForLiveView(page);

    // Two routes and one stop, and no agency.txt at all: the published version
    // holds two routes no agency accounts for (AC-27).
    const routes = [
      "route_id,route_short_name,route_long_name,route_type",
      "E2E_F1,1,First findings route,3",
      "E2E_F2,2,Second findings route,3",
    ].join("\n");
    const stops = [
      "stop_id,stop_name,stop_lat,stop_lon",
      "E2E_S1,Findings stop,42.36,-71.05",
    ].join("\n");

    // Two .txt entries in one submission reach the same import run a zip would;
    // the browser sends multiple entries where the LiveView test harness sends
    // one, so no archive has to be encoded here.
    await setImportFiles(page, [
      { name: "routes.txt", mimeType: "text/plain", buffer: Buffer.from(routes) },
      { name: "stops.txt", mimeType: "text/plain", buffer: Buffer.from(stops) },
    ]);

    await page.fill("#gtfs-import-version-name", `E2E findings ${Date.now()}`);
    await page.click("#gtfs-import-submit");

    const result = page.locator("#gtfs-import-result");

    await expect(result).toContainText("Imported", { timeout: 120_000 });

    // The finding describes the version just published, not the URL version.
    const findings = page.locator("#gtfs-import-agency-findings");

    await expect(findings).toContainText("No agency in this feed");
    await expect(findings).toContainText(
      "2 routes need an operating agency before export.",
    );

    const setUpAgency = page.locator("#gtfs-import-set-up-agency");

    await expect(setUpAgency).toHaveText("Set up agency");
    await expect(setUpAgency).not.toHaveAttribute(
      "href",
      `/gtfs/${importStartId}/settings/agencies`,
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(
      page,
      testInfo,
      IMPORT_FINDINGS_CAPTURE_DIR,
      "import-findings-1280",
    );

    await page.setViewportSize({ width: MOBILE.width, height: MOBILE.height });
    await findings.scrollIntoViewIfNeeded();
    await expect(setUpAgency).toBeInViewport();
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureIn(
      page,
      testInfo,
      IMPORT_FINDINGS_CAPTURE_DIR,
      "import-findings-375",
    );
  });
});
