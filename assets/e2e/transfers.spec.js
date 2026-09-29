// Transfers page journeys (EV-29).
//
// Runs against the reset-and-seeded browser database the repository's Playwright
// configuration already uses (`mise run prepare:browser`, workers: 1, retries: 0)
// with `BROWSER_E2E=true`, and drives the real page: router → `TransfersLive` →
// `Gtfs` facades → PostgreSQL. Only the Esri tile hosts are faked, at the network
// boundary, so no journey reaches the internet.
//
// The fixtures come from `test/support/browser_seed.exs`. The "Browser Transfers
// Version" carries the transfer network — a station with two platform children
// and an entrance, three routes, five trips and eight general rules plus two
// in-seat records — and the "Browser E2E Version" carries no transfers at all.
// Rule ids are random per seed, so every journey finds a rule by the copy it
// renders rather than by an id; only the seeded stop ids are literal.
//
// The journeys share one version and mutate it in order (create, edit, delete),
// so they run serially and a re-run needs `mise run prepare:browser` first. Test
// titles keep the prefixes branch review greps: first use, list, inspector,
// in-seat, create, duplicate, edit, guard, pick, map, related, delete, layout.
//
// The Esri tile responses are 1x1 PNGs and the failure journey aborts them; the
// captured frames land in the run's `--output` directory for inspection next to
// the reference prototype.
import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

const EDITOR_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const TRANSFERS_VERSION = "Browser Transfers Version";
const FIRST_USE_VERSION = "Browser E2E Version";
const ROUTE = "BXF_24";

// The whole-station default is the one station rule with no route on either side.
const WHOLE_STATION_BOTH_SIDES =
  /Any route · whole station[\s\S]*Any route · whole station/;

const DESKTOP = { width: 1440, height: 1000 };
const PHONE = { width: 375, height: 812 };
const NARROW = { width: 320, height: 800 };

// A 1x1 opaque PNG, so the tile layers succeed without a network request.
const ONE_PX_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC";

// The map draws streets through this app's own Geoapify proxy, so the tile
// requests are same-origin and no journey reaches an external tile host.
const TILE_ROUTE = "**/map/tiles/**";

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

