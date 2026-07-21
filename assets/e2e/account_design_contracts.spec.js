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

const SETTINGS_USER = {
  email: "account-settings@gtfs-planner.test",
  password: "AccountSettings123!",
};

// One-use password mutation per `mise run prepare:browser` reset.
const PASSWORD_MUTATE_USER = {
  email: "account-password-mutate@gtfs-planner.test",
  password: "AccountPassword123!",
};

const DASHBOARD_STATE_ROOTS = [
  "#dashboard-system-administrator",
  "#dashboard-organization",
  "#dashboard-no-version",
  "#dashboard-no-organization",
  "#dashboard-organization-unavailable",
  "#dashboard-no-task-access",
];

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");
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

async function captureSharedMetrics(locator) {
  return locator.evaluate((el) => {
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      height: rect.height,
      width: rect.width,
      minHeight: style.minHeight,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      borderLeftWidth: style.borderLeftWidth,
      borderLeftStyle: style.borderLeftStyle,
      className: typeof el.className === "string" ? el.className : "",
    };
  });
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return main && !main.hasAttribute("data-phx-pending");
  });
  await page.evaluate(async () => {
    if (document.fonts?.ready) await document.fonts.ready;
  });
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
  await page.waitForSelector("#account-settings");
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
    await expect(accountLink).toContainText("Account settings");

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
      page.locator("#app-header span.text-brand"),
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
  test("shared header button and callout metrics match design references", async ({
    page,
  }) => {
    await logIn(page, EDITOR_USER);

    await page.goto("/design/navigation");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-header-demo");
    const refHeaderH1 = page.locator("#ds-header-demo h1").first();
    await expect(refHeaderH1).toBeVisible();
    const refHeaderMetrics = await captureSharedMetrics(refHeaderH1);

    await page.goto("/design/buttons");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-page-buttons");
    const refPrimary = page
      .locator("#ds-page-buttons a.btn-primary, #ds-page-buttons button.btn-primary")
      .first();
    await expect(refPrimary).toBeVisible();
    const refPrimaryMetrics = await captureSharedMetrics(refPrimary);

    await page.goto("/design/feedback");
    await waitForLiveView(page);
    await page.waitForSelector("#ds-callout-demo");
    const refWarning = page
      .locator("#ds-callout-demo .border-warning, #ds-callout-demo [class*='border-warning']")
      .first();
    const refInfo = page
      .locator("#ds-callout-demo .border-info, #ds-callout-demo [class*='border-info']")
      .first();
    await expect(refWarning).toBeVisible();
    await expect(refInfo).toBeVisible();
    const refWarningMetrics = await captureSharedMetrics(refWarning);

    // Ideal organization (editor + published version)
    await page.goto("/");
    await waitForLiveView(page);
    await page.waitForSelector("#dashboard-organization");
    const prodH1 = page.locator("#dashboard-organization h1").first();
    const prodPrimary = page
      .locator("#dashboard-organization a.btn-primary")
      .first();
    await expect(prodH1).toBeVisible();
    await expect(prodPrimary).toBeVisible();
    await expect(prodPrimary).toContainText("View routes");

    const prodH1Metrics = await captureSharedMetrics(prodH1);
    expect(prodH1Metrics.fontSize).toBe(refHeaderMetrics.fontSize);
    expect(prodH1Metrics.fontWeight).toBe(refHeaderMetrics.fontWeight);

    const prodPrimaryMetrics = await captureSharedMetrics(prodPrimary);
    expect(prodPrimaryMetrics.className).toContain("btn-primary");
    expect(prodPrimaryMetrics.height).toBeGreaterThanOrEqual(44);
    expect(prodPrimaryMetrics.width).toBeGreaterThanOrEqual(44);
    expect(Number.parseInt(prodPrimaryMetrics.fontWeight, 10)).toBeGreaterThanOrEqual(
      500,
    );
    // Shared button stack should share semantic primary class with reference.
    expect(refPrimaryMetrics.className).toContain("btn-primary");

    const focus = await focusVisible(page, prodPrimary);
    expect(focus.isFocused).toBe(true);
    expect(focus.outlineVisible || focus.ringVisible).toBe(true);

    // System administrator primary action
    await page.context().clearCookies();
    await openDashboard(page, SYSTEM_ADMIN_USER);
    await page.waitForSelector("#dashboard-system-administrator");
    const adminPrimary = page.locator(
      "#dashboard-system-administrator a.btn-primary[href='/admin/organizations']",
    );
    await expect(adminPrimary).toContainText("Manage organizations");
    await expect(adminPrimary).not.toHaveClass(/btn-active/);
    const adminMetrics = await captureSharedMetrics(adminPrimary);
    expect(adminMetrics.height).toBeGreaterThanOrEqual(44);

    // Dedicated no-version seed: warning callout, no GTFS destination.
    await page.context().clearCookies();
    await openDashboard(page, NO_VERSION_USER);
    await page.waitForSelector("#dashboard-no-version");
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    const callout = page.locator("#dashboard-no-version .border-warning").first();
    await expect(callout).toBeVisible();
    await expect(callout).toContainText("No published GTFS version");
    const calloutMetrics = await captureSharedMetrics(callout);
    expect(calloutMetrics.borderLeftStyle).not.toBe("none");
    expect(parseFloat(calloutMetrics.borderLeftWidth)).toBeGreaterThanOrEqual(
      parseFloat(refWarningMetrics.borderLeftWidth) - 0.5,
    );

    // Organization admin without editor: Manage users when a published version exists.
    await page.context().clearCookies();
    await openDashboard(page, ORG_ADMIN_USER);
    const orgAdminRoot = await visibleDashboardRoot(page);
    expect(orgAdminRoot).toBe("#dashboard-organization");
    await expect(
      page.locator(`${orgAdminRoot} a.btn-primary[href='/admin/users']`),
    ).toContainText("Manage users");
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
  });

  test("representative states reflow without overflow at required viewports", async ({
    page,
  }) => {
    const scenarios = [
      {
        user: EDITOR_USER,
        root: "#dashboard-organization",
        label: "organization",
      },
      {
        user: SYSTEM_ADMIN_USER,
        root: "#dashboard-system-administrator",
        label: "system-admin",
      },
      {
        user: NO_VERSION_USER,
        root: "#dashboard-no-version",
        label: "no-version",
      },
      {
        user: NO_TASK_USER,
        root: "#dashboard-no-task-access",
        label: "no-task",
      },
    ];

    for (const scenario of scenarios) {
      await page.context().clearCookies();
      await openDashboard(page, scenario.user);
      await page.waitForSelector(scenario.root);

      for (const viewport of VIEWPORTS) {
        await page.setViewportSize({
          width: viewport.width,
          height: viewport.height,
        });
        await page.goto("/");
        await waitForLiveView(page);
        await page.waitForSelector(scenario.root);

        expect(
          await bodyFitsViewport(page),
          `${scenario.label} overflow at ${viewport.label}`,
        ).toBe(true);

        const actions = page.locator(
          `${scenario.root} a.btn, ${scenario.root} button.btn`,
        );
        const count = await actions.count();
        for (let i = 0; i < count; i++) {
          const action = actions.nth(i);
          if (!(await action.isVisible())) continue;
          const box = await action.boundingBox();
          expect(box).not.toBeNull();
          expect(box.height).toBeGreaterThanOrEqual(44);
          expect(box.width).toBeGreaterThanOrEqual(44);
        }

        const h1Count = await page.locator(`${scenario.root} h1`).count();
        expect(h1Count).toBe(1);
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
      "No published GTFS version",
    );
    // Authorized org name may appear; GTFS destinations must not.
    await expect(page.locator("#dashboard-no-version h1")).toHaveCount(1);

    await page.context().clearCookies();
    await openDashboard(page, NO_TASK_USER);
    await page.waitForSelector("#dashboard-no-task-access");
    await expect(page.locator("#dashboard-no-task-access")).toBeVisible();
    await expect(page.locator("#dashboard-no-task-access a.btn")).toHaveCount(0);
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    await expect(page.locator("a[href='/admin/users']")).toHaveCount(0);
    await expect(page.locator("a[href='/admin/organizations']")).toHaveCount(0);
  });

  test("reviewed dashboard state screenshots", async ({ page }) => {
    // Ideal organization (editor seed has published version + Browser Test Org name).
    await openDashboard(page, EDITOR_USER);
    await page.waitForSelector("#dashboard-organization");
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    await waitForLiveView(page);
    const orgRoot = page.locator("#dashboard-organization");
    await expect(orgRoot).toBeVisible();
    // Do not mask tenant name: presence of authorized org name is the contract.
    await expect(orgRoot).toHaveScreenshot("dashboard-organization-1280.png", {
      animations: "disabled",
    });

    // System administrator
    await page.context().clearCookies();
    await openDashboard(page, SYSTEM_ADMIN_USER);
    await page.waitForSelector("#dashboard-system-administrator");
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    await waitForLiveView(page);
    await expect(page.locator("#dashboard-system-administrator")).toHaveScreenshot(
      "dashboard-system-administrator-1280.png",
      {
        animations: "disabled",
        mask: [
          page.locator("#dashboard-system-administrator p").first(),
        ],
      },
    );

    // Dedicated no-version seed
    await page.context().clearCookies();
    await openDashboard(page, NO_VERSION_USER);
    await page.waitForSelector("#dashboard-no-version");
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    await waitForLiveView(page);
    await expect(page.locator("#dashboard-no-version")).toHaveScreenshot(
      "dashboard-no-version-1280.png",
      { animations: "disabled" },
    );

    // Dedicated no-task seed
    await page.context().clearCookies();
    await openDashboard(page, NO_TASK_USER);
    await page.waitForSelector("#dashboard-no-task-access");
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    await waitForLiveView(page);
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
    await page.waitForSelector("#account-settings");

    await expect(page).toHaveTitle(/Account settings/);
    await expect(page.locator("#account-settings-title")).toHaveText(
      "Account settings",
    );
    await expect(page.locator("#email-settings-title")).toHaveText(
      "Change email",
    );
    await expect(page.locator("#password-settings-title")).toHaveText(
      "Change password",
    );

    const h1Count = await page.locator("#account-settings h1").count();
    expect(h1Count).toBe(1);
    const h2Count = await page.locator("#account-settings h2").count();
    expect(h2Count).toBe(2);

    await expect(page.locator("#email-submit")).toHaveClass(/btn-outline/);
    await expect(page.locator("#password-submit")).toHaveClass(/btn-outline/);
    await expect(page.locator("#email-submit")).not.toHaveClass(/btn-primary/);
    await expect(page.locator("#password-submit")).not.toHaveClass(
      /btn-primary/,
    );

    const emailMetrics = await captureFormFieldMetrics(page, "#email_form");
    const passwordMetrics = await captureFormFieldMetrics(
      page,
      "#password_form",
    );
    expect(emailMetrics.labelAboveInput).toBe(true);
    expect(passwordMetrics.labelAboveInput).toBe(true);
    expect(emailMetrics.buttonClass).toContain("btn-outline");
    expect(passwordMetrics.buttonClass).toContain("btn-outline");
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
      await page.waitForSelector("#account-settings");

      expect(
        await bodyFitsViewport(page),
        `settings overflow at ${viewport.label}`,
      ).toBe(true);

      for (const sectionId of ["#email-settings", "#password-settings"]) {
        const section = page.locator(sectionId);
        const box = await section.boundingBox();
        expect(box).not.toBeNull();
        // Full available width up to 40rem (640px).
        expect(box.width).toBeLessThanOrEqual(640 + 1);
        expect(box.width).toBeGreaterThan(0);
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
    // proposed email kept, first invalid focused. Avoid HTML5 type=email blocks.
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await page.waitForSelector("#account-settings");
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
      () => {
        const active = document.activeElement;
        return (
          active &&
          ["email-address", "email-current-password"].includes(active.id)
        );
      },
      null,
      { timeout: 10_000 },
    );
    await waitForLiveView(page);
    await expect(page.locator("#email-address")).toHaveValue(proposedEmail);
    await expect(page.locator("#email-current-password")).toHaveValue("");
    const focusedAfterEmail = await page.evaluate(
      () => document.activeElement && document.activeElement.id,
    );
    expect(["email-address", "email-current-password"]).toContain(
      focusedAfterEmail,
    );

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
      () => {
        const active = document.activeElement;
        return (
          active &&
          [
            "password-current-password",
            "password-new-password",
            "password-confirmation",
          ].includes(active.id)
        );
      },
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
    expect([
      "password-current-password",
      "password-new-password",
      "password-confirmation",
    ]).toContain(focusedAfterPassword);

    // No skeleton/placeholder during synchronous account context mount.
    await page.goto("/users/settings");
    await waitForLiveView(page);
    await expect(
      page.locator(".motion-safe\\:animate-pulse, [aria-busy='true']"),
    ).toHaveCount(0);
    await expect(page.locator("#account-settings")).toBeVisible();
  });

  test("reviewed account-settings screenshots at 320/1280/640 with email masked", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    await openSettings(page, SETTINGS_USER);

    const emailMask = [
      page.locator("#email-address"),
      page.locator(`text=${SETTINGS_USER.email}`),
    ];

    for (const { width, height, label } of [
      { width: 320, height: 568, label: "320" },
      { width: 1280, height: 800, label: "1280" },
      { width: 640, height: 400, label: "640" },
    ]) {
      await page.setViewportSize({ width, height });
      await page.goto("/users/settings");
      await waitForLiveView(page);
      const root = page.locator("#account-settings");
      await expect(root).toBeVisible();
      await expect(root).toHaveScreenshot(`account-settings-${label}.png`, {
        animations: "disabled",
        mask: emailMask,
      });
    }

    // Deterministic email task error root.
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
    await expect(page.locator("#account-settings")).toBeVisible();

    await page.evaluate(() => window.liveSocket.disconnect());
    await page.waitForSelector("#client-error", { state: "visible", timeout: 10_000 });
    await expect(page.locator("#client-error")).toContainText(/reconnect/i);

    await page.evaluate(() => window.liveSocket.connect());
    await waitForLiveView(page);
    await expect(page.locator("#account-settings")).toBeVisible();
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
    await expect(page.locator("#account-settings")).toBeVisible();
  });
});
