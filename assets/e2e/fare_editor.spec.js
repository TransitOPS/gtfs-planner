// Fare editor browser journeys.
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`. Every seeded version is resolved by its exact name through
// the version panel, so a journey reads the fixture it names instead of
// whichever version is the organization's default.
//
// Step 31 seeds the five versions the editor's journeys draw. This file's `shell`
// block is step 32's: the Fares page shell, its five tabs and the routes between
// the two LiveViews. The following steps add one journey block each, the way
// `fare_zones.spec.js` grew alongside the zone workspace.
import { test, expect } from "@playwright/test";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { bodyFitsViewport } from "./browser_helpers.js";

// Each journey checks desktop and phone states and captures both views.
test.setTimeout(120_000);

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

// The five versions `test/support/browser_seed.exs` creates for this package,
// each in the state the editor draws for it.
const VERSIONS = {
  managed: "Browser North Coast Fares Version",
  blank: "Browser Blank Fares Version",
  unmanaged: "Browser Unmanaged V1 Fares Version",
  mismatch: "Browser Fares Mismatch Version",
  gaps: "Browser Fares Gaps Version",
};

// The five tabs and the path each one names, in the order the strip shows them.
const TABS = [
  ["prices", ""],
  ["where", "/where"],
  ["transfers", "/transfers"],
  ["zones", "/zones"],
  ["checks", "/checks"],
];

const DESKTOP = { width: 1440, height: 900, label: "1440" };
const PHONE = { width: 390, height: 844, label: "390" };

// A 1×1 transparent PNG. The zone workspace's map requests tiles, and answering
// them locally keeps a shell journey from depending on the Geoapify plan or on
// network access — the same stub `fare_zones.spec.js` installs.
const BLANK_TILE = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
  "base64",
);

// Spec artifacts deliberately do not belong to implementation worktrees. Set
// FARE_EDITOR_SPEC_ROOT to the canonical package when this test runs in one.
const SPEC_ROOT =
  process.env.FARE_EDITOR_SPEC_ROOT ||
  resolve(REPO_ROOT, "..", "gtfs-planner", ".specs", "29-fares-v1-v2-add-edit");
const REFERENCE_PATH = resolve(
  SPEC_ROOT,
  "references",
  "fares-editor-prototype.html",
);

const CAPTURE_DIR =
  process.env.FARE_EDITOR_CAPTURE_DIR ||
  resolve(dirname(REFERENCE_PATH), "../evidence/captures");

let priceRecovery;

// ── shared helpers ────────────────────────────────────────────────────────

async function logIn(page) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  await page.waitForSelector("[data-phx-main].phx-connected");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// A click that lands before the LiveView joins is dropped, so every navigation
// waits for the mounted view first.
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

async function restoreFarePrice(page) {
  if (!priceRecovery) return;

  for (const otherPage of page.context().pages()) {
    if (otherPage !== page) await otherPage.close();
  }

  await logIn(page);
  await page.goto(`/gtfs/${priceRecovery.versionId}/settings/fares`);
  await waitForLiveView(page);
  await page.reload();
  await waitForLiveView(page);

  const amount = page.locator(priceRecovery.selector);
  if ((await amount.inputValue()) !== priceRecovery.expected) {
    await amount.fill(priceRecovery.value);
    await amount.blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fare-note")).toContainText("1 price saved");
    await page.reload();
    await waitForLiveView(page);
  }

  await expect(page.locator(priceRecovery.selector)).toHaveValue(priceRecovery.expected);
  priceRecovery = undefined;
}

function psql(databaseUrl, sql) {
  return execFileSync(
    "psql",
    [
      "-X",
      "--no-psqlrc",
      "-v",
      "ON_ERROR_STOP=1",
      "--tuples-only",
      "--no-align",
      "--dbname",
      databaseUrl,
      "-c",
      sql,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 },
  ).trim();
}

function fareTestDatabase() {
  const databaseUrl = process.env.GTFS_PLANNER_TEST_DATABASE_URL;
  const ownedDirectory = process.env.FARE_EDITOR_OWNED_PG_DIR;
  if (!databaseUrl || !ownedDirectory) {
    throw new Error("The load-error capture requires the owned fare-editor test database environment.");
  }

  const parsed = new URL(databaseUrl);
  const databasePath = decodeURIComponent(parsed.pathname.slice(1));
  if (
    !new Set(["127.0.0.1", "::1"]).has(parsed.hostname) ||
    !/^gtfs_planner_exunit(?:_[a-zA-Z0-9]+)*$/.test(databasePath)
  ) {
    throw new Error("The load-error capture refused a database outside the loopback test target.");
  }

  const databaseName = psql(databaseUrl, "SELECT current_database()");
  const serverAddress = psql(databaseUrl, "SELECT host(inet_server_addr())");
  const dataDirectory = psql(databaseUrl, "SHOW data_directory");
  if (databaseName !== databasePath || !new Set(["127.0.0.1", "::1"]).has(serverAddress)) {
    throw new Error("The load-error capture refused a database whose server identity is not the loopback test target.");
  }
  if (realpathSync(dataDirectory) !== realpathSync(ownedDirectory)) {
    throw new Error("The load-error capture refused a PostgreSQL data directory other than FARE_EDITOR_OWNED_PG_DIR.");
  }

  return databaseUrl;
}

function fareProductLockCount(databaseUrl, applicationName) {
  const sql = `
    SELECT count(*)
    FROM pg_locks AS locks
    JOIN pg_class AS relation ON relation.oid = locks.relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    JOIN pg_stat_activity AS activity ON activity.pid = locks.pid
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'fare_products'
      AND locks.mode = 'AccessExclusiveLock'
      AND locks.granted
      AND activity.application_name = '${applicationName}'
  `;
  return psql(databaseUrl, sql);
}

async function disconnectBlockedFareReader(databaseUrl, lockerPid) {
  const readerScope = `
    reader.datname = current_database()
    AND reader.usename = current_user
    AND reader.backend_type = 'client backend'
    AND reader.state = 'active'
    AND reader.wait_event_type = 'Lock'
    AND reader.pid <> pg_backend_pid()
    AND reader.query ~ '^[[:space:]]*SELECT'
    AND reader.query LIKE '%"fare_products"%'
    AND ${lockerPid} = ANY(pg_blocking_pids(reader.pid))
  `;
  let readerPid;
  await expect.poll(() => {
    readerPid = psql(databaseUrl, `
      SELECT reader.pid FROM pg_stat_activity AS reader WHERE ${readerScope}
    `);
    return readerPid;
  }, { timeout: 10000, intervals: [100, 250, 500] }).toMatch(/^[0-9]+$/);

  // A held query's timeout reports Postgrex query_canceled, not the connection
  // loss this state handles. Disconnect only the reader blocked by this test's
  // exact locker, on the positively verified owned database, before it times out.
  const terminated = psql(databaseUrl, `
    SELECT pg_terminate_backend(reader.pid) FROM pg_stat_activity AS reader
    WHERE reader.pid = ${readerPid} AND ${readerScope}
  `);
  expect(terminated).toBe("t");
  console.log("Owned fare catalog reader termination", JSON.stringify({ readerPid, lockerPid, terminated }));
}

async function withFareProductCatalogLock(callback) {
  const databaseUrl = fareTestDatabase();
  const applicationName = `fare_layout_lock_${randomUUID().replaceAll("-", "")}`;
  const locker = spawn(
    "gtimeout",
    [
      "--signal=TERM",
      "--kill-after=10s",
      "120s",
      "psql",
      "-X",
      "--no-psqlrc",
      "-v",
      "ON_ERROR_STOP=1",
      "--tuples-only",
      "--no-align",
      "--dbname",
      databaseUrl,
    ],
    { stdio: ["pipe", "ignore", "ignore"] },
  );
  let spawnError;
  let backendPid;
  locker.once("error", (error) => {
    spawnError = error;
  });
  locker.stdin.end(
    `SET application_name = '${applicationName}'; BEGIN; LOCK TABLE public.fare_products IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(300); ROLLBACK;`,
  );

  try {
    await expect.poll(() => {
      if (spawnError) throw spawnError;
      return fareProductLockCount(databaseUrl, applicationName);
    }, {
      timeout: 10000,
      intervals: [100, 250, 500],
    }).toBe("1");
    backendPid = psql(databaseUrl, `
      SELECT pid FROM pg_stat_activity
      WHERE datname = current_database() AND usename = current_user
        AND application_name = '${applicationName}'
    `);
    expect(backendPid).toMatch(/^[0-9]+$/);
    console.log("Owned fare catalog lock", JSON.stringify({ applicationName, backendPid }));
    await callback(() => disconnectBlockedFareReader(databaseUrl, backendPid));
  } finally {
    // Closing psql alone does not interrupt the server's pg_sleep; its lock
    // could otherwise outlive a failed scenario. End only this recorded,
    // uniquely named backend on the positively verified disposable cluster.
    try {
      if (backendPid) {
        const terminated = psql(databaseUrl, `
          SELECT pg_terminate_backend(pid) FROM pg_stat_activity
          WHERE pid = ${backendPid} AND datname = current_database()
            AND usename = current_user AND application_name = '${applicationName}'
        `);
        console.log("Owned fare catalog lock termination", JSON.stringify({ backendPid, terminated }));
      }
    } finally {
      if (locker.pid && locker.exitCode === null && locker.signalCode === null) {
        locker.kill("SIGTERM");
      }
      if (locker.pid) {
        await expect.poll(() => locker.exitCode !== null || locker.signalCode !== null, {
          timeout: 5000,
        }).toBe(true);
      }
      await expect.poll(() => fareProductLockCount(databaseUrl, applicationName), {
        timeout: 5000,
        intervals: [100, 250, 500],
      }).toBe("0");
    }
  }
}

// Resolves any seeded version by its exact name through the version panel. The
// panel lists every published version of the organization, so a journey reads
// the fixture it names instead of whichever version is the default.
async function versionIdByName(page, name) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: name });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${name} is missing its version ID`);
  return versionId;
}

