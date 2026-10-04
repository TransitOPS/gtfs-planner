// TODS generator entry and prerequisites (EV-8, spec 37 step 8).
//
// The journey enters through the ordinary account menu, so the entry is proven
// where a reader actually gets it, and it reads its two worlds — one version with
// a garage, one organization whose version has none — from the seeded browser
// database `bin/test-browser` builds with `workers: 1`, `retries: 0` and
// `BROWSER_E2E=true`. Expected labels, paths, dates and copy are literal values
// from the package spec, never derived from the components under test.
//
// Captures and the observed-facts record are written only when
// TODS_GENERATOR_CAPTURE_DIR names a directory, so an ordinary run records
// nothing and the evidence run keeps its screenshots outside the commit.
import { test, expect } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { bodyFitsViewport, logInAs } from "./browser_helpers";

// The two seeded generator worlds, and the credentials the seed prints.
const WITH_GARAGE = {
  email: "tods-generator@gtfs-planner.test",
  password: "TodsGenerator123!",
  versionName: "Browser TODS Version",
};
const WITHOUT_GARAGE = {
  email: "tods-generator-empty@gtfs-planner.test",
  password: "TodsGenerator123!",
  versionName: "Browser TODS No Garage Version",
};

// The window the seed fixes: the first date with service is Wednesday 7 October
// 2026, so the generator's own defaulting shows Monday 5 – Sunday 11 October.
const DEFAULT_START = "2026-10-05";
const DEFAULT_END = "2026-10-11";

const DESKTOP = { width: 1440, height: 1000, label: "desktop" };
const MOBILE = { width: 375, height: 812, label: "mobile" };
const VIEWPORTS = [DESKTOP, MOBILE];

const CAPTURE_ROOT = process.env.TODS_GENERATOR_CAPTURE_DIR;
const observed = [];

function record(fact) {
  observed.push(fact);
}

async function capture(page, name) {
  if (!CAPTURE_ROOT) return null;

  mkdirSync(CAPTURE_ROOT, { recursive: true });
  const path = resolve(CAPTURE_ROOT, `${name}.png`);
  await page.screenshot({ path, fullPage: true });
  return path;
}

// Writes the observed literal facts and the screenshot paths once, after the
// last journey has run.
test.afterAll(() => {
  if (!CAPTURE_ROOT) return;

  mkdirSync(CAPTURE_ROOT, { recursive: true });
  writeFileSync(
    resolve(CAPTURE_ROOT, "entry-prerequisites.json"),
    `${JSON.stringify({ spec: "37-tods-generator", step: 8, observed }, null, 2)}\n`,
  );
});

// A click that lands before the LiveView joins is dropped, so every menu
// interaction waits for the connected view first.
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

// Opens the account menu the way a person does and reads the generator entry's
// own destination, so the journey never guesses a version ID.
async function generatorHref(page) {
  await page.locator("#user-menu [data-user-menu-trigger]").click();
  await expect(page.locator("#user-menu [data-user-menu-trigger]")).toHaveAttribute(
    "aria-expanded",
    "true",
  );

  const link = page.locator("#tods-generator-link");
  await expect(link).toBeVisible();
  await expect(link).toContainText("TODS generator");

  const href = await link.getAttribute("href");
  if (!href) throw new Error("the generator entry carries no destination");

  return href;
}

// Settings stays first and the generator sits directly beneath it.
async function expectMenuOrder(page) {
  const ids = await page
    .locator("#user-menu-panel a[id]")
    .evaluateAll((links) => links.map((link) => link.id));

  expect(ids).toEqual(["settings-link", "tods-generator-link"]);
}

async function openGenerator(page, account, label) {
  await logInAs(page, account);
  await waitForLiveView(page);

  const href = await generatorHref(page);
  expect(href).toMatch(new RegExp(`/gtfs/[^/]+/tods-generator$`));

  await expectMenuOrder(page);
  await page.locator("#tods-generator-link").click();
  await page.waitForURL((url) => url.pathname === href);
  await waitForLiveView(page);

  record({ state: "entry", viewport: label, href });
  return href;
}

