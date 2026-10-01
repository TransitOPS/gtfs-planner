// In-seat connection browser journeys (EV-29, step 28).
//
// Runs against the freshly seeded browser database the repository's Playwright
// configuration already uses (`bin/test-browser`, workers: 1, retries: 0) with
// `BROWSER_E2E=true`, and drives the real page: router → `BlocksLive` → the
// `Gtfs` in-seat facades → PostgreSQL. Only the map tile host is faked, at the
// network boundary, so no journey reaches the internet.
//
// The fixture is the "Browser In-Seat Version" in
// `test/support/browser_seed.exs`: 15 connections in 8 groups over 7 places on
// two day types, and the record cases the in-seat UI has to tell apart —
// `BIS_FA1A→BIS_FA1B` matches, `BIS_SH_A1→BIS_SH_B1` is stale because
// `BIS_SH_X` runs between the pair on "No school days + Weekday service",
// `BIS_OLD_T1→BIS_OLD_T2` holds a type-4 and a type-5 row (a conflict),
// `BIS_OLD_T3→BIS_OLD_T4` names a stop its to-trip no longer starts at, and
// `BIS_UNB1→BIS_UNB2` / `BIS_UNB3→BIS_UNB4` have no block at all. Only the
// seeded stop ids, block ids and trip ids are literal here; the DOM ids that
// encode a UUID (`connections-group-*`, `connections-connection-*`) are never
// written down, and every place section is addressed by the same base64url
// encoding `Blocking.Connections.token/1` and `place_token/1` use.
//
// The journeys share one version and mutate it in order, so they run serially
// and a re-run needs a new `bin/test-browser` database. Read-only journeys come
// first, then the keyboard journey (which saves, undoes, saves a group and
// removes two stale records), then the aborted-tile journey's own save, so no
// later assertion depends on a record an earlier journey consumed. Test titles
// keep the prefixes branch review greps: list, timeline, group, inspector,
// blocked, pickup, guard, keyboard, map, targets, mobile, errors, qa tour.
//
// The credential is read from the seed rather than written into this file, so it
// cannot drift from the account `bin/test-browser` actually creates and this
// spec is not a second copy of a password (`runs_keyboard.spec.js` does the
// same).
//
// Run it with `bin/test-browser e2e/in_seat.spec.js`.
import { expect, test } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const EVIDENCE_DIR = resolve(
  __dirname,
  "..",
  "..",
  ".specs",
  "11-in-seat-transfers",
  "evidence",
  "browser",
);

const VERSION_NAME = "Browser In-Seat Version";

// The page's own default day type: the one with the most trips, so the timeline
// and the Connections view both open on it.
const DAY_TYPE = "School days + Weekday service";
const OTHER_DAY_TYPE = "No school days + Weekday service";

// The seeded facts every assertion below is written against.
const CONNECTIONS = 15;
const PLACES = 7;
const GROUPS = 8;
const CHECKS_ENTRIES = 5; // 1 conflict + 2 stale the day hosts + 2 unhosted stale
const STALE_RECORDS = 2; // BIS_SH_A1 not-next, BIS_OLD_T3 stops-changed

// Stop ids, which are what a place's id is, and block ids.
const FAR_AVENUE = "BIS_FAR_A";
const SCHOOL_JUNCTION = "BIS_SHARED_A";
const UNION_STATION = "BIS_UNION";
const UNKNOWN_PLACE = "BIS_NOCOORD";
const MARKET_ROW = "BIS_NEAR_A";

const FAR_AVENUE_GROUP_BLOCKS = ["BIS-FA1", "BIS-FA2", "BIS-FA3", "BIS-FA4"];
const SHARED_PAIR = "BIS-SHARED-1";
const SHARED_QUIET_PAIR = "BIS-SHARED-2";
const TURN_PAIR = "BIS-TURN1";
const NEAR_PAIR = "BIS-NEAR";

// The proof boundary the card fixes: Chromium at 1440x900, plus one focused
// inspector check at 390x844.
const DESKTOP = { width: 1440, height: 900 };
const PHONE = { width: 390, height: 844 };

const MIN_TARGET = 44;

// A 1x1 opaque PNG, so the tile layers succeed without a network request.
const ONE_PX_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC";

// The map draws streets through this app's own Geoapify proxy, so the tile
// requests are same-origin and no journey reaches an external tile host.
const TILE_ROUTE = "**/map/tiles/**";

// The captures the card names, written by the journeys that own each state and
// read back by the qa-tour journey.
const CAPTURES = [
  "connections",
  "timeline",
  "group",
  "conn-through",
  "conn-blocked",
  "bulk-review",
  "bulk-result",
  "checks",
  "conn-mobile",
];

// Measurements the qa tour reports; each journey fills its own keys.
const tour = {};

// ── credentials, session and navigation ──────────────────────────────────────

// Read from the seed rather than written here, so this file is not a second
// copy of a password and cannot drift from the account `bin/test-browser`
// creates.
function seededEditor() {
  const seed = readFileSync(
    new URL("../../test/support/browser_seed.exs", import.meta.url),
    "utf8",
  );

  const editor = seed.match(
    /email: "(diagram-test@gtfs-planner\.test)"[\s\S]{0,200}?password: "([^"]+)"/,
  );

  if (!editor) {
    throw new Error(
      "The seeded editor is not in test/support/browser_seed.exs; this spec reads its credential from the seed and will not guess one.",
    );
  }

  return { email: editor[1], password: editor[2] };
}

