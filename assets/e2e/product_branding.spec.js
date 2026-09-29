// Product branding journey (EV-11, step 11).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0).
// Read-only: it logs in, checks the header brand block and the product-hidden
// task links, and captures the signed-out login frame. Ids, src paths, alts and
// credentials are literal values from the spec and the seed.
//
// Captures go to BRANDING_CAPTURE_DIR when set, otherwise to the test's
// gitignored output directory.
import { test, expect } from "@playwright/test";
import { mkdirSync } from "fs";
import { bodyFitsViewport } from "./browser_helpers";

// A 404 or corrupt SVG still lays out a box, so require a decoded image.
async function expectImageLoaded(locator) {
  await expect(locator).toBeVisible();
  expect(
    await locator.evaluate((el) => el.complete && el.naturalWidth > 0),
  ).toBe(true);
}

const PLANNER_EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
  versionName: "Browser E2E Version",
  logo: "/images/gtfs-planner-logo.svg",
  brand: "planner",
};

const PATHWAYS_EDITOR = {
  email: "pathways-editor@gtfs-planner.test",
  password: "PathwaysEditor123!",
  versionName: "Browser Pathways Version",
  logo: "/images/pathways-studio-logo.svg",
  brand: "pathways",
};

const DESKTOP = { width: 1440, height: 1000, label: "desktop" };
const MOBILE = { width: 375, height: 812, label: "mobile" };

const LOGIN_VIEWPORTS = [
  { width: 1440, height: 900 },
  { width: 390, height: 844 },
  { width: 320, height: 700 },
];

function capturePath(testInfo, name) {
  const dir = process.env.BRANDING_CAPTURE_DIR;
  if (!dir) return testInfo.outputPath(name);
  mkdirSync(dir, { recursive: true });
  return `${dir}/${name}`;
}

async function logIn(page, account) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', account.email);
  await page.fill('input[name="user[password]"]', account.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function waitForLiveView(page) {
  await page.waitForSelector("[data-phx-main]", { state: "attached" });
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]");
    return Boolean(
      main &&
      main.classList.contains("phx-connected") &&
      !main.hasAttribute("data-phx-pending") &&
      window.liveSocket?.isConnected(),
    );
  });
}

async function versionId(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);
  return option.getAttribute("data-version-id");
}

for (const account of [PLANNER_EDITOR, PATHWAYS_EDITOR]) {
  for (const viewport of [DESKTOP, MOBILE]) {
    test(`${account.brand} editor header at ${viewport.label}`, async ({
      page,
    }, testInfo) => {
      await page.setViewportSize({
        width: viewport.width,
        height: viewport.height,
      });
      await logIn(page, account);
      await waitForLiveView(page);

      const id = await versionId(page, account.versionName);
      await page.goto(`/gtfs/${id}/routes`);
      await waitForLiveView(page);

      await expect(page.locator("#app-brand-logo")).toHaveAttribute(
        "src",
        account.logo,
      );
      await expectImageLoaded(page.locator("#app-brand-logo"));

      if (viewport === DESKTOP) {
        const planner = account === PLANNER_EDITOR;
        const gated = ["#nav-operations", "#nav-flex"];
        const shown = [
          "#nav-routes",
          "#nav-calendars",
          "#nav-stops",
          "#nav-gtfs",
        ];

        for (const selector of gated) {
          await expect(page.locator(selector)).toHaveCount(planner ? 1 : 0);
          if (planner) await expect(page.locator(selector)).toBeVisible();
        }
        for (const selector of shown) {
          await expect(page.locator(selector)).toBeVisible();
        }
      }

      expect(await bodyFitsViewport(page)).toBe(true);
      await page.screenshot({
        path: capturePath(
          testInfo,
          `${account.brand}-header-${viewport.label}.png`,
        ),
      });
    });
  }
}

for (const viewport of LOGIN_VIEWPORTS) {
  test(`signed-out login shows both brands at ${viewport.width}`, async ({
    page,
  }, testInfo) => {
    await page.setViewportSize(viewport);
    await page.goto("/users/log_in");

    await expectImageLoaded(page.locator('#auth-brands img[alt="GTFS Planner"]'));
    await expectImageLoaded(
      page.locator('#auth-brands img[alt="Pathways Studio"]'),
    );

    expect(await bodyFitsViewport(page)).toBe(true);
    await page.screenshot({
      path: capturePath(testInfo, `login-${viewport.width}.png`),
    });
  });
}