for (const { width, height, label } of VIEWPORTS) {
  test.describe(`TODS generator entry at ${label}`, () => {
    test.use({ viewport: { width, height } });

    test("entry and prerequisites: the account menu opens the initiating form", async ({
      page,
    }) => {
      const pageErrors = [];
      page.on("pageerror", (error) => pageErrors.push(error.message));

      const href = await openGenerator(page, WITH_GARAGE, label);
      const versionId = href.split("/")[2];

      // What the page says before it offers a control.
      await expect(page.locator("#tods-generator-purpose")).toContainText(
        "Generate fictional operations data",
      );
      await expect(page.locator("#tods-generator-purpose")).toContainText(
        "internal testing and demonstrations",
      );
      await expect(page.locator("#tods-generator-purpose")).toContainText(
        "does not publish a feed",
      );
      await expect(page.locator("#tods-generator-purpose")).toContainText(
        "affects every matching date",
      );
      await expect(page.locator("#tods-generator-scope")).toContainText(WITH_GARAGE.versionName);

      // The form, its defaulted first active calendar week and its one garage,
      // which is preselected because one garage is not a choice.
      await expect(page.locator("#tods-generator-form")).toBeVisible();
      await expect(page.locator("#tods-start-date")).toHaveValue(DEFAULT_START);
      await expect(page.locator("#tods-end-date")).toHaveValue(DEFAULT_END);
      await expect(page.locator("#tods-representative-week")).toHaveValue(DEFAULT_START);
      await expect(page.locator("#tods-garage-select option:checked")).toHaveText("TODS Depot");
      await expect(page.locator("#tods-generator-rules")).toBeVisible();
      await expect(page.locator("#tods-generator-rules-link")).toHaveAttribute(
        "href",
        `/gtfs/${versionId}/runs`,
      );

      // The one primary, spelled exactly as the package requires, and a 44px
      // target.
      const preview = page.locator("#tods-preview-button");
      await expect(preview).toHaveText("Preview generation");
      await expect(preview).toBeEnabled();

      const box = await preview.boundingBox();
      expect(box.height).toBeGreaterThanOrEqual(44);

      expect(await bodyFitsViewport(page)).toBe(true);
      expect(pageErrors).toEqual([]);

      const shot = await capture(page, `entry-ready-${label}`);
      record({ state: "ready-form", viewport: label, screenshot: shot });
    });

    test("entry and prerequisites: no garage links to Garages and comes back", async ({
      page,
    }) => {
      const pageErrors = [];
      page.on("pageerror", (error) => pageErrors.push(error.message));

      const href = await openGenerator(page, WITHOUT_GARAGE, label);
      const versionId = href.split("/")[2];

      // The prerequisite is stated, and the control it blocks explains itself.
      const missing = page.locator("#tods-generator-missing-garages");
      await expect(missing).toBeVisible();
      await expect(missing).toContainText("Add a garage first");
      await expect(page.locator("#tods-preview-blocked")).toBeVisible();
      await expect(page.locator("#tods-preview-button")).toBeDisabled();

      const garagesLink = missing.locator(`a[href="/gtfs/${versionId}/settings/garages"]`);
      await expect(garagesLink).toBeVisible();

      const shot = await capture(page, `entry-no-garage-${label}`);
      record({ state: "missing-garages", viewport: label, screenshot: shot });

      // The link opens the real garage page…
      await garagesLink.click();
      await page.waitForURL((url) => url.pathname === `/gtfs/${versionId}/settings/garages`);
      await waitForLiveView(page);
      await expect(page.locator("#garages-first-use-empty")).toBeVisible();

      // …and the generator is reachable again with the same state.
      await page.goto(href);
      await waitForLiveView(page);
      await expect(page.locator("#tods-generator-missing-garages")).toBeVisible();
      await expect(page.locator("#tods-preview-button")).toBeDisabled();

      expect(await bodyFitsViewport(page)).toBe(true);
      expect(pageErrors).toEqual([]);

      record({ state: "returned", viewport: label, path: `/gtfs/${versionId}/settings/garages` });
    });
  });
}

test("entry and prerequisites: the missing-prerequisite page fits 320px", async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 568 });

  const href = await openGenerator(page, WITHOUT_GARAGE, "320px");

  await expect(page.locator("#tods-generator-missing-garages")).toBeVisible();
  await expect(page.locator("#tods-generator-form")).toBeVisible();
  expect(await bodyFitsViewport(page)).toBe(true);

  const box = await page.locator("#tods-preview-button").boundingBox();
  expect(box.height).toBeGreaterThanOrEqual(44);

  const shot = await capture(page, "entry-no-garage-320px");
  record({ state: "missing-garages", viewport: "320px", path: href, screenshot: shot });
});