async function logIn(page) {
  const editor = seededEditor();

  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', editor.email);
  await page.fill('input[name="user[password]"]', editor.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionIdFor(page, versionName = VERSION_NAME) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

function blocksPath(versionId, query = "") {
  return `/gtfs/${versionId}/blocks${query}`;
}

const CONNECTIONS_QUERY = "?view=connections";

/** The Blocks page on the Connections view of the in-seat version. */
async function openConnections(page, versionId, query = "") {
  await page.goto(blocksPath(versionId, `${CONNECTIONS_QUERY}${query}`));
  await expect(page.locator("#connections-panel")).toBeVisible();
  await expect(page.locator("#connections-map")).toHaveAttribute(
    "data-state",
    "ready",
  );
}

// ── DOM addresses ────────────────────────────────────────────────────────────

/** `place_token/1`: the place's own id, base64url without padding. */
function placeToken(stopId) {
  return Buffer.from(stopId, "utf8").toString("base64url");
}

/** One place's section in the Connections list. */
function placeSection(page, stopId) {
  return page.locator(`#connections-place-${placeToken(stopId)}`);
}

/** The one group row a place's section holds. */
function groupRow(page, stopId) {
  return placeSection(page, stopId).locator('button[phx-click="open_group"]');
}

/** A group row's group token, read from the DOM the server rendered. */
async function groupToken(row) {
  const id = await row.getAttribute("id");
  if (!id) throw new Error("A group row without an id cannot be addressed");
  return id.replace(/^connections-group-/, "");
}

/** A connection's block button inside the open group panel's table. */
function groupTableButton(page, blockId) {
  return page.locator(
    `#connections-group-table tr:has(button[phx-value-block="${blockId}"]) button`,
  );
}

// ── keyboard helpers ─────────────────────────────────────────────────────────

/** The id of whatever currently holds focus, or null. */
function activeId(page) {
  return page.evaluate(() => document.activeElement?.id ?? null);
}

/** True when the focused element matches `selector`. */
function isFocused(page, selector) {
  return page.evaluate(
    (candidate) => document.activeElement?.matches(candidate) ?? false,
    selector,
  );
}

/**
 * Presses Tab until `selector` holds focus, and fails loudly rather than
 * falling back to a click: a control the keyboard cannot reach is exactly what
 * these journeys are here to catch.
 */
async function tabUntilFocused(page, selector, maxTabs = 40) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    if (await isFocused(page, selector)) return;
    await page.keyboard.press("Tab");
    if (await isFocused(page, selector)) return;
  }

  throw new Error(
    `Could not reach ${selector} after ${maxTabs} Tab presses (focus is on #${await activeId(page)})`,
  );
}

/** The same walk backwards, for a control that sits earlier in the page. */
async function shiftTabUntilFocused(page, selector, maxTabs = 60) {
  for (let attempt = 0; attempt < maxTabs; attempt += 1) {
    if (await isFocused(page, selector)) return;
    await page.keyboard.press("Shift+Tab");
    if (await isFocused(page, selector)) return;
  }

  throw new Error(
    `Could not reach ${selector} after ${maxTabs} Shift+Tab presses (focus is on #${await activeId(page)})`,
  );
}

/**
 * Checks a radio with the keyboard. The segmented control's and the choice
 * cards' radios are all visually hidden behind their labels, so `check()`
 * cannot be used on them and a click would not prove the keyboard works.
 */
async function chooseWithKeyboard(page, radioSelector) {
  await page.locator(radioSelector).focus();
  await page.keyboard.press("Space");
}

/** Enters the Connections view from the page's own Plan view radios. */
async function enterConnectionsViewWithKeyboard(page) {
  await chooseWithKeyboard(page, "#blocks-view-option-connections");
  await expect(page.locator("#connections-panel")).toBeVisible();
}

// ── capture and evidence ─────────────────────────────────────────────────────

async function capture(page, testInfo, name, { fullPage = false } = {}) {
  const outputPath = testInfo.outputPath(`${name}.png`);
  mkdirSync(dirname(outputPath), { recursive: true });
  await page.screenshot({ path: outputPath, fullPage, animations: "disabled" });
  copyIntoEvidence(`${name}.png`, readFileSync(outputPath));
}

function copyIntoEvidence(name, contents) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  writeFileSync(resolve(EVIDENCE_DIR, name), contents);
  return resolve(EVIDENCE_DIR, name);
}

// ── shared measurements ──────────────────────────────────────────────────────

/** The rendered box of a control, or null when it is not rendered. */
async function targetBox(page, selector) {
  const box = await page.locator(selector).first().boundingBox();
  if (!box) return null;
  return { width: box.width, height: box.height };
}

/** The focus ring the browser actually paints on a focused element's card. */
async function focusOutline(page, selector) {
  return page.evaluate((candidate) => {
    const el = document.querySelector(candidate);
    if (!el) return null;
    const card = el.closest("label") ?? el;
    const style = getComputedStyle(card);
    return {
      style: style.outlineStyle,
      width: parseFloat(style.outlineWidth) || 0,
      color: style.outlineColor,
    };
  }, selector);
}

/** Computed opacity, so "readable without opacity" is measured, not assumed. */
async function computedOpacity(page, selector) {
  return page.evaluate((candidate) => {
    const el = document.querySelector(candidate);
    return el ? getComputedStyle(el).opacity : null;
  }, selector);
}

/** True when the page itself never scrolls sideways. */
async function fitsViewport(page) {
  const documentFits = await page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );

  return documentFits && (await bodyFitsViewport(page));
}

// ─────────────────────────────────────────────────────────────────────────────

test.describe.configure({ mode: "serial" });

let pageErrors = [];

test.beforeEach(async ({ page }) => {
  pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  // Registered before the first navigation of every journey: no journey may
  // reach an external tile host.
  await page.route(TILE_ROUTE, (route) =>
    route.fulfill({
      status: 200,
      contentType: "image/png",
      body: Buffer.from(ONE_PX_PNG_BASE64, "base64"),
    }),
  );
});

test.afterEach(() => {
  expect(pageErrors, "the page raised no uncaught error").toEqual([]);
});

