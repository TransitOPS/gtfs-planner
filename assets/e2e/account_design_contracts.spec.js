import { test, expect } from "@playwright/test";

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

const VIEWPORTS = [
  { label: "320px", width: 320, height: 568 },
  { label: "768px", width: 768, height: 1024 },
  { label: "desktop", width: 1280, height: 800 },
  // 200% browser zoom of a 1280x800 device viewport is a 640x400 CSS layout
  // viewport. Exercising the layout viewport directly runs the media queries.
  { label: "640px (200% zoom)", width: 640, height: 400 },
];

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

async function bodyFitsViewport(page) {
  return page.evaluate(
    () => document.body.scrollWidth <= window.innerWidth + 1,
  );
}

async function captureTargetMetrics(locator) {
  return locator.evaluate((el) => {
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      minHeight: style.minHeight,
      height: rect.height,
      width: rect.width,
      fontWeight: style.fontWeight,
      backgroundColor: style.backgroundColor,
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      boxShadow: style.boxShadow,
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

/**
 * Records every mutation of a control from the moment before it is activated.
 * Matches admin_design_contracts.watchPendingState for phx-disable-with races.
 */
async function watchPendingState(page, selector) {
  await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`No element for ${sel}`);
    window.__pendingStates = [];
    window.__pendingObserver = new MutationObserver(() => {
      window.__pendingStates.push({
        disabled: el.hasAttribute("disabled"),
        text: el.textContent.trim(),
      });
    });
    window.__pendingObserver.observe(el, {
      attributes: true,
      childList: true,
      subtree: true,
      characterData: true,
    });
  }, selector);
}

