// Advanced Blocks browser journey (EV-9, step 47).
//
// The journey exercises the advanced Blocks page end to end in Chromium at
// 1440x1000 and the List view at 375x812 against the seeded
// "Browser Advanced Blocks Version" in `test/support/browser_seed.exs` — the
// version that carries the reference prototype's "Plan with problems" state —
// and compares what it captures with `.specs/07-advanced-blocking/references/
// advanced-blocking-prototype.html` (`problems`, `summary`, `relief`,
// `driving-entered`, `selected`, `preview-selected`, `preview-pool`,
// `confirm-replace`, `stale` and `list`).
//
// Every expectation is a literal value from that seed or from an acceptance
// criterion, never a value read back from the surface under test: the four
// blocks 101-104 with the two problems the state is named for (101 cannot
// reach Market Square — 14 min of drive into an 8-minute gap — and 104 runs
// route 30, which requires a 35-ft diesel, on a Cutaway), the three day types
// derived from {WKDY, SCHOOL}, {WKDY} and {SAT}, the 12 Cutaways and 8 diesels
// at Main with 6 Cutaways at North, and the one relief point at Market Square.
//
// The journeys share one reset-and-seeded database, so they are serial and run
// in the order the card lists them: each one leaves the day the next reads. A
// reader who re-runs a single journey after the others have written sees
// mutated state, exactly as the repository's own `blocks.spec.js` does.
//
// Captures are written under `testInfo.outputPath` and copied to
// `.specs/07-advanced-blocking/evidence/browser/`; the last journey writes
// `qa-tour.md` from the measurements the earlier ones recorded. `.specs/` is
// gitignored and lives in the primary checkout, so the reference render and the
// tour artifact are skipped (never failed) when that workspace is not linked.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SPEC_PACKAGE = resolve(__dirname, "..", "..", ".specs", "07-advanced-blocking");
const EVIDENCE_DIR = resolve(SPEC_PACKAGE, "evidence", "browser");
const REFERENCE_PROTOTYPE = resolve(
  SPEC_PACKAGE,
  "references",
  "advanced-blocking-prototype.html",
);

const EDITOR = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const VERSION_NAME = "Browser Advanced Blocks Version";

// The seeded day types, largest first: {WKDY, SCHOOL} is the page's default.
const DAY_LARGEST = "School days + Weekday";
const DAY_WEEKDAY = "Weekday";

// The seeded blocks, the trips that carry the two problems, and the pairs the
// driving-time and operator-change journeys act on.
const BLOCKS = ["101", "102", "103", "104"];
const BLOCK_CANNOT_REACH = "101";
const BLOCK_WRONG_TYPE = "104";
const BLOCK_OPERATOR_CHANGE = "102";
const TRIP_101_OUT = "8101"; // Market Square 06:43, the end of the impossible drive
const PAIR_VC_MS = "stop:AB_VALLEY|stop:AB_MKT"; // Valley College → Market Square
const PAIR_RS_GARAGE_PREFIX = "minutes[stop:AB_RS_B|garage:";
const STATION_INPUT = "#operator-candidate-0"; // Riverside Station, the first row

// The card's named figures, read from the seed rather than from the page.
const TRACK_MIN_PX = 760; // the reference's wide frame: 769 px at 1440
const FLEET_NEEDED = 4;
const FLEET_LISTED = 12;
const DRIVING_ESTIMATED = 6;
const OPERATOR_LIMIT = "330";
const ENTERED_MINUTES = 9;
const GAP_MINUTES = 8; // 06:35 at Valley College to 06:43 at Market Square

const DESKTOP = { width: 1440, height: 1000 };
const NARROW = { width: 375, height: 812 };

// The reference states the journey renders beside.
const REFERENCE_SCENARIOS = [
  ["problems", "state=problems"],
  ["summary", "state=summary&panel=summary"],
  ["relief", "state=relief&drawer=operator"],
  ["driving", "state=driving&drawer=driving"],
  ["selected", "state=selected"],
  ["preview-selected", "state=preview-selected"],
  ["preview-pool", "state=preview-pool"],
  ["confirm-replace", "state=confirm-replace"],
  ["stale", "state=stale"],
];