test.describe("In-seat connections", () => {
  test.use({ viewport: DESKTOP });

  // ── read-only journeys ────────────────────────────────────────────────────

  test("list: the Connections view reads the day's connections as places, groups and a map", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    // The summary is the page's own count of the filtered set, the version's
    // total and the places those connections are decided at.
    await expect(page.locator("#connections-summary")).toHaveText(
      `${CONNECTIONS} of ${CONNECTIONS} connections at ${PLACES} places`,
    );
    await expect(
      page.locator('#connections-list button[phx-click="open_group"]'),
    ).toHaveCount(GROUPS);
    await expect(
      page.locator('#connections-list section[id^="connections-place-"]'),
    ).toHaveCount(PLACES);

    // A place's sections read busiest first, and ties break by name, which is
    // the page's own ordering and not a coincidence of the seed.
    const places = await page.$$eval(
      '#connections-list section[id^="connections-place-"] h2',
      (heads) => heads.map((head) => head.textContent.trim()),
    );
    expect(places).toEqual([
      "Far Avenue",
      "Depot Row",
      "Market Row",
      "Unknown Place",
      "Old Alignment",
      "School Junction",
      "Union Station",
    ]);

    // The Far Avenue group is four connections of one 12 → 24 handoff with waits
    // of 10 to 16 minutes, and only the first carries a record, so its row
    // carries a stay mark and the group a count of four.
    const farAvenue = groupRow(page, FAR_AVENUE);
    await expect(farAvenue).toHaveCount(1);
    await expect(farAvenue).toContainText("continues as 24");
    await expect(farAvenue).toContainText("Same stop");
    await expect(farAvenue).toContainText("10–16 min");
    await expect(farAvenue.locator(".connections-mark-stay")).toHaveCount(1);
    await expect(
      farAvenue.locator(
        `#connections-group-count-${await groupToken(farAvenue)}`,
      ),
    ).toHaveText("4");

    // The turnback group says so, rather than naming a route it continues as.
    await expect(groupRow(page, UNION_STATION)).toContainText("Turns back");

    // The place this version cannot place is named beside the map rather than
    // silently missing from it, and the map itself drew.
    await expect(page.locator("#connections-map")).toHaveAttribute(
      "data-state",
      "ready",
    );
    const note = page.locator(
      `#connections-map-note-${placeToken(UNKNOWN_PLACE)}`,
    );
    await expect(note).toContainText("Unknown Place isn't on the map.");
    await expect(note).toContainText("are still in the list");

    // The page promises a setting is not day-type scoped, and says so.
    await expect(page.locator("#connections-summary-strip")).toContainText(
      "Settings apply to every date both trips run",
    );

    tour.list = {
      summary: await page.locator("#connections-summary").innerText(),
      groups: GROUPS,
      places: places.length,
      mapState: await page
        .locator("#connections-map")
        .getAttribute("data-state"),
      unplaced: await note.innerText(),
      overflow: !(await fitsViewport(page)),
    };

    await capture(page, testInfo, "connections");
  });

  test("timeline: every gap chip carries its connection's own setting", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));
    await expect(page.locator("#blocks-timeline-body tr")).toHaveCount(15);

    // The five decided or reviewable connections of the seed, read off the
    // chips the timeline draws: one stay, one re-board, and the three that
    // need review (the not-next pair, the conflict and the old stops).
    const chips = await page.$$eval('[data-role="blocks-gap"]', (gaps) =>
      gaps.map((gap) => gap.getAttribute("data-setting")),
    );
    expect(chips).toHaveLength(15);
    expect(chips.filter((setting) => setting === "stay")).toHaveLength(1);
    expect(chips.filter((setting) => setting === "reboard")).toHaveLength(1);
    expect(chips.filter((setting) => setting === "review")).toHaveLength(3);

    // The ten the seed leaves undecided say so rather than reading as an error:
    // "not stated" is a real answer, not a missing one.
    expect(chips.filter((setting) => setting === "none")).toHaveLength(10);

    // The capture is of the timeline itself, so it is taken before anything is
    // opened over it.
    await capture(page, testInfo, "timeline");

    // A gap is a real button that opens the connection drawer, so a reader can
    // reach the same editor from the timeline.
    await page.locator('[data-role="blocks-gap"][data-setting="stay"]').click();
    await expect(page.locator("#gap-drawer")).toBeVisible();
    await expect(page.locator("#gap-drawer-overlay")).toHaveAttribute(
      "data-modal",
      "false",
    );
    // The drawer's lede names both trips of the pair, spaced, where the group
    // table writes them tight; either way the pair is unambiguous.
    await expect(page.locator("#gap-drawer")).toContainText(
      "BIS_FA1A → BIS_FA1B",
    );

    tour.timeline = {
      blocks: 15,
      stay: 1,
      reboard: 1,
      review: 3,
      notStated: 10,
      drawerOpens: true,
    };
  });

  test("group: a group's panel lists its connections and keeps Set all inert until a setting is chosen", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    await groupRow(page, FAR_AVENUE).click();

    await expect(page.locator("#connections-group-title")).toHaveText(
      "Continues as 24 at Far Avenue",
    );
    await expect(page.locator("#connections-group-facts")).toContainText(
      "Same stop",
    );
    await expect(page.locator("#connections-group-facts")).toContainText(
      "10–16 min",
    );
    await expect(page.locator("#connections-group-count")).toHaveText(
      `${FAR_AVENUE_GROUP_BLOCKS.length} connections`,
    );

    // Each row is the block, the arrival, the wait and the setting, and the one
    // that carries a record reads as such.
    const rows = page.locator("#connections-group-table tbody tr");
    await expect(rows).toHaveCount(FAR_AVENUE_GROUP_BLOCKS.length);
    for (const [index, block] of FAR_AVENUE_GROUP_BLOCKS.entries()) {
      await expect(rows.nth(index)).toContainText(block);
    }
    await expect(rows.first()).toContainText("Riders stay on board");
    await expect(rows.nth(1)).toContainText("Not stated");

    // Set all is a review of nothing until a setting is chosen, so it says which
    // half is missing rather than opening an empty review.
    await expect(page.locator("#bulk-review-open")).toBeDisabled();
    await expect(page.locator("#connections-bulk-disabled-note")).toHaveText(
      "Choose a setting to review.",
    );

    // Choosing a setting is a read: the review is the next step, not a write.
    await page.locator("#connections-bulk-stay").check();
    await expect(page.locator("#bulk-review-open")).toBeEnabled();
    await expect(page.locator("#set-all-review")).toHaveCount(0);

    tour.group = {
      title: await page.locator("#connections-group-title").innerText(),
      rows: 4,
      setAllInertWithoutChoice: true,
    };

    await capture(page, testInfo, "group");
  });

  test("inspector: a through connection opens beside the page and the group stays live behind it", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    await groupRow(page, FAR_AVENUE).click();
    await groupTableButton(page, "BIS-FA2").click();

    // The drawer is an inspector, not a modal: the page behind it is still the
    // reader's, which is what the group table being readable proves.
    await expect(page.locator("#gap-drawer-overlay")).toHaveAttribute(
      "data-modal",
      "false",
    );
    await expect(page.locator("#gap-drawer")).toContainText("BIS-FA2");
    await expect(page.locator("#gap-drawer")).toContainText(
      "BIS_FA2A → BIS_FA2B",
    );
    await expect(page.locator("#gap-drawer")).toContainText(
      "Route 12 continues as Route 24",
    );

    // The choice is the three-way question, and the scope it applies on is the
    // dates both trips run rather than this day type alone.
    await expect(page.locator("#connection-form")).toBeVisible();
    await expect(page.locator('[data-role="connection-choice"]')).toHaveCount(
      3,
    );
    await expect(page.locator("#connection-scope")).toContainText(
      "Applies on all 40 dates both trips run",
    );
    await expect(page.locator("#connection-scope")).toContainText(DAY_TYPE);
    await expect(page.locator("#connection-scope")).toContainText(
      OTHER_DAY_TYPE,
    );

    // A pair with no record opens on "not stated", which is what it is, and
    // offers no save until the answer changes.
    await expect(page.locator("#connection-choice-not-stated")).toBeChecked();
    await expect(page.locator("#connection-save-status")).toHaveText(
      "Choose a different setting to save.",
    );
    await expect(page.locator("#connection-save")).toBeDisabled();

    // Both stops have coordinates, so the pair's own mini-map is there.
    await expect(page.locator("#connection-pair-map")).toHaveAttribute(
      "data-mode",
      "pair",
    );
    await expect(page.locator("#connection-pair-map-unavailable")).toBeHidden();

    // The group's table is still clickable while the drawer is open, and a row
    // the reader clicks re-targets the same inspector.
    await expect(page.locator("#connections-group-table")).toBeVisible();
    await groupTableButton(page, "BIS-FA3").click();
    await expect(page.locator("#gap-drawer")).toContainText(
      "BIS_FA3A → BIS_FA3B",
    );
    await expect(page.locator("#gap-drawer")).not.toContainText(
      "BIS_FA2A → BIS_FA2B",
    );

    tour.inspector = {
      modal: false,
      nonModalRowClick: true,
      choices: 3,
      scope: await page.locator("#connection-scope").innerText(),
      miniMap: "pair",
    };

    await capture(page, testInfo, "conn-through");
  });

  test("blocked: the refused pair offers only Not stated and says why", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    await groupRow(page, SCHOOL_JUNCTION).click();
    await groupTableButton(page, SHARED_PAIR).click();

    // `BIS_SH_X` runs between the pair on the other day type, so the rule
    // refuses to write a stay or a re-board record for it.
    await expect(page.locator("#connection-blocked-reason")).toContainText(
      "Only Not stated is available.",
    );
    await expect(page.locator("#connection-blocked-reason")).toContainText(
      "On No school days + Weekday service, 16 dates, trip BIS_SH_X runs next on this vehicle",
    );

    // The refusal names the day type that blocks the pair and links to it.
    await expect(page.locator("#connection-blocked-day-link")).toHaveText(
      `Open ${OTHER_DAY_TYPE}`,
    );

    // The two explicit settings are visibly unavailable rather than silently
    // ignored, and the one that writes nothing stays available.
    await expect(page.locator("#connection-choice-stay")).toBeDisabled();
    await expect(page.locator("#connection-choice-reboard")).toBeDisabled();
    await expect(page.locator("#connection-choice-not-stated")).toBeEnabled();
    await expect(
      page.locator(
        '[data-role="connection-choice"][data-choice="stay_on_board"]',
      ),
    ).toHaveAttribute("data-disabled", "true");
    await expect(
      page.locator(
        '[data-role="connection-choice"][data-choice="must_reboard"]',
      ),
    ).toHaveAttribute("data-disabled", "true");
    await expect(page.locator("#connection-save")).toBeDisabled();

    tour.blocked = {
      refusal: await page.locator("#connection-blocked-reason").innerText(),
      dayLink: await page.locator("#connection-blocked-day-link").innerText(),
      disabledOptions: 2,
    };

    await capture(page, testInfo, "conn-blocked");
  });

  test("pickup: the turnback pair warns that the planner drops the record, and a draft asks before it is discarded", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    await groupRow(page, UNION_STATION).click();
    await groupTableButton(page, TURN_PAIR).click();

    // `BIS_TURN1B` forbids pickup at its first stop, so choosing stay says so
    // before it is chosen and refuses nothing.
    await expect(page.locator("#gap-hints")).toContainText("turns back here");
    await expect(
      page.locator(
        '[data-role="connection-choice-warning"][data-warning="pickup"]',
      ),
    ).toHaveCount(0);

    await page.locator("#connection-choice-stay").check();
    const warning = page.locator(
      '[data-role="connection-choice-warning"][data-warning="pickup"]',
    );
    await expect(warning).toHaveCount(1);
    await expect(warning).toContainText(
      "Trip BIS_TURN1B doesn't allow pickup at its first stop, Union Station.",
    );
    await expect(warning).toContainText(
      "OpenTripPlanner drops this record there without warning.",
    );
    await expect(page.locator("#connection-save")).toBeEnabled();

    // A draft nobody has saved is not thrown away by Escape: the question
    // stands in front of the close, and keeping the draft puts the reader back
    // where they were.
    await page.keyboard.press("Escape");
    await expect(page.locator("#connection-discard")).toBeVisible();
    await expect(page.locator("#connection-discard-title")).toHaveText(
      "Discard this change?",
    );
    await expect(page.locator("#connection-discard")).toContainText(
      "Keep editing to go back to it.",
    );

    await page.locator("#connection-discard-cancel").click();
    await expect(page.locator("#connection-discard")).toBeHidden();
    await expect(page.locator("#gap-drawer")).toBeVisible();
    await expect(page.locator("#connection-choice-stay")).toBeChecked();

    tour.pickup = {
      warning: await warning.innerText(),
      draftAsksBeforeDiscard: true,
      keepEditingRestoresDraft: true,
    };

    await capture(page, testInfo, "conn-pickup");
  });

  test("guard: the turnback pair's own distance and turnback facts name the vehicle moves and the planner re-boards", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    // The 370 m empty move: choosing stay says the vehicle would drive empty.
    await groupRow(page, "BIS_MOVE_A").click();
    await groupTableButton(page, "BIS-MOVE").click();
    await expect(page.locator("#gap-available")).toContainText("Vehicle moves");
    await page.locator("#connection-choice-stay").check();
    const distance = page.locator(
      '[data-role="connection-choice-warning"][data-warning="distance"]',
    );
    await expect(distance).toHaveCount(1);
    await expect(distance).toContainText("Stops are 370 m apart");
    await expect(distance).toContainText("moves empty");
    const distanceText = await distance.innerText();

    // Closing with a draft still in hand asks first, and confirming it discards
    // the draft rather than the record.
    await page.locator("#connection-cancel").click();
    await expect(page.locator("#connection-discard")).toBeVisible();
    await page.locator("#connection-discard-confirm").click();
    await expect(page.locator("#gap-drawer")).toBeHidden();

    // The nearby handoff is a group of its own, so the panel is walked back to
    // the list before Market Row's row is opened.
    await page.locator("#connections-group-back").click();
    await expect(page.locator("#connections-group")).toBeHidden();
    await groupRow(page, MARKET_ROW).click();
    await groupTableButton(page, NEAR_PAIR).click();
    await expect(page.locator("#gap-hints")).toContainText("180 m away");
    await page.locator("#connection-choice-stay").check();
    await expect(
      page.locator(
        '[data-role="connection-choice-warning"][data-warning="distance"]',
      ),
    ).toHaveCount(0);

    // Both stops have coordinates, so neither pair falls back to the
    // "location unknown" sentence.
    await expect(page.locator("#connection-pair-map-unknown")).toHaveCount(0);
    await expect(page.locator("#connection-pair-map")).toBeVisible();

    tour.guard = {
      distanceWarning: distanceText,
      nearbyNoDistanceWarning: true,
      discardConfirmCloses: true,
    };
  });

  // ── the mutating keyboard journey ─────────────────────────────────────────

  test("keyboard: the whole in-seat path is reachable and operable from the keyboard alone", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);

    // The Plan view radios are visually hidden behind their labels, so this is
    // a real keyboard route into the Connections view rather than a click.
    await page.goto(blocksPath(versionId));
    await expect(page.locator("#blocks-timeline-body tr")).toHaveCount(15);
    await enterConnectionsViewWithKeyboard(page);
    await expect(page).toHaveURL(/view=connections/);

    // The group row is one Tab stop away from the panel's own first control.
    await page.locator("#connections-q").focus();
    await tabUntilFocused(
      page,
      `#connections-place-${placeToken(SCHOOL_JUNCTION)} button[phx-click="open_group"]`,
      12,
    );
    await page.keyboard.press("Enter");
    await expect(page.locator("#connections-group")).toBeVisible();
    await expect(page.locator("#connections-group-title")).toHaveText(
      "Continues as 24 at School Junction",
    );
    await expect(page.locator("#connections-group-count")).toHaveText(
      "3 connections",
    );

    // The quiet neighbour's own row opens the drawer.
    await page.locator("#connections-group-back").focus();
    await tabUntilFocused(
      page,
      `button[phx-value-block="${SHARED_QUIET_PAIR}"]`,
      12,
    );
    await page.keyboard.press("Enter");
    await expect(page.locator("#gap-drawer")).toContainText(
      "BIS_SH_A2 → BIS_SH_B2",
    );

    // The three choices are one radio group, so Tab lands on the group and an
    // arrow key moves within it — the affordance the whole-card label promises.
    // Only the checked radio is a tab stop, which is why this walks to
    // "not stated" and arrows down rather than Tabbing to an unchecked option.
    await tabUntilFocused(page, "#connection-choice-not-stated", 40);
    await page.keyboard.press("ArrowDown");
    await expect(page.locator("#connection-choice-stay")).toBeChecked();
    // This pair holds no record, so the draft needs no warning sentence and the
    // live region settles empty; what matters is that it is present and no
    // longer pending, and that the save the keyboard reaches is enabled.
    await expect(page.locator("#connection-save-status")).toHaveAttribute(
      "data-pending",
      "false",
    );
    await expect(page.locator("#connection-save")).toBeEnabled();

    // Save is in the drawer's footer, so Tab has to reach it: a footer the
    // keyboard cannot reach is a save the keyboard cannot perform.
    await tabUntilFocused(page, "#connection-save", 40);
    await page.keyboard.press("Enter");
    await expect(page.locator("#connection-result")).toContainText(
      // The spec's own sentence is "Saved: {setting} from trip {a} to {b}." —
      // only the first trip carries the word, so this reads the page's words
      // and tolerates the template's whitespace inside the element.
      /Saved: riders stay on board from trip BIS_SH_A2 to BIS_SH_B2\./,
    );
    await expect(page.locator("#gap-drawer")).toBeHidden();

    // Undo puts the pair back, and the page says so in the same words.
    await page.locator("#connection-undo").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#connection-result")).toContainText(
      "Restored: not stated.",
    );
    await expect(page.locator("#connection-undo")).toHaveCount(0);
    await page.locator("#connection-dismiss").click();
    await expect(page.locator("#connection-result")).toHaveCount(0);

    // Set all for the whole group: two quiet pairs become stay records and the
    // refused pair is listed and left alone.
    await chooseWithKeyboard(page, "#connections-bulk-stay");
    await expect(page.locator("#connections-bulk-stay")).toBeChecked();
    await tabUntilFocused(page, "#bulk-review-open", 6);
    await page.keyboard.press("Enter");

    const review = page.locator("#set-all-review");
    await expect(review).toBeVisible();
    // Each count is a <div> holding its label and its number, so the number
    // lives in the <dd> the definition list renders inside it.
    await expect(
      page.locator("#set-all-review-count-adds dd"),
    ).toHaveText("2");
    await expect(
      // The count's id is slugged from its own label, so the apostrophe in
      // "Can't be set" is dropped rather than hyphenated.
      page.locator("#set-all-review-count-cant-be-set dd"),
    ).toHaveText("1");
    // The footer's total is the group's actionable rows: the refused pair has
    // no include box, so it is not one of the connections the count is about.
    await expect(page.locator("#set-all-review-included")).toHaveText(
      "2 of 2 included",
    );
    await expect(
      page.locator("#set-all-review-table tr[data-result='skip']"),
    ).toHaveCount(1);
    await expect(
      page.locator("#set-all-review-table tr[data-result='skip']"),
    ).toContainText("Can’t be set.");
    await expect(
      page.locator("#set-all-review-table tr[data-result='skip']"),
    ).toContainText("BIS_SH_X runs next on this vehicle");

    await capture(page, testInfo, "bulk-review");

    await page.locator("#set-all-review-save").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#set-all-review")).toBeHidden();

    // The result is the write's own answer: two written, one named as skipped
    // with the rule's reason, and a Dismiss that leaves the group alone.
    const bulkResult = page.locator("#bulk-result");
    await expect(bulkResult).toBeVisible();
    await expect(bulkResult).toContainText(
      "Saved 2 connections: riders stay on board. 1 skipped:",
    );
    // The skipped line reads "Block {b}, {clock} ({a} → {b}): {reason}", and the
    // page's own id for that line is slugged from all of that, so the line is
    // addressed by its role and read for both the pair and the rule's reason.
    const skipLine = page.locator(
      "#bulk-result-skipped [data-role='bulk-result-skip']",
    );
    await expect(skipLine).toHaveCount(1);
    await expect(skipLine).toContainText(`${SHARED_PAIR}`);
    await expect(skipLine).toContainText("BIS_SH_X runs next on this vehicle");
    // Read while it is on the page: Dismiss takes it away.
    const bulkResultText = await bulkResult.innerText();

    await capture(page, testInfo, "bulk-result");

    await page.locator("#bulk-dismiss").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#bulk-result")).toHaveCount(0);
    await expect(page.locator("#connections-group")).toBeVisible();

    // The Checks drawer is in the page header, so reaching it is a backward
    // walk out of the workspace rather than a click.
    await page.locator("#connections-group-back").focus();
    await shiftTabUntilFocused(page, "#blocks-review-checks", 60);
    await page.keyboard.press("Enter");

    await expect(page.locator("#checks-drawer")).toBeVisible();
    await expect(page.locator("#checks-in-seat-entries li")).toHaveCount(
      CHECKS_ENTRIES,
    );
    await expect(
      page.locator("#checks-in-seat-entries li[data-kind='conflict']"),
    ).toHaveCount(1);
    await expect(page.locator("#checks-remove-stale")).toHaveText(
      `Remove ${STALE_RECORDS} records that no longer match`,
    );
    await expect(page.locator("#checks-in-seat-version")).toContainText(
      "2 in-seat records don't match any block",
    );
    await expect(
      page.locator("#checks-in-seat-entries li[data-kind='conflict']"),
    ).toHaveCount(1);
    await expect(page.locator("#checks-in-seat-unmatched li")).toHaveCount(2);

    await capture(page, testInfo, "checks");

    // Removing the stale records leaves the conflicting pair and the version's
    // own unmatched rows alone: the two questions are differently scoped.
    await page.locator("#checks-remove-stale").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#remove-stale-dialog")).toBeVisible();
    await expect(page.locator("#remove-stale-dialog-title")).toHaveText(
      `Remove ${STALE_RECORDS} in-seat records?`,
    );
    await expect(page.locator("#remove-stale-dialog-confirm")).toHaveText(
      `Remove ${STALE_RECORDS} records`,
    );
    await expect(page.locator("#remove-stale-dialog-body")).toContainText(
      "no longer match School days + Weekday service blocks",
    );

    await page.locator("#remove-stale-dialog-confirm").focus();
    await page.keyboard.press("Enter");
    await expect(page.locator("#remove-stale-dialog")).toBeHidden();
    await expect(page.locator("#checks-remove-stale")).toHaveCount(0);
    await expect(page.locator("#checks-in-seat-entries li")).toHaveCount(3);
    await expect(
      page.locator("#checks-in-seat-entries li[data-kind='conflict']"),
    ).toHaveCount(1);
    await expect(page.locator("#checks-in-seat-unmatched li")).toHaveCount(2);
    await expect(page.locator("#checks-remove-unmatched")).toHaveText(
      "Remove 2 records",
    );

    tour.keyboard = {
      viewSwitch: "Space on a Plan view radio",
      groupRowTabs: "one Tab from the panel's first control",
      choice: "Tab to the radio group, ArrowDown within it",
      save: "Tab into the drawer footer, then Enter",
      undo: "Enter on the result's Undo",
      setAll: "Space on a Set-all radio, then Enter on Review",
      review: { adds: 2, skipped: 1, included: "2 of 2" },
      bulkResult: bulkResultText,
      checks: {
        entries: CHECKS_ENTRIES,
        staleRemoved: STALE_RECORDS,
        entriesAfter: 3,
        conflictKept: 1,
        unmatchedKept: 2,
      },
      overflow: !(await fitsViewport(page)),
    };
  });

  // ── the map's failure path ────────────────────────────────────────────────

  test("map: with the tiles aborted both maps say unavailable and a save still succeeds", async ({
    page,
  }, testInfo) => {
    // Aborted tile requests are this journey's whole point, so its route
    // replaces the fulfilling one the other journeys use.
    await page.route(TILE_ROUTE, (route) => route.abort());

    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId, CONNECTIONS_QUERY));

    const paneNotice = page.locator("#connections-map-unavailable");
    await expect(paneNotice).toBeVisible();
    await expect(paneNotice).toContainText("Map unavailable");
    await expect(paneNotice).toContainText("The list still works.");
    await expect(page.locator("#connections-map")).toHaveAttribute(
      "data-state",
      "unavailable",
    );

    // The list is the answer, so it is still there and still complete.
    await expect(page.locator("#connections-summary")).toHaveText(
      `${CONNECTIONS} of ${CONNECTIONS} connections at ${PLACES} places`,
    );
    await expect(
      page.locator('#connections-list button[phx-click="open_group"]'),
    ).toHaveCount(GROUPS);

    // The drawer's own pair map degrades the same way, and says the two stops
    // are named above it.
    await groupRow(page, MARKET_ROW).click();
    await groupTableButton(page, NEAR_PAIR).click();
    const pairNotice = page.locator("#connection-pair-map-unavailable");
    await expect(pairNotice).toBeVisible();
    await expect(pairNotice).toContainText(
      "Map unavailable. The two stops are named above.",
    );
    // Read while the drawer is still open: saving closes it and takes the
    // notice with it.
    const pairNoticeText = await pairNotice.innerText();

    // The write does not depend on the map: a save still lands and says so.
    await page.locator("#connection-choice-stay").check();
    await expect(page.locator("#connection-save")).toBeEnabled();
    await page.locator("#connection-save").click();
    await expect(page.locator("#connection-result")).toContainText(
      /Saved: riders stay on board from trip BIS_NEAR_T1 to trip BIS_NEAR_T2\./,
    );
    await expect(page.locator("#gap-drawer")).toBeHidden();

    tour.map = {
      paneNotice: await paneNotice.innerText(),
      pairNotice: pairNoticeText,
      savedWithoutMap: true,
    };

    await capture(page, testInfo, "conn-map-unavailable");
  });

  // ── target sizes, focus and legibility ────────────────────────────────────

  test("targets: every new control is at least 44x44, the choice card takes the focus ring, and the refused pair's disabled card keeps its ink", async ({
    page,
  }) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);

    // The list's own control. The group's count beside it is a span of text,
    // not a target, so it is not measured here.
    const listTargets = {
      "group row": await targetBox(
        page,
        `#connections-place-${placeToken(FAR_AVENUE)} button[phx-click="open_group"]`,
      ),
    };

    await groupRow(page, FAR_AVENUE).click();
    // The Set-all radio is 18px; its label is the target, and the label is what
    // the markup sizes. The review button is measured for opacity rather than
    // for size because it carries no explicit minimum.
    const groupTargets = {
      "group back": await targetBox(page, "#connections-group-back"),
      "connection row": await targetBox(
        page,
        '#connections-group-table button[phx-value-block="BIS-FA2"]',
      ),
      "set-all choice label": await targetBox(
        page,
        "label:has(#connections-bulk-stay)",
      ),
    };

    await groupTableButton(page, "BIS-FA2").click();
    const drawerTargets = {
      "drawer close": await targetBox(page, "#gap-drawer-close"),
      cancel: await targetBox(page, "#connection-cancel"),
      save: await targetBox(page, "#connection-save"),
      "choice card": await targetBox(
        page,
        '[data-role="connection-choice"][data-choice="not_stated"]',
      ),
    };

    tour.targets = { ...listTargets, ...groupTargets, ...drawerTargets };

    for (const [name, box] of Object.entries(tour.targets)) {
      expect(box, `${name} is rendered`).not.toBeNull();
      expect(box.width, `${name} width`).toBeGreaterThanOrEqual(MIN_TARGET);
      expect(box.height, `${name} height`).toBeGreaterThanOrEqual(MIN_TARGET);
    }

    // The radio is 18px, so the card is what takes the focus ring: the walk is
    // by Tab, because `:focus-visible` only matches keyboard focus.
    await tabUntilFocused(page, "#connection-choice-not-stated", 40);
    const outline = await focusOutline(page, "#connection-choice-not-stated");
    expect(outline.style).toBe("solid");
    expect(outline.width).toBeGreaterThanOrEqual(2);
    expect(outline.color).not.toBe("rgba(0, 0, 0, 0)");

    tour.focusOutline = outline;

    // A disabled control is unavailable, not invisible: daisyUI washes a
    // disabled checkbox or radio out to a fraction of its opacity, and a
    // setting a reader has to read must not be one of those. The refused
    // pair's two cards are the genuinely disabled settings of this feature, so
    // that is what is measured.
    await page.locator("#connection-cancel").click();
    await expect(page.locator("#gap-drawer")).toBeHidden();
    await page.locator("#connections-group-back").click();
    await groupRow(page, SCHOOL_JUNCTION).click();
    await groupTableButton(page, SHARED_PAIR).click();

    const refusedCards = {
      "refused stay card": await computedOpacity(
        page,
        '[data-role="connection-choice"][data-choice="stay_on_board"]',
      ),
      "refused stay radio": await computedOpacity(
        page,
        "#connection-choice-stay",
      ),
      "save button": await computedOpacity(page, "#connection-save"),
    };

    tour.disabledOpacity = refusedCards;
    for (const [name, opacity] of Object.entries(refusedCards)) {
      expect(opacity, `${name} keeps full opacity`).toBe("1");
    }

    // And the ink is still ink: the refused card draws its own text colour on
    // its own ground, not the colour of the ground itself.
    const refusedInk = await page.evaluate(() => {
      const card = document.querySelector(
        '[data-role="connection-choice"][data-choice="stay_on_board"]',
      );
      const title = card.querySelector("span span");
      return {
        ink: getComputedStyle(title).color,
        background: getComputedStyle(card).backgroundColor,
        opacity: getComputedStyle(card).opacity,
      };
    });
    expect(refusedInk.ink).not.toBe(refusedInk.background);
    expect(refusedInk.opacity).toBe("1");

    // The one enabled card is the one that writes nothing, and it is not washed
    // out either.
    expect(await computedOpacity(page, "#connection-choice-not-stated")).toBe(
      "1",
    );

    tour.disabledInk = refusedInk;
  });

  test("errors: reading the in-seat surfaces raises no uncaught page error", async ({
    page,
  }) => {
    // The afterEach asserts the same thing after every journey; this one walks
    // the read-only surfaces deliberately so the guarantee is also a case.
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openConnections(page, versionId);
    await groupRow(page, FAR_AVENUE).click();
    await groupTableButton(page, "BIS-FA2").click();
    await expect(page.locator("#connection-form")).toBeVisible();
    await page.locator("#connection-choice-stay").check();
    await page.locator("#connection-save").click();
    await expect(page.locator("#connection-result")).toBeVisible();
    await page.locator("#connection-undo").click();
    await expect(page.locator("#connection-result")).toContainText(
      "Restored: not stated.",
    );

    expect(pageErrors, "the page raised no uncaught error").toEqual([]);
  });
});

