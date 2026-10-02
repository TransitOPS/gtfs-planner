import { test, expect } from "@playwright/test";
import {
  VIEWPORTS,
  bodyFitsViewport,
  readPendingStates,
  watchPendingState,
} from "./browser_helpers.js";

// Account design contracts (Package 11).
// Step 3 owns the account-navigation block. Step 4 owns the dashboard block.
// Step 5 owns the account-settings block. Step 8 owns mutation credentials.

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const SYSTEM_ADMIN_USER = {
  email: "browser-test@gtfs-planner.test",
  password: "BrowserTest123!",
};

const ORG_ADMIN_USER = {
  email: "admin-contracts@gtfs-planner.test",
  password: "AdminContracts123!",
};

// Package 11 dedicated seeds (test/support/browser_seed.exs). Credentials are
// test-only mirrors; never application config.
const NO_VERSION_USER = {
  email: "account-no-version@gtfs-planner.test",
  password: "AccountNoVersion123!",
};

const NO_TASK_USER = {
  email: "account-no-task@gtfs-planner.test",
  password: "AccountNoTask123!",
};

// 26-homepage seeds (test/support/browser_seed.exs). The homepage body's states
// are the planner attention page, the planner team list, the pathways board and
// the access states above/below.
const PLANNER_HOME_USER = {
  email: "home-planner@gtfs-planner.test",
  password: "BrowserTest123!",
};

const PLANNER_MEMBER_USER = {
  email: "home-planner-member@gtfs-planner.test",
  password: "BrowserTest123!",
};

const PATHWAYS_HOME_USER = {
  email: "home-pathways@gtfs-planner.test",
  password: "BrowserTest123!",
};

const SETTINGS_USER = {
  email: "account-settings@gtfs-planner.test",
  password: "AccountSettings123!",
};

// One-use password mutation per `bin/test-browser` database.
const PASSWORD_MUTATE_USER = {
  email: "account-password-mutate@gtfs-planner.test",
  password: "AccountPassword123!",
};

const DASHBOARD_STATE_ROOTS = [
  "#dashboard-system-administrator",
  "#home-planner",
  "#home-pathways",
  "#dashboard-no-version",
  "#dashboard-no-organization",
  "#dashboard-organization-unavailable",
  "#dashboard-no-task-access",
  "#home-admin-only",
];

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");
  // The form is a LiveView: a field filled or a submit sent before the join is
  // reset by the first patch or posted without it.
  await waitForLiveView(page);
  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function openDashboard(page, user) {
  await logIn(page, user);
  await page.goto("/");
  await waitForLiveView(page);
}

async function visibleDashboardRoot(page) {
  for (const id of DASHBOARD_STATE_ROOTS) {
    const loc = page.locator(id);
    if ((await loc.count()) > 0 && (await loc.isVisible())) {
      return id;
    }
  }
  return null;
}

// Resolves once the main LiveView has joined, so hook-owned controls such as the
// account menu are mounted. The server-rendered page is visible before that.
async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return (
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending")
    );
  });
  await page.evaluate(async () => {
    if (document.fonts?.ready) await document.fonts.ready;
  });
}

// The seeded clock and date strings move with the seed run, and a masked box
// follows the masked text's width in a proportional font, so the content-sized
// masked regions are pinned to fixed inline sizes: the captured geometry is then
// identical at 1:15 AM and 10:15 AM UTC and on any run date, and no comparison
// tolerance is involved. Every pinned width is the two-digit-hour worst case
// rounded up (`#fact-created` carries the seed run's account-created date). The
// widths are asserted after pinning so a mask whose box stops being fixed fails
// here instead of flaking the reviewed screenshot.
// Full timestamps include the year; reserve room for the canonical display.
const PINNED_MASK_WIDTHS = [
  ["#resume-list .tabular-nums.text-muted", 160],
  ["#check-time", 160],
  ["#export-meta", 224],
  ["#editing-now span", 152],
  ["#export-line", 176],
  ["#fact-created", 104],
];

// Playwright clips an element screenshot at the element's box, and a fractional
// page scroll offset can move that clip boundary by one device pixel, so the
// reviewed element screenshots are taken from the top of the page.
async function scrollToTop(page) {
  await page.evaluate(() =>
    window.scrollTo({ top: 0, left: 0, behavior: "instant" }),
  );
  await page.waitForFunction(() => window.scrollY === 0);
}

async function pinMaskGeometry(page) {
  await page.addStyleTag({
    content: PINNED_MASK_WIDTHS.map(
      ([selector, width]) => `${selector} { inline-size: ${width}px; }`,
    ).join("\n"),
  });

  const pinned = await page.evaluate(
    (specs) =>
      specs.map(([selector, expected]) => ({
        selector,
        expected,
        boxes: [...document.querySelectorAll(selector)].map((el) => ({
          width: Math.round(el.getBoundingClientRect().width),
          overflow: el.scrollWidth - el.clientWidth,
        })),
      })),
    PINNED_MASK_WIDTHS,
  );

  for (const { selector, expected, boxes } of pinned) {
    for (const { width, overflow } of boxes) {
      expect(width, `${selector} masked width is pinned`).toBe(expected);
      expect(overflow, `${selector} content fits its pinned masked box`).toBeLessThanOrEqual(0);
    }
  }
}