test.describe("Transfers", () => {
  test.use({ viewport: DESKTOP });

  test("first use: a version without rules asks for its first one", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page, FIRST_USE_VERSION);

    await page.goto(`/gtfs/${versionId}/transfers`);

    const firstUse = page.locator("#transfers-first-use");
    await expect(firstUse).toBeVisible();
    await expect(firstUse).toContainText("Most connections need no rule");
    await expect(page.locator("#transfers-first-use-create")).toHaveText(
      "Create transfer rule",
    );
    await expect(firstUse.getByRole("button")).toHaveCount(1);
    // The panel carries the one create action, so the header has none.
    await expect(page.locator("#transfers-create")).toHaveCount(0);
    await expect(page.locator("#transfers-no-results")).toHaveCount(0);
    await expect(page.locator("#transfers-view-in-seat")).toContainText(
      /Stay on board\s*0/,
    );

    await capture(page, testInfo, "first-use-1440x1000");
  });

  test("list: the stop filter narrows to the station's own rules and clears", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    await expect(page.locator("#transfers-count")).toHaveText("8 transfer rules");

    await openFilters(page);
    await page.locator("#transfer-filter-stop").selectOption("BXF_CEN");

    await expect(page).toHaveURL(/[?&]stop=BXF_CEN(&|$)/);
    await expect(page.locator("#transfers-count")).toHaveText(
      "5 of 8 transfer rules",
    );
    await expect(page.locator("#transfers-chip-stop")).toContainText(
      "Transfer Central Station",
    );
    await expect(page.locator("#transfers > tr")).toHaveCount(5);

    // The station filter matches the station itself and its two platform
    // children — not the entrance, which no rule may name.
    const listed = page.locator("#transfers");
    await expect(listed).toContainText("Transfer Central Station");
    await expect(listed).toContainText("Transfer Central · Bay A");
    await expect(listed).toContainText("Transfer Central · Bay C");
    await expect(listed).not.toContainText("Transfer Museum");
    await expect(listed).not.toContainText("Transfer Harbor");

    const phone = page.locator("#transfers");
    await page.setViewportSize(PHONE);
    await expect(phone).toBeVisible();
    await capture(page, testInfo, "list-375x812", phone);

    await page.setViewportSize(DESKTOP);
    await capture(page, testInfo, "list-1440x1000");

    await page.locator("#transfers-clear-filters").click();

    await expect(page.locator("#transfers-count")).toHaveText("8 transfer rules");
    await expect(page).not.toHaveURL(/[?&]stop=/);
  });

  test("inspector: the overlap callout compares the competing rules and inspects the reverse", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    const rule = ruleRow(
      page,
      "Transfer Central Station",
      "Transfer Central Station",
      "Route 12",
    );
    await expect(rule).toHaveCount(1);
    await selectRow(page, rule);

    await expect(page.locator("#transfer-inspector")).toBeVisible();
    await expect(page.locator("#transfer-inspector-overlap")).toContainText(
      "1 other rule of equal priority can apply to some of the same trips",
    );

    const compare = page.locator("#transfer-compare-dialog");

    await press(
      page,
      page.locator("#transfer-inspector-compare"),
      visible(compare),
    );
    await expect(compare).toBeVisible();
    await expect(compare).toContainText("Minimum time · 2 min");
    await expect(compare).toContainText("Not possible");
    await expect(compare.getByRole("button", { name: "Edit rule" })).toHaveCount(
      2,
    );

    // The compare view is a single-action dialog: "Close" is its only control.
    await press(
      page,
      page.locator("#transfer-compare-dialog-cancel"),
      hidden(compare),
    );
    await expect(compare).not.toBeVisible();

    const phone = page.locator("#transfer-inspector");
    await page.setViewportSize(PHONE);
    await expect(phone).toBeVisible();
    await capture(page, testInfo, "inspector-375x812", phone);

    await page.setViewportSize(DESKTOP);

    // The rule that names the station's two platforms in the other direction is
    // its exact mirror, so "View the reverse rule" selects it.
    const stationRule = ruleRow(
      page,
      "Transfer Central · Bay A",
      "Transfer Central · Bay C",
    );
    await expect(stationRule).toHaveCount(1);
    await selectRow(page, stationRule);

    const inspector = page.locator("#transfer-inspector");
    // The arrival cell has its own id, so the wait does not ride on the cell's
    // position among the panel's `strong` elements.
    const arrival = page.locator("#transfer-inspector-arrive");

    await press(
      page,
      page.locator("#transfer-inspector-reverse-inspect"),
      async () => (await arrival.innerText()) === "Transfer Central · Bay C",
    );

    await expect(inspector).toContainText("Transfer Central · Bay C");
    await expect(inspector).toContainText("Transfer Central · Bay A");
    await expect(inspector).toContainText("Route 24");
    await expect(inspector).toContainText("Route 12");

    await capture(page, testInfo, "inspector-1440x1000");
  });

  test("in-seat: the managed-on-Blocks view is read-only", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    const chip = page.locator("#transfers-view-in-seat");

    await activate(
      page,
      () => chip.click(),
      async () => (await chip.getAttribute("aria-pressed")) === "true",
    );

    await expect(page).toHaveURL(/[?&]view=in_seat(&|$)/);
    await expect(page.locator("#transfers-count")).toHaveText(
      "2 stay-on-board records",
    );
    await expect(page.locator("#transfers-view-in-seat")).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    await expect(
      page.locator('#transfers input[id^="transfer-check-"]'),
    ).toHaveCount(0);
    await expect(page.locator("#transfers-create")).toHaveCount(0);
    await expect(page.locator("#transfers-delete-selected")).toHaveCount(0);
    await expect(page.locator("#transfer-inspector-edit")).toHaveCount(0);

    // The stopless record says so instead of rendering a blank endpoint.
    const stopless = ruleRow(
      page,
      "No stop recorded",
      "No stop recorded",
      "Trip BXF_24_0840",
    );
    await expect(stopless).toHaveCount(1);
    await expect(stopless).toContainText("No stop recorded");

    await selectRow(page, stopless);
    await expect(page.locator("#transfer-inspector-blocks-note")).toContainText(
      "Changes are made there.",
    );

    // Below 1024px the record the operator opened has the screen, not the list.
    const phone = page.locator("#transfer-inspector");
    await page.setViewportSize(PHONE);
    await expect(phone).toBeVisible();
    await expect(page.locator("#transfers")).not.toBeVisible();
    await capture(page, testInfo, "in-seat-375x812", phone);

    await page.setViewportSize(DESKTOP);
    await capture(page, testInfo, "in-seat-1440x1000");
  });

  test("create: the keyboard alone fills and submits a new rule", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);
    await openCreate(page);

    await expect(page.locator("#transfer-editor")).toBeVisible();

    await chooseStopWithKeyboard(page, "from", "Transfer Museum");
    await chooseStopWithKeyboard(page, "to", "Transfer Market Street");

    // The draft starts on "Minimum time", so the operator reaches the kind
    // radios from the last stop field and picks "Preferred transfer point" with
    // the arrow keys, as a native radio group allows: the cards run Timed, Minimum
    // time, Not possible, Preferred, so Up twice wraps round to the last one.
    await tabUntilFocused(page, "transfer-type-2");
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowUp");
    await expect(page.locator("#transfer-type-0")).toBeChecked();
    await expect(page.locator("#transfer-min-time")).toHaveCount(0);
    await expect(page.locator("#transfer-dirty")).toBeVisible();

    await page.setViewportSize(PHONE);
    await capture(page, testInfo, "editor-375x812");
    await page.setViewportSize(DESKTOP);

    await page.locator("#transfer-save").focus();
    await page.keyboard.press("Enter");

    await expect(page.locator("#flash-group")).toContainText(
      `Transfer rule saved in ${TRANSFERS_VERSION}.`,
    );
    await expect(page.locator("#transfer-editor")).toHaveCount(0);
    await expect(page.locator("#transfers-count")).toHaveText("9 transfer rules");

    const created = ruleRow(
      page,
      "Transfer Museum",
      "Transfer Market Street",
    );
    await expect(created).toHaveCount(1);
    await expect(
      created.locator('button[id^="transfer-select-"][aria-current="true"]'),
    ).toHaveCount(1);
    await expect(page.locator("#transfer-inspector")).toContainText(
      "Preferred transfer point",
    );

    await capture(page, testInfo, "create-1440x1000");
  });

  test("duplicate: the same stops and services name the rule that holds them", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);
    await openCreate(page);

    await pickStop(page, "from", "Transfer Museum");
    await pickStop(page, "to", "Transfer Market Street");
    await page.locator("#transfer-type-0").click();

    const error = page.locator("#transfer-form-error");
    await press(page, page.locator("#transfer-save"), visible(error));
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "A rule already covers these stops and services.",
    );
    await expect(page.locator("#transfer-open-existing")).toHaveText(
      "Open existing rule",
    );
    await expect(page.locator("#transfers-count")).toHaveCount(0);

    // The draft is kept, so the operator corrects it instead of retyping it.
    await expect(stopInput(page, "from")).toHaveValue(
      "Transfer Museum",
    );
    await expect(stopInput(page, "to")).toHaveValue(
      "Transfer Market Street",
    );
    await expect(page.locator("#transfer-dirty")).toBeVisible();

    await capture(page, testInfo, "duplicate-1440x1000");

    await discardDraft(page);
  });

  test("edit: the station default's minimum time saves and reads in minutes", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    const rule = ruleRow(
      page,
      "Transfer Central Station",
      "Transfer Central Station",
      WHOLE_STATION_BOTH_SIDES,
    );
    await expect(rule).toHaveCount(1);
    await selectRow(page, rule);

    const editor = page.locator("#transfer-editor");

    await press(
      page,
      page.locator("#transfer-inspector-edit"),
      visible(editor),
    );

    await expect(page.locator("#transfer-min-time")).toHaveValue("300");

    await page.locator("#transfer-min-time").fill("360");
    await expect(page.locator("#transfer-min-time-readout")).toContainText(
      "6 min",
    );

    await press(page, page.locator("#transfer-save"), hidden(editor));

    await expect(page.locator("#flash-group")).toContainText(
      `Transfer rule saved in ${TRANSFERS_VERSION}.`,
    );
    await expect(page.locator("#transfer-editor")).toHaveCount(0);

    const saved = ruleRow(
      page,
      "Transfer Central Station",
      "Transfer Central Station",
      WHOLE_STATION_BOTH_SIDES,
    );
    await expect(saved).toContainText("6 min");

    await capture(page, testInfo, "edit-1440x1000");
  });

  test("guard: a dirty draft asks before a header link takes the operator away", async ({
    page,
  }, testInfo) => {
    const versionId = await openTransfers(page);
    await openCreate(page);

    await page.locator("#transfer-min-time").fill("120");
    await expect(page.locator("#transfer-dirty")).toBeVisible();

    const dialog = page.locator("#transfer-discard-dialog");
    const calendars = page.locator("#main-navigation #nav-calendars");

    await press(page, calendars, visible(dialog));

    await expect(dialog).toBeVisible();
    await expect(page.locator("#transfer-discard-dialog-title")).toHaveText(
      "Discard unsaved changes?",
    );
    await expect(page).toHaveURL(new RegExp(`/gtfs/${versionId}/transfers$`));

    await capture(page, testInfo, "guard-1440x1000");

    await press(
      page,
      page.locator("#transfer-discard-dialog-cancel"),
      hidden(dialog),
    );

    await expect(dialog).not.toBeVisible();
    await expect(page.locator("#transfer-min-time")).toHaveValue("120");

    await press(page, calendars, visible(dialog));
    await expect(dialog).toBeVisible();

    await press(
      page,
      page.locator("#transfer-discard-dialog-confirm"),
      hidden(dialog),
    );

    await page.waitForURL(/\/calendars$/);
    await expect(page.locator("h1")).toHaveText("Calendars");
  });

  test("pick: a focused candidate marker sets the stop for that side", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);
    await openCreate(page);

    const callout = page.locator("#transfer-pick-callout");

    await press(page, page.locator("#transfer-pick-from"), visible(callout));
    await expect(callout).toBeVisible();
    await expect(page.locator("#transfer-map-title")).toHaveText(
      "Choose where riders arrive",
    );

    // The context pane opens at the zoom of the rule the page had selected, so
    // the version's other stops are reached by fitting the map while the pick
    // runs: the hook reports the new bounds for the live session.
    const marker = page.locator(
      '#transfer-map .leaflet-marker-icon[title="Transfer Harbor"]',
    );
    await press(page, page.locator("#transfer-map-fit"), visible(marker));

    await expect(marker).toBeVisible();
    await expect(marker).toHaveAttribute("tabindex", "0");

    await capture(page, testInfo, "pick-1440x1000");

    await marker.focus();
    await page.keyboard.press("Enter");

    await expect(stopInput(page, "from")).toHaveValue(
      "Transfer Harbor",
    );
    await expect(page.locator("#transfer-pick-callout")).toHaveCount(0);
    await expect(page.locator("#transfer-map-title")).toHaveText(
      "Preview of this connection",
    );

    await discardDraft(page);
  });

  test("map: aborted tiles report the failure and a new rule still saves", async ({
    page,
  }, testInfo) => {
    // Aborted tile requests are this journey's whole point, so its route
    // replaces the fulfilling one the other journeys use.
    await page.route(TILE_ROUTE, (route) => route.abort());

    await openTransfers(page);
    await openCreate(page);

    const unavailable = page.locator("#transfer-map-unavailable");
    await expect(unavailable).toBeVisible();
    await expect(unavailable).toContainText("Map unavailable");
    await expect(page.locator("#transfer-map-legend")).toHaveCount(0);

    const phone = page.locator("#transfer-map-region");
    await page.setViewportSize(PHONE);
    await expect(phone).toBeVisible();
    await capture(page, testInfo, "map-375x812", phone);
    await page.setViewportSize(DESKTOP);
    await capture(page, testInfo, "map-1440x1000");

    await pickStop(page, "from", "Transfer Market Street");
    await pickStop(page, "to", "Transfer Harbor");
    await page.locator("#transfer-type-0").click();

    await press(
      page,
      page.locator("#transfer-save"),
      visible(page.locator("#transfers")),
    );

    await expect(page.locator("#flash-group")).toContainText(
      `Transfer rule saved in ${TRANSFERS_VERSION}.`,
    );
    await expect(page.locator("#transfers-count")).toHaveText("10 transfer rules");
    await expect(ruleRow(page, "Transfer Market Street", "Transfer Harbor")).toHaveCount(1);
  });

  test("related: the route's View transfers link lists exactly the rules it counts", async ({
    page,
  }, testInfo) => {
    await logIn(page);
    const versionId = await versionIdFor(page, TRANSFERS_VERSION);

    await page.goto(`/gtfs/${versionId}/routes/${ROUTE}`);

    const link = page.locator("#route-transfers-link");
    await expect(link).toBeVisible();
    await waitForLiveView(page);

    const summary = await page.locator("#route-transfers-summary").innerText();
    const count = Number(summary.match(/^(\d+) transfer rules? mentions?/)[1]);
    expect(count).toBeGreaterThan(0);

    await link.click();
    await page.waitForURL(/\/transfers\?/);

    await expect(page).toHaveURL(new RegExp(`[?&]route=${ROUTE}(&|$)`));
    await expect(page.locator("#transfers-count")).toHaveText(
      new RegExp(`^\\s*${count} of \\d+ transfer rules\\s*$`),
    );
    await expect(page.locator("#transfers > tr")).toHaveCount(count);

    await capture(page, testInfo, "related-1440x1000");
  });

  test("delete: bulk delete removes exactly the checked rules, then one more", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    await expect(page.locator("#transfers-count")).toHaveText("10 transfer rules");

    const marketRule = ruleRow(
      page,
      "Transfer Market Street",
      "Transfer Market Street",
      "Route 12",
    );
    const museumRule = ruleRow(page, "Transfer Museum", "Transfer Harbor");
    await expect(marketRule).toHaveCount(1);
    await expect(museumRule).toHaveCount(1);

    await marketRule.locator('input[id^="transfer-check-"]').click();
    await museumRule.locator('input[id^="transfer-check-"]').click();

    await expect(page.locator("#transfers-count")).toHaveText("2 selected");

    const dialog = page.locator("#transfer-delete-dialog");

    await press(
      page,
      page.locator("#transfers-delete-selected"),
      visible(dialog),
    );
    await expect(dialog).toBeVisible();
    await expect(page.locator("#transfer-delete-dialog-title")).toHaveText(
      "Delete 2 transfer rules?",
    );
    await expect(
      dialog.locator("#transfer-delete-dialog-body"),
    ).toContainText("Transfer Market Street to Transfer Market Street");
    await expect(
      dialog.locator("#transfer-delete-dialog-body"),
    ).toContainText("Transfer Museum to Transfer Harbor");

    await press(
      page,
      page.locator("#transfer-delete-dialog-confirm"),
      hidden(dialog),
    );

    await expect(dialog).not.toBeVisible();
    await expect(page.locator("#transfers-count")).toHaveText("8 transfer rules");
    await expect(
      ruleRow(page, "Transfer Market Street", "Transfer Market Street"),
    ).toHaveCount(0);
    await expect(ruleRow(page, "Transfer Museum", "Transfer Harbor")).toHaveCount(
      0,
    );

    // The rule the create journey made is untouched by the bulk delete, and the
    // inspector's own delete removes only it.
    const created = ruleRow(page, "Transfer Museum", "Transfer Market Street");
    await expect(created).toHaveCount(1);

    await capture(page, testInfo, "delete-1440x1000");

    await selectRow(page, created);

    await press(
      page,
      page.locator("#transfer-inspector-delete"),
      visible(page.locator("#transfer-delete-dialog")),
    );

    await expect(page.locator("#transfer-delete-dialog-title")).toHaveText(
      "Delete 1 transfer rule?",
    );

    await press(
      page,
      page.locator("#transfer-delete-dialog-confirm"),
      hidden(page.locator("#transfer-delete-dialog")),
    );

    await expect(page.locator("#transfer-delete-dialog")).not.toBeVisible();
    await expect(page.locator("#transfers-count")).toHaveText("7 transfer rules");
    await expect(
      ruleRow(page, "Transfer Museum", "Transfer Market Street"),
    ).toHaveCount(0);
  });

  test("layout: the list, inspector and editor fit the phone and 320px widths", async ({
    page,
  }, testInfo) => {
    await openTransfers(page);

    // Below 1024px the list and the rule take the screen in turn, so each surface
    // is reached the way an operator reaches it: the list first, a row to open the
    // rule, the way back, then the editor.
    const list = page.locator("#transfers-view-general");
    const inspector = page.locator("#transfer-inspector");

    await expect(page.locator("#transfers-count")).toBeVisible();
    await expect(inspector).toBeVisible();

    for (const [label, size] of [
      ["phone", PHONE],
      ["narrow", NARROW],
    ]) {
      await page.setViewportSize(size);

      await expect(list).toBeVisible();
      await expect(inspector).not.toBeVisible();
      expect(await fitsViewport(page), `${label} list`).toBe(true);

      const row = page.locator('#transfers button[id^="transfer-select-"]').first();
      await press(page, row, visible(inspector));
      await expect(inspector).toBeVisible();
      await expect(list).not.toBeVisible();
      expect(await fitsViewport(page), `${label} inspector`).toBe(true);

      await press(
        page,
        page.locator("#transfer-inspector-back"),
        visible(list),
      );
      await expect(list).toBeVisible();

      await openCreate(page);
      await expect(page.locator("#transfer-editor")).toBeVisible();
      expect(await fitsViewport(page), `${label} editor`).toBe(true);

      await press(
        page,
        page.locator("#transfer-cancel"),
        hidden(page.locator("#transfer-editor")),
      );
      await expect(page.locator("#transfer-editor")).toHaveCount(0);
    }

    await capture(page, testInfo, "layout-320x800");
  });
});