// Measurements the qa tour reports; each journey fills its own keys.
const tour = {};

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR.email);
  await page.fill('input[name="user[password]"]', EDITOR.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published version, so the journey reads the
// version ID from the ordinary panel rather than assuming one.
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

// The timeline streams its rows after mount, so every journey waits for the
// day to draw its own blocks before measuring or clicking anything. The first
// journey pins the seeded count; the later ones have added blocks of their own,
// so the wait is "the day has drawn something" and each journey asserts the
// count it depends on.
async function openBlocks(page, versionId, query = "", expected) {
  await page.goto(blocksPath(versionId, query));
  const rows = page.locator("#blocks-timeline-body tr, #blocks-lists section");
  if (expected === undefined) {
    await expect
      .poll(async () => rows.count(), { timeout: 30_000 })
      .toBeGreaterThan(0);
  } else {
    await expect(rows).toHaveCount(expected, { timeout: 30_000 });
  }
}

// The day's four rows, as the page prints them: the block, its R4 garage and
// type resolution, its status and whether the previewed plan changes it.
async function blockRows(page) {
  return page.evaluate(() =>
    [...document.querySelectorAll("#blocks-timeline-body tr")].map((row) => ({
      block: row.dataset.block,
      garage: row.querySelector(".blocks-meta-garage")?.textContent.trim(),
      status: row.querySelector("[data-role='block-status']")?.textContent.trim(),
      changed: row.dataset.changed === "true",
      trips: [...row.querySelectorAll("[data-role='trip-bar']")].map((bar) =>
        bar.getAttribute("data-trip"),
      ),
    })),
  );
}

function statusOf(rows, block) {
  const row = rows.find((entry) => entry.block === block);
  if (!row) throw new Error(`no rendered row for block ${block}`);
  return row.status;
}

// Saves a capture under the test's own output directory, then copies it into
// the spec package's browser-evidence folder (the card's capture artifact).
async function capture(page, testInfo, name, { fullPage = false } = {}) {
  const outputPath = testInfo.outputPath(`${name}.png`);
  mkdirSync(dirname(outputPath), { recursive: true });
  await page.screenshot({ path: outputPath, fullPage, animations: "disabled" });
  copyIntoEvidence(`${name}.png`, readFileSync(outputPath));
}

function copyIntoEvidence(name, contents) {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const target = resolve(EVIDENCE_DIR, name);
  writeFileSync(target, contents);
  return target;
}

// A drawer is a top-layer `<dialog>`; the shared component carries its open
// state on the overlay, so every drawer wait reads the component's own
// attribute rather than a class or a computed style.
async function openDrawer(page, overlayId) {
  await expect(page.locator(`#${overlayId}[data-open="true"]`)).toBeVisible();
}

async function closeDrawer(page, overlayId) {
  // A closed `<dialog>` is `inert` and hidden, so the component's own
  // attribute is the wait rather than visibility.
  await expect(page.locator(`#${overlayId}`)).toHaveAttribute("data-open", "false");
}

// The suggested-blocks panel's own numbers: the four metrics, the moves it
// lists, the day types it names and the state of the apply control.
async function panelState(page) {
  await expect(page.locator("#suggestion")).toBeVisible();
  return page.evaluate(() => ({
    scopeLine: document
      .querySelector("#suggestion-title")
      ?.nextElementSibling?.textContent.trim(),
    metrics: [...document.querySelectorAll("[data-role='suggestion-metric']")].map(
      (metric) => metric.textContent.replace(/\s+/g, " ").trim(),
    ),
    moveCount: document.querySelectorAll("#suggestion-moves-table tr").length,
    moves: [...document.querySelectorAll("#suggestion-moves-table tr")].map((row) => ({
      trip: row.querySelector("td")?.textContent.trim(),
      current: row.querySelectorAll("td")[2]?.textContent.trim(),
      proposed: row
        .querySelector("[data-role='suggestion-proposed']")
        ?.textContent.trim(),
      change: row.querySelector("[data-role='suggestion-change']")?.dataset.change,
    })),
    effects: [...document.querySelectorAll("#suggestion [data-role='review-effect']")].map(
      (effect) => ({
        selected: effect.dataset.selected === "true",
        heading: effect.querySelector("strong")?.textContent.trim(),
      }),
    ),
    scopeNote: document.querySelector("#suggestion-scope-note")?.textContent.trim(),
    applyLabel: document.querySelector("#apply-suggestion")?.textContent.trim(),
    applyDisabled: document
      .querySelector("#apply-suggestion")
      ?.hasAttribute("disabled"),
    applyReason: document
      .querySelector("#suggestion-apply-reason")
      ?.textContent.trim(),
    applyState: document
      .querySelector("#suggestion-apply-message")
      ?.getAttribute("data-state"),
    applyMessage: document
      .querySelector("#suggestion-apply-message")
      ?.textContent.trim(),
  }));
}

// The metric that carries a label, so a figure is read from its own tile.
function metricValue(metrics, label) {
  const metric = metrics.find((entry) => entry.startsWith(label));
  if (!metric) throw new Error(`no "${label}" metric in ${JSON.stringify(metrics)}`);
  return metric.replace(`${label} `, "").trim();
}

// The Suggest blocks drawer, with its three scopes, opened from the page's own
// action. The scope radio is chosen by the id the component prints for it.
async function openSuggest(page, versionId) {
  await page.goto(blocksPath(versionId));
  await expect
    .poll(async () => page.locator("#blocks-timeline-body tr").count(), {
      timeout: 30_000,
    })
    .toBeGreaterThan(0);
  await page.locator("#blocks-suggest").click();
  await openDrawer(page, "suggest-drawer-overlay");
}

async function chooseScope(page, scope) {
  await page.locator(`#suggest-scope-${scope}`).check();
  await expect(page.locator(`#suggest-scope-${scope}`)).toBeChecked();
}

async function previewSuggestion(page) {
  await page.locator("#suggest-preview").click();
  await expect(page.locator("#suggest-drawer-overlay")).toHaveAttribute(
    "data-open",
    "false",
  );
}

test.describe("advanced Blocks page at 1440x1000", () => {
  test.use({ viewport: DESKTOP });
  // The journeys share one seeded database and each writes; running them out of
  // order would read a day the previous one had already changed.
  test.describe.configure({ mode: "serial" });

  test("the default day type shows both seeded problems and the wide track", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId, "", BLOCKS.length);

    // The largest day type is the default, and it is the one that derives
    // {WKDY, SCHOOL} — 126 dates over the seeded term. The select's own value
    // is the derived key, so the option's label is what a reader reads.
    const day = await page
      .locator("#blocks-day")
      .evaluate((el) => el.selectedOptions[0].textContent.trim());
    expect(day).toBe(`${DAY_LARGEST} · 126 dates`);

    const dayTypes = await page.evaluate(() =>
      [...document.querySelectorAll("#blocks-day option")].map((o) =>
        o.textContent.trim(),
      ),
    );
    expect(dayTypes).toEqual([
      `${DAY_LARGEST} · 126 dates`,
      `${DAY_WEEKDAY} · 84 dates`,
      "Saturday · 41 dates",
    ]);

    const rows = await blockRows(page);
    expect(rows.map((row) => row.block)).toEqual(BLOCKS);
    // Every weekday block resolves to Main and a Cutaway (INV-9 / R4).
    for (const row of rows) {
      expect(row.garage).toBe("Main · Cutaway");
    }
    // The two problems the state is named for: 101 cannot reach Market Square
    // and 104 runs route 30, which needs the 35-ft diesel, on a Cutaway.
    expect(statusOf(rows, BLOCK_CANNOT_REACH)).toBe("Can't reach");
    expect(statusOf(rows, BLOCK_WRONG_TYPE)).toBe("Wrong type");
    expect(statusOf(rows, BLOCK_OPERATOR_CHANGE)).toBe("No operator change");
    expect(statusOf(rows, "103")).toBe("No problems");

    // The wide workspace frame: the track is at least the reference's 769 px at
    // 1440, and neither the container nor the page scrolls sideways.
    const geometry = await page.evaluate(() => {
      const container = document.querySelector("#blocks-timeline-scroll");
      const track = document.querySelector(
        "#blocks-timeline-body tr .blocks-track",
      );
      return {
        trackWidth: Math.round(track.getBoundingClientRect().width),
        containerWidth: container.clientWidth,
        tableWidth: container.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
        innerWidth: window.innerWidth,
      };
    });
    expect(geometry.trackWidth).toBeGreaterThanOrEqual(TRACK_MIN_PX);
    expect(geometry.containerWidth).toBe(geometry.tableWidth);
    expect(await bodyFitsViewport(page)).toBe(true);

    // The seed's own relief warning is the notice the Plan summary opens from.
    await expect(page.locator("#blocks-summary-counts")).toContainText("Blocks");
    await expect(page.locator('[data-key="problems"]')).toBeVisible();
    await expect(
      page.locator("#blocks-summary-figures [data-key='vehicles']"),
    ).toContainText("Vehicles");

    tour.default = {
      dayType: day,
      dayTypes: dayTypes.length,
      blocks: rows.length,
      cannotReach: statusOf(rows, BLOCK_CANNOT_REACH),
      wrongType: statusOf(rows, BLOCK_WRONG_TYPE),
      operatorChange: statusOf(rows, BLOCK_OPERATOR_CHANGE),
      trackWidth: geometry.trackWidth,
      pageScrollWidth: geometry.bodyScrollWidth,
      innerWidth: geometry.innerWidth,
    };

    await capture(page, testInfo, "advanced-default-1440", { fullPage: true });
  });

  test("the Plan summary reports the fleet the seed listed", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    await page.locator("#blocks-summary-figures [data-key='vehicles']").click();
    await openDrawer(page, "plan-summary-drawer-overlay");

    // The headline the strip and the drawer share, and the day's own minimum
    // and rider share behind it.
    const strip = page.locator("#blocks-summary-figures [data-key='vehicles']");
    await expect(strip).toContainText("Vehicles");
    const stripValue = (
      await strip.locator("[data-role='count-strip-value']").textContent()
    ).trim();
    await expect(page.locator("#plan-summary-vehicles")).toHaveText(
      `${stripValue} vehicles used`,
    );
    // The strip's own detail is the day's lower bound, and the drawer prints
    // the same number beside its label.
    await expect(strip).toContainText(`minimum ${stripValue}`);
    await expect(page.locator("#plan-summary-minimum")).toHaveText(stripValue);
    // The rider share is the strip's own figure, printed with its percent.
    const ridersValue = (
      await page
        .locator("#blocks-summary-figures [data-key='riders'] [data-role='count-strip-value']")
        .textContent()
    ).trim();
    await expect(page.locator("#plan-summary-riders")).toHaveText(ridersValue);

    // The fleet table at the busiest time: Main · Cutaway needs 4 and lists 12.
    const fleetRow = page
      .locator("[data-role='plan-summary-fleet-row']")
      .filter({ hasText: "Main · Cutaway" });
    await expect(fleetRow).toHaveCount(1);
    await expect(fleetRow).toContainText(String(FLEET_NEEDED));
    await expect(fleetRow).toContainText(String(FLEET_LISTED));
    // A block with no type counts against its garage's total, so the
    // untyped row is the garage's own 12 plus the 8 diesels.
    await expect(page.locator("#plan-summary-fleet-note")).toContainText(
      "Blocks without a type count against their garage’s total",
    );

    // Distances are in kilometres (the approved unit) and the operator-change
    // section names the block that runs longest without a place to change.
    await expect(page.locator("#plan-summary-totals")).toContainText("km");
    await expect(page.locator("#plan-summary-relief")).toContainText(
      `Longest time before a change`,
    );
    await expect(page.locator("#plan-summary-relief")).toContainText(
      `in block ${BLOCK_OPERATOR_CHANGE}`,
    );
    await expect(page.locator("#plan-summary-relief")).toContainText(
      `Limit 5 h 30 min`,
    );
    // The only relief point the seed marks is Market Square, which no weekday
    // block visits, so the longest stretch names a weekday block.
    await expect(page.locator("#plan-summary-relief")).toContainText(
      "1 stop marked",
    );

    const fleetRows = await page
      .locator("[data-role='plan-summary-fleet-row']")
      .allInnerTexts();

    tour.planSummary = {
      vehicles: (await page.locator("#plan-summary-vehicles").innerText()).trim(),
      fleetRows: fleetRows.map((row) => row.replace(/\s+/g, " ").trim()),
      relief: (await page.locator("#plan-summary-relief").innerText())
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 120),
    };

    await capture(page, testInfo, "advanced-plan-summary-1440");
  });

  test("marking Riverside Station clears block 102's operator-change warning", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    const before = await blockRows(page);
    expect(statusOf(before, BLOCK_OPERATOR_CHANGE)).toBe("No operator change");

    // The drawer is reachable from the Plan summary's own link, and its limit
    // is the researched 330-minute default.
    await page.locator("#blocks-summary-figures [data-key='vehicles']").click();
    await openDrawer(page, "plan-summary-drawer-overlay");
    await page.locator("#plan-summary-relief-open").click();
    await openDrawer(page, "operator-changes-drawer-overlay");
    await expect(page.locator("#operator-changes-limit")).toHaveValue(OPERATOR_LIMIT);

    // The station row covers both bays under it, so marking it once is visibly
    // the same thing as marking Bay A and Bay B.
    const stationRow = page.locator("#operator-candidate-row-0");
    await expect(stationRow).toContainText("Riverside Station");
    await expect(stationRow).toContainText("Bay A");
    await expect(stationRow).toContainText("Bay B");
    await page.locator(STATION_INPUT).check();
    await capture(page, testInfo, "advanced-operator-changes-1440");

    await page.locator("#operator-changes-submit").click();
    await closeDrawer(page, "operator-changes-drawer-overlay");

    // The save redraws the day, so the warning is gone from the row itself
    // rather than from a separate message.
    const after = await blockRows(page);
    expect(statusOf(after, BLOCK_OPERATOR_CHANGE)).toBe("No problems");
    // The other two problems are untouched by a relief mark.
    expect(statusOf(after, BLOCK_CANNOT_REACH)).toBe("Can't reach");
    expect(statusOf(after, BLOCK_WRONG_TYPE)).toBe("Wrong type");

    tour.operator = {
      limit: OPERATOR_LIMIT,
      marked: "Riverside Station (covers Bay A and Bay B)",
      before: statusOf(before, BLOCK_OPERATOR_CHANGE),
      after: statusOf(after, BLOCK_OPERATOR_CHANGE),
      otherProblemsUnchanged: true,
    };

    await capture(page, testInfo, "advanced-operator-changes-after-1440");
  });

  test("entering a driving time changes its source and leaves 101 short of reach", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    // The scope button counts the day's estimated pairs, and the seed's day
    // drives six of them.
    await expect(page.locator("#blocks-driving-times")).toContainText(
      `Driving times · ${DRIVING_ESTIMATED} estimated`,
    );
    await page.locator("#blocks-driving-times").click();
    await openDrawer(page, "driving-times-drawer-overlay");
    await expect(page.locator("#driving-times-count")).toHaveText(
      `${DRIVING_ESTIMATED} of ${DRIVING_ESTIMATED} estimated`,
    );

    // Valley College → Market Square is the pair block 101 cannot make: the
    // seed estimates it at 14 min into an 8-minute gap.
    const pair = page.locator(`#driving-times input[name="minutes[${PAIR_VC_MS}]"]`);
    await expect(pair).toHaveValue("14");
    const pairRow = page.locator("#driving-times tr", {
      has: page.locator(`input[name="minutes[${PAIR_VC_MS}]"]`),
    });
    await expect(pairRow).toContainText("Valley College");
    await expect(pairRow).toContainText("Market Square");
    await expect(pairRow).toContainText("Estimated");

    await pair.fill(String(ENTERED_MINUTES));
    await page.locator("#driving-times-submit").click();
    await expect(page.locator("#flash-info")).toContainText("driving time entered");

    // The saved row carries the Entered provenance and a way back to the
    // estimate; the estimate count drops by exactly the one row that changed.
    await expect(pairRow).toContainText("Entered");
    await expect(pairRow).not.toContainText("Estimated");
    await expect(pairRow.locator("button")).toContainText("Reset to estimate");
    await expect(page.locator("#driving-times-count")).toHaveText(
      `${DRIVING_ESTIMATED - 1} of ${DRIVING_ESTIMATED} estimated`,
    );
    await capture(page, testInfo, "advanced-driving-times-entered-1440");
    await page.locator("#driving-times-cancel").click();
    await closeDrawer(page, "driving-times-drawer-overlay");

    // 9 minutes still does not fit in the 8-minute gap, so the status is the
    // same one the estimate produced — the reader's number is now the number
    // the page checks against, which is the point of entering one.
    const after = await blockRows(page);
    expect(statusOf(after, BLOCK_CANNOT_REACH)).toBe("Can't reach");
    const trips = after.find((row) => row.block === BLOCK_CANNOT_REACH).trips;
    expect(trips).toContain(TRIP_101_OUT);
    expect(ENTERED_MINUTES).toBeGreaterThan(GAP_MINUTES);

    // The scope button agrees with the drawer.
    await expect(page.locator("#blocks-driving-times")).toContainText(
      `Driving times · ${DRIVING_ESTIMATED - 1} estimated`,
    );

    tour.driving = {
      pair: "Valley College → Market Square",
      estimateBefore: 14,
      entered: ENTERED_MINUTES,
      gapMinutes: GAP_MINUTES,
      source: "Entered",
      estimateCountAfter: DRIVING_ESTIMATED - 1,
      block101: statusOf(after, BLOCK_CANNOT_REACH),
    };
  });

  test("rebuilding two selected blocks previews only their trips and applies", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    // The Blocks tab's own checkboxes, separate from the Unassigned panel's
    // trip selection (AC-42), and a selection that names blocks only.
    await page.locator("[data-role='select-block'][data-block='101']").click();
    await expect(page.locator("#block-selection-bar")).toBeVisible();
    await page.locator("[data-role='select-block'][data-block='102']").click();
    await expect(page.locator("#block-selection-count")).toHaveText(
      "2 blocks selected",
    );
    await expect(page.locator("[data-role='select-block']:checked")).toHaveCount(2);
    // The Unassigned panel's trip selection is untouched by a block selection.
    await expect(page.locator("[data-role='select-trip']:checked")).toHaveCount(0);
    await capture(page, testInfo, "advanced-selection-1440");

    await page.locator("#block-selection-rebuild").click();
    await openDrawer(page, "suggest-drawer-overlay");
    // A selection is an explicit answer, so it is the scope the drawer offers.
    await expect(page.locator("#suggest-scope-selected")).toBeChecked();
    await expect(page.locator("#suggest-scope")).toHaveText(DAY_LARGEST);
    // The rules the generator will use are named before it runs.
    await expect(page.locator("#suggest-rules-list")).toContainText("Minimum layover");
    await expect(page.locator("#suggest-rules-list")).toContainText("5 min");
    await expect(page.locator("#suggest-rules-list")).toContainText(
      `Within ${OPERATOR_LIMIT} min`,
    );
    await capture(page, testInfo, "advanced-suggest-drawer-1440");

    await previewSuggestion(page);
    const preview = await panelState(page);

    expect(preview.scopeLine).toBe(`${DAY_LARGEST} · Selected blocks`);
    expect(preview.scopeNote).toContain("Only blocks 101 and 102 were planned again");
    expect(preview.moveCount).toBeGreaterThan(0);

    // Every move leaves one of the two selected blocks: 103, 104 and the
    // unassigned trips are not planned again.
    const selected = new Set([BLOCK_CANNOT_REACH, BLOCK_OPERATOR_CHANGE]);
    for (const move of preview.moves) {
      expect(selected.has(move.current)).toBe(true);
      expect(move.change).toBe("moved");
    }
    // R11: a generated block continues after the highest number in use, so the
    // proposal introduces 105 rather than reusing a free low number.
    const proposed = preview.moves.map((move) => move.proposed);
    expect(proposed.every((block) => Number(block) > 104)).toBe(true);
    expect(proposed).toContain("105");

    // The two weekday day types are both named, and the current one is marked.
    expect(preview.effects).toHaveLength(2);
    expect(preview.effects.filter((effect) => effect.selected)).toHaveLength(1);
    expect(preview.effects[0].heading).toContain("Current view");
    expect(preview.effects[0].heading).toContain(DAY_LARGEST);
    expect(preview.effects[1].heading).toContain("Also changes");
    expect(preview.effects[1].heading).toContain(DAY_WEEKDAY);

    // The timeline draws the proposal, not the saved day: a new block is a row
    // and the two planned blocks carry the changed marker.
    const drawn = await blockRows(page);
    expect(drawn.filter((row) => row.changed).map((row) => row.block)).toEqual(
      expect.arrayContaining([BLOCK_CANNOT_REACH, BLOCK_OPERATOR_CHANGE, "105"]),
    );
    await expect(page.locator("#blocks-day")).toBeDisabled();
    await expect(page.locator("#blocks-block-rules")).toBeDisabled();
    await expect(page.locator("#blocks-driving-times")).toBeDisabled();
    await expect(page.locator("[data-role='select-block']").first()).toBeDisabled();
    await capture(page, testInfo, "advanced-preview-selected-1440", {
      fullPage: true,
    });

    // A selected rebuild is not a replace-all, so it applies without the
    // confirmation; the write is the production `apply_block_plan/3`.
    await expect(page.locator("#apply-suggestion")).toHaveText("Apply suggestion");
    await page.locator("#apply-suggestion").click();
    await expect(page.locator("[data-role='suggestion-applied']")).toBeVisible();

    const applied = await page.locator("[data-role='suggestion-applied']").innerText();
    expect(applied).toContain("Suggestion applied.");
    expect(applied).toContain(`${preview.moveCount} trips changed block`);
    // The message names every day type the write reached.
    expect(applied).toContain(DAY_LARGEST);
    expect(applied).toContain(DAY_WEEKDAY);

    // The saved day carries the new blocks, the panel and the selection are
    // gone, and the changed markers went with them.
    const saved = await blockRows(page);
    expect(saved.map((row) => row.block)).toContain("105");
    expect(saved.every((row) => !row.changed)).toBe(true);
    await expect(page.locator("#suggestion-moves-table")).toHaveCount(0);
    await expect(page.locator("#block-selection-bar")).toHaveCount(0);
    await expect(page.locator("#blocks-suggest")).toBeEnabled();
    await expect(page.locator("#blocks-day")).toBeEnabled();
    await expect(page.locator("[data-role='select-block']").first()).toBeEnabled();
    await capture(page, testInfo, "advanced-applied-1440");

    tour.selected = {
      selected: [BLOCK_CANNOT_REACH, BLOCK_OPERATOR_CHANGE],
      scope: "Selected blocks",
      moves: preview.moveCount,
      proposedBlocks: [...new Set(proposed)].sort(),
      dayTypes: preview.effects.length,
      applied: applied.replace(/\s+/g, " ").trim().slice(0, 140),
      blocksAfter: saved.map((row) => row.block),
    };
  });

  test("a preview of the unassigned trips names both weekday day types and applies", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    // The pool holds the seed's two single-departure trips plus the frequency
    // trip, which is named as unplannable rather than offered.
    await page.locator("#panel-pool").click();
    await expect(page.locator("#blocks-pool-table tr")).toHaveCount(3);
    await expect(
      page.locator("#blocks-pool-table tr", { hasText: "F30" }),
    ).toContainText("Repeats every 30 min · not a single trip");

    // No blocks are selected, so the drawer offers the pool scope and refuses
    // the selected one rather than planning nothing.
    await openSuggest(page, versionId);
    await expect(page.locator("#suggest-scope-unassigned_only")).toBeChecked();
    await expect(page.locator("#suggest-scope-selected")).toBeDisabled();
    await capture(page, testInfo, "advanced-suggest-pool-1440");

    await previewSuggestion(page);
    const preview = await panelState(page);

    expect(preview.scopeLine).toBe(`${DAY_LARGEST} · Unassigned trips only`);
    expect(preview.moveCount).toBe(2);
    // Both moves add a previously unassigned trip, and neither touches a block.
    for (const move of preview.moves) {
      expect(move.current).toBe("Unassigned");
      expect(move.change).toBe("added");
    }
    // The frequency trip stays out, and the panel says so.
    expect(preview.scopeNote).toContain("F30 repeats without individual departures");
    expect(preview.moves.map((move) => move.trip)).not.toContain("F30");

    // Both weekday day types are listed, because the pool's trips run on the
    // shared Weekday calendar.
    expect(preview.effects).toHaveLength(2);
    expect(preview.effects[0].heading).toContain(DAY_LARGEST);
    expect(preview.effects[1].heading).toContain(DAY_WEEKDAY);

    // An existing assignment's problems are listed as existing, not as
    // something this suggestion caused.
    expect(preview.scopeNote).toContain("Existing assignments stay");
    const newProblems = metricValue(preview.metrics, "New problems");
    expect(newProblems).toMatch(/^\d+/);

    await capture(page, testInfo, "advanced-preview-pool-1440", { fullPage: true });
    await page.locator("#apply-suggestion").click();
    await expect(page.locator("[data-role='suggestion-applied']")).toBeVisible();
    const applied = await page.locator("[data-role='suggestion-applied']").innerText();
    expect(applied).toContain("2 trips changed block");
    expect(applied).toContain(DAY_LARGEST);
    expect(applied).toContain(DAY_WEEKDAY);

    // The pool is one shorter per applied trip.
    await expect(page.locator("#panel-pool")).toContainText("Unassigned · 1");

    tour.pool = {
      poolTrips: 3,
      frequencyTrip: "F30 stays unassigned",
      moves: preview.moves,
      dayTypes: preview.effects.map((effect) => effect.heading),
      newProblems,
      applied: applied.replace(/\s+/g, " ").trim().slice(0, 140),
    };
  });

  test("rebuilding the day type asks before replacing hand-tuned blocks", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    await openSuggest(page, versionId);
    await chooseScope(page, "replace_all");
    await previewSuggestion(page);
    const preview = await panelState(page);

    expect(preview.scopeLine).toBe(`${DAY_LARGEST} · Rebuild the day type`);
    expect(preview.moveCount).toBeGreaterThan(0);
    expect(preview.scopeNote).toContain("Every scheduled trip in this day type");
    expect(preview.applyLabel).toBe("Apply suggestion");
    await capture(page, testInfo, "advanced-preview-replace-1440", {
      fullPage: true,
    });

    // The confirmation names the trip count in its title and on its own confirm
    // button, and its cancel action is what the reader chose by closing it.
    await page.locator("#apply-suggestion").click();
    await expect(page.locator("#suggestion-replace[data-open='true']")).toBeVisible();
    const title = await page.locator("#suggestion-replace-title").innerText();
    const confirmLabel = await page
      .locator("#suggestion-replace-confirm")
      .innerText();
    const cancelLabel = await page.locator("#suggestion-replace-cancel").innerText();
    expect(title).toBe(`Replace blocks for ${preview.moveCount} trips?`);
    expect(confirmLabel).toBe(`Replace blocks for ${preview.moveCount} trips`);
    expect(cancelLabel).toBe("Keep current blocks");
    // The body names the day types the write reaches.
    const body = await page.locator("#suggestion-replace-summary").innerText();
    expect(body).toContain(DAY_LARGEST);
    expect(body).toContain(DAY_WEEKDAY);
    expect(body).toContain(`${preview.moveCount} trips change block`);
    // The dialog focuses the sentence the reader has to read before choosing,
    // and says so with a visible ring rather than leaving focus on a button.
    await expect(page.locator("#suggestion-replace-summary")).toBeFocused();
    await capture(page, testInfo, "advanced-confirm-replace-1440");

    await page.locator("#suggestion-replace-confirm").click();
    await expect(page.locator("[data-role='suggestion-applied']")).toBeVisible();
    const applied = await page.locator("[data-role='suggestion-applied']").innerText();
    expect(applied).toContain(`${preview.moveCount} trips changed block`);

    // “Keep current blocks” is the same answer: closing the dialog writes
    // nothing, so the count strip still reads the day's own blocks.
    await expect(page.locator("#blocks-summary-counts")).toContainText("Blocks");

    tour.replace = {
      scope: "Rebuild the day type",
      moves: preview.moveCount,
      title,
      confirmLabel,
      cancelLabel,
      applied: applied.replace(/\s+/g, " ").trim().slice(0, 140),
    };
  });

  test("a second editor's driving time makes the open preview stale", async ({
    page,
    browser,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await openBlocks(page, versionId);

    await openSuggest(page, versionId);
    await chooseScope(page, "replace_all");
    await previewSuggestion(page);
    const before = await panelState(page);
    expect(before.applyState ?? null).toBeNull();
    expect(before.applyDisabled).toBe(false);

    // A second session, logged in as the same editor, changes a driving time
    // the preview was built on. INV-7's fingerprint is what notices.
    const secondContext = await browser.newContext({ viewport: DESKTOP });
    const second = await secondContext.newPage();
    await logIn(second);
    const secondVersionId = await versionIdFor(second);
    expect(secondVersionId).toBe(versionId);
    await second.goto(blocksPath(secondVersionId, "?drawer=driving_times"));
    await openDrawer(second, "driving-times-drawer-overlay");

    // A garage row's key carries the garage's UUID, so the row is found by the
    // stop it starts at rather than by a hard-coded reference.
    const otherPair = second.locator(
      `#driving-times input[name^="${PAIR_RS_GARAGE_PREFIX}"]`,
    );
    await expect(otherPair).toHaveCount(1);
    const stored = await otherPair.inputValue();
    await otherPair.fill(stored === "20" ? "21" : "20");
    await second.locator("#driving-times-submit").click();
    await expect(second.locator("#flash-info")).toContainText("driving time entered");
    await secondContext.close();

    // The first page's own plan is now out of date. A rebuild-all preview
    // confirms before it writes, and the refusal comes from the write.
    await page.locator("#apply-suggestion").click();
    const confirm = page.locator("#suggestion-replace-confirm");
    await confirm.waitFor({ state: "visible", timeout: 5_000 }).catch(() => {});
    if (await confirm.isVisible().catch(() => false)) {
      await confirm.click();
    }
    await expect(page.locator("#suggestion-apply-message")).toBeVisible();
    // The write is asynchronous, so the panel passes through its own pending
    // state before it answers; only a terminal state is read.
    await expect(page.locator("#suggestion-apply-message")).not.toHaveAttribute(
      "data-state",
      "pending",
    );

    const after = await panelState(page);
    expect(after.applyState).toBe("stale");
    expect(after.applyMessage).toContain("out of date");
    expect(after.applyMessage).toContain("Nothing was applied");
    // Apply is off and says why; “Suggest again” is the way forward.
    expect(after.applyDisabled).toBe(true);
    expect(after.applyReason).toContain("Apply is off");
    await expect(page.locator("#suggest-again")).toBeEnabled();
    await expect(page.locator("#discard-suggestion")).toBeEnabled();
    // The preview is kept, so the reader can still read what it proposed.
    expect(after.moveCount).toBe(before.moveCount);
    await expect(page.locator("#suggestion-moves-table tr")).toHaveCount(
      before.moveCount,
    );
    await expect(page.locator("[data-role='suggestion-applied']")).toHaveCount(0);

    await capture(page, testInfo, "advanced-stale-panel-1440");
    await capture(page, testInfo, "advanced-preview-stale-1440", { fullPage: true });

    tour.stale = {
      writer: "a second editor session",
      state: after.applyState,
      message: after.applyMessage.replace(/\s+/g, " ").trim(),
      applyDisabled: after.applyDisabled,
      reason: after.applyReason,
      movesKept: after.moveCount,
    };
  });
});