async function captureTargetMetrics(locator) {
  return locator.evaluate((el) => {
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      height: rect.height,
      width: rect.width,
      fontWeight: style.fontWeight,
    };
  });
}

// The homepage's regions load asynchronously once the client is connected, so
// every homepage measurement waits for the connected marker and for the
// region skeletons to be gone before it reads geometry.
async function waitForHomeRegions(page) {
  await waitForLiveView(page);
  await page.waitForSelector("[data-phx-main].phx-connected", { state: "attached" });
  await expect(
    page.locator(
      "#resume-loading, #share-loading, #attention-loading, #board-loading",
    ),
  ).toHaveCount(0);
}

async function capturePrimaryMetrics(locator) {
  return locator.evaluate((el) => {
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      backgroundColor: style.backgroundColor,
      height: rect.height,
      width: rect.width,
    };
  });
}

async function focusVisible(page, locator) {
  await locator.focus();
  return locator.evaluate((el) => {
    const style = window.getComputedStyle(el);
    const outlineVisible =
      style.outlineStyle !== "none" && parseFloat(style.outlineWidth || "0") > 0;
    const ringVisible =
      style.boxShadow !== "none" && style.boxShadow.includes("rgb");
    return {
      isFocused: document.activeElement === el,
      outlineVisible,
      ringVisible,
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      boxShadow: style.boxShadow,
    };
  });
}

async function openSettings(page, user = EDITOR_USER) {
  await logIn(page, user);
  await page.goto("/users/settings");
  await waitForLiveView(page);
  await page.waitForSelector("#account-page");
}

async function captureFormFieldMetrics(page, formSelector) {
  return page.locator(formSelector).evaluate((form) => {
    // Core input wraps label text in span.label above the control inside <label>.
    const labelText = form.querySelector("label span.label");
    const input = form.querySelector("input:not([type='hidden'])");
    const help = form.querySelector("[id$='-help']");
    const button = form.querySelector("button[type='submit'], button.btn");
    const labelRect = labelText?.getBoundingClientRect();
    const inputRect = input?.getBoundingClientRect();
    const helpRect = help?.getBoundingClientRect();
    const buttonRect = button?.getBoundingClientRect();
    const inputStyle = input ? window.getComputedStyle(input) : null;
    return {
      formWidth: form.getBoundingClientRect().width,
      labelAboveInput:
        labelRect && inputRect ? labelRect.bottom <= inputRect.top + 4 : false,
      inputHeight: inputRect?.height ?? 0,
      buttonHeight: buttonRect?.height ?? 0,
      buttonWidth: buttonRect?.width ?? 0,
      buttonClass: typeof button?.className === "string" ? button.className : "",
      inputBorderWidth: inputStyle?.borderTopWidth ?? "",
      helpGap:
        helpRect && inputRect ? helpRect.top - inputRect.bottom : null,
      fontSize: inputStyle?.fontSize ?? "",
    };
  });
}

test.describe.configure({ mode: "serial" });