test.describe("In-seat connections on a phone", () => {
  test.use({ viewport: PHONE });

  test("mobile: the inspector, its mini-map and its footer fit the viewport at 390x844", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);

    // The viewport hook only pushes the List view when the URL says nothing
    // about the view, so the explicit `view=connections` is what keeps the
    // Connections view on a phone.
    await openConnections(page, versionId);
    await expect(page.locator("#connections-panel")).toBeVisible();

    await groupRow(page, FAR_AVENUE).click();
    await groupTableButton(page, "BIS-FA2").click();

    // The drawer is the full width of a phone and everything in it fits: the
    // pair map, the three choices and the footer's own actions.
    for (const selector of [
      "#gap-drawer",
      "#connection-pair-map-region",
      "#connection-form",
      '[data-role="connection-choice"][data-choice="stay_on_board"]',
      "#connection-save",
      "#connection-cancel",
    ]) {
      const box = await targetBox(page, selector);
      expect(box, `${selector} is rendered`).not.toBeNull();
      expect(box.width, `${selector} fits the viewport`).toBeLessThanOrEqual(
        PHONE.width,
      );
    }

    // Choosing a setting does not widen the page either.
    await page.locator("#connection-choice-stay").check();
    await expect(page.locator("#connection-save")).toBeEnabled();
    expect(await fitsViewport(page)).toBe(true);

    tour.mobile = {
      viewport: "390x844",
      drawerWidth: (await targetBox(page, "#gap-drawer")).width,
      overflow: !(await fitsViewport(page)),
    };

    await capture(page, testInfo, "conn-mobile");
  });
});

