// Integrated information-architecture navigation and restyled header journey
// (EV-6, step 7).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`. The journey is read-only: it navigates, opens the two
// header menus and captures the composed surfaces at the two required viewports.
// Expected labels, paths, roles and initials are literal values from the spec and
// the information architecture, not derived from the components under test.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// Seeded organization administrator with only `pathways_studio_admin`, so the
// account menu must fall back to the existing Users page.
const ORG_ADMIN = {
  email: "admin-contracts@gtfs-planner.test",
  password: "AdminContracts123!",
};

const VERSION_NAME = "Browser E2E Version";
const ORGANIZATION_NAME = "Browser Test Org";
const ADMIN_ORGANIZATION_NAME = "Admin Contracts Org";
const STATION = "BROWSER_STATION";
const SCHEDULES_ROUTE = "BROWSER_SCHEDULES_READY";
const SCHEDULE_PATTERN = "BROWSER-SCHED-P1";

// diagram-test@… splits on `-`, so the header avatar must read DT.
const EDITOR_INITIALS = "DT";

const DESKTOP = { width: 1440, height: 1000, label: "desktop" };
const MOBILE = { width: 375, height: 812, label: "mobile" };
const VIEWPORTS = [DESKTOP, MOBILE];

// `[id, label, path segment]`, in the information architecture's order.
const TASKS = [
  ["nav-routes", "Routes", "routes"],
  ["nav-calendars", "Calendars", "calendars"],
  ["nav-operations", "Operations", "blocks"],
  ["nav-stops", "Stops & stations", "stops"],
  ["nav-flex", "Flex", "flex"],
  ["nav-gtfs", "GTFS", "export"],
];

// The five allowlisted placeholder sections: tab id, page title, URL slug.
const SETTINGS_SECTIONS = [
  ["settings-tab-feed_details", "Feed details", "feed-details"],
  ["settings-tab-agencies", "Agencies", "agencies"],
  ["settings-tab-fares", "Fares", "fares"],
  ["settings-tab-export_defaults", "Export defaults", "export-defaults"],
  ["settings-tab-feed_url", "Published feed URL", "feed-url"],
];