test.describe("account navigation", () => {
  test("reference header geometry and account link contracts across viewports", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto("/design/navigation");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-page-navigation");
    await page.waitForSelector("#ds-header-demo");

    const referenceButton = page.locator("#ds-header-demo button").first();
    await expect(referenceButton).toBeVisible();
    const referenceMetrics = await captureTargetMetrics(referenceButton);
    expect(referenceMetrics.height).toBeGreaterThanOrEqual(32);

    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.waitForSelector("#app-header nav[aria-label='Main navigation']");

    // Account actions moved out of the task nav into the header account menu.
    await expect(
      page.locator(
        "#app-header nav[aria-label='Main navigation'] a[href='/users/settings']",
      ),
    ).toHaveCount(0);

    const menuTrigger = page.locator("#user-menu [data-user-menu-trigger]");
    await expect(menuTrigger).toBeVisible();
    await expect(menuTrigger).toHaveAttribute("aria-expanded", "false");
    const triggerMetrics = await captureTargetMetrics(menuTrigger);
    expect(triggerMetrics.height).toBeGreaterThanOrEqual(44);

    await menuTrigger.click();
    await expect(menuTrigger).toHaveAttribute("aria-expanded", "true");

    const accountLink = page.locator("#user-menu-panel a[href='/users/settings']");
    await expect(accountLink).toBeVisible();
    await expect(accountLink).toHaveAttribute("aria-current", "page");
    await expect(accountLink).toContainText("Profile settings");

    const accountMetrics = await captureTargetMetrics(accountLink);
    expect(accountMetrics.height).toBeGreaterThanOrEqual(44);

    expect(Number.parseInt(accountMetrics.fontWeight, 10)).toBeGreaterThanOrEqual(
      600,
    );

    const focus = await focusVisible(page, accountLink);
    expect(focus.isFocused).toBe(true);
    expect(focus.outlineVisible || focus.ringVisible).toBe(true);

    // Escape closes the menu and returns focus to the trigger.
    await page.keyboard.press("Escape");
    await expect(menuTrigger).toHaveAttribute("aria-expanded", "false");
    await expect(accountLink).toBeHidden();
    expect(await menuTrigger.evaluate((el) => el === document.activeElement)).toBe(
      true,
    );

    for (const viewport of VIEWPORTS) {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.goto("/users/settings");
      await waitForLiveView(page);
      await page.waitForSelector(
        "#app-header nav[aria-label='Main navigation']",
      );

      expect(await bodyFitsViewport(page)).toBe(true);

      const trigger = page.locator("#user-menu [data-user-menu-trigger]");
      await expect(trigger).toBeVisible();
      const triggerBox = await trigger.boundingBox();
      expect(triggerBox).not.toBeNull();
      expect(triggerBox.height).toBeGreaterThanOrEqual(44);

      await trigger.click();
      await expect(trigger).toHaveAttribute("aria-expanded", "true");

      const menuAccountLink = page.locator(
        "#user-menu-panel a[href='/users/settings']",
      );
      await expect(menuAccountLink).toBeVisible();
      const box = await menuAccountLink.boundingBox();
      expect(box).not.toBeNull();
      expect(box.height).toBeGreaterThanOrEqual(44);

      const focused = await focusVisible(page, menuAccountLink);
      expect(focused.isFocused).toBe(true);
      expect(focused.outlineVisible || focused.ringVisible).toBe(true);
    }
  });

  test("reviewed #app-header screenshots at narrow and desktop widths", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.waitForSelector("#app-header");

    const header = page.locator("#app-header");
    const mask = [
      page.locator("#app-brand"),
      page.locator("#gtfs-version-switcher"),
    ];

    for (const { width, height, label } of [
      { width: 320, height: 568, label: "320" },
      { width: 1280, height: 800, label: "1280" },
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto("/users/settings");
      await waitForLiveView(page);
      await expect(header).toBeVisible();

      const trigger = page.locator("#user-menu [data-user-menu-trigger]");
      await trigger.click();
      await expect(trigger).toHaveAttribute("aria-expanded", "true");
      await expect(page.locator("#user-menu-panel")).toBeVisible();

      await expect(header).toHaveScreenshot(
        `account-header-${label}.png`,
        {
          animations: "disabled",
          mask,
        },
      );
    }
  });
});

