// TODS generator entry, prerequisites, preview and save (EV-8, EV-10; spec 37
// steps 8 and 9).
//
// The journey enters through the ordinary account menu, so the entry is proven
// where a reader actually gets it, and it reads its seeded worlds from the
// browser database `bin/test-browser` builds with `workers: 1`, `retries: 0` and
// `BROWSER_E2E=true`. Expected labels, paths, dates and copy are literal values
// from the package spec, never derived from the components under test.
//
// Step 9's journey saves one real generation into the step-9 world and then
// reads it back on the ordinary Blocks, Runs, Rosters and Export surfaces. It is
// deliberately ordered — the desktop journey saves once and records the request
// URL it saved under, and the mobile journey reads that same request and the
// records it wrote — because the seed holds one version and a second save of the
// same request would be the same generation. An ordinary `bin/test-browser` run
// executes the whole file in order with one worker.
//
// Captures and the observed-facts records are written only when
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

// The step-9 world: `TodsGeneratorFixtures.tods_world_fixture/1`'s published
// version with a small schedule, one garage and one unblocked trip, so a
// generation adds block "103", the runs cut from the three blocks and one
// single-slot roster line and fictional operator per run-day.
const SAVED = {
  email: "tods-save@gtfs-planner.test",
  password: "TodsGenerator123!",
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
const saved = [];

// The URL the desktop journey saved under, with its request token. The mobile
// journey reads that same request, which is the recovery the page promises.
let savedRequestPath = null;

function record(fact) {
  observed.push(fact);
}

function recordSaved(fact) {
  saved.push(fact);
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

  writeFileSync(
    resolve(CAPTURE_ROOT, "result.json"),
    `${JSON.stringify(
      { spec: "37-tods-generator", step: 9, saved, requestPath: savedRequestPath },
      null,
      2,
    )}\n`,
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

// The step-9 journey. Desktop runs it: the real menu opens the generator, the
// preview reads the seeded schedule, and the save writes one generation. Every
// consumer then reads the same request back on the ordinary screens.
test.describe("TODS generator preview and save at desktop", () => {
  test.use({ viewport: { width: DESKTOP.width, height: DESKTOP.height } });

  test("preview and save: the menu saves one generation and shows its receipt", async ({
    page,
  }) => {
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await logInAs(page, SAVED);
    await waitForLiveView(page);

    const href = await generatorHref(page);
    await page.locator("#tods-generator-link").click();
    await page.waitForURL((url) => url.pathname === href);
    await waitForLiveView(page);

    const versionId = href.split("/")[2];

    // One garage is preselected, because one garage is not a choice.
    await expect(page.locator("#tods-garage-select option:checked")).not.toHaveText(
      "Choose a garage",
    );

    await page.locator("#tods-preview-button").click();

    // The preview is a real read of the stored schedule: one new block for the
    // one unblocked trip, the assumption the allocation rests on, and the
    // recurring effect a saved roster change has beyond the selected dates.
    await expect(page.locator("#tods-generation-preview")).toBeVisible();
    await expect(page.locator("#tods-preview-count-blocks")).toHaveText("1 new block");
    await expect(page.locator("#tods-preview-kept")).toContainText("2 existing blocks");
    await expect(page.locator("#tods-preview-staffed")).toContainText("repeats by weekday");
    await expect(page.locator("#tods-preview-assumption-one_operator_per_run_day")).toBeVisible();
    await expect(page.locator("#tods-save-button")).toHaveText("Save generation");

    const saveBox = await page.locator("#tods-save-button").boundingBox();
    expect(saveBox.height).toBeGreaterThanOrEqual(44);
    expect(await bodyFitsViewport(page)).toBe(true);
    expect(pageErrors).toEqual([]);

    const previewShot = await capture(page, "journey-preview-desktop");
    recordSaved({ state: "preview", viewport: "desktop", screenshot: previewShot });
    recordSaved({
      state: "preview-facts",
      blocks: "1 new block",
      kept: "2 existing blocks",
    });

    // Save is one committing transaction of the stored preview.
    await page.locator("#tods-save-button").click();
    await expect(page.locator("#tods-generation-result")).toBeVisible();
    await expect(page.locator("#tods-result-count-blocks")).toHaveText("1 block");

    const url = new URL(page.url());
    savedRequestPath = `${url.pathname}${url.search}`;
    expect(savedRequestPath).toContain("request=");

    // The result's links are the ordinary screens and the normal operations
    // export, not a generator-specific route.
    await expect(page.locator("#tods-result-blocks")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/blocks`,
    );
    await expect(page.locator("#tods-result-runs")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/runs`,
    );
    await expect(page.locator("#tods-result-rosters")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/rosters`,
    );
    await expect(page.locator("#tods-result-operators")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/rosters`,
    );
    await expect(page.locator("#tods-result-export")).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/export?type=operations`,
    );

    await expect(page.locator("#tods-result-operators-note")).toContainText("Operators ·");
    expect(await bodyFitsViewport(page)).toBe(true);
    expect(pageErrors).toEqual([]);

    const resultShot = await capture(page, "journey-result-desktop");
    recordSaved({ state: "result", viewport: "desktop", screenshot: resultShot });

    // The ordinary Blocks screen shows the block the save stored.
    await page.goto(`/gtfs/${versionId}/blocks`);
    await waitForLiveView(page);
    await expect(page.locator('[data-block="103"]').first()).toBeVisible();

    const blocksShot = await capture(page, "journey-blocks-desktop");
    recordSaved({ state: "blocks", viewport: "desktop", screenshot: blocksShot });

    // The ordinary Runs screen shows runs cut from it.
    await page.goto(`/gtfs/${versionId}/runs`);
    await waitForLiveView(page);
    await expect(page.locator("#runs-timeline-body tr[data-run]").first()).toBeVisible();

    // The Rosters page carries the saved lines, and its existing Operators
    // drawer lists the fictional operators beside the organization's own.
    await page.goto(`/gtfs/${versionId}/rosters`);
    await waitForLiveView(page);
    await expect(page.locator("#rosters-operators-button")).toBeVisible();
    await page.locator("#rosters-operators-button").click();
    await expect(page.locator("#rosters-operators-drawer")).toBeVisible();
    await expect(page.locator("#rosters-operators-rows")).toContainText("Demo operator");

    const operatorsShot = await capture(page, "journey-operators-desktop");
    recordSaved({ state: "operators", viewport: "desktop", screenshot: operatorsShot });

    // The normal Export page opens on the operations type the result linked to.
    await page.goto(`/gtfs/${versionId}/export?type=operations`);
    await waitForLiveView(page);
    await expect(page.locator("#export-type-operations")).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/export\\?type=operations$`));

    expect(pageErrors).toEqual([]);
  });
});

// The records the desktop journey saved, read back at a phone viewport: the
// generator now has nothing left to add, and the ordinary Blocks, Rosters and
// Export screens show the same persisted facts. The journey reads its version
// through the ordinary account menu, so the world is not handed to it by a test.
test.describe("TODS generator persisted data at mobile", () => {
  test.use({ viewport: { width: MOBILE.width, height: MOBILE.height } });

  test("persisted data: the saved generation is on the ordinary screens", async ({ page }) => {
    const pageErrors = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));

    await logInAs(page, SAVED);
    await waitForLiveView(page);

    const href = await generatorHref(page);
    await page.locator("#tods-generator-link").click();
    await page.waitForURL((url) => url.pathname === href);
    await waitForLiveView(page);

    const versionId = href.split("/")[2];

    // The work the desktop journey saved is now stored work: a fresh preview of
    // the same request has nothing left to add and refuses to save.
    await page.locator("#tods-preview-button").click();
    await expect(page.locator("#tods-generation-preview")).toBeVisible();
    await expect(page.locator("#tods-save-blocked")).toBeVisible();
    await expect(page.locator("#tods-save-button")).toBeDisabled();
    expect(await bodyFitsViewport(page)).toBe(true);
    expect(pageErrors).toEqual([]);

    const previewShot = await capture(page, "journey-preview-mobile");
    recordSaved({ state: "preview-nothing-left", viewport: "mobile", screenshot: previewShot });

    // The ordinary Blocks screen shows the block the save stored. A phone renders
    // the page's List view, and a desktop its day grid; each names the same block.
    await page.goto(`/gtfs/${versionId}/blocks`);
    await waitForLiveView(page);
    await expect(page.getByRole("heading", { name: "Block 103" })).toBeVisible();
    await expect(page.getByText("gen-a", { exact: true })).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);

    const blocksShot = await capture(page, "journey-blocks-mobile");
    recordSaved({ state: "blocks", viewport: "mobile", screenshot: blocksShot });

    // The Rosters page carries the saved lines, and its existing Operators drawer
    // lists the fictional operators beside the organization's own.
    await page.goto(`/gtfs/${versionId}/rosters`);
    await waitForLiveView(page);
    await page.locator("#rosters-operators-button").click();
    await expect(page.locator("#rosters-operators-rows")).toContainText("Demo operator");
    expect(await bodyFitsViewport(page)).toBe(true);

    const operatorsShot = await capture(page, "journey-operators-mobile");
    recordSaved({ state: "operators", viewport: "mobile", screenshot: operatorsShot });

    // The normal Export page opens on the operations type the result linked to.
    await page.goto(`/gtfs/${versionId}/export?type=operations`);
    await waitForLiveView(page);
    await expect(page.locator("#export-type-operations")).toBeVisible();
    expect(await bodyFitsViewport(page)).toBe(true);
    expect(pageErrors).toEqual([]);
  });
});