async function logIn(page, account = EDITOR) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', account.email);
  await page.fill('input[name="user[password]"]', account.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// A click or key press that lands before the LiveView joins is dropped, so each
// navigation waits for the mounted view first.
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

// The seeded database names its published version, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
async function seededVersionId(page, name = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function capture(page, testInfo, name) {
  await page.screenshot({ path: testInfo.outputPath(`${name}.png`) });
}

async function expectNoPageOverflow(page) {
  expect(await bodyFitsViewport(page)).toBe(true);
}

// Opens the account menu the way a person does, then returns the panel.
async function openAccountMenu(page) {
  await page.locator("#user-menu [data-user-menu-trigger]").click();
  await expect(
    page.locator("#user-menu [data-user-menu-trigger]"),
  ).toHaveAttribute("aria-expanded", "true");

  return page.locator("#user-menu-panel");
}

async function openVersionMenu(page) {
  await page.locator("#gtfs-version-trigger").click();
  await expect(page.locator("#gtfs-version-panel")).toBeVisible();

  return page.locator("#gtfs-version-panel");
}

// Every header link, button and menu item must clear the 44px activation floor.
async function expectHeaderTargetsAreLargeEnough(page) {
  const targets = page.locator(
    "#app-header a:visible, #app-header button:visible, #user-menu-panel [role='menuitem']:visible",
  );
  const count = await targets.count();

  for (let i = 0; i < count; i += 1) {
    const box = await targets.nth(i).boundingBox();
    expect(box).not.toBeNull();
    expect(box.height).toBeGreaterThanOrEqual(44);
  }
}

// Collects the only image/asset failure this step's claims depend on: a header
// font that silently falls back.
function watchFontRequests(page) {
  const failed = [];
  page.on("response", (response) => {
    if (response.status() >= 400 && /\/fonts\//.test(response.url())) {
      failed.push(`${response.status()} ${response.url()}`);
    }
  });
  return failed;
}

for (const { width, height, label } of VIEWPORTS) {
  test.describe(`integrated header and destinations at ${label}`, () => {
    test.use({ viewport: { width, height } });

    test("task links, area bars, placeholder, Settings and moved pages", async ({
      page,
    }, testInfo) => {
      const failedFonts = watchFontRequests(page);
      const pageErrors = [];
      page.on("pageerror", (error) => pageErrors.push(error.message));

      await logIn(page);
      await waitForLiveView(page);

      const versionId = await seededVersionId(page);

      // ── Main navigation: the six literal labels, in order, without icons ──
      for (const [id, taskLabel, segment] of TASKS) {
        const link = page.locator(`#main-navigation #${id}`);
        await expect(link).toHaveText(taskLabel);
        await expect(link).toHaveAttribute(
          "href",
          `/gtfs/${versionId}/${segment}`,
        );
      }

      await expect(page.locator("#main-navigation a")).toHaveCount(
        TASKS.length,
      );
      await expect(page.locator("#main-navigation svg")).toHaveCount(0);
      await expect(
        page.locator("#main-navigation a[aria-current='page']"),
      ).toHaveCount(0);

      await capture(page, testInfo, `header-${label}`);

      // ── Each task opens its own destination and is the only current one ──
      for (const [id, taskLabel, segment] of TASKS) {
        await page.locator(`#main-navigation #${id}`).click();
        await page.waitForURL(new RegExp(`/gtfs/[^/]+/${segment}$`));
        await waitForLiveView(page);

        await expect(
          page.locator("#main-navigation a[aria-current='page']"),
        ).toHaveCount(1);
        await expect(page.locator(`#main-navigation #${id}`)).toHaveAttribute(
          "aria-current",
          "page",
        );
        await expect(
          page.locator("#main-navigation a[aria-current='page']"),
        ).toHaveText(taskLabel);
        await expectNoPageOverflow(page);
      }

      // ── GTFS holds Export and Import as ordinary tabs ──
      await page.locator("#main-navigation #nav-gtfs").click();
      await page.waitForURL(/\/gtfs\/[^/]+\/export$/);
      await expect(
        page.locator("#gtfs-sub-nav a[aria-current='page']"),
      ).toHaveText("Export");
      await expect(page.locator("#main-navigation #nav-gtfs")).toHaveAttribute(
        "aria-current",
        "page",
      );

      await page.locator("#gtfs-tab-import").click();
      await page.waitForURL(/\/gtfs\/[^/]+\/import$/);
      await waitForLiveView(page);
      await expect(
        page.locator("#gtfs-sub-nav a[aria-current='page']"),
      ).toHaveText("Import");
      await expect(page.locator("#gtfs-import-upload")).toBeVisible();
      await capture(page, testInfo, `gtfs-import-${label}`);
      await expectNoPageOverflow(page);

      // ── Transfers is the Routes area's second tab ──
      await page.goto(`/gtfs/${versionId}/routes`);
      await page.locator("#routes-tab-transfers").click();
      await page.waitForURL(/\/transfers$/);
      await waitForLiveView(page);

      await expect(
        page.locator("#routes-tabs a[aria-current='page']"),
      ).toHaveText("Transfers");
      await expect(page.locator("#transfers-page")).toBeVisible();
      await expect(page.locator("h1")).toHaveText("Transfers");
      await expect(page.locator("#coming-soon-status")).toHaveCount(0);
      await expect(
        page.locator("#main-navigation #nav-routes"),
      ).toHaveAttribute("aria-current", "page");
      await capture(page, testInfo, `transfers-${label}`);
      await expectNoPageOverflow(page);

      // ── Operations covers Blocks, Runs and Rosters ──
      await page.locator("#main-navigation #nav-operations").click();
      await page.waitForURL(/\/blocks$/);
      await waitForLiveView(page);
      await expect(page.locator("h1")).toHaveText("Blocks");
      await expect(
        page.locator("#operations-sub-nav a[aria-current='page']"),
      ).toHaveText("Blocks");
      await capture(page, testInfo, `operations-${label}`);

      for (const [tab, title] of [
        ["operations-tab-runs", "Runs"],
        ["operations-tab-rosters", "Rosters"],
        ["operations-tab-blocks", "Blocks"],
      ]) {
        await page.locator(`#${tab}`).click();
        await page.waitForURL(new RegExp(`/${title.toLowerCase()}$`));
        await waitForLiveView(page);

        await expect(page.locator("h1")).toHaveText(title);
        await expect(
          page.locator("#operations-sub-nav a[aria-current='page']"),
        ).toHaveCount(1);
        await expect(
          page.locator("#operations-sub-nav a[aria-current='page']"),
        ).toHaveText(title);
        await expectNoPageOverflow(page);
      }

      // ── Flex has a task link and no area bar ──
      await page.locator("#main-navigation #nav-flex").click();
      await page.waitForURL(/\/flex$/);
      await waitForLiveView(page);
      await expect(page.locator("h1")).toHaveText("Flex");
      await expect(page.locator("#main-navigation #nav-flex")).toHaveAttribute(
        "aria-current",
        "page",
      );
      await capture(page, testInfo, `flex-${label}`);
      await expectNoPageOverflow(page);

      // ── Settings is the account menu's first item, under the organization ──
      const panel = await openAccountMenu(page);
      await expect(panel).toContainText(ORGANIZATION_NAME);
      await expect(panel.locator("#settings-link")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/settings`,
      );
      await expect(panel.locator("#settings-link")).toContainText(
        "Agencies, fares, exports, garages, fleet",
      );
      await expect(panel.locator("[role='menuitem']").first()).toHaveAttribute(
        "id",
        "settings-link",
      );
      await capture(page, testInfo, `account-menu-${label}`);
      await expectHeaderTargetsAreLargeEnough(page);

      await panel.locator("#settings-link").click();
      await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings$`));
      await waitForLiveView(page);

      await expect(page.locator("#settings-overview")).toBeVisible();
      await expect(
        page.locator("#main-navigation a[aria-current='page']"),
      ).toHaveCount(0);
      await expect(
        page.locator("#settings-nav a[aria-current='page']"),
      ).toHaveCount(1);
      await expect(page.locator("h1")).toHaveText("Settings");
      await capture(page, testInfo, `settings-${label}`);
      await expectNoPageOverflow(page);

      // ── The five allowlisted sections render their shared body ──
      for (const [tab, title, slug] of SETTINGS_SECTIONS) {
        await page.locator(`#${tab}`).click();
        await page.waitForURL(new RegExp(`/settings/${slug}$`));
        await waitForLiveView(page);

        await expect(page.locator("h1")).toHaveText(title);
        await expect(page.locator("#coming-soon-status")).toHaveText(
          /Coming soon/,
        );
        await expect(
          page.locator("#coming-soon form, #coming-soon button"),
        ).toHaveCount(0);
        await expect(
          page.locator("#settings-nav a[aria-current='page']"),
        ).toHaveCount(1);
      }

      await capture(page, testInfo, `settings-section-${label}`);

      // ── The moved Garages and Fleet pages keep the Settings bar ──
      await page.locator("#settings-tab-garages").click();
      await page.waitForURL(/\/settings\/garages$/);
      await waitForLiveView(page);
      await expect(page.locator("h1")).toHaveText("Garages");
      await expect(
        page.locator("#settings-nav a[aria-current='page']"),
      ).toHaveText("Garages");
      await expect(
        page.locator("#main-navigation a[aria-current='page']"),
      ).toHaveCount(0);
      await capture(page, testInfo, `garages-${label}`);

      await page.locator("#settings-tab-fleet").click();
      await page.waitForURL(/\/settings\/fleet$/);
      await waitForLiveView(page);
      await expect(page.locator("h1")).toHaveText("Fleet");
      await expect(
        page.locator("#settings-nav a[aria-current='page']"),
      ).toHaveText("Fleet");
      await capture(page, testInfo, `fleet-${label}`);
      await expectNoPageOverflow(page);

      // ── Evolutions is a station tab below the station heading ──
      await page.goto(`/gtfs/${versionId}/stops/${STATION}`);
      await page.waitForSelector("#station-sub-nav");
      await waitForLiveView(page);
      await page.locator("#station-tab-evolutions").click();
      await page.waitForURL(/\/evolutions$/);
      await waitForLiveView(page);

      await expect(page.locator("#coming-soon-status")).toHaveText(
        /Coming soon/,
      );
      await expect(page.locator("h1")).toHaveCount(1);
      await expect(
        page.locator("#station-sub-nav a[aria-current='page']"),
      ).toHaveText("Evolutions");
      await capture(page, testInfo, `evolutions-${label}`);
      await expectNoPageOverflow(page);

      // ── Alignment stays inside the existing pattern task flow ──
      await page.goto(
        `/gtfs/${versionId}/routes/${SCHEDULES_ROUTE}/patterns/${SCHEDULE_PATTERN}`,
      );
      await page.waitForSelector("#pattern-tabs");
      await waitForLiveView(page);
      await page.locator("#pattern-task-alignment").click();
      await expect(page).toHaveURL(/task=alignment/);
      await expect(page.locator("#coming-soon")).toBeVisible();

      await expect(page.locator("h1")).toHaveCount(1);
      await expect(page.locator("#coming-soon-title")).toHaveText("Alignment");
      await expect(
        page.locator("#main-navigation #nav-routes"),
      ).toHaveAttribute("aria-current", "page");
      await capture(page, testInfo, `alignment-${label}`);
      await expectNoPageOverflow(page);

      // ── The version menu lists versions first, then Rename version… ──
      const versionPanel = await openVersionMenu(page);
      await expect(versionPanel.locator("p")).toHaveText("Switch version");

      const menuItems = versionPanel.locator("[role='menuitem']");
      await expect(menuItems.first()).toHaveAttribute(
        "data-version-option",
        "",
      );
      await expect(menuItems.last()).toHaveAttribute(
        "id",
        "gtfs-version-rename",
      );
      await expect(versionPanel.locator("#gtfs-version-rename")).toHaveText(
        "Rename version…",
      );
      await expect(
        versionPanel.locator("[data-version-option]").first(),
      ).toHaveAttribute("aria-current", "true");
      await capture(page, testInfo, `version-menu-${label}`);

      await page.keyboard.press("Escape");
      await expect(versionPanel).toBeHidden();

      expect(failedFonts).toEqual([]);
      expect(pageErrors).toEqual([]);
    });
  });
}

test.describe("header presentation", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("one aligned row, design-system fonts in the header and Inter in the page", async ({
    page,
  }) => {
    const failedFonts = watchFontRequests(page);

    await logIn(page);
    await waitForLiveView(page);
    const versionId = await seededVersionId(page);
    await page.goto(`/gtfs/${versionId}/routes`);
    await waitForLiveView(page);

    // One row: the header stays at its single-row height.
    const headerBox = await page.locator("#app-header").boundingBox();
    expect(headerBox.height).toBeLessThan(120);

    // The tool cluster shares the task links' row.
    const navBox = await page.locator("#main-navigation").boundingBox();
    const triggerBox = await page
      .locator("#user-menu [data-user-menu-trigger]")
      .boundingBox();
    expect(Math.abs(navBox.y - triggerBox.y)).toBeLessThan(40);
    expect(triggerBox.y + triggerBox.height).toBeLessThanOrEqual(
      navBox.y + navBox.height + 40,
    );

    // The product name and the page h1 share a left edge.
    const brandBox = await page
      .locator("#app-header a[aria-label='Pathways Studio - Go to homepage']")
      .boundingBox();
    const h1Box = await page.locator("main h1").first().boundingBox();
    expect(Math.abs(brandBox.x - h1Box.x)).toBeLessThanOrEqual(1);

    // The header uses the design system's face; the page keeps Inter.
    const headerFont = await page
      .locator("#app-header")
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(headerFont).toContain("Figtree");

    const h1Font = await page
      .locator("main h1")
      .first()
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(h1Font).toContain("Inter");
    expect(h1Font).not.toContain("Figtree");

    const productFont = await page
      .locator(
        "#app-header a[aria-label='Pathways Studio - Go to homepage'] span",
      )
      .first()
      .evaluate((el) => getComputedStyle(el).fontFamily);
    expect(productFont).toContain("Gabarito");

    // Both families are loaded from the app's own static files.
    const loaded = await page.evaluate(async () => {
      await document.fonts.ready;
      return [...document.fonts].map((face) => `${face.family} ${face.weight}`);
    });
    expect(loaded).toContain("Figtree 400");
    expect(loaded).toContain("Figtree 600");
    expect(loaded).toContain("Gabarito 600");

    expect(
      await page.evaluate(() => document.fonts.check("600 14px Figtree")),
    ).toBe(true);
    expect(
      await page.evaluate(() => document.fonts.check("600 21px Gabarito")),
    ).toBe(true);

    // The trigger shows the seeded editor's initials, worked out from the email.
    await expect(
      page.locator("#user-menu [data-user-menu-trigger] span").first(),
    ).toHaveText(EDITOR_INITIALS);
    await expect(
      page.locator("#user-menu [data-user-menu-trigger]"),
    ).toHaveAttribute("aria-label", `Account menu for ${EDITOR.email}`);

    // Keyboard focus uses the design system's two-pixel outline.
    await page.keyboard.press("Tab"); // skip to main content
    await page.keyboard.press("Tab"); // product link
    await page.keyboard.press("Tab"); // Routes

    expect(await page.evaluate(() => document.activeElement?.id)).toBe(
      "nav-routes",
    );

    const outline = await page
      .locator("#nav-routes")
      .evaluate((el) => getComputedStyle(el));
    expect(parseFloat(outline.outlineWidth)).toBeGreaterThanOrEqual(2);
    expect(outline.outlineStyle).not.toBe("none");

    expect(failedFonts).toEqual([]);
  });

  test("keyboard opens the account menu, follows Settings and scrolls an offscreen tab", async ({
    page,
  }) => {
    await logIn(page);
    await waitForLiveView(page);
    const versionId = await seededVersionId(page);
    await page.goto(`/gtfs/${versionId}/routes`);
    await waitForLiveView(page);

    // Tab from the top of the document to the account trigger.
    let reachedTrigger = false;
    for (let i = 0; i < 25 && !reachedTrigger; i += 1) {
      await page.keyboard.press("Tab");
      reachedTrigger = await page.evaluate(() =>
        document.activeElement?.hasAttribute("data-user-menu-trigger"),
      );
    }
    expect(reachedTrigger).toBe(true);

    await page.keyboard.press("Enter");
    await expect(page.locator("#user-menu-panel")).toBeVisible();
    await expect(page.locator("#settings-link")).toBeFocused();

    await page.keyboard.press("Enter");
    await page.waitForURL(new RegExp(`/gtfs/${versionId}/settings$`));
    await waitForLiveView(page);
    await expect(page.locator("#settings-overview")).toBeVisible();

    // The Settings bar scrolls locally: the last tab must be reachable and
    // visible inside the bar without overflowing the document.
    const bar = page.locator("#settings-nav");
    const lastTab = page.locator("#settings-tab-fleet");

    await lastTab.scrollIntoViewIfNeeded();
    await expect(lastTab).toBeVisible();

    const barBox = await bar.boundingBox();
    const tabBox = await lastTab.boundingBox();
    expect(tabBox.x).toBeGreaterThanOrEqual(barBox.x - 1);
    expect(tabBox.x + tabBox.width).toBeLessThanOrEqual(
      barBox.x + barBox.width + 1,
    );
    await expectNoPageOverflow(page);

    // Reaching it with the keyboard keeps it inside the bar as well.
    let reachedLastTab = false;
    for (let i = 0; i < 40 && !reachedLastTab; i += 1) {
      await page.keyboard.press("Tab");
      reachedLastTab = await page.evaluate(() =>
        document.activeElement?.matches("#settings-tab-fleet"),
      );
    }
    expect(reachedLastTab).toBe(true);

    const focusedTabBox = await lastTab.boundingBox();
    expect(focusedTabBox.x).toBeGreaterThanOrEqual(barBox.x - 1);
    await expectNoPageOverflow(page);
  });
});

test.describe("organization administrator fallback", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("the account menu sends an org-admin-only login to Users", async ({
    page,
  }, testInfo) => {
    await logIn(page, ORG_ADMIN);
    await waitForLiveView(page);

    const panel = await openAccountMenu(page);
    await expect(panel).toContainText(ADMIN_ORGANIZATION_NAME);

    const settings = panel.locator("#settings-link");
    await expect(settings).toHaveAttribute("href", "/admin/users");
    await expect(settings).toContainText("Organization name, users");
    await expect(
      page.locator("#main-navigation a[href*='/gtfs/']"),
    ).toHaveCount(0);
    await capture(page, testInfo, "admin-settings-desktop");

    await settings.click();
    await page.waitForURL(/\/admin\/users$/);
    await waitForLiveView(page);

    // The Settings item is current on the Users family, and the trigger too.
    await expect(
      page.locator("#settings-link[aria-current='page']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#user-menu [data-user-menu-trigger][data-current='true']"),
    ).toBeVisible();
    await expect(
      page.locator("#main-navigation a[aria-current='page']"),
    ).toHaveCount(0);
    await expectNoPageOverflow(page);
  });
});