test.describe("dashboard", () => {
  test("homepage states use design-system tokens and one primary action", async ({
    page,
  }) => {
    // Planner attention state (the seeded calendars end in ten days).
    await openDashboard(page, PLANNER_HOME_USER);
    await waitForHomeRegions(page);
    await page.waitForSelector("#attention");
    await expect(page.locator("#home-planner")).toBeVisible();

    const plannerH1 = page.locator("#home-planner h1").first();
    await expect(plannerH1).toBeVisible();
    const plannerH1Metrics = await plannerH1.evaluate((el) => {
      const style = window.getComputedStyle(el);
      return { family: style.fontFamily, size: style.fontSize };
    });
    expect(plannerH1Metrics.family).toContain("Gabarito");
    expect(plannerH1Metrics.size).toBe("30px");

    await expect(page.locator("#home-page .bg-action:visible")).toHaveCount(1);
    const plannerPrimary = page.locator("#home-page .bg-action:visible").first();
    await expect(plannerPrimary).toContainText("Open calendars");
    const plannerPrimaryMetrics = await capturePrimaryMetrics(plannerPrimary);
    expect(plannerPrimaryMetrics.backgroundColor).toBe("rgb(200, 24, 112)");
    expect(plannerPrimaryMetrics.height).toBeGreaterThanOrEqual(44);
    expect(plannerPrimaryMetrics.width).toBeGreaterThanOrEqual(44);

    // The homepage body must not leak daisyUI button styling (FH-12).
    await expect(
      page.locator(
        "#home-page .btn, #home-page .btn-primary, #home-page .btn-outline",
      ),
    ).toHaveCount(0);

    const plannerFocus = await focusVisible(page, plannerPrimary);
    expect(plannerFocus.isFocused).toBe(true);
    expect(plannerFocus.outlineVisible || plannerFocus.ringVisible).toBe(true);

    // Pathways board state.
    await page.context().clearCookies();
    await openDashboard(page, PATHWAYS_HOME_USER);
    await waitForHomeRegions(page);
    await page.waitForSelector("#board-rows tr");
    await expect(page.locator("#home-pathways h1")).toHaveText("Stations");
    await expect(page.locator("#home-page .bg-action:visible")).toHaveCount(1);
    const pathwaysPrimary = page.locator("#home-page .bg-action:visible").first();
    await expect(pathwaysPrimary).toContainText("Open floorplan");
    expect((await capturePrimaryMetrics(pathwaysPrimary)).backgroundColor).toBe(
      "rgb(200, 24, 112)",
    );

    // System administrator primary action.
    await page.context().clearCookies();
    await openDashboard(page, SYSTEM_ADMIN_USER);
    await waitForHomeRegions(page);
    await page.waitForSelector("#dashboard-system-administrator");
    const adminPrimary = page.locator(
      "#dashboard-system-administrator .bg-action[href='/admin/organizations']",
    );
    await expect(adminPrimary).toContainText("Manage organizations");
    expect((await capturePrimaryMetrics(adminPrimary)).height).toBeGreaterThanOrEqual(
      44,
    );

    // Dedicated no-version seed: the warning callout, no GTFS destination and
    // no primary action.
    await page.context().clearCookies();
    await openDashboard(page, NO_VERSION_USER);
    await page.waitForSelector("#dashboard-no-version");
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    await expect(page.locator("#dashboard-no-version")).toContainText(
      "There is no service data to work on yet",
    );
    await expect(page.locator("#dashboard-no-version .bg-warning-bg")).toHaveCount(1);
    await expect(page.locator("#home-page .bg-action")).toHaveCount(0);

    // Organization admin without editor: Manage users is the only primary.
    await page.context().clearCookies();
    await openDashboard(page, ORG_ADMIN_USER);
    await waitForHomeRegions(page);
    await page.waitForSelector("#home-admin-only");
    const orgAdminPrimary = page.locator(
      "#home-admin-only .bg-action[href='/admin/users']",
    );
    await expect(orgAdminPrimary).toContainText("Manage users");
    expect((await capturePrimaryMetrics(orgAdminPrimary)).height).toBeGreaterThanOrEqual(
      44,
    );
    await expect(page.locator("#home-admin-only")).toContainText(
      "needs the Editor role",
    );
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);

    // No task access: no primary and no administration destination.
    await page.context().clearCookies();
    await openDashboard(page, NO_TASK_USER);
    await page.waitForSelector("#dashboard-no-task-access");
    await expect(page.locator("#dashboard-no-task-access")).toContainText(
      "cannot edit yet",
    );
    await expect(page.locator("#home-page .bg-action")).toHaveCount(0);
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
  });

  test("each homepage state reflows without overflow at required viewports", async ({
    page,
  }) => {
    test.setTimeout(600_000);

    const scenarios = [
      {
        user: PLANNER_HOME_USER,
        root: "#home-planner",
        ready: "#attention",
        label: "planner-attention",
      },
      {
        user: PLANNER_MEMBER_USER,
        root: "#home-planner",
        ready: "#resume-list li:not(#resume-empty)",
        label: "planner-new-member",
      },
      {
        user: PATHWAYS_HOME_USER,
        root: "#home-pathways",
        ready: "#board-rows tr",
        label: "pathways-board",
      },
      {
        user: ORG_ADMIN_USER,
        root: "#home-admin-only",
        ready: "#home-admin-only",
        label: "admin-only",
      },
      {
        user: SYSTEM_ADMIN_USER,
        root: "#dashboard-system-administrator",
        ready: "#dashboard-system-administrator",
        label: "system-admin",
      },
      {
        user: NO_VERSION_USER,
        root: "#dashboard-no-version",
        ready: "#dashboard-no-version",
        label: "no-version",
      },
      {
        user: NO_TASK_USER,
        root: "#dashboard-no-task-access",
        ready: "#dashboard-no-task-access",
        label: "no-task",
      },
    ];

    for (const scenario of scenarios) {
      await page.context().clearCookies();
      await openDashboard(page, scenario.user);
      await waitForHomeRegions(page);
      await page.waitForSelector(scenario.root);

      expect(await visibleDashboardRoot(page), `${scenario.label} root`).toBe(
        scenario.root,
      );

      for (const viewport of VIEWPORTS) {
        await page.setViewportSize({
          width: viewport.width,
          height: viewport.height,
        });
        await page.goto("/");
        await waitForHomeRegions(page);
        await page.waitForSelector(scenario.root);
        await page.waitForSelector(scenario.ready, { state: "visible" });

        expect(
          await bodyFitsViewport(page),
          `${scenario.label} overflow at ${viewport.label}`,
        ).toBe(true);

        const actions = page.locator(
          "#home-page a:visible, #home-page button:visible, #home-page input:visible",
        );
        const count = await actions.count();
        for (let i = 0; i < count; i++) {
          const action = actions.nth(i);
          const box = await action.boundingBox();
          expect(box).not.toBeNull();
          expect(box.height).toBeGreaterThanOrEqual(44);
        }

        const h1Count = await page.locator(`${scenario.root} h1`).count();
        expect(h1Count).toBe(1);

        const primaries = await page.locator("#home-page .bg-action:visible").count();
        expect(primaries).toBeLessThanOrEqual(1);
      }
    }
  });

  test("dedicated no-version and no-task seeds render truthful roots", async ({
    page,
  }) => {
    await openDashboard(page, NO_VERSION_USER);
    await page.waitForSelector("#dashboard-no-version");
    await expect(page.locator("#dashboard-no-version")).toBeVisible();
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    await expect(page.locator("#dashboard-no-version")).toContainText(
      "There is no service data to work on yet",
    );
    // Authorized org name may appear; GTFS destinations must not.
    await expect(page.locator("#dashboard-no-version h1")).toHaveCount(1);
    await expect(page.locator("#home-page .bg-action")).toHaveCount(0);

    await page.context().clearCookies();
    await openDashboard(page, NO_TASK_USER);
    await page.waitForSelector("#dashboard-no-task-access");
    await expect(page.locator("#dashboard-no-task-access")).toBeVisible();
    await expect(page.locator("#dashboard-no-task-access")).toContainText(
      "cannot edit yet",
    );
    await expect(page.locator("#dashboard-no-task-access h1")).toHaveCount(1);
    await expect(page.locator("#home-page .bg-action")).toHaveCount(0);
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    await expect(page.locator("a[href='/admin/users']")).toHaveCount(0);
    await expect(page.locator("a[href='/admin/organizations']")).toHaveCount(0);
  });

  test("reviewed dashboard state screenshots", async ({ page }) => {
    test.setTimeout(180_000);

    // The seeded dates move with the seed run date, so the planner page's
    // lede, attention copy and clock times are masked; its layout, chrome,
    // tones and single primary stay reviewed.
    const openAt1280 = async (user, root, ready) => {
      await page.context().clearCookies();
      await openDashboard(page, user);
      await waitForHomeRegions(page);
      await page.waitForSelector(ready, { state: "visible" });
      await page.setViewportSize({ width: 1280, height: 800 });
      await page.goto("/");
      await waitForHomeRegions(page);
      await page.waitForSelector(ready, { state: "visible" });
      await expect(page.locator(root)).toBeVisible();
      await pinMaskGeometry(page);
    };

    await openAt1280(PLANNER_HOME_USER, "#home-planner", "#attention");
    await expect(page.locator("#home-planner")).toHaveScreenshot(
      "home-planner-1280.png",
      {
        animations: "disabled",
        mask: [
          page.locator("#home-lede"),
          page.locator("#attention h3"),
          page.locator("#attention p"),
          page.locator("#check-time"),
          page.locator("#export-meta"),
          page.locator("#resume-latest-context"),
          // The row clock, not the route badges: `RouteIdentity.route_badge`
          // also carries `tabular-nums`, so the mask pins the muted time span.
          // The row's kind-and-change line carries seeded dates too, such as
          // "Calendar · end date moved to Nov 28".
          page.locator("#resume-list .tabular-nums.text-muted"),
          page.locator("#resume-list span.block.truncate.text-muted"),
        ],
      },
    );

    // The board's last-edited times and the rail's clock times move with the
    // seed run date.
    await openAt1280(PATHWAYS_HOME_USER, "#home-pathways", "#board-rows tr");
    await expect(page.locator("#home-pathways")).toHaveScreenshot(
      "home-pathways-1280.png",
      {
        animations: "disabled",
        mask: [
          page.locator(
            "#board-table tbody td:last-child span.block:not(.truncate)",
          ),
          page.locator("#resume-latest-context"),
          page.locator("#editing-now span"),
          page.locator("#export-line"),
        ],
      },
    );

    // System administrator: the organization count follows the seed.
    await openAt1280(
      SYSTEM_ADMIN_USER,
      "#dashboard-system-administrator",
      "#dashboard-system-administrator",
    );
    await expect(page.locator("#dashboard-system-administrator")).toHaveScreenshot(
      "dashboard-system-administrator-1280.png",
      {
        animations: "disabled",
        mask: [page.locator("#dashboard-system-administrator p").first()],
      },
    );

    // Organization admin without editor.
    await openAt1280(ORG_ADMIN_USER, "#home-admin-only", "#home-admin-only");
    await expect(page.locator("#home-admin-only")).toHaveScreenshot(
      "home-admin-only-1280.png",
      { animations: "disabled" },
    );

    // Dedicated no-version seed.
    await openAt1280(
      NO_VERSION_USER,
      "#dashboard-no-version",
      "#dashboard-no-version",
    );
    await expect(page.locator("#dashboard-no-version")).toHaveScreenshot(
      "dashboard-no-version-1280.png",
      { animations: "disabled" },
    );

    // Dedicated no-task seed.
    await openAt1280(
      NO_TASK_USER,
      "#dashboard-no-task-access",
      "#dashboard-no-task-access",
    );
    await expect(page.locator("#dashboard-no-task-access")).toHaveScreenshot(
      "dashboard-no-task-access-1280.png",
      { animations: "disabled" },
    );

    // Missing/unavailable are not browser-login-reachable without a production
    // session bypass. LiveView tests own those non-disclosure branches.
  });
});