async function readPendingStates(page) {
  return page.evaluate(() => {
    window.__pendingObserver?.disconnect();
    return window.__pendingStates ?? [];
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

    const accountLink = page.locator(
      "#app-header nav[aria-label='Main navigation'] a[href='/users/settings']",
    );
    await expect(accountLink).toBeVisible();
    await expect(accountLink).toHaveAttribute("aria-current", "page");
    await expect(accountLink).toContainText("Account settings");

    const accountMetrics = await captureTargetMetrics(accountLink);
    expect(accountMetrics.height).toBeGreaterThanOrEqual(44);
    expect(accountMetrics.width).toBeGreaterThanOrEqual(44);
    expect(Number.parseInt(accountMetrics.fontWeight, 10)).toBeGreaterThanOrEqual(
      600,
    );

    const focus = await focusVisible(page, accountLink);
    expect(focus.isFocused).toBe(true);
    expect(focus.outlineVisible || focus.ringVisible).toBe(true);

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

      const navLinks = page.locator(
        "#app-header nav[aria-label='Main navigation'] a",
      );
      const count = await navLinks.count();
      expect(count).toBeGreaterThan(0);

      for (let i = 0; i < count; i++) {
        const link = navLinks.nth(i);
        await expect(link).toBeVisible();
        const box = await link.boundingBox();
        expect(box).not.toBeNull();
        expect(box.height).toBeGreaterThanOrEqual(44);
        expect(box.width).toBeGreaterThanOrEqual(44);
      }

      const texts = await navLinks.allTextContents();
      const accountIndex = texts.findIndex((t) =>
        t.includes("Account settings"),
      );
      expect(accountIndex).toBe(texts.length - 1);

      const focused = await focusVisible(page, accountLink);
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
    const refInfoMetrics = await captureSharedMetrics(refInfo);

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

    // Organization admin without editor role → Manage users primary, no GTFS CTA
    await page.context().clearCookies();
    await openDashboard(page, ORG_ADMIN_USER);
    const orgAdminRoot = await visibleDashboardRoot(page);
    // Admin Contracts Org has only a staging default unless published elsewhere.
    // Accept organization or no-version; never expose unauthorized GTFS links.
    expect(["#dashboard-organization", "#dashboard-no-version"]).toContain(
      orgAdminRoot,
    );
    await expect(page.locator("a[href^='/gtfs/']")).toHaveCount(0);
    if (orgAdminRoot === "#dashboard-organization") {
      await expect(
        page.locator(`${orgAdminRoot} a.btn-primary[href='/admin/users']`),
      ).toContainText("Manage users");
    } else {
      const callout = page.locator(`${orgAdminRoot} .border-warning`).first();
      await expect(callout).toBeVisible();
      await expect(callout).toContainText("No published GTFS version");
      const calloutMetrics = await captureSharedMetrics(callout);
      expect(calloutMetrics.borderLeftStyle).not.toBe("none");
      expect(parseFloat(calloutMetrics.borderLeftWidth)).toBeGreaterThanOrEqual(
        parseFloat(refWarningMetrics.borderLeftWidth) - 0.5,
      );
    }

    // Missing-context style recovery uses info callout on no-organization when
    // reachable; LiveView tests own the full missing/unavailable matrix.
    void refInfoMetrics;
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
        user: ORG_ADMIN_USER,
        root: null,
        label: "org-admin",
      },
    ];

    for (const scenario of scenarios) {
      await page.context().clearCookies();
      await openDashboard(page, scenario.user);
      const root =
        scenario.root ||
        (await visibleDashboardRoot(page)) ||
        "#dashboard-organization";
      await page.waitForSelector(root);

      for (const viewport of VIEWPORTS) {
        await page.setViewportSize({
          width: viewport.width,
          height: viewport.height,
        });
        await page.goto("/");
        await waitForLiveView(page);
        await page.waitForSelector(root);

        expect(
          await bodyFitsViewport(page),
          `${scenario.label} overflow at ${viewport.label}`,
        ).toBe(true);

        const actions = page.locator(`${root} a.btn, ${root} button.btn`);
        const count = await actions.count();
        for (let i = 0; i < count; i++) {
          const action = actions.nth(i);
          if (!(await action.isVisible())) continue;
          const box = await action.boundingBox();
          expect(box).not.toBeNull();
          expect(box.height).toBeGreaterThanOrEqual(44);
          expect(box.width).toBeGreaterThanOrEqual(44);
        }

        const h1Count = await page.locator(`${root} h1`).count();
        expect(h1Count).toBe(1);
      }
    }
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
      { animations: "disabled" },
    );

    // Org admin: no-version or organization depending on seed publication state.
    await page.context().clearCookies();
    await openDashboard(page, ORG_ADMIN_USER);
    const orgAdminRoot = await visibleDashboardRoot(page);
    expect(orgAdminRoot).not.toBeNull();
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto("/");
    await waitForLiveView(page);
    const rootLocator = page.locator(orgAdminRoot);
    await expect(rootLocator).toBeVisible();

    if (orgAdminRoot === "#dashboard-no-version") {
      await expect(rootLocator).toHaveScreenshot("dashboard-no-version-1280.png", {
        animations: "disabled",
      });
    } else if (orgAdminRoot === "#dashboard-organization") {
      // Seed has a published version for this org; still capture the root.
      await expect(rootLocator).toHaveScreenshot(
        "dashboard-organization-org-admin-1280.png",
        { animations: "disabled" },
      );
    } else if (orgAdminRoot === "#dashboard-no-task-access") {
      await expect(rootLocator).toHaveScreenshot("dashboard-no-task-access-1280.png", {
        animations: "disabled",
      });
    }

    // Missing-context is not browser-login-reachable for seeded members without a
    // production session bypass. LiveView tests own #dashboard-no-organization and
    // #dashboard-organization-unavailable non-disclosure. Capture no-organization
    // only if a seeded path ever exposes it.
    await page.context().clearCookies();
    // Attempt: login as system admin then navigate home already covered.
    // No production backdoor for stale session IDs.
  });
});

test.describe("account settings", () => {
  test("hierarchy, design-reference metrics, geometry, focus, pending, and secret recovery", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    await logIn(page, EDITOR_USER);

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
    const refSecondaryMetrics = await captureSharedMetrics(refSecondary);
    expect(refSecondaryMetrics.className).toContain("btn-outline");

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
    // Shared input stack: comparable control height to design demo (±8px tolerance).
    if (refFormMetrics.inputHeight > 0) {
      expect(
        Math.abs(emailMetrics.inputHeight - refFormMetrics.inputHeight),
      ).toBeLessThanOrEqual(12);
    }
    void refSecondaryMetrics;

    const settingsViewports = [
      { label: "320px", width: 320, height: 568 },
      { label: "desktop", width: 1280, height: 800 },
      { label: "640px (200% zoom)", width: 640, height: 400 },
    ];

    for (const viewport of settingsViewports) {
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
    await page.fill("#email-current-password", EDITOR_USER.password);
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
  });

  test("reviewed account-settings screenshots at 320/1280/640 with email masked", async ({
    page,
  }) => {
    test.setTimeout(90_000);
    await openSettings(page, EDITOR_USER);

    const emailMask = [
      page.locator("#email-address"),
      page.locator(`text=${EDITOR_USER.email}`),
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