async function logIn(page) {
  await page.goto("/users/log_in");
  await page.fill('input[name="user[email]"]', EDITOR_USER.email);
  await page.fill('input[name="user[password]"]', EDITOR_USER.password);
  await page.getByRole("button", { name: "Log in" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

// The seeded database names its published versions, so the journeys read the
// version id from the ordinary panel rather than assuming one.
async function versionIdFor(page, versionName) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: versionName });

  await expect(option).toHaveCount(1);

  const versionId = await option.getAttribute("data-version-id");
  if (!versionId) throw new Error(`${versionName} is missing its version ID`);
  return versionId;
}

async function openTransfers(page) {
  await logIn(page);
  const versionId = await versionIdFor(page, TRANSFERS_VERSION);

  await page.goto(`/gtfs/${versionId}/transfers`);
  await expect(page.locator("#transfers-page")).toBeVisible();
  await waitForLiveView(page);

  return versionId;
}

// A click that lands before the LiveView joins is dropped, so every journey
// waits for the mounted view before it presses anything.
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

// One rule's row. The stream body's rows carry no id, so a row is named by the
// endpoints its own controls announce, then narrowed by the copy it renders —
// three station defaults share one endpoint pair, and only their selectors and
// types tell them apart.
function ruleRow(page, from, to, ...texts) {
  const rows = page
    .locator("#transfers > tr")
    .filter({
      has: page.locator(`button[aria-label="Inspect rule ${from} to ${to}"]`),
    });

  return texts.reduce((found, text) => found.filter({ hasText: text }), rows);
}