test.describe("account settings", () => {
  test("hierarchy, design-reference metrics, geometry, focus, pending, and secret recovery", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    // Non-destructive settings user: keeps EDITOR_USER free of email-change noise.
    await logIn(page, SETTINGS_USER);

    // Design references first.
    await page.goto("/design/inputs");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-inputs-demo-form");
    const refFormMetrics = await captureFormFieldMetrics(
      page,
      "#ds-inputs-demo-form",
    );

    await page.goto("/design/buttons");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-page-buttons");
    const refSecondary = page
      .locator(
        "#ds-page-buttons button.btn-outline, #ds-page-buttons a.btn-outline",
      )
      .first();
    await expect(refSecondary).toBeVisible();
    await expect(refSecondary).toHaveClass(/btn-outline/);

    await page.goto("/design/feedback");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-page-feedback");

    // Production settings.
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.waitForSelector("#account-page");

    await expect(page).toHaveTitle(/Profile settings/);
    await expect(page.locator("#account-settings-title")).toHaveText(
      "Profile settings",
    );
    await expect(page.locator("#email-settings-title")).toHaveText(
      "Email address",
    );
    await expect(page.locator("#password-settings-title")).toHaveText(
      "Password",
    );

    const h1Count = await page.locator("#account-page h1").count();
    expect(h1Count).toBe(1);
    const h2Count = await page.locator("#account-page h2").count();
    expect(h2Count).toBe(4);

    // Each card's submit is its own primary action; the page carries no other
    // primary, so the two card submits are the only two.
    await expect(page.locator("#email-submit")).toHaveClass(/btn-primary/);
    await expect(page.locator("#password-submit")).toHaveClass(/btn-primary/);
    await expect(page.locator("#account-page .btn-primary")).toHaveCount(2);

    const emailMetrics = await captureFormFieldMetrics(page, "#email_form");
    const passwordMetrics = await captureFormFieldMetrics(
      page,
      "#password_form",
    );
    expect(emailMetrics.labelAboveInput).toBe(true);
    expect(passwordMetrics.labelAboveInput).toBe(true);
    expect(emailMetrics.buttonClass).toContain("btn-primary");
    expect(passwordMetrics.buttonClass).toContain("btn-primary");
    // Shared input stack: comparable control height to design demo (±12px tolerance).
    if (refFormMetrics.inputHeight > 0) {
      expect(
        Math.abs(emailMetrics.inputHeight - refFormMetrics.inputHeight),
      ).toBeLessThanOrEqual(12);
    }
    for (const viewport of VIEWPORTS) {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await page.goto("/users/settings");
      await waitForLiveView(page);
      await page.waitForSelector("#account-page");

      expect(
        await bodyFitsViewport(page),
        `settings overflow at ${viewport.label}`,
      ).toBe(true);

      // The redesign's grid puts the email and password cards in the fluid
      // column and the access/facts rail in a fixed 20rem column at lg. Each
      // card fills its column exactly, sits flush with the page container's
      // left gutter, and never crosses its right gutter.
      const pageBox = await page.locator("#account-page").boundingBox();

      for (const sectionId of ["#email-settings", "#password-settings"]) {
        const section = page.locator(sectionId);
        const box = await section.boundingBox();
        const columnWidth = await section.evaluate(
          (el) => el.parentElement.getBoundingClientRect().width,
        );
        expect(box).not.toBeNull();
        expect(box.width).toBeGreaterThan(0);
        expect(Math.abs(box.width - columnWidth)).toBeLessThanOrEqual(1);
        expect(Math.abs(box.x - pageBox.x)).toBeLessThanOrEqual(1);
        expect(box.x + box.width).toBeLessThanOrEqual(
          pageBox.x + pageBox.width + 1,
        );
      }

      if (viewport.width >= 1024) {
        const rail = await page.locator("#sign-in-facts").boundingBox();
        const email = await page.locator("#email-settings").boundingBox();
        expect(Math.abs(rail.width - 320)).toBeLessThanOrEqual(1);
        expect(
          Math.abs(rail.x + rail.width - (pageBox.x + pageBox.width)),
        ).toBeLessThanOrEqual(1);
        expect(rail.x - (email.x + email.width)).toBeGreaterThanOrEqual(16);
      }

      for (const controlId of [
        "#email-address",
        "#email-current-password",
        "#email-submit",
        "#password-current-password",
        "#password-new-password",
        "#password-confirmation",
        "#password-submit",
      ]) {
        const control = page.locator(controlId);
        await expect(control).toBeVisible();
        const box = await control.boundingBox();
        expect(box).not.toBeNull();
        expect(box.height).toBeGreaterThanOrEqual(44);
      }
    }

    // Keyboard order + focus ring once at desktop (visual order contract).
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/users/settings");
    await waitForLiveView(page);

    const tabOrder = [
      "#email-address",
      "#email-current-password",
      "#email-submit",
      "#password-current-password",
      "#password-new-password",
      "#password-confirmation",
      "#password-submit",
    ];
    await page.locator(tabOrder[0]).focus();
    for (let i = 0; i < tabOrder.length; i++) {
      const activeId = await page.evaluate(
        () => document.activeElement && document.activeElement.id,
      );
      expect(activeId).toBe(tabOrder[i].slice(1));
      if (i < tabOrder.length - 1) {
        await page.keyboard.press("Tab");
      }
    }

    const focus = await focusVisible(page, page.locator("#email-submit"));
    expect(focus.isFocused).toBe(true);
    expect(focus.outlineVisible || focus.ringVisible).toBe(true);

    // Pending email submit (MutationObserver before click).
    await page.fill("#email-address", "pending-check@example.com");
    await page.fill("#email-current-password", SETTINGS_USER.password);
    await watchPendingState(page, "#email-submit");
    await page.locator("#email-submit").click();
    await page.waitForSelector("#flash-info", { timeout: 10_000 });
    await waitForLiveView(page);
    const emailPending = await readPendingStates(page);
    expect(
      emailPending.some(
        (s) => s.disabled || s.text.includes("Sending confirmation"),
      ),
    ).toBe(true);

    // Failed email submit (valid email shape, wrong password): secret cleared,
    // proposed email kept, and focus lands on the email error summary, which
    // lists every problem and links to each field (`focus_scoped_target`,
    // FormErrorFocus). Avoid HTML5 type=email blocks.
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.waitForSelector("#account-page");
    const proposedEmail = "different-settings@example.com";
    await page.fill("#email-address", proposedEmail);
    await page.fill("#email-current-password", "wrong-password-value");
    await page.locator("#email-submit").click();
    await page.waitForFunction(
      () =>
        document.querySelector("#email-current-password")?.value === "" &&
        !!document.querySelector("#email_form [aria-invalid='true']"),
      null,
      { timeout: 10_000 },
    );
    await page.waitForFunction(
      () => document.activeElement?.id === "email-error-summary",
      null,
      { timeout: 10_000 },
    );
    await waitForLiveView(page);
    await expect(page.locator("#email-address")).toHaveValue(proposedEmail);
    await expect(page.locator("#email-current-password")).toHaveValue("");
    const focusedAfterEmail = await page.evaluate(
      () => document.activeElement && document.activeElement.id,
    );
    expect(focusedAfterEmail).toBe("email-error-summary");

    // Failed password submit: use long-enough values that pass minlength HTML
    // constraints but fail server confirmation/current-password checks.
    await page.fill("#password-current-password", "wrong-password-value");
    await page.fill("#password-new-password", "shortone12345");
    await page.fill("#password-confirmation", "different12345");
    await watchPendingState(page, "#password-submit");
    await page.locator("#password-submit").click();
    await page.waitForFunction(
      () =>
        document.querySelector("#password-current-password")?.value === "" &&
        !!document.querySelector("#password_form [aria-invalid='true']"),
      null,
      { timeout: 10_000 },
    );
    await page.waitForFunction(
      () => document.activeElement?.id === "password-error-summary",
      null,
      { timeout: 10_000 },
    );
    await waitForLiveView(page);
    const passwordPending = await readPendingStates(page);
    expect(
      passwordPending.some(
        (s) => s.disabled || s.text.includes("Changing password"),
      ),
    ).toBe(true);
    await expect(page.locator("#password-current-password")).toHaveValue("");
    await expect(page.locator("#password-new-password")).toHaveValue("");
    await expect(page.locator("#password-confirmation")).toHaveValue("");
    const focusedAfterPassword = await page.evaluate(
      () => document.activeElement && document.activeElement.id,
    );
    expect(focusedAfterPassword).toBe("password-error-summary");

    // No skeleton/placeholder during synchronous account context mount.
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await expect(
      page.locator(".motion-safe\\:animate-pulse, [aria-busy='true']"),
    ).toHaveCount(0);
    await expect(page.locator("#account-page")).toBeVisible();
  });

  test("reviewed account-settings screenshots at 320/1280/640 with email masked", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    await openSettings(page, SETTINGS_USER);

    const emailMask = [
      page.locator("#email-address"),
      page.locator(`text=${SETTINGS_USER.email}`),
      // The account-created date is the seed run's date, so it is masked and
      // width-pinned like the dashboard's seeded dates.
      page.locator("#fact-created"),
    ];

    for (const { width, height, label } of [
      { width: 320, height: 568, label: "320" },
      { width: 1280, height: 800, label: "1280" },
      { width: 640, height: 400, label: "640" },
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto("/users/settings");
      await waitForLiveView(page);
      await pinMaskGeometry(page);
      const root = page.locator("#account-page");
      await expect(root).toBeVisible();
      await expect(root).toHaveScreenshot(`account-settings-${label}.png`, {
        animations: "disabled",
        mask: emailMask,
      });
    }

    // Deterministic email task error root. The page is scrolled to the top
    // before the element screenshot so the clip boundary lands on the same
    // device row on every run (a fractional scroll offset shifts the card's
    // top border by one pixel).
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.fill("#email-address", "settings-error@example.com");
    await page.fill("#email-current-password", "wrong-password-value");
    await page.locator("#email-submit").click();
    await page.waitForFunction(
      () => document.querySelector("#email_form [aria-invalid='true']"),
    );
    await waitForLiveView(page);
    await scrollToTop(page);
    await expect(page.locator("#email-settings")).toHaveScreenshot(
      "account-settings-email-error-1280.png",
      {
        animations: "disabled",
        mask: [page.locator("#email-address")],
      },
    );

    // Deterministic password task error root.
    await page.fill("#password-current-password", "wrong-password-value");
    await page.fill("#password-new-password", "shortone12345");
    await page.fill("#password-confirmation", "different12345");
    await page.locator("#password-submit").click();
    await page.waitForFunction(
      () => document.querySelector("#password_form [aria-invalid='true']"),
    );
    await waitForLiveView(page);
    await scrollToTop(page);
    await expect(page.locator("#password-settings")).toHaveScreenshot(
      "account-settings-password-error-1280.png",
      {
        animations: "disabled",
      },
    );
  });
});