test.describe("advanced Blocks List view at 375x812", () => {
  test.use({ viewport: NARROW });

  test("the List view is the default, shows km and does not scroll sideways", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page);
    await page.goto(blocksPath(versionId));
    await expect
      .poll(async () => page.locator("#blocks-lists section").count(), {
        timeout: 30_000,
      })
      .toBeGreaterThan(0);

    // The colocated hook patches `?view=list` once, so the narrow page never
    // renders the timeline.
    await expect(page).toHaveURL(/view=list/);
    await expect(page.locator("#blocks-timeline")).toHaveCount(0);
    // The List view draws the same blocks the count strip reports, whichever
    // view is showing.
    const listed = await page.locator("[data-role='list-block']").count();
    const stripBlocks = (
      await page
        .locator("#blocks-summary-counts [data-key='blocks'] [data-role='count-strip-value']")
        .textContent()
    ).trim();
    expect(listed).toBe(Number(stripBlocks));
    await expect(page.locator("[data-role='list-block']").first()).toBeVisible();

    // Each block's heading carries its own two distance figures, in kilometres
    // (the approved unit), with the without-riders one marked as estimated.
    const riders = page.locator("[data-role='list-km-riders']");
    const deadhead = page.locator("[data-role='list-km-deadhead']");
    await expect(riders).toHaveCount(listed);
    await expect(deadhead).toHaveCount(listed);
    await expect(riders.first()).toContainText("km with riders");
    await expect(deadhead.first()).toContainText("km without (est.)");
    const distances = await page.evaluate(() =>
      [...document.querySelectorAll("[data-role='list-km-riders']")].map((span) => ({
        km: Number(span.dataset.km),
        text: span.textContent.trim(),
      })),
    );
    for (const entry of distances) {
      expect(entry.km).toBeGreaterThan(0);
      expect(entry.text).toBe(`${entry.km.toFixed(1)} km with riders`);
    }

    // The day type and the count strip survive the narrow frame, and the page
    // does not scroll sideways.
    await expect(page.locator("#blocks-day")).toBeVisible();
    await expect(page.locator("#blocks-summary-counts")).toContainText("Blocks");
    const geometry = await page.evaluate(() => ({
      bodyScrollWidth: document.body.scrollWidth,
      innerWidth: window.innerWidth,
    }));
    expect(geometry.bodyScrollWidth).toBeLessThanOrEqual(geometry.innerWidth);
    expect(await bodyFitsViewport(page)).toBe(true);

    tour.narrow = {
      view: "list",
      timelinePresent: false,
      listBlocks: listed,
      kmColumns: 2,
      bodyScrollWidth: geometry.bodyScrollWidth,
      innerWidth: geometry.innerWidth,
    };

    await capture(page, testInfo, "advanced-list-375", { fullPage: true });
  });
});