async function routeBlankTiles(page) {
  await page.route("**/map/tiles/**", (route) =>
    route.fulfill({ status: 200, contentType: "image/png", body: BLANK_TILE }),
  );
}

async function capture(page, testInfo, name) {
  await assertFareLayout(page);
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  // A drawer slides in over the page, so a capture taken as it arrives shows a
  // half-open panel. Playwright fast-forwards CSS animations so every capture
  // shows the settled state.
  await page.screenshot({ path, fullPage: true, animations: "disabled" });
  return path;
}

// A drawer and its confirm dialog are fixed to the edge of the viewport, so a
// full-page capture — which the Prices tab needs for its whole grid — leaves
// them off the image. Drawer states are captured in the viewport instead.
async function captureDrawer(page, testInfo, name) {
  await assertFareLayout(page);
  let path = testInfo.outputPath(`${name}.png`);

  if (CAPTURE_DIR) {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    path = resolve(CAPTURE_DIR, `${name}.png`);
  }

  await page.screenshot({ path, fullPage: false, animations: "disabled" });
  return path;
}

// Capture each immutable prototype state at both prepared viewports. Keep the
// reference on its own page so it cannot replace the production state or its
// measurements.
async function captureReference(page, testInfo, query, name) {
  expect(existsSync(REFERENCE_PATH), `required fare editor prototype is missing: ${REFERENCE_PATH}`).toBe(true);

  const reference = await page.context().newPage();
  try {
    mkdirSync(CAPTURE_DIR, { recursive: true });
    for (const viewport of [DESKTOP, PHONE]) {
      await reference.setViewportSize({ width: viewport.width, height: viewport.height });
      await reference.goto(`file://${REFERENCE_PATH}${query}`);
      await reference.waitForLoadState("networkidle");
      await reference.screenshot({
        path: resolve(CAPTURE_DIR, `${name}-${viewport.label}.png`),
        fullPage: false,
      });
    }
  } finally {
    await reference.close();
  }
}

async function captureFirstPaintLoading(page, testInfo, versionId) {
  for (const viewport of [DESKTOP, PHONE]) {
    const loadingPage = await page.context().newPage();
    try {
      await loadingPage.setViewportSize({ width: viewport.width, height: viewport.height });
      await loadingPage.routeWebSocket("**/live/websocket*", () => {});
      await loadingPage.goto(`/gtfs/${versionId}/settings/fares`);
      await expect(loadingPage.locator("#fare-editor-loading")).toBeVisible();
      await capture(loadingPage, testInfo, `prod-loading-${viewport.label}`);
    } finally {
      await loadingPage.close();
    }
  }
}

// Each layout-tagged journey calls this at the state it captures. Keep the
// measurements in the browser so device-pixel scaling cannot hide CSS overflow
// or undersized controls.
async function assertFareLayout(page) {
  expect(page.url(), "production metrics must never measure the prototype").not.toMatch(/^file:/);
  await expect(page.locator("#fare-editor-page, #route-fares")).toHaveCount(1);
  // Measure the settled drawer before checking targets; screenshot animation
  // handling happens after these assertions. Infinite decorative animations
  // have no completed state and must not block a capture.
  await page.evaluate(async () => {
    const finite = document.getAnimations().filter((animation) =>
      animation.effect?.getComputedTiming().iterations !== Infinity,
    );
    await Promise.all(finite.map((animation) => animation.finished.catch(() => {})));
  });
  const measurements = await page.evaluate(() => {
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
    };
    const controls = [...document.querySelectorAll(
      'button, input:not([type="hidden"]), select, textarea, summary, a.btn, [role="button"]',
    )].filter(visible).filter((element) => !element.matches("a:not(.btn)"));
    const primary = [...document.querySelectorAll(
      'button.btn-primary, a.btn-primary, [role="button"].btn-primary',
    )].filter(visible);
    const overlays = primary.filter((element) => element.closest('[role="dialog"], dialog, .drawer'));
    const pagePrimaries = primary.filter((element) => !element.closest('[role="dialog"], dialog, .drawer'));
    return {
      viewport: window.innerWidth,
      document: document.documentElement.scrollWidth,
      shortControls: controls.filter((element) => {
        const target = element.matches('input[type="checkbox"], input[type="radio"]')
          ? element.closest("label") || element
          : element;
        return target.getBoundingClientRect().height < 44;
      }).map((element) => {
        const target = element.matches('input[type="checkbox"], input[type="radio"]')
          ? element.closest("label") || element
          : element;
        return {
          tag: element.tagName,
          id: element.id,
          text: element.textContent.trim().slice(0, 50),
          height: target.getBoundingClientRect().height,
        };
      }),
      pagePrimaries: pagePrimaries.length,
      overlayPrimaries: overlays.length,
    };
  });

  expect(measurements.document, `horizontal overflow at ${measurements.viewport}px: ${JSON.stringify(measurements)}`)
    .toBeLessThanOrEqual(measurements.viewport);
  expect(measurements.pagePrimaries, `multiple page primaries: ${JSON.stringify(measurements)}`)
    .toBeLessThanOrEqual(1);
  expect(measurements.overlayPrimaries, `multiple overlay primaries: ${JSON.stringify(measurements)}`)
    .toBeLessThanOrEqual(1);
  expect(measurements.shortControls, `controls below 44px: ${JSON.stringify(measurements.shortControls)}`)
    .toEqual([]);

  // Start each capture's keyboard check at a visible control in the active
  // dialog or page. A refused submit can replace the previously focused
  // control, and a modal makes background controls inert.
  await page.evaluate(() => {
    const scope = Array.from(document.querySelectorAll('dialog[open]')).at(-1) || document;
    const candidates = Array.from(
      scope.querySelectorAll(
        'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    );
    const firstVisible = candidates.find((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return (
        rect.width > 0 &&
        rect.height > 0 &&
        style.visibility !== "hidden" &&
        style.display !== "none" &&
        !element.closest('[aria-hidden="true"], [inert]')
      );
    });

    firstVisible?.focus();
  });
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => {
    const element = document.activeElement;
    if (!element || element === document.body) {
      return {
        visible: false,
        tag: element?.tagName ?? null,
        id: element?.id ?? null,
        focusVisible: false,
        outline: null,
        boxShadow: null,
      };
    }
    const style = getComputedStyle(element);
    const outline = style.outlineStyle !== "none" && parseFloat(style.outlineWidth) > 0;
    const shadow = style.boxShadow !== "none";
    return {
      visible: element.matches(":focus-visible") && (outline || shadow),
      tag: element.tagName,
      id: element.id,
      focusVisible: element.matches(":focus-visible"),
      outlineStyle: style.outlineStyle,
      outlineWidth: style.outlineWidth,
      boxShadow: style.boxShadow,
    };
  });
  expect(
    focus.visible,
    `Tab focus must be visible and treated: ${JSON.stringify(focus)}`,
  ).toBe(true);
}

// ── shell ─────────────────────────────────────────────────────────────────