// The first press on a freshly mounted page can land before the LiveView has
// taken the DOM over, and a dropped press looks exactly like a slow one.
// Re-issuing the press until the page answers is what makes the journeys
// deterministic; the state they assert afterwards is unchanged.
async function activate(page, trigger, settled, timeout = 15_000) {
  await expect
    .poll(
      async () => {
        if (await settled()) return true;
        await trigger();
        return settled();
      },
      { timeout, intervals: [500] },
    )
    .toBe(true);
}

// A press on a control the server re-renders can land between its mousedown and
// mouseup, which drops the click without an error. `press` re-issues it until
// the surface the control opens has answered.
async function press(page, control, settled) {
  await activate(page, () => control.click(), settled);
}

function visible(locator) {
  return () => locator.isVisible();
}

function hidden(locator) {
  return async () => !(await locator.isVisible());
}

// Opens the editor from the header's own button.
async function openCreate(page) {
  const button = page.locator("#transfers-create");
  const editor = page.locator("#transfer-editor");

  await activate(page, () => button.click(), () => editor.isVisible());
}

// Opens the filter disclosure, whose own button says whether it is open.
async function openFilters(page) {
  const toggle = page.locator("#transfers-filters-toggle");

  await activate(
    page,
    () => toggle.click(),
    async () => (await toggle.getAttribute("aria-expanded")) === "true",
  );

  await expect(page.locator("#transfer-filter-fields")).toBeVisible();
}