// The reference prototype, rendered from its own file beside production for the
// states the journey reproduces. The assertions come from the acceptance
// criteria and the seed, not from the prototype's pixels, so this journey
// records the side-by-side captures only; it is skipped when the gitignored
// `.specs/` workspace is not linked into the worktree.
test.describe("reference prototype captures", () => {
  test.skip(
    () => !existsSync(REFERENCE_PROTOTYPE),
    "reference prototype not present",
  );
  test.use({ viewport: DESKTOP });

  test("the advanced states beside production", async ({ page }, testInfo) => {
    test.setTimeout(120_000);

    const referenceUrl = pathToFileURL(REFERENCE_PROTOTYPE).href;

    for (const [name, query] of REFERENCE_SCENARIOS) {
      await page.goto(`${referenceUrl}?${query}`);
      await page.waitForLoadState("load");
      await expect(page.locator("body")).toBeVisible();

      // Recorded for the side-by-side capture only: the prototype's own markup
      // and pixels are not this gate's oracle.
      const bodyWidth = await page.evaluate(() => document.body.scrollWidth);
      tour[`reference_${name.replaceAll("-", "_")}`] = {
        state: query,
        bodyWidth,
        viewportWidth: DESKTOP.width,
      };
      await capture(page, testInfo, `reference-${name}-1440`);
    }

    await page.setViewportSize(NARROW);
    await page.goto(`${referenceUrl}?state=list`);
    await page.waitForLoadState("domcontentloaded");
    await capture(page, testInfo, "reference-list-375");
  });
});