// ── Reduced motion + reconnect (Step 8) ──
test.describe("account motion and reconnect", () => {
  test("reduced motion removes nonessential delay while state remains visible", async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openSettings(page, SETTINGS_USER);

    expect(
      await page.evaluate(
        () => matchMedia("(prefers-reduced-motion: reduce)").matches,
      ),
    ).toBe(true);

    await page.evaluate(() => window.liveSocket.disconnect());
    await page.waitForSelector("#client-error", {
      state: "visible",
      timeout: 10_000,
    });

    // Layout flash spinner uses motion-safe:animate-spin; under reduce it is none.
    const spinner = page.locator("#client-error .motion-safe\\:animate-spin");
    await expect(spinner).toBeVisible();
    const animation = await spinner.evaluate(
      (el) => window.getComputedStyle(el).animationName,
    );
    expect(animation).toBe("none");

    await page.evaluate(() => window.liveSocket.connect());
    await waitForLiveView(page);
    await expect(page.locator("#client-error")).toBeHidden();

    // Pending/error state changes remain observable under reduced motion.
    await page.fill("#email-address", "motion-check@example.com");
    await page.fill("#email-current-password", "wrong-password-value");
    await page.locator("#email-submit").click();
    await page.waitForFunction(
      () => !!document.querySelector("#email_form [aria-invalid='true']"),
      null,
      { timeout: 10_000 },
    );
    await expect(page.locator("#email_form [aria-invalid='true']").first()).toBeVisible();
    await expect(page.locator("#email-address")).toHaveValue(
      "motion-check@example.com",
    );
    await expect(page.locator(".motion-safe\\:animate-pulse")).toHaveCount(0);
  });

  test("disconnect and reconnect keep account layout reachable", async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await openSettings(page, SETTINGS_USER);
    await expect(page.locator("#account-page")).toBeVisible();

    await page.evaluate(() => window.liveSocket.disconnect());
    await page.waitForSelector("#client-error", { state: "visible", timeout: 10_000 });
    await expect(page.locator("#client-error")).toContainText(/reconnect/i);

    await page.evaluate(() => window.liveSocket.connect());
    await waitForLiveView(page);
    await expect(page.locator("#account-page")).toBeVisible();
    await expect(page.locator("#email-submit")).toBeEnabled();
    await expect(page.locator("#client-error")).toBeHidden();
  });
});