async function selectRow(page, row) {
  const button = row.locator('button[id^="transfer-select-"]').first();
  const id = (await button.getAttribute("id")).replace("transfer-select-", "");

  // The page selects its first row on load without naming it in the URL, and the
  // rows of equal name sort by id, so the intended rule may already be the current
  // one. Pressing it names the rule in the URL either way, which is what opens it
  // below 1024px, so the press is repeated until both the URL and the row's own
  // current marker say it is the rule the inspector shows.
  await activate(
    page,
    () => button.click(),
    async () =>
      page.url().includes(`rule=${id}`) &&
      (await button.getAttribute("aria-current")) === "true",
  );
}

async function capture(page, testInfo, name, subject) {
  // A phone-width frame scrolls its subject into view: the panes stack there,
  // and a frame taken at the top of the page would show the list instead of
  // the pane the journey is about. A subject already on screen is left alone.
  if (subject) await subject.scrollIntoViewIfNeeded();

  await page.screenshot({ path: testInfo.outputPath(`${name}.png`) });
}

// The keyboard path through the stop autocomplete: the LiveSelect owns the text
// input and answers ArrowDown and Enter, which is how a keyboard operator picks
// an option.
async function chooseStopWithKeyboard(page, side, label) {
  const input = stopInput(page, side);

  await input.focus();
  await page.keyboard.type(label);

  const option = page
    .locator(`#transfer-${side}-stop ul div[data-idx]`)
    .filter({ hasText: label })
    .first();
  await expect(option).toBeVisible();

  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");

  await expect(input).toHaveValue(label);
}