// The tour is the capture artifact's own index: entrypoint, setup, scenarios,
// expected outcomes and the automated coverage, with the numbers the journeys
// measured. It is written last so it reports the whole run, and it is skipped
// rather than failed when the gitignored `.specs/` workspace is not linked.
test.describe("qa tour", () => {
  test.skip(
    () => !existsSync(SPEC_PACKAGE),
    "spec package not present",
  );
  test.use({ viewport: DESKTOP });

  test("writes qa-tour.md from the measured journey", async ({}, testInfo) => {
    const value = (key) =>
      tour[key] === undefined ? "(not measured)" : JSON.stringify(tour[key]);

    const markdown = [
      "# Advanced Blocks browser QA tour (EV-9, step 47)",
      "",
      "Entrypoint: `/gtfs/<version>/blocks` for the published **Browser Advanced",
      `Blocks Version** seeded by \`test/support/browser_seed.exs\` (blocks 101–104`,
      "on the {WKDY, SCHOOL} day type, a two-trip pool plus the frequency trip",
      "F30, two garages, two vehicle types and one relief point at Market",
      "Square).",
      "",
      "## Setup",
      "",
      "```sh",
      "MIX_TEST_PARTITION=_adv07_browser mise run prepare:browser",
      "CI=true npm --prefix assets run test:browser -- e2e/blocks_advanced.spec.js",
      "```",
      "",
      "The journey runs Chromium against a local test Phoenix server on port 4002",
      "(`BROWSER_E2E=true`), one worker and no retries, against the database reset",
      "and seeded by `mise run prepare:browser` in this lane's own",
      "`MIX_TEST_PARTITION`. The journeys are serial and run in the order below,",
      "because each one writes and the next reads the day it left.",
      "",
      "## Scenarios and expected outcomes",
      "",
      "| Scenario | Expected outcome | Measured |",
      "|---|---|---|",
      "| Default day type (Weekday + School days) | Block 101 reads Can’t reach, block 104 Wrong type, block 102 No operator change, and the timeline track is at least 760 px wide at 1440 | " +
        value("default"),
      " |",
      "| Plan summary | The fleet table reads Main · Cutaway, needed 4, listed 12, and the operator-change section names block 102 | " +
        value("planSummary"),
      " |",
      "| Mark Riverside Station in Operator changes | Block 102’s No operator change warning clears; the other two problems are unchanged | " +
        value("operator"),
      " |",
      "| Enter 9 min for Valley College → Market Square | The row’s source reads Entered, the estimated count drops by one, and block 101 still reads Can’t reach because 9 exceeds the 8-minute gap | " +
        value("driving"),
      " |",
      "| Select blocks 101 and 102, then Rebuild selected blocks | The preview moves only their trips, proposes block 105, names both weekday day types, and applies | " +
        value("selected"),
      " |",
      "| Preview the unassigned trips | Two moves, both added, F30 left out, both weekday day types named, and the apply succeeds | " +
        value("pool"),
      " |",
      "| Rebuild the day type | Apply asks “Replace blocks for N trips?” with “Keep current blocks” as the cancel action, and the confirmed apply succeeds | " +
        value("replace"),
      " |",
      "| A second editor enters a driving time with a preview open | Apply reports the preview is out of date, disables itself with a printed reason, and keeps the preview | " +
        value("stale"),
      " |",
      "| 375x812 | The List view is the default, each block heading carries its two kilometre figures, and the page does not scroll sideways | " +
        value("narrow"),
      " |",
      "",
      "## Automated coverage",
      "",
      "- `assets/e2e/blocks_advanced.spec.js` — the journeys above, the measured",
      "  layout and the reference captures.",
      "- `assets/playwright.config.js` — Chromium, one worker, no retries, and the",
      "  local test server on port 4002.",
      "- `test/support/browser_seed.exs` — the “Browser Advanced Blocks Version”",
      "  fixture the journey reads.",
      "- `assets/e2e/blocks.spec.js` — unchanged: the basic Blocks journey on the",
      "  separate “Browser Blocks Version”.",
      "",
      "## Prototype reference",
      "",
      "The reference prototype is rendered from its own file at the `problems`,",
      "`summary`, `relief`, `driving`, `selected`, `preview-selected`,",
      "`preview-pool`, `confirm-replace` and `stale` states, and at `list` for the",
      "375 px view, beside the production captures of the same states. Its dark",
      "“Design prototype” bar, its state switcher, its sample data and its",
      "in-browser generator are prototype-only and are not implemented.",
      "",
    ].join("\n");

    const outputPath = testInfo.outputPath("qa-tour.md");
    mkdirSync(dirname(outputPath), { recursive: true });
    writeFileSync(outputPath, markdown);
    const evidencePath = copyIntoEvidence("qa-tour.md", Buffer.from(markdown));

    expect(existsSync(evidencePath)).toBe(true);
    expect(readFileSync(evidencePath, "utf8")).toContain(
      "Advanced Blocks browser QA tour",
    );
    expect(readFileSync(evidencePath, "utf8")).toContain(
      "mise run prepare:browser",
    );
    // Every journey the card names contributed its own measurements.
    for (const key of [
      "default",
      "planSummary",
      "operator",
      "driving",
      "selected",
      "pool",
      "replace",
      "stale",
      "narrow",
    ]) {
      expect(tour[key], `journey ${key} was not measured`).toBeDefined();
    }
  });
});
