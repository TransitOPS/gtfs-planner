import { test, expect } from "@playwright/test";

// Account design contracts (Package 11).
// Step 3 owns the account-navigation block. Later steps extend this file.

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VIEWPORTS = [
  { label: "320px", width: 320, height: 568 },
  { label: "768px", width: 768, height: 1024 },
  { label: "desktop", width: 1280, height: 800 },
  // 200% browser zoom of a 1280x800 device viewport is a 640x400 CSS layout
  // viewport. Exercising the layout viewport directly runs the media queries.
  { label: "640px (200% zoom)", width: 640, height: 400 },
];

async function logIn(page, user = EDITOR_USER) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
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
