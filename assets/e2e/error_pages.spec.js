import { test, expect } from "@playwright/test";

/**
 * Real-browser coverage for the branded HTML error pages.
 *
 * Covers Package 18 acceptance:
 *   - AC-10: real Chromium GET of a unique missing route observes 404 plus the
 *     shared anonymous app shell, the 404 status label, one heading, the
 *     explanation, and the visible "Return home" recovery action.
 *   - AC-11: the real 404 page never produces body-level horizontal overflow
 *     at 320 px, 768 px, 1280 px, or the 640 px CSS viewport (the project's
 *     200%-zoom layout-viewport equivalent).
 *   - AC-12: sequential keyboard Tab navigation reaches #error-page-404-home
 *     with a computed visible focus indicator, a bounding box at least 44 px
 *     tall, and Enter activates the native `/` link to reach the signed-out
 *     authentication boundary at /users/log_in without JavaScript-only help.
 *
 * The webServer in assets/playwright.config.js runs the real Phoenix endpoint
 * on port 4002 with MIX_ENV=test. This file adds no crashing production or
 * test-only route — the direct-render 500 contract is owned by the focused
 * controller tests in test/gtfs_planner_web/controllers/error_html_test.exs.
 */

const MISSING_PATH = "/missing-route-error-pages-018-dsa-step-3";

// ── AC-10: real 404 response and shared shell visibility ──
test.describe("Real 404 page response and shell", () => {
  test("Chromium navigation to a unique missing path returns 404 and the branded shell", async ({
    page,
  }) => {
    const response = await page.goto(MISSING_PATH);
    expect(response).not.toBeNull();
    expect(response.status()).toBe(404);

    // The response is an HTML document (Phoenix endpoint error rendering).
    const contentType = response.headers()["content-type"] ?? "";
    expect(contentType).toContain("text/html");

    // Shared anonymous shell is present and visible.
    await expect(page.locator("#app-header")).toBeVisible();
    await expect(page.locator("#main-content")).toBeVisible();

    // 404 wrapper carries the stable contract IDs and recovery action.
    await expect(page.locator("#error-page-404")).toBeVisible();
    await expect(page.locator("#error-page-404-status")).toContainText("404");
    await expect(page.locator("#error-page-404 h1")).toBeVisible();
    await expect(page.locator("#error-page-404-home")).toBeVisible();
    await expect(page.locator("#error-page-404-home")).toHaveAttribute(
      "href",
      "/",
    );
    await expect(page.locator("#error-page-404-home")).toContainText(
      "Return home",
    );
  });
});

// ── AC-11: no body horizontal overflow at required CSS viewports ──
test.describe("Real 404 responsive reflow", () => {
  for (const width of [320, 640, 768, 1280]) {
    test(`no body horizontal overflow at ${width}px CSS viewport`, async ({
      page,
    }) => {
      await page.setViewportSize({ width, height: 800 });
      await page.goto(MISSING_PATH);
      await page.waitForSelector("#error-page-404");

      const overflow = await page.evaluate(() => {
        return {
          innerWidth: window.innerWidth,
          bodyScrollWidth: document.body.scrollWidth,
          fits: document.body.scrollWidth <= window.innerWidth,
        };
      });
      expect(overflow.innerWidth).toBe(width);
      expect(overflow.bodyScrollWidth).toBeLessThanOrEqual(overflow.innerWidth);
      expect(overflow.fits).toBe(true);
    });
  }
});

// ── AC-12: keyboard reach, focus visibility, target size, native nav ──
test.describe("Real 404 keyboard focus and target", () => {
  test("Tab reaches #error-page-404-home with a visible focus indicator and >=44px height", async ({
    page,
  }) => {
    await page.goto(MISSING_PATH);
    await page.waitForSelector("#error-page-404-home");

    // DOM tab order in the anonymous shell is:
    //   1. skip link (#main-content sr-only focus:not-sr-only)
    //   2. logo home link
    //   3. #error-page-404-home
    // Sequential Tab from the body reaches the recovery link deterministically.
    // The skip link is visually hidden until focused, so it appears first
    // without breaking the visible order contract.
    const target = page.locator("#error-page-404-home");
    await target.focus();
    await expect(target).toBeFocused();

    // Computed focus indicator: the rendered link must show a non-trivial
    // outline or box-shadow when it owns keyboard focus.
    const focusIndicator = await target.evaluate((el) => {
      const styles = window.getComputedStyle(el);
      const outlineWidth = parseFloat(styles.outlineWidth) || 0;
      const outlineStyle = styles.outlineStyle;
      const boxShadow = styles.boxShadow;
      const matchesFocusVisible = el.matches(":focus-visible");
      return {
        outlineWidth,
        outlineStyle,
        boxShadow,
        matchesFocusVisible,
      };
    });
    const hasVisibleOutline =
      focusIndicator.outlineStyle !== "none" &&
      focusIndicator.outlineWidth > 0;
    const hasVisibleBoxShadow =
      focusIndicator.boxShadow !== "none" && focusIndicator.boxShadow !== "";
    expect(focusIndicator.matchesFocusVisible).toBe(true);
    expect(
      hasVisibleOutline || hasVisibleBoxShadow,
      "expected a visible outline or box-shadow on #error-page-404-home",
    ).toBe(true);

    // 44 px minimum target height per design-system contract.
    const box = await target.boundingBox();
    expect(box).not.toBeNull();
    expect(box.height).toBeGreaterThanOrEqual(44);
  });

  test("keyboard sequential Tab reaches #error-page-404-home from a fresh page load", async ({
    page,
  }) => {
    await page.goto(MISSING_PATH);
    await page.waitForSelector("#error-page-404-home");

    // Bounded Tab walk that mirrors a keyboard user's traversal. The skip
    // link is first (and becomes visible when focused); the home logo link
    // follows; #error-page-404-home is next in the anonymous shell.
    let reached = false;
    for (let i = 0; i < 10; i += 1) {
      await page.keyboard.press("Tab");
      const onTarget = await page.evaluate(() => {
        return document.activeElement?.id === "error-page-404-home";
      });
      if (onTarget) {
        reached = true;
        break;
      }
    }
    expect(reached).toBe(true);
  });

  test("Enter on #error-page-404-home performs native navigation to /users/log_in", async ({
    page,
  }) => {
    await page.goto(MISSING_PATH);
    await page.waitForSelector("#error-page-404-home");

    const target = page.locator("#error-page-404-home");
    await target.focus();
    await expect(target).toBeFocused();

    // Native keyboard activation only — no evaluate(), no click helper.
    await page.keyboard.press("Enter");

    // The home route (`/`) is authenticated and signed-out visitors are
    // redirected to the existing /users/log_in auth boundary. This is the
    // current routing contract; the error page itself does not pick a login
    // destination.
    await page.waitForURL("**/users/log_in", { timeout: 10_000 });
    expect(page.url()).toMatch(/\/users\/log_in$/);
  });

  test("Return home remains a native recovery link with JavaScript disabled", async ({
    browser,
  }) => {
    const context = await browser.newContext({ javaScriptEnabled: false });
    const page = await context.newPage();

    try {
      const response = await page.goto(MISSING_PATH);
      expect(response).not.toBeNull();
      expect(response.status()).toBe(404);

      const target = page.locator("a#error-page-404-home");
      await expect(target).toHaveAttribute("href", "/");
      await target.focus();

      await Promise.all([
        page.waitForURL("**/users/log_in", { timeout: 10_000 }),
        page.keyboard.press("Enter"),
      ]);

      expect(page.url()).toMatch(/\/users\/log_in$/);
    } finally {
      await context.close();
    }
  });
});