// The same choice with a pointer, for the journeys whose subject is not the
// keyboard itself.
async function pickStop(page, side, label) {
  const input = stopInput(page, side);

  await input.click();
  await input.fill(label);

  const option = page
    .locator(`#transfer-${side}-stop ul div[data-idx]`)
    .filter({ hasText: label })
    .first();
  await expect(option).toBeVisible();

  await option.click();
  await expect(input).toHaveValue(label);
}

// The LiveSelect renders the wrapper under the component's dashed id and the
// text input under the form field's own id, which is the id its label points at.
function stopInput(page, side) {
  return page.locator(`#transfer_${side}_stop_id_text_input`);
}

async function focusedId(page) {
  return page.evaluate(() => document.activeElement?.id ?? "");
}

async function tabUntilFocused(page, id, limit = 12) {
  for (let press = 0; press < limit; press += 1) {
    if ((await focusedId(page)) === id) return;
    await page.keyboard.press("Tab");
  }

  expect(await focusedId(page)).toBe(id);
}

// Closing a draft the operator changed goes through the guard's own dialog.
async function discardDraft(page) {
  const editor = page.locator("#transfer-editor");
  const dialog = page.locator("#transfer-discard-dialog");

  await press(page, page.locator("#transfer-cancel"), visible(dialog));

  if (await dialog.isVisible()) {
    await press(
      page,
      page.locator("#transfer-discard-dialog-confirm"),
      hidden(editor),
    );
  }

  await expect(editor).toHaveCount(0);
}

// The page may not scroll sideways: the layout viewport holds the whole
// document, and the body holds nothing wider than it either.
async function fitsViewport(page) {
  const documentFits = await page.evaluate(
    () => document.documentElement.scrollWidth <= window.innerWidth,
  );

  return documentFits && (await bodyFitsViewport(page));
}