// The Fares page shell. The seeded fare editor fixtures are each found by their
// own name and the page opens on each of them without error, the five tabs name
// their own paths, the Zones tab lands on the zone workspace's own LiveView, the
// retired Fare rules path redirects to Where fares apply, and the header carries
// exactly one primary per tab. Every later journey block builds on this.
test.describe("layout", () => {
test.beforeEach(async ({ page }) => {
  await restoreFarePrice(page);
  // A replacement Playwright worker has no memory of the previous worker's
  // pending recovery. Restore the two persisted prices through the real editor
  // before each scenario, so a failed scenario cannot contaminate its successor.
  await logIn(page);
  const versionId = await versionIdByName(page, VERSIONS.managed);
  for (const [selector, value] of [
    ["#price-local_ride-adult", "1.50"],
    ["#price-intercity_ride-adult", "6.00"],
  ]) {
    priceRecovery = { versionId, selector, value, expected: `$${value}` };
    await restoreFarePrice(page);
  }
});

test.afterEach(async ({ page }) => {
  await restoreFarePrice(page);
});

test("shell", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};

  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  // Five distinct versions: a name resolving to another version's row would
  // silently give a journey the wrong fixture.
  expect(new Set(Object.values(found)).size).toBe(Object.keys(VERSIONS).length);

  const versionId = found.managed;

  await captureFirstPaintLoading(page, testInfo, versionId);

  for (const key of Object.keys(VERSIONS)) {
    await page.goto(`/gtfs/${found[key]}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("h1")).toHaveText("Fares");
    await expect(page).toHaveURL(
      new RegExp(`/gtfs/${found[key]}/settings/fares$`),
    );

    // The journey reached the version it named: the switcher marks it current.
    await expect(
      page.locator(`#gtfs-version-option-${found[key]}`),
    ).toHaveAttribute("aria-current", "true");
  }

  // The page frame: the back link, the lede and the one primary.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("#fare-editor-page")).toBeAttached();
  await expect(page.locator("#settings-back")).toHaveAttribute(
    "href",
    `/gtfs/${versionId}/settings`,
  );
  await expect(page.locator("#fare-editor-page")).toContainText(
    "What riders pay and which fare each ride charges.",
  );

  // No Settings nav, and the loading skeleton is gone once the fares resolved.
  await expect(page.locator("#settings-nav")).toHaveCount(0);
  await expect(page.locator("#fare-editor-loading")).toHaveCount(0);

  // One primary per view, and it follows the tab. The quiet "Open helper"
  // button beside it is not a primary, so the count is of primary buttons.
  for (const [tab, suffix] of [
    ["prices", ""],
    ["where", "/where"],
    ["transfers", "/transfers"],
    ["checks", "/checks"],
  ]) {
    await page.goto(`/gtfs/${versionId}/settings/fares${suffix}`);
    await waitForLiveView(page);

    const primaries = page.locator(
      "#fare-editor-page header button.btn-primary",
    );
    const expected = tab === "checks" ? 0 : 1;

    await expect(primaries).toHaveCount(expected);
  }

  // Every tab names its own path, and exactly one of them is current.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  for (const [tab, suffix] of TABS) {
    await expect(page.locator(`#fares-tab-${tab}`)).toHaveAttribute(
      "href",
      `/gtfs/${versionId}/settings/fares${suffix}`,
    );
  }

  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  for (const [tab] of TABS.filter(([name]) => name !== "prices")) {
    await expect(page.locator(`#fares-tab-${tab}`)).not.toHaveAttribute(
      "aria-current",
      "page",
    );
  }

  // The Checks tab carries the version's result, so a setup problem stays
  // visible from the other tabs. The seeded managed version is clean, so the
  // mark is a check beside a zero.
  await expect(
    page.locator("#fares-tab-checks #fares-checks-count"),
  ).toHaveText("0");

  // Zones is the other LiveView: the tab lands on the zone workspace's panel.
  await page.locator("#fares-tab-zones").click();
  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/zones$`),
    {
      timeout: 15000,
    },
  );
  await waitForLiveView(page);

  await expect(page.locator("#fare-zones-panel")).toBeAttached();
  await expect(page.locator("#fares-tab-zones")).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#fare-editor-page")).toHaveCount(0);

  // The retired Fare rules path redirects to Where fares apply rather than
  // rendering a tab of its own or 404ing.
  await page.goto(`/gtfs/${versionId}/settings/fares/rules`);
  await waitForLiveView(page);

  await expect(page).toHaveURL(
    new RegExp(`/gtfs/${versionId}/settings/fares/where$`),
  );
  await expect(page.locator("#fares-tab-where")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // A version with no fares at all still opens the shell.
  await page.goto(`/gtfs/${found.blank}/settings/fares`);
  await waitForLiveView(page);

  await expect(page.locator("h1")).toHaveText("Fares");
  await expect(page.locator("#fares-tab-prices")).toHaveAttribute(
    "aria-current",
    "page",
  );

  // ── captures ────────────────────────────────────────────────────────────
  // The shell at both prepared viewports, beside the prototype states it
  // follows, so branch review compares the same page at the same sizes.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({
      width: viewport.width,
      height: viewport.height,
    });
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);

    await expect(page.locator("#fare-editor-page")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `shell-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=prices", "ref-prices");
  await captureReference(page, testInfo, "?state=loading", "ref-loading");
  await captureReference(page, testInfo, "?state=load-error", "ref-load-error");

  // Finish the current page's catalog read before introducing the fault, so
  // only the next connected mount's reader can be blocked by our lock.
  await expect(page.locator("#fare-table")).toBeVisible();
  await withFareProductCatalogLock(async (disconnectReader) => {
    for (const viewport of [DESKTOP, PHONE]) {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await page.goto(`/gtfs/${versionId}/settings/fares`);
      await waitForLiveView(page);
      await disconnectReader();
      await expect(page.locator("#fare-editor-error")).toBeVisible({ timeout: 25_000 });
      await expect(page.locator("#fare-editor-reload")).toBeVisible();
      await capture(page, testInfo, `prod-load-error-${viewport.label}`);
    }
  });

  await page.locator("#fare-editor-reload").click();
  await expect(page.locator("#fare-table")).toBeVisible();
  await waitForLiveView(page);
});

// ── prices ─────────────────────────────────────────────────────────────────