// ── Destructive password handoff (isolated one-use seed) ──
test.describe("account password mutation", () => {
  test("native password success replaces the session for the dedicated user", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    const newPassword = "AccountPasswordChanged456!";

    await openSettings(page, PASSWORD_MUTATE_USER);
    await page.fill("#password-current-password", PASSWORD_MUTATE_USER.password);
    await page.fill("#password-new-password", newPassword);
    await page.fill("#password-confirmation", newPassword);
    // LiveView validates first (trigger_submit), then the form natively POSTs
    // to /users/update_password and re-issues a session on /users/settings.
    const postResponse = page.waitForResponse(
      (res) =>
        res.url().includes("/users/update_password") &&
        res.request().method() === "POST" &&
        res.status() >= 200 &&
        res.status() < 400,
      { timeout: 15_000 },
    );
    await page.locator("#password-submit").click();
    await postResponse;
    await page.waitForURL((url) => url.pathname === "/users/settings", {
      timeout: 15_000,
    });
    await waitForLiveView(page);
    await expect(page.getByText("Password updated successfully.")).toBeVisible({
      timeout: 10_000,
    });
    // Pending MutationObserver is destroyed by the native navigation; success
    // flash + POST response are the durable progress-observer outcomes here.
    // Non-destructive settings tests still capture disabled/pending labels.

    // Old credential must fail after successful change.
    await page.context().clearCookies();
    await page.goto("/users/log_in");
    await expect(page.locator("#login_form")).toBeVisible();
    await page.fill('input[name="user[email]"]', PASSWORD_MUTATE_USER.email);
    await page.fill(
      'input[name="user[password]"]',
      PASSWORD_MUTATE_USER.password,
    );
    await page.locator('button:has-text("Log in")').click();
    await expect(page).toHaveURL(/\/users\/log_in/);
    await expect(page.locator("#login_form")).toBeVisible();
    await expect(page.locator("#login-recovery, #flash-error").first()).toBeVisible({
      timeout: 10_000,
    });

    // New credential authenticates.
    await page.fill('input[name="user[email]"]', PASSWORD_MUTATE_USER.email);
    await page.fill('input[name="user[password]"]', newPassword);
    await page.locator('button:has-text("Log in")').click();
    await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await expect(page.locator("#account-page")).toBeVisible();
  });
});