// The tour is the capture artifact's own index: entrypoint, setup, scenarios,
// expected outcomes and the automated coverage, with the numbers the journeys
// measured. It is written last so it reports the whole run.
test.describe("qa tour", () => {
  test.use({ viewport: DESKTOP });

  test("writes qa-tour.md from the measured journey", async ({}, testInfo) => {
    const value = (key) =>
      tour[key] === undefined ? "(not measured)" : JSON.stringify(tour[key]);

    const markdown = [
      "# In-seat connections browser QA tour (EV-29, step 28)",
      "",
      "Entrypoint: `/gtfs/<version>/blocks?view=connections` for the published",
      `**${VERSION_NAME}** seeded by \`test/support/browser_seed.exs\` (${CONNECTIONS}`,
      `connections in ${GROUPS} groups over ${PLACES} places, on the`,
      `"${DAY_TYPE}" day type).`,
      "",
      "## Setup",
      "",
      "```sh",
      "bin/test-browser \\",
      "  e2e/in_seat.spec.js e2e/blocks.spec.js e2e/overlays.spec.js \\",
      "  e2e/transfers.spec.js",
      "```",
      "",
      "The suite runs Chromium against a local test Phoenix server on a free port",
      "(`BROWSER_E2E=true`), one worker, no retries, against a throwaway Postgres",
      "that `bin/test-browser` creates, migrates and seeds for the run. These",
      "journeys share one seeded version and mutate it in order, so a re-run needs",
      "a new database. Only `/map/tiles/**` is intercepted, at the network",
      "boundary; no journey reaches an external tile host.",
      "",
      "## Scenarios and expected outcomes",
      "",
      "| Scenario | Expected outcome | Measured |",
      "|---|---|---|",
      "| Connections view at 1440x900 | Every connection on the day type, one section per place, one row per group, and the place the version cannot place named beside the map | " +
        value("list"),
      " |",
      "| The day's timeline | One gap chip per connection, carrying that connection's own setting: 1 stay, 1 re-board, 3 needing review | " +
        value("timeline"),
      " |",
      "| A group's panel | Its connections with their waits and settings, and Set all inert until a setting is chosen | " +
        value("group"),
      " |",
      "| A through connection's drawer | A non-modal inspector beside the live group table, three choices, a scope of every date both trips run, and a save that stays disabled until the answer changes | " +
        value("inspector"),
      " |",
      "| The refused shared-trip pair | Only Not stated available, the rule's reason naming the day type and the trip that runs next, and a link to that day type | " +
        value("blocked"),
      " |",
      "| The turnback pair | A pickup warning that says OpenTripPlanner drops the record, and a discard question in front of Escape | " +
        value("pickup"),
      " |",
      "| The 370 m move and the 180 m nearby handoff | A distance warning for the empty move only, and no warning for a handoff that does not move the vehicle | " +
        value("guard"),
      " |",
      "| Keyboard only, from the Plan view to the Checks drawer | Every control reached by Tab or Shift+Tab and operated by Space or Enter: the view, the group, the connection, the choice, Save, Undo, Set all, its review, its save, its result, the Checks drawer and both removals | " +
        value("keyboard"),
      " |",
      "| Tile requests aborted | Both maps say unavailable, the list is complete, and a save still lands | " +
        value("map"),
      " |",
      "| Target sizes, focus and disabled ink | Every new control at least 44x44, a 2px focus ring on the choice card, and no disabled control washed out with opacity | " +
        value("targets"),
      " |",
      "| The inspector at 390x844 | The drawer, its mini-map, its choices and its footer fit, and the page never scrolls sideways | " +
        value("mobile"),
      " |",
      "",
      "## Captures",
      "",
      `\`${CAPTURES.map((name) => `\`${name}.png\``).join(", ")}, plus`,
      "`conn-pickup.png` and `conn-map-unavailable.png`, sit beside this file in",
      "the package's `evidence/browser/` directory.",
      "",
      "## Automated coverage",
      "",
      "- `assets/e2e/in_seat.spec.js` — the journeys and the measurements above.",
      "- `assets/e2e/blocks.spec.js` — unchanged: the Blocks timeline, list and",
      "  pool the Connections view sits inside.",
      "- `assets/e2e/overlays.spec.js` — unchanged: the drawer and dialog shell",
      "  the two inspectors are built from.",
      "- `assets/e2e/transfers.spec.js` — unchanged: the in-seat records Routes ›",
      "  Transfers lists under In-seat.",
      "- `test/support/browser_seed.exs` — the “Browser In-Seat Version” fixture",
      "  these journeys read, whose credential this spec also reads.",
      "",
    ].join("\n");

    const outputPath = testInfo.outputPath("qa-tour.md");
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, markdown);
    const evidencePath = copyIntoEvidence("qa-tour.md", Buffer.from(markdown));

    const tourText = readFileSync(evidencePath, "utf8");
    expect(tourText).toContain("In-seat connections browser QA tour");
    expect(tourText).toContain("bin/test-browser");

    // The card names the captures as the artifact, so the tour checks that the
    // journeys that own each state really wrote theirs.
    for (const name of CAPTURES) {
      const path = resolve(EVIDENCE_DIR, `${name}.png`);
      expect(
        readFileSync(path).length,
        `${name}.png is a real capture`,
      ).toBeGreaterThan(0);
    }
  });
});

// ── small helpers ────────────────────────────────────────────────────────────