// The Prices tab's fare grid, the save bar's unsaved preview, the conflict
// panel, and the older-format lens. Each state is proved through the DOM the
// LiveView renders — the grid is one cell per fare and rider type named for the
// row it writes, the save bar counts and describes what is unsaved, a concurrent
// change blocks the save until a price is chosen, and the lens tints exactly
// the cells the older format carries.
test("prices", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);
  priceRecovery = {
    versionId,
    selector: "#price-local_ride-adult",
    expected: "$1.50",
    value: "1.50",
  };

  // The grid itself: one row per fare, one column per rider type, and the
  // payment method sub-row for a fare the app prices differently.
  await page.goto(`/gtfs/${versionId}/settings/fares`);
  await waitForLiveView(page);

  const table = page.locator("#fare-table");
  await expect(table).toBeAttached();
  await expect(page.locator("#fare-table-title")).toHaveText("Fare table");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");
  await expect(page.locator("#price-local_ride-adult-app")).toHaveValue("$1.25");
  await expect(page.locator("#price-local_ride-child")).toHaveValue("Free");
  await expect(page.locator("#price-save-bar")).toHaveCount(0);

  // Editing one price raises the save bar, which names what is unsaved and how.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();

  const saveBar = page.locator("#price-save-bar");
  await expect(saveBar).toBeAttached();
  await expect(page.locator("#save-prices")).toHaveText("Save 1 price");
  await expect(saveBar).toContainText("Local ride · Adult $1.50 → $1.75");
  await expect(page.locator("#fares-conflict")).toHaveCount(0);

  // A price `Fares.Money.parse/1` refuses keeps its own text, is marked
  // invalid, and blocks the save rather than being read as a blank.
  await page.locator("#price-local_ride-adult").fill("1..5");
  await page.locator("#price-local_ride-adult").blur();

  await expect(page.locator("#price-local_ride-adult")).toHaveValue("1..5");
  await expect(page.locator("#price-local_ride-adult")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.locator("#save-prices")).toHaveAttribute(
    "aria-disabled",
    "true",
  );
  await expect(saveBar).toContainText("Fix the highlighted price to save.");

  // The lens tints exactly the cells the older format carries: the default
  // rider type on a single ride's own row, and nothing else.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();

  await page.locator("#fare-lens").check();
  await expect(page.locator("#fare-lens-note")).toBeAttached();

  const tinted = page.locator('#fare-table [data-lens="in"]');
  await expect(tinted).toHaveCount(5);
  await expect(page.locator("#price-local_ride-adult").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "in",
  );
  await expect(page.locator("#price-local_ride-adult-app").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "out",
  );
  await expect(page.locator("#price-local_ride-reduced").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "out",
  );

  await page.locator("#fare-lens").uncheck();
  await expect(page.locator("#price-local_ride-adult").locator("xpath=..")).toHaveAttribute(
    "data-lens",
    "off",
  );

  // Discarding throws the edit away without writing anything.
  await page.locator("#discard-prices").click();
  await expect(page.locator("#price-save-bar")).toHaveCount(0);
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // Saving writes the reviewed cell and notes it, with the Undo beside it.
  await page.locator("#price-local_ride-adult").fill("1.75");
  await page.locator("#price-local_ride-adult").blur();
  await page.locator("#save-prices").click();

  await expect(page.locator("#fare-note")).toContainText("1 price saved");
  await expect(page.locator("#undo-prices")).toBeAttached();
  await expect(page.locator("#price-save-bar")).toHaveCount(0);
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

  // Undo puts the reviewed amount back.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // ── captures ────────────────────────────────────────────────────────────
  // The grid and each of its states at both prepared viewports, beside the
  // prototype states they follow.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });

    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-${viewport.label}`);

    // The seed's Toledo to Corvallis journey is $6.00. Its final intercity
    // leg uses this cell, so the unsaved 25-cent change previews $6.25.
    await page.locator("#price-intercity_ride-adult").fill("6.25");
    await page.locator("#price-intercity_ride-adult").blur();
    try {
      await expect(page.locator("#price-save-bar")).toContainText(
        "Toledo to Corvallis $6.00 → $6.25",
      );
      await capture(page, testInfo, `prod-prices-journeys-${viewport.label}`);
    } finally {
      if (await page.locator("#discard-prices").count()) {
        await page.locator("#discard-prices").click();
      }
    }
    await expect(page.locator("#price-intercity_ride-adult")).toHaveValue("$6.00");

    // The save bar with an unsaved price, the editing state.
    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();
    await expect(page.locator("#price-save-bar")).toBeAttached();
    await capture(page, testInfo, `prices-editing-${viewport.label}`);
    await page.locator("#discard-prices").click();

    // The invalid state: a price the parser refuses.
    await page.locator("#price-local_ride-adult").fill("1..5");
    await page.locator("#price-local_ride-adult").blur();
    await expect(page.locator("#save-prices")).toHaveAttribute(
      "aria-disabled",
      "true",
    );
    await capture(page, testInfo, `prices-invalid-${viewport.label}`);
    await page.locator("#discard-prices").click();

    // The saved state: the note with its Undo beside it.
    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fare-note")).toContainText("1 price saved");
    await capture(page, testInfo, `prices-saved-${viewport.label}`);
    await page.locator("#undo-prices").click();
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

    // The conflict panel, reached the way it happens: a second editor on the
    // same version saves the cell between this editor's edit and their save.
    // The second tab is the same signed-in session, so it is the same operator
    // on another tab rather than a fixture-only shortcut.
    const second = await page.context().newPage();
    await second.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(second);

    await page.locator("#price-local_ride-adult").fill("1.75");
    await page.locator("#price-local_ride-adult").blur();

    await second.locator("#price-local_ride-adult").fill("1.60");
    await second.locator("#price-local_ride-adult").blur();
    await second.locator("#save-prices").click();
    await expect(second.locator("#fare-note")).toContainText("1 price saved");

    await page.locator("#save-prices").click();
    await expect(page.locator("#fares-conflict")).toBeAttached();
    await expect(page.locator("#save-prices")).toHaveAttribute(
      "aria-disabled",
      "true",
    );
    await expect(page.locator("#fares-conflict")).toContainText("Local ride · Adult");
    await expect(page.locator("#fares-conflict")).toContainText("$1.60");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-conflict-${viewport.label}`);

    // Choosing this editor's price resolves the conflict and saves. The panel
    // is scrolled to the top of the viewport first: the save bar is sticky to
    // the bottom of the panel, and a radio scrolled under it is not clickable.
    await page.locator("#fares-conflict").evaluate((panel) => {
      panel.scrollIntoView({ block: "start" });
    });
    const keepMine = page.locator('#fares-conflict input[value="mine"]').first();
    await keepMine.locator("xpath=ancestor::label").click({ noWaitAfter: true });
    await expect(page.locator("#fares-conflict")).toContainText("Yours is kept");
    await page.locator("#save-prices").click();
    await expect(page.locator("#fares-conflict")).toHaveCount(0);
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

    // Undo takes that save back to what was stored when it was reviewed, and a
    // last edit puts the version back at the sample's own $1.50 so the journeys
    // after this one read the fixture they seeded.
    await page.locator("#undo-prices").click();
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.60");

    await second.close();

    await page.locator("#price-local_ride-adult").fill("1.50");
    await page.locator("#price-local_ride-adult").blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fare-note")).toContainText("1 price saved");
    await page.reload();
    await waitForLiveView(page);
    await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

    // The older-format lens.
    await page.locator("#fare-lens").check();
    await expect(page.locator("#fare-lens-note")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prices-lens-${viewport.label}`);
    await page.locator("#fare-lens").uncheck();
  }

  await captureReference(page, testInfo, "?state=prices", "ref-prices-grid");
  await captureReference(page, testInfo, "?state=prices-editing", "ref-prices-editing");
  await captureReference(page, testInfo, "?state=prices-invalid", "ref-prices-invalid");
  await captureReference(page, testInfo, "?state=prices-saved", "ref-prices-saved");
  await captureReference(page, testInfo, "?state=prices-conflict", "ref-prices-conflict");
  await captureReference(page, testInfo, "?state=prices-lens", "ref-prices-lens");
  await captureReference(page, testInfo, "?state=prices-journeys", "ref-prices-journeys");
});

// ── drawers ───────────────────────────────────────────────────────────────

// The three drawers the Prices tab owns — the fare, the rider type and the
// payment method — and the confirm dialog that settles a fare's rules.
//
// Each journey proves one thing through the DOM the LiveView renders: a
// rejected save lands on the error summary rather than on the first field, a
// priced fare cannot be deleted until the operator says what its rides charge
// instead, the rider type shown first offers no delete action, and Escape puts
// focus back on the control that opened the drawer.
test("drawers", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);

  const openPrices = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
  };

  // A refused save focuses the summary that lists what to fix, and the summary
  // links to the field each failure names. Both drawers, so the answer is not
  // the fare drawer's own habit.
  await openPrices();

  await page.locator("#create-fare").click();
  await expect(page.locator("#fare-drawer")).toBeAttached();
  await expect(page.locator("#fare-media-cash")).toBeChecked();
  await page.locator("#fare-price-adult").fill("1.00");
  await page.locator("#fare-save").click();

  const summary = page.locator("#error-summary");
  await expect(summary).toBeAttached();
  await expect(summary).toHaveAttribute("tabindex", "-1");
  await expect(page.locator('#error-summary a[href="#fare-name"]')).toHaveCount(1);
  await expect(
    await page.evaluate(() => document.activeElement?.id),
  ).toBe("error-summary");

  // No summary at all while the form is valid: it is drawn only for a refusal.
  await page.locator("#fare-name").fill("Summer beach shuttle");
  await page.locator("#fare-save").click();

  await expect(page.locator("#fare-drawer")).toHaveCount(0);
  await expect(page.locator("#error-summary")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("Summer beach shuttle saved");
  await expect(page.locator("#fare-table")).toContainText("Summer beach shuttle");

  // The fare is removed again so the journeys after this one read the fixture
  // they seeded.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#fare-table")).not.toContainText(
    "Summer beach shuttle",
  );

  // Escape closes the drawer and puts focus back on the control that opened it,
  // which is the fare name the grid drew.
  await page.locator("#fare-open-local_ride").click();
  await expect(page.locator("#fare-drawer")).toBeAttached();
  await expect(page.locator("#fare-name")).toHaveValue("Local ride");

  await page.keyboard.press("Escape");
  await expect(page.locator("#fare-drawer")).toHaveCount(0);
  expect(await page.evaluate(() => document.activeElement?.id)).toBe(
    "fare-open-local_ride",
  );

  // A fare no rule charges deletes without a replacement question at all.
  await openPrices();
  await page.locator("#create-fare").click();

  await page.locator("#fare-name").fill("Summer beach shuttle");
  await page.locator("#fare-price-adult").fill("1.00");
  await page.locator("#fare-save").click();
  await expect(page.locator("#fare-table")).toContainText("Summer beach shuttle");

  // A priced fare will not go until its rules say what they charge instead.
  await page.locator("#fare-open-valley_ride").click();
  await page.locator("#fare-delete").click();
  await expect(page.locator("#fare-delete-dialog")).toBeAttached();
  await expect(page.locator("#fare-delete-rules")).toContainText("Valley ride");
  await expect(page.locator("#fare-delete-replacement")).toBeAttached();

  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-delete-dialog")).toBeAttached();
  await expect(page.locator("#fare-delete-replacement")).toHaveAttribute(
    "aria-invalid",
    "true",
  );
  await expect(page.locator("#fare-delete-replacement-error")).toHaveText(
    "Choose what these rides charge instead.",
  );
  await expect(page.locator("#fare-table")).toContainText("Valley ride");

  // Choosing Coast ride deletes the fare and points its rules there.
  await page.locator("#fare-delete-replacement").selectOption("coast_ride_adult_cash");
  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-delete-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-table")).not.toContainText("Valley ride");

  // Undo is the whole way back, and it restores the fare and its rules.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-table")).toContainText("Valley ride");

  await page.locator("#fare-open-summer_beach_shuttle").click();
  await page.locator("#fare-delete").click();
  await expect(page.locator("#fare-delete-unused")).toBeAttached();
  await page.locator("#fare-delete-dialog-confirm").click();
  await expect(page.locator("#fare-table")).not.toContainText(
    "Summer beach shuttle",
  );

  // The rider type shown first is the one trip planners lead with, so it offers
  // no delete action; another one does.
  await page.locator("#rider-edit-adult").click();
  await expect(page.locator("#rider-drawer")).toBeAttached();
  await expect(page.locator("#rider-name")).toHaveValue("Adult");
  await expect(page.locator("#rider-delete")).toHaveCount(0);
  await expect(page.locator("#rider-default")).toBeDisabled();

  await page.locator("#rider-cancel").click();
  await expect(page.locator("#rider-drawer")).toHaveCount(0);

  await page.locator("#rider-edit-reduced").click();
  await expect(page.locator("#rider-delete")).toBeAttached();
  await page.locator("#rider-cancel").click();

  // A create states the starting prices it would create before it writes them.
  await page.locator("#create-rider").click();
  await expect(page.locator("#rider-starting-preview")).toBeAttached();
  await expect(page.locator("#rider-name")).toHaveValue("");
  await page.locator("#rider-save").click();
  await expect(page.locator('#error-summary a[href="#rider-name"]')).toHaveCount(1);

  await page.locator("#rider-name").fill("Senior (65+)");
  await page.locator("#rider-starting-half").check();
  await page.locator("#rider-save").click();
  await expect(page.locator("#rider-drawer")).toHaveCount(0);
  await expect(page.locator("#rider-edit-senior_65")).toBeAttached();

  await page.locator("#undo-prices").click();
  await expect(page.locator("#rider-edit-senior_65")).toHaveCount(0);

  // The payment method drawer offers GTFS's five kinds and the fares that
  // accept it.
  await page.locator("#create-media").click();
  await expect(page.locator("#media-drawer")).toBeAttached();
  await expect(page.locator("#media-kind-4")).toBeAttached();

  await page.locator("#media-save").click();
  await expect(page.locator('#error-summary a[href="#media-name"]')).toHaveCount(1);

  await page.locator("#media-name").fill("NCT Ride app");
  await page.locator("#media-kind-4").check();
  await page.locator("#media-fare-local_ride").check();
  await page.locator("#media-save").click();
  await expect(page.locator("#media-drawer")).toHaveCount(0);
  await expect(page.locator("#fare-payment-title")).toBeAttached();
  await expect(page.locator("#media-open-nct_ride_app")).toBeAttached();
  await expect(page.locator("#fare-payment-list")).toContainText(
    "NCT Ride app",
  );

  // The payment method this journey made is removed again through its own
  // drawer, so the captures below read the fixture this journey seeded.
  await page.locator("#media-open-nct_ride_app").click();
  await page.locator("#media-delete").click();
  await page.locator("#media-delete-dialog-confirm").click();
  await expect(page.locator("#media-drawer")).toHaveCount(0);
  // The seed already carries an app by that name, so what went is the method
  // this journey made — its own row, the one the drawer opened.
  await expect(page.locator("#media-open-nct_ride_app")).toHaveCount(0);
  await expect(page.locator("#media-open-app")).toBeAttached();

  // ── captures ────────────────────────────────────────────────────────────
  // Each drawer state at both prepared viewports, beside the prototype states
  // they follow.
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPrices();

    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `drawers-prices-${viewport.label}`);

    // Passes use the same fare drawer with the pass-specific fields and
    // older-format explanation.
    await page.locator("#fare-open-day_pass").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(page.locator("#fare-name")).toHaveValue("Day pass");
    await expect(page.locator('#fare-kind input[type="radio"][value="pass"]')).toBeChecked();
    await expect(page.locator("#fare-result-card")).toContainText("$4.00");
    await expect(page.locator("#fare-result-card")).toContainText("Not in the older format");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `prod-pass-edit-${viewport.label}`);
    await page.locator("#fare-cancel").click();

    // The fare drawer, empty and ready to be filled in.
    await page.locator("#create-fare").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
await captureDrawer(page, testInfo, `drawers-fare-create-${viewport.label}`);

    // The same drawer with prices typed, so the live result card is showing.
    await page.locator("#fare-name").fill("Summer beach shuttle");
    await page.locator("#fare-price-adult").fill("1.00");
    await page.locator("#fare-price-reduced").fill("0.50");
    await page.locator("#fare-differ").check();
    await expect(page.locator("#fare-result-card")).toBeAttached();
    await expect(page.locator("#fare-result-card")).toContainText("$1.00");
    await captureDrawer(page, testInfo, `drawers-fare-filled-${viewport.label}`);

    // The refused state: the summary focused and linked to the name.
    await page.locator("#fare-name").fill("");
    await page.locator("#fare-save").click();
    await expect(page.locator("#error-summary")).toBeAttached();
    await captureDrawer(page, testInfo, `drawers-fare-errors-${viewport.label}`);
    await page.locator("#fare-cancel").click();

    // The fare being edited, with its own prices.
    await page.locator("#fare-open-local_ride").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(page.locator("#fare-result-card")).toContainText("$1.50");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-fare-edit-${viewport.label}`);
    await page.locator("#fare-cancel").click();

    // The delete dialog, and the refused delete that asks for a replacement.
    await page.locator("#fare-open-valley_ride").click();
    await page.locator("#fare-delete").click();
    await expect(page.locator("#fare-delete-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-fare-delete-${viewport.label}`);

    await page.locator("#fare-delete-dialog-confirm").click();
    await expect(page.locator("#fare-delete-replacement-error")).toHaveText(
      "Choose what these rides charge instead.",
    );
    await captureDrawer(page, testInfo, `drawers-fare-delete-error-${viewport.label}`);

    await page.locator("#fare-delete-replacement").selectOption("coast_ride_adult_cash");
    await expect(page.locator("#fare-delete-replacement")).toHaveValue(
      "coast_ride_adult_cash",
    );
    await page.locator("#fare-delete-dialog-cancel").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await page.locator("#fare-cancel").click();

    // The rider type drawer, and its create with the starting prices stated.
    await page.locator("#create-rider").click();
    await expect(page.locator("#rider-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-rider-create-${viewport.label}`);
    await page.locator("#rider-cancel").click();

    await page.locator("#rider-edit-reduced").click();
    await expect(page.locator("#rider-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-rider-edit-${viewport.label}`);
    await page.locator("#rider-delete").click();
    await expect(page.locator("#rider-delete-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `prod-rider-delete-${viewport.label}`);
    await page.locator("#rider-delete-dialog-cancel").click();
    await page.locator("#rider-cancel").click();

    // The payment method drawer and its create.
    await page.locator("#create-media").click();
    await expect(page.locator("#media-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-create-${viewport.label}`);
    await page.locator("#media-cancel").click();

    await page.locator("#media-open-app").click();
    await expect(page.locator("#media-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-edit-${viewport.label}`);

    await page.locator("#media-delete").click();
    await expect(page.locator("#media-delete-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `drawers-media-delete-${viewport.label}`);
    await page.locator("#media-delete-dialog-cancel").click();
  }

  await captureReference(page, testInfo, "?state=fare-edit", "ref-fare-edit");
  await captureReference(page, testInfo, "?state=pass-edit", "ref-pass-edit");
  await captureReference(page, testInfo, "?state=fare-create", "ref-fare-create");
  await captureReference(page, testInfo, "?state=fare-errors", "ref-fare-errors");
  await captureReference(page, testInfo, "?state=fare-delete", "ref-fare-delete");
  await captureReference(page, testInfo, "?state=rider-create", "ref-rider-create");
  await captureReference(page, testInfo, "?state=rider-edit", "ref-rider-edit");
  await captureReference(page, testInfo, "?state=rider-delete", "ref-rider-delete");
  await captureReference(page, testInfo, "?state=media-create", "ref-media-create");
});

// ── bulk ──────────────────────────────────────────────────────────────────

// The Change prices dialog. The journey proves the preview is computed and
// never written, that Update writes exactly what the preview listed, that Undo
// reverses it, and that choices moving nothing leave Update disabled with the
// reason on screen. Five single-ride fares have six adult prices because Local
// ride is sold on both cash and the NCT Ride app; adult-only Update therefore
// changes six prices.
test("bulk", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);

  const openPrices = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator("#fare-table")).toBeAttached();
  };

  // The dialog opens on the prototype's defaults, with a preview rather than a
  // save: nothing is written until Update.
  await openPrices();
  await page.locator("#change-prices").click();
  await expect(page.locator("#price-change-dialog")).toBeAttached();
  await expect(page.locator("#price-change-preview-badge")).toHaveText(
    "Preview · not saved",
  );
  await expect(page.locator("#price-change-scope")).toHaveValue("single");
  await expect(page.locator("#price-change-amount")).toHaveValue("0.25");
  await expect(page.locator("#price-change-round")).toHaveValue("0.05");
  await expect(page.locator("#price-change-half")).toBeChecked();
  await expect(page.locator("#price-change-rider-child")).toBeDisabled();

  const count = Number(
    (await page.locator("#price-change-count").innerText()).split("\n")[0].trim(),
  );
  expect(count).toBeGreaterThan(0);
  await expect(page.locator("#price-change-largest")).toContainText("+$0.25");
  await expect(page.locator("#price-change-row-local_ride_adult_cash")).toContainText(
    "$1.75",
  );
  await expect(page.locator("#price-change-empty")).toHaveCount(0);

  // A preview writes nothing.
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  // The choices recompute the preview: a percentage on one rider type.
  await page.locator("#price-change-rider-adult").check();
  await page.locator("#price-change-rider-reduced").uncheck();
  await page.locator("#price-change-rider-youth").uncheck();
  await page.locator("#price-change-how").selectOption("percent");
  await page.locator("#price-change-percent").fill("10");
  await page.locator("#price-change-round").selectOption("0.25");

  // 10% of Coast ride's $3.50 is $3.85, which rounds down to $3.75.
  await expect(page.locator("#price-change-row-coast_ride_adult_cash")).toContainText(
    "$3.75",
  );
  await expect(page.locator("#price-change-row-local_ride_reduced_cash")).toHaveCount(
    0,
  );

  // A choice that moves nothing disables Update and says why.
  await page.locator("#price-change-percent").fill("0");
  await expect(page.locator("#price-change-empty")).toBeAttached();
  await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();
  await expect(page.locator("#price-change-dialog-confirm")).toHaveText(
    "Update prices",
  );
  await expect(page.locator("#price-change-status")).toContainText(
    "Nothing changes until you update.",
  );

  // An unreadable amount is refused the same way, with its own reason.
  await page.locator("#price-change-percent").fill("ten percent");
  await expect(page.locator("#price-change-value-error")).toBeAttached();
  await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();

  // ── captures ────────────────────────────────────────────────────────────
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openPrices();

    await page.locator("#change-prices").click();
    await expect(page.locator("#price-change-dialog")).toBeAttached();
    await expect(page.locator("#price-change-count")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `bulk-${viewport.label}`);

    // The disabled state, with the reason on the status line.
    await page.locator("#price-change-amount").fill("0.00");
    await expect(page.locator("#price-change-empty")).toBeAttached();
    await expect(page.locator("#price-change-dialog-confirm")).toBeDisabled();
    await captureDrawer(page, testInfo, `bulk-empty-${viewport.label}`);

    await page.locator("#price-change-dialog-cancel").click();
    await expect(page.locator("#price-change-dialog")).toHaveCount(0);
  }

  // Update writes exactly what the preview listed, and Undo reverses it.
  await openPrices();
  await page.locator("#change-prices").click();
  await page.locator("#price-change-rider-reduced").uncheck();
  await page.locator("#price-change-rider-youth").uncheck();
  await page.locator("#price-change-rider-adult").check();

  await expect(page.locator("#price-change-dialog-confirm")).toHaveText(
    "Update 6 prices",
  );
  await page.locator("#price-change-dialog-confirm").click();
  await expect(page.locator("#price-change-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("6 prices changed");
  await expect(page.locator("#undo-prices")).toBeAttached();
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.75");

  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("Change undone.");
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");

  await captureReference(page, testInfo, "?state=bulk", "ref-bulk");
});

// ── setup ───────────────────────────────────────────────────────────────────

// The Prices tab's first-use setup, the fare-free summary, an imported
// version's read-only view with its conversion review, and the mismatch banner.
// Each state is proved through the DOM the LiveView renders, and each capture is
// taken at both prepared viewports beside the prototype state it follows.
test("setup", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};
  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  const conversionId = await versionIdByName(page, "Browser Unmanaged V1 Conversion Fares Version");

  const openVersion = async (versionId) => {
    await page.goto(`/gtfs/${versionId}/settings/fares`);
    await waitForLiveView(page);
  };

  // ── the first-use setup ────────────────────────────────────────────────
  // A version with no fare rows asks the four questions instead of drawing the
  // grid, and carries its one primary inside the panel rather than in the
  // header beside it.
  await openVersion(found.blank);

  await expect(page.locator("#fare-setup")).toBeAttached();
  await expect(page.locator("#fare-table")).toHaveCount(0);
  await expect(page.locator("#create-fare")).toHaveCount(0);
  await expect(page.locator("#setup-create")).toBeAttached();
  await expect(page.locator("#setup-step-1")).toBeAttached();
  await expect(page.locator("#setup-step-2")).toBeAttached();

  // The live result card reads the answers as they stand.
  await expect(page.locator("#setup-result")).toContainText("$1.50");
  await expect(page.locator("#setup-result")).toContainText("Reduced fare $0.75");
  await expect(page.locator("#setup-result")).toContainText(
    "Creates 1 fare, 3 rider types, 1 transfer rule.",
  );

  // Choosing a different structure changes what is asked, and the card follows.
  await page.locator("#setup-kind-route").check();
  await expect(page.locator("#setup-groups")).toBeAttached();
  await expect(page.locator("#setup-adult")).toHaveCount(0);
  await expect(page.locator("#setup-group-0-name")).toHaveValue("Local routes");
  await expect(page.locator("#setup-group-0-price")).toHaveValue("1.50");

  // A third group is the one answer that is not a field.
  await page.locator("#add-route-group").click();
  await expect(page.locator("#setup-group-2-name")).toHaveValue("");

  // A price the writer will not read is refused on the field it names, and
  // nothing is written.
  await page.locator("#setup-kind-flat").check();
  await page.locator("#setup-adult").fill("one fifty");
  await page.locator("#setup-adult").blur();
  await page.locator("#setup-create").click();

  await expect(page.locator("#fare-setup")).toBeAttached();
  await expect(page.locator("#setup-error-summary")).toBeAttached();
  await expect(page.locator("#setup-adult-error")).toBeAttached();

  // ── captures ────────────────────────────────────────────────────────────
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.blank);

    await expect(page.locator("#fare-setup")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-${viewport.label}`);

    // The route structure, whose group rows are the widest answer.
    await page.locator("#setup-kind-route").check();
    await expect(page.locator("#setup-groups")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-route-${viewport.label}`);

    // The zone structure's own question.
    await page.locator("#setup-kind-zone").check();
    await expect(page.locator("#setup-adult")).toHaveValue("1.50");
    await expect(page.locator("#setup-zone-help")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-first-use-zone-${viewport.label}`);

    // A refused answer, with the summary and the field's own reason.
    await page.locator("#setup-kind-flat").check();
    await page.locator("#setup-adult").fill("one fifty");
    await page.locator("#setup-adult").blur();
    await page.locator("#setup-create").click();
    await expect(page.locator("#setup-error-summary")).toBeAttached();
    await capture(page, testInfo, `setup-refused-${viewport.label}`);
  }

  // Create fares writes the whole set and lands on the Prices grid.
  await openVersion(found.blank);
  await page.locator("#setup-adult").fill("1.50");
  await page.locator("#setup-adult").blur();
  await page.locator("#setup-create").click();

  await expect(page.locator("#fare-setup")).toHaveCount(0);
  await expect(page.locator("#fare-table")).toBeAttached();
  await expect(page.locator("#fare-note")).toContainText("Fares created");
  await expect(page.locator("#create-fare")).toBeAttached();
  await expect(page.locator("#price-local_ride-adult")).toHaveValue("$1.50");
  await expect(page.locator("#price-local_ride-reduced")).toHaveValue("$0.75");
  await expect(page.locator("#price-local_ride-child")).toHaveValue("Free");

  // The fare-free summary is the state the free structure leaves behind. Undo
  // takes the version back to the setup, so the same version draws it without a
  // second fixture.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-setup")).toBeAttached();

  await openVersion(found.blank);
  await page.locator("#setup-kind-free").check();
  await page.locator("#setup-create").click();
  await expect(page.locator("#fare-free")).toBeAttached();

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.blank);

    // The summary replaces the grid: there is no price here to type, and the
    // header carries no primary of its own.
    await expect(page.locator("#fare-free")).toBeAttached();
    await expect(page.locator("#fare-table")).toHaveCount(0);
    await expect(page.locator("#create-fare")).toHaveCount(0);
    await expect(page.locator("#fare-free-lede")).toContainText("Free");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-free-${viewport.label}`);

    // "Start charging fares" opens the fare the setup wrote, in the same drawer
    // the grid's own fare names open.
    await page.locator("#start-charging-fares").click();
    await expect(page.locator("#fare-drawer")).toBeAttached();
    await expect(page.locator("#fare-name")).toHaveValue("Free ride");
    await captureDrawer(page, testInfo, `setup-free-drawer-${viewport.label}`);
    await page.locator("#fare-drawer-close").click();
    await expect(page.locator("#fare-drawer")).toHaveCount(0);
  }

  // ── an imported version ────────────────────────────────────────────────
  // The stored fares are drawn, and none of them can be typed into.
  await openVersion(conversionId);

  await expect(page.locator("#unmanaged-fares")).toBeAttached();
  await expect(page.locator("#edit-fares")).toBeAttached();
  await expect(page.locator("#unmanaged-v1-table")).toContainText("LOCAL");
  await expect(page.locator("#fare-table input[name^='price[']")).toHaveCount(0);
  await expect(page.locator("#change-prices")).toHaveCount(0);
  await expect(page.locator("#create-fare")).toHaveCount(0);

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(conversionId);
    await expect(page.locator("#unmanaged-fares")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-imported-v1-${viewport.label}`);
  }

  await page.locator("#edit-fares").click();
  await expect(page.locator("#conversion-review")).toBeAttached();
  await expect(page.locator("#conversion-review-confirm")).toHaveText(
    "Convert fares",
  );
  await expect(page.locator("#conversion-price-differences")).toContainText("0");
  await expect(page.locator("#conversion-counts")).toContainText("5 fares");
  await expect(page.locator("#conversion-known-differences")).toBeAttached();
  await expect(page.locator("#conversion-kept-older")).toContainText("COAST");

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(conversionId);
    await page.locator("#edit-fares").click();
    await expect(page.locator("#conversion-review")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `setup-conversion-review-${viewport.label}`);
    await page.locator("#conversion-review-cancel").click();
  }

  // Convert makes the grid editable, and the imported rows are left as they
  // were: the version exports what it imported until somebody changes a price.
  await openVersion(conversionId);
  await page.locator("#edit-fares").click();
  await page.locator("#conversion-review-confirm").click();

  await expect(page.locator("#conversion-review")).toHaveCount(0);
  await expect(page.locator("#fare-table")).toBeAttached();
  await expect(page.locator("#create-fare")).toBeAttached();
  await expect(page.locator("#fare-note")).toContainText("Fares converted");
  await expect(page.locator("#fare-table input[name^='price[']")).not.toHaveCount(0);

  // ── the mismatch banner ────────────────────────────────────────────────
  await openVersion(found.mismatch);

  await expect(page.locator("#fares-mismatch")).toBeAttached();
  await expect(page.locator("#fares-mismatch-detail")).toContainText("LOCAL");
  await expect(page.locator("#fares-mismatch-detail")).toContainText("$1.75");

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openVersion(found.mismatch);
    await expect(page.locator("#fares-mismatch")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `setup-mismatch-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=first-use", "ref-setup-first-use");
  await captureReference(page, testInfo, "?state=first-use-route", "ref-setup-route");
  await captureReference(page, testInfo, "?state=first-use-zone", "ref-setup-zone");
  await captureReference(page, testInfo, "?state=free", "ref-setup-free");
  await captureReference(page, testInfo, "?state=imported-v1", "ref-setup-imported");
  await captureReference(page, testInfo, "?state=mismatch", "ref-setup-mismatch");
});

// ── where ───────────────────────────────────────────────────────────────────

// Where fares apply: the route groups table and its drawer, the zone matrix
// with its gap cells and the cell dialog, and the passes table. The journeys
// below are the three prepared cases — the CST→TOL gap filled with both
// directions, route 10 moving from Intercity into Local routes with the warning
// that says so, and the Day pass's acceptance of Local routes removed and put
// back through Undo — and then the states at both prepared viewports beside the
// prototype states they follow.
test("where", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const found = {};
  for (const [key, name] of Object.entries(VERSIONS)) {
    found[key] = await versionIdByName(page, name);
  }

  const openWhere = async (versionId) => {
    await page.goto(`/gtfs/${versionId}/settings/fares/where`);
    await waitForLiveView(page);
    await expect(page.locator("#route-groups")).toBeAttached();
  };

  // ── the gaps version: a cell nobody priced, and the dialog that fills it ──
  await openWhere(found.gaps);

  // The groups table names each group, how a ride is charged and every route it
  // holds. The sample's `CST → TOL` cell is the gap: it says so in words, not by
  // colour alone.
  await expect(page.locator("#route-group-N_LOCAL")).toContainText("Local routes");
  // The gaps fixture removes route 40 from the sample's thirteen Local routes.
  await expect(page.locator("#route-group-N_LOCAL")).toContainText("12 routes");
  await expect(page.locator("#route-group-N_LOCAL")).toContainText("By zone");
  await expect(page.locator("#route-group-N_INTERCITY")).toContainText("Intercity");

  await expect(page.locator("#zone-matrix-N_LOCAL")).toBeAttached();
  const gapCell = page.locator("[data-cell='CST-TOL']");
  await expect(gapCell).toContainText("No fare");
  await expect(gapCell).toHaveAttribute("data-gap", "true");

  // The neighbouring priced cells read as prices, so the gap is visibly the odd
  // one out rather than an empty square.
  await expect(page.locator("[data-cell='CST-CST']")).toContainText("$1.50");
  await expect(page.locator("[data-cell='CST-CST']")).toContainText("Local ride");

  // The gaps version's group is the fixture that dropped route 40, so the table
  // offers the version's own answer to the route it left behind.
  await expect(page.locator("#route-groups-unassigned [data-group-badge]")).toHaveCount(1);
  await expect(page.locator("#route-groups-unassigned [data-group-badge='40']")).toHaveText("40");
  await expect(page.locator("#add-unassigned-to-group")).toBeAttached();

  // ── case 1: the gap, filled with both directions ──────────────────────────
  await gapCell.click();
  await expect(page.locator("#cell-dialog")).toBeAttached();
  await expect(page.locator("#cell-dialog")).toContainText(
    "Fare from Coast zone to Toledo and valley",
  );
  await expect(page.locator("#cell-fare-none")).toBeChecked();

  // Both directions of the pair were cleared, so filling the reverse along with
  // this one is offered and offered ticked: the return ride is nobody's price
  // yet either.
  await expect(page.locator("#cell-return")).toBeAttached();
  await expect(page.locator("#cell-both")).toBeChecked();

  await page.locator("#cell-fare-valley_coast_ride_adult_cash").check();
  await page.locator("#cell-dialog-confirm").click();

  await expect(page.locator("#cell-dialog")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("Valley-coast ride");
  await expect(page.locator("[data-cell='CST-TOL']")).toContainText(
    "Valley-coast ride",
  );
  await expect(page.locator("[data-cell='CST-TOL']")).toContainText("$5.00");
  // The reverse cell was filled by the same write, which is what "both" means.
  await expect(page.locator("[data-cell='TOL-CST']")).toContainText(
    "Valley-coast ride",
  );

  // Undo takes the pair back to the gap, so the journey after this one reads the
  // fixture it seeded.
  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("undone");
  await expect(page.locator("[data-cell='CST-TOL']")).toContainText("No fare");

  // ── case 2: route 10 moves between groups, with the warning that says so ───
  await openWhere(found.gaps);
  await page.locator("#edit-group-N_LOCAL").click();

  await expect(page.locator("#group-drawer")).toBeAttached();
  await expect(page.locator("#group-name")).toHaveValue("Local routes");

  // The route list says where every route is now, so the move is readable
  // before anything is ticked.
  await expect(page.locator("label[for='group-route-10']")).toContainText(
    "In Intercity",
  );
  await expect(page.locator("#group-moving")).toHaveCount(0);

  await page.locator("#group-route-10").check();
  await expect(page.locator("#group-moving")).toContainText("Route 10");
  await expect(page.locator("#group-moving")).toContainText(
    "moves from Intercity",
  );

  await page.locator("#save-route-group").click();

  await expect(page.locator("#group-drawer")).toHaveCount(0);
  await expect(page.locator("#fare-note")).toContainText("Local routes saved");
  // The route is in the group it was moved to and the group it came from is one
  // route smaller.
  await expect(page.locator("[data-group-badge='10']")).toBeAttached();
  await expect(page.locator("#route-group-N_INTERCITY")).toContainText("0 routes");
  // Moving route 10 adds one route to the gaps fixture's twelve.
  await expect(page.locator("#route-group-N_LOCAL")).toContainText("13 routes");

  await page.locator("#undo-prices").click();
  await expect(page.locator("#route-group-N_INTERCITY")).toContainText("Intercity");
  await expect(page.locator("#route-group-N_INTERCITY")).toContainText("1 route");
  await expect(page.locator("#route-group-N_LOCAL")).toContainText("12 routes");

  // ── case 3: a pass's acceptance of a group, and Undo ──────────────────────
  await openWhere(found.managed);

  await expect(page.locator("#passes")).toBeAttached();
  await expect(page.locator("#passes")).toContainText("Day pass");
  await expect(page.locator("#pass-day_pass_adult_cash-N_LOCAL")).toBeChecked();
  await expect(page.locator("#pass-day_pass_adult_cash-N_INTERCITY")).not.toBeChecked();

  await page.locator("#pass-day_pass_adult_cash-N_LOCAL").uncheck();

  await expect(page.locator("#fare-note")).toContainText("is no longer accepted");
  await expect(page.locator("#pass-day_pass_adult_cash-N_LOCAL")).not.toBeChecked();

  await page.locator("#undo-prices").click();
  await expect(page.locator("#fare-note")).toContainText("undone");
  await expect(page.locator("#pass-day_pass_adult_cash-N_LOCAL")).toBeChecked();

  // ── captures ────────────────────────────────────────────────────────────
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openWhere(found.gaps);

    await expect(page.locator("#zone-matrix-N_LOCAL")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `where-groups-${viewport.label}`);

    // The gap and the cell dialog that fills it, captured in the viewport
    // because the dialog is fixed to the edge of it.
    await page.locator("[data-cell='CST-TOL']").click();
    await expect(page.locator("#cell-dialog")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `where-cell-${viewport.label}`);

    await page.locator("#cell-fare-valley_coast_ride_adult_cash").check();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `where-cell-chosen-${viewport.label}`);
    await page.locator("#cell-dialog-cancel").click();

    // The group drawer, empty and with a move in it.
    await page.locator("#edit-group-N_LOCAL").click();
    await expect(page.locator("#group-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `where-group-edit-${viewport.label}`);

    await page.locator("#group-route-10").check();
    await expect(page.locator("#group-moving")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `where-group-moving-${viewport.label}`);

    // And its own refusal: the required name has not been supplied.
    await page.locator("#group-route-10").uncheck();
    await page.locator("#cancel-route-group").click();

    await page.locator("#create-route-group").click();
    await page.locator("#group-name").fill("");
    await page.locator("#save-route-group").click();
    await expect(page.locator("#error-summary")).toBeAttached();
    await captureDrawer(page, testInfo, `where-group-refused-${viewport.label}`);
    await page.locator("#cancel-route-group").click();

    // The passes table, on the version that has one.
    await openWhere(found.managed);
    await expect(page.locator("#passes")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `where-passes-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=where", "ref-where");
  await captureReference(page, testInfo, "?state=where-gaps", "ref-where-gaps");
  await captureReference(page, testInfo, "?state=cell", "ref-where-cell");
  await captureReference(page, testInfo, "?state=group-edit", "ref-where-group-edit");
});

// Route Details reads the fare editor's version-scoped workspace. The page
// shows route group membership as read-only for managed fares and leaves the
// imported network input available on an unmanaged version.
test("route", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const managedVersion = await versionIdByName(page, VERSIONS.managed);
  const unmanagedVersion = await versionIdByName(page, VERSIONS.unmanaged);

  await page.setViewportSize(DESKTOP);
  await page.goto(`/gtfs/${managedVersion}/routes/4`);
  await waitForLiveView(page);
  await expect(page.locator("#route-fares")).toBeVisible();
  await expect(page.locator("#route-fares-provisional")).toContainText("Local routes");
  await expect(page.locator("#route-fares-rides")).toContainText("Within Toledo and valley");
  await expect(page.locator("#route-fares-rides")).toContainText("Newport local ↔ Toledo and valley");
  await expect(page.locator("#route-fares-rides")).toContainText("$1.50");
  await expect(page.locator("#route-fares-rides")).toContainText("$2.50");
  await expect(page.locator("#route-fares-passes")).toContainText("Day pass");
  await expect(page.locator("#route-fares-transfers")).toContainText("Pay the difference to Intercity");
  await expect(page.locator("#route-details-network")).toHaveCount(0);
  await page.locator("#route-fares").scrollIntoViewIfNeeded();
  await capture(page, testInfo, "route-managed-1440");
  await captureReference(page, testInfo, "?state=route", "ref-route");

  await page.setViewportSize(PHONE);
  await page.goto(`/gtfs/${managedVersion}/routes/4`);
  await waitForLiveView(page);
  await expect(page.locator("#route-fares")).toBeVisible();
  expect(await bodyFitsViewport(page)).toBe(true);
  await page.locator("#route-fares").scrollIntoViewIfNeeded();
  await capture(page, testInfo, "route-managed-390");

  await page.goto(`/gtfs/${unmanagedVersion}/routes/4`);
  await waitForLiveView(page);
  await expect(page.locator("#route-fares")).toHaveCount(0);
  await page.locator("#route-details-network").locator("xpath=ancestor::details").locator("summary").click();
  await expect(page.locator("#route-details-network")).toBeVisible();
});

// The Where tab's time periods and complete fare-rule list. The interaction
// reaches the production writer; captures keep the transient drawers in view.
test("rules", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);
  const openWhere = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares/where`);
    await waitForLiveView(page);
    await expect(page.locator("#time-periods-card")).toBeAttached();
  };

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openWhere();

    await page.locator("#create-time-period").click();
    await expect(page.locator("#time-period-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `rules-time-create-${viewport.label}`);

    const periodName = `Weekday peak ${viewport.label}`;
    await page.locator("#time-period-name").fill(periodName);
    for (const day of [1, 2, 3, 4, 5]) {
      const checkbox = page.locator(`#time-period-day-${day}`);
      await page.locator(`label[for="time-period-day-${day}"]`).click();
      await expect(checkbox).toBeChecked();
    }
    await page.locator("#time-period-range-0-start").fill("07:00");
    await page.locator("#time-period-range-0-end").fill("09:00");
    await page.locator("#save-time-period").click();
    await expect(page.locator("#time-period-drawer")).toHaveCount(0);
    await expect(page.locator("#time-periods-list")).toContainText(periodName);

    await page.locator("#add-fare-rule").click();
    await expect(page.locator("#rule-drawer")).toBeAttached();
    await expect(page.locator("#rule-time-period")).toBeEnabled();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `rules-create-${viewport.label}`);

    await page.locator("#rule-network").selectOption("N_LOCAL");
    await page.locator("#rule-from-area").selectOption("TOL");
    await page.locator("#rule-to-area").selectOption("CST");
    await page.locator("#rule-fare-coast_ride_adult_cash").check();
    await expect(page.locator("#rule-overlap")).toContainText("Valley-coast ride");
    await page.locator("#rule-overlap-replace").check();
    await expect(page.locator("#rule-overlap-replace")).toBeChecked();
    await expect(page.locator("#save-rule")).toContainText("Replace Valley-coast ride");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `rules-overlap-${viewport.label}`);
    await page.locator("#cancel-rule").click();

    await page.locator("#rule-list summary").click();
    await page.locator("#show-rule-feed-ids").check();
    await expect(page.locator("#fare-rules code").first()).toContainText("network_id");
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `rules-list-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=time-create", "ref-rules-time-create");
  await captureReference(page, testInfo, "?state=rule-create", "ref-rules-create");
  await captureReference(page, testInfo, "?state=rule-overlap", "ref-rules-overlap");
  await captureReference(page, testInfo, "?state=rule-list", "ref-rules-list");
});

// Transfer policy editing uses the normalized route-group pair in both the
// matrix and the scoped writer. The reverse direction is deliberately
// inexpressible under R6 for the North Coast sample.
test("transfers", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const versionId = await versionIdByName(page, VERSIONS.managed);
  const openTransfers = async () => {
    await page.goto(`/gtfs/${versionId}/settings/fares/transfers`);
    await waitForLiveView(page);
    await expect(page.locator("#transfer-matrix")).toBeAttached();
  };

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await openTransfers();

    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-transfers-${viewport.label}`);

    await page
      .locator('#transfer-matrix button[phx-value-from="N_LOCAL"][phx-value-to="N_LOCAL"]')
      .click();
    await expect(page.locator("#transfer-drawer")).toBeAttached();
    await expect(page.locator("#transfer-pay")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `prod-transfer-local-${viewport.label}`);
    await page.locator("#cancel-transfer").click();

    await page.locator("#add-transfer-rule").click();
    await expect(page.locator("#transfer-drawer")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await captureDrawer(page, testInfo, `prod-transfer-create-${viewport.label}`);
    await page.locator("#cancel-transfer").click();

    await page
      .locator('#transfer-matrix button[phx-value-from="N_LOCAL"][phx-value-to="N_INTERCITY"]')
      .click();
    await expect(page.locator("#transfer-drawer")).toBeAttached();
    await page.locator("#transfer-drawer").evaluate(async (drawer) => {
      await Promise.all(
        drawer
          .getAnimations({ subtree: true })
          .map((animation) => animation.finished.catch(() => {})),
      );
    });
    await expect(page.locator("#transfer-pay")).toContainText("The difference");
    await expect(page.locator("#transfer-form select[name='transfer[count]']")).toHaveCount(0);
    await expect.poll(() => bodyFitsViewport(page)).toBe(true);
    await captureDrawer(page, testInfo, `transfers-edit-${viewport.label}`);

    await page.locator("#transfer-form input[name='transfer[minutes]']").fill("75");
    await page.locator("#save-transfer").click();
    await expect(page.locator("#transfer-drawer")).toHaveCount(0);
    await expect(
      page.locator('#transfer-matrix button[phx-value-from="N_LOCAL"][phx-value-to="N_INTERCITY"]'),
    ).toContainText("75 minutes");

    await page
      .locator('#transfer-matrix button[phx-value-from="N_INTERCITY"][phx-value-to="N_LOCAL"]')
      .click();
    await expect(page.locator("#transfer-pay-difference")).toBeDisabled();
    await expect(page.locator("#transfer-difference-reason")).toBeAttached();
    await captureDrawer(page, testInfo, `transfers-r6-disabled-${viewport.label}`);
    await page.locator("#cancel-transfer").click();
    await expect(page.locator("#transfer-drawer")).toHaveCount(0);
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `transfers-matrix-${viewport.label}`);
  }

  const blankVersion = await versionIdByName(page, VERSIONS.blank);
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await page.goto(`/gtfs/${blankVersion}/settings/fares/transfers`);
    await waitForLiveView(page);
    await expect(page.locator("#transfers-empty")).toBeAttached();
    await expect(page.locator("#transfer-matrix")).toHaveCount(0);
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-transfers-empty-${viewport.label}`);
  }

  await captureReference(page, testInfo, "?state=transfers", "ref-transfers");
  await captureReference(page, testInfo, "?state=transfer-edit", "ref-transfer-edit");
  await captureReference(page, testInfo, "?state=transfer-local", "ref-transfer-local");
  await captureReference(page, testInfo, "?state=transfer-create", "ref-transfer-create");
  await captureReference(page, testInfo, "?state=transfers-empty", "ref-transfers-empty");
});

// Checks, journey pricing and exported format counts share the authenticated
// version's current fare rows. The reduced-rider example is independently
// priced from North Coast's $1.50 cash fare; saved journey acceptance is
// exercised separately by the LiveView security regression.
test("checks", async ({ page }, testInfo) => {
  await routeBlankTiles(page);
  await logIn(page);

  const managedId = await versionIdByName(page, VERSIONS.managed);
  const gapsId = await versionIdByName(page, VERSIONS.gaps);

  await page.goto(`/gtfs/${gapsId}/settings/fares/checks`);
  await waitForLiveView(page);
  await expect(page.locator("#fare-problems")).toBeAttached();
  await expect(page.locator("#fare-problems")).toContainText("Set the missing fare");
  await expect(page.locator("#fare-problems a[href$='/settings/fares/where']").first()).toBeAttached();
  await expect(page.locator("#journey-check")).toBeAttached();
  await expect(page.locator("#journey-result")).toHaveAttribute("aria-live", "polite");
  await expect(page.locator("#saved-journeys")).toBeAttached();
  await expect(page.locator("#formats")).toBeAttached();

  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `checks-issues-${viewport.label}`);
  }
  await captureReference(page, testInfo, "?state=checks-issues", "ref-checks-issues");

  await page.goto(`/gtfs/${managedId}/settings/fares/checks`);
  await waitForLiveView(page);
  await expect(page.locator("#formats")).toBeAttached();
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await expect(page.locator("#fare-problems")).toBeAttached();
    await expect(page.locator("#formats")).toBeAttached();
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-checks-${viewport.label}`);
    await page.locator("#formats").scrollIntoViewIfNeeded();
    await capture(page, testInfo, `prod-checks-formats-${viewport.label}`);
  }
  await captureReference(page, testInfo, "?state=checks", "ref-checks");
  await captureReference(page, testInfo, "?state=checks-formats", "ref-checks-formats");

  await page.goto(`/gtfs/${managedId}/settings/fares/checks`);
  await waitForLiveView(page);
  await page.locator("#journey-route-0").selectOption("1");
  await page.locator("#journey-from-0").selectOption("NTC");
  await page.locator("#journey-to-0").selectOption("NYE");
  await page.locator("#journey-rider").selectOption("adult");
  await page.locator("#journey-media").selectOption("cash");
  await expect(page.locator("#journey-result")).toContainText("$1.50");
  await page.locator("#journey-rider").selectOption("reduced");
  await expect(page.locator("#journey-result")).toContainText("$0.75");
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-checks-local-${viewport.label}`);
  }
  await captureReference(page, testInfo, "?state=checks-local", "ref-checks-local");

  // A second real ride boards 160 minutes after the first, beyond the
  // N_LOCAL → N_INTERCITY transfer allowance. Both legs are priced
  // independently, so the operator sees the $8.50 total and its two charges.
  await page.locator("#journey-rider").selectOption("adult");
  await page.locator("#journey-route-0").selectOption("4");
  await page.locator("#journey-from-0").selectOption("TOLEDO");
  await page.locator("#journey-to-0").selectOption("NTC");
  await page.locator('input[name="journey[legs][0][departs]"]').fill("07:40");
  await page.locator("#journey-add-leg").click();
  await page.locator("#journey-route-1").selectOption("10");
  await page.locator("#journey-from-1").selectOption("NTC");
  await page.locator("#journey-to-1").selectOption("CORVALLIS");
  await page.locator('input[name="journey[legs][1][departs]"]').fill("10:20");
  await expect(page.locator("#journey-result")).toContainText("$8.50");
  await expect(page.locator("#journey-result")).toContainText("Ride 1:");
  await expect(page.locator("#journey-result")).toContainText("Ride 2:");
  for (const viewport of [DESKTOP, PHONE]) {
    await page.setViewportSize({ width: viewport.width, height: viewport.height });
    await expect(bodyFitsViewport(page)).resolves.toBe(true);
    await capture(page, testInfo, `prod-checks-late-${viewport.label}`);
  }

  // Changing the saved journey's intercity fare through Prices makes its
  // existing Checks row visibly stale. Recovery is registered before the
  // write and runs both here and in afterEach if any assertion fails.
  priceRecovery = {
    versionId: managedId,
    selector: "#price-intercity_ride-adult",
    expected: "$6.00",
    value: "6.00",
  };
  try {
    await page.goto(`/gtfs/${managedId}/settings/fares`);
    await waitForLiveView(page);
    await expect(page.locator(priceRecovery.selector)).toHaveValue("$6.00");
    await page.locator(priceRecovery.selector).fill("6.25");
    await page.locator(priceRecovery.selector).blur();
    await page.locator("#save-prices").click();
    await expect(page.locator("#fare-note")).toContainText("1 price saved");

    await page.goto(`/gtfs/${managedId}/settings/fares/checks`);
    await waitForLiveView(page);
    const savedJourney = page
      .locator("#saved-journeys li")
      .filter({ hasText: "Toledo to Corvallis" });
    await expect(savedJourney).toContainText("Expected $6.00 · current $6.25");
    await expect(savedJourney).toContainText("Price changed");
    for (const viewport of [DESKTOP, PHONE]) {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await expect(bodyFitsViewport(page)).resolves.toBe(true);
      await capture(page, testInfo, `prod-checks-test-fail-${viewport.label}`);
    }
  } finally {
    await restoreFarePrice(page);
  }

  await captureReference(page, testInfo, "?state=checks-late", "ref-checks-late");
  await captureReference(page, testInfo, "?state=checks-test-fail", "ref-checks-test-fail");
});
});
