import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import {
  bodyFitsViewport,
  captureShot,
  logInAs,
  readZipTextMember,
} from "./browser_helpers";

/**
 * Shared route identity controls (spec 16, step 18).
 *
 * `GtfsPlannerWeb.Gtfs.RouteFormComponents.identity_fields/1` is the "Name and
 * appearance" grammar both the create drawer and Route › Details render. This
 * step builds the stateless component and its contract; steps 21 (create
 * drawer) and 22 (Route › Details) are the steps that mount it at
 * /gtfs/:version/routes and /gtfs/:version/routes/:route_id.
 *
 * Step 21 mounted `identity_fields/1` and `color_fields/1` in the real Create
 * route drawer at /gtfs/:version/routes, and step 22 mounted the same controls
 * in the real Route > Details workspace at
 * /gtfs/:version/routes/:route_id, so both groups of cases below run against
 * production surfaces. No temporary endpoint or preview route was added.
 *
 * The component's stable control ids, which both mounting steps inherit:
 *   #<prefix>-identity                 the shared region
 *   #<prefix>-short / #<prefix>-long   route number and route name
 *   #<prefix>-names-error              the one shared at-least-one-name message
 *   #<prefix>-mode-group / #<prefix>-mode-<n>
 *                                       radio chips for the version's top modes
 *   #<prefix>-mode-other               every other accepted mode
 *   #<prefix>-agency / #<prefix>-agency-label / #<prefix>-agency-readonly
 */

const CREATE_USER = {
  email: "diagram-test@gtfs-planner.test",
  password: "DiagramTest123!",
};

const DETAILS_ROUTE = "BROWSER_PATTERNS_READY";

/**
 * Shared route color field (spec 16, step 20).
 *
 * `GtfsPlannerWeb.Gtfs.RouteFormComponents.color_fields/1` renders Route color
 * / Text color and the contrast readout that both the create drawer and Route
 * › Details share, and `assets/js/route_details_editor.js` keeps the readout
 * live while the operator types. Like the identity controls above, this step
 * builds the component and its contract; steps 21 and 22 mount it, so the cases
 * below now run against the Details workspace step 22 rendered.
 *
 * The control ids this step publishes, which both mounting steps inherit:
 *   #<prefix>-color-fields / #<prefix>-color-picker / #<prefix>-color
 *   #<prefix>-text-mode-group / #<prefix>-text-mode-automatic
 *   #<prefix>-text-mode-custom / #<prefix>-text-wrap / #<prefix>-text
 *   #<prefix>-color-error / #<prefix>-text-error / #<prefix>-color-help
 *   #<prefix>-contrast / #<prefix>-contrast-badge / #<prefix>-contrast-verdict
 *   #<prefix>-contrast-verdict-text / #<prefix>-contrast-ratio
 *   #<prefix>-contrast-advice / #<prefix>-use-automatic
 */

async function awaitConnected(page) {
  await page.waitForSelector("[data-phx-main].phx-connected");
}

// Route tabs are in-app live navigations between LiveViews. The outgoing view
// keeps `phx-connected` until the destination replaces it, so a bare connected
// check right after a tab click can pass on the view being left. Wait for the
// destination's own URL and marker, then for its connection.
async function awaitRouteTab(page, path, marker) {
  await expect(page).toHaveURL(new RegExp(`${path}$`));
  await expect(page.locator(marker)).toBeVisible();
  await awaitConnected(page);
}

function routeTab(page, name) {
  return page
    .locator('nav[aria-label="Route navigation"]')
    .getByRole("link", { name });
}

async function logIn(page, user = CREATE_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

  // The form submits over the LiveView socket: wait for the connection so a
  // fast click is never dropped before the view is joined.
  await awaitConnected(page);

  await page.fill('input[name="user[email]"]', user.email);
  await page.fill('input[name="user[password]"]', user.password);
  await page.locator('button:has-text("Log in")').click();
  await page.waitForURL((url) => !url.pathname.startsWith("/users/log_in"));
}

async function versionId(page) {
  const option = page
    .locator("#gtfs-version-panel [data-version-option]")
    .filter({ hasText: "Browser E2E Version" });

  await expect(option).toHaveCount(1);

  const id = await option.getAttribute("data-version-id");
  if (!id) throw new Error("Browser E2E Version is missing its version ID");
  return id;
}

test.describe("Route identity controls", () => {
  test("create drawer identity fields are labelled, optional and reachable", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();
    await expect(
      page.locator("#new-route-form #new-route-identity"),
    ).toBeVisible();

    // Both name inputs stay individually optional (R1 accepts either), so the
    // browser never blocks the drawer on a name the server has not rejected.
    await expect(page.locator("#new-route-short")).not.toHaveAttribute(
      "required",
      /.*/,
    );
    await expect(page.locator("#new-route-long")).not.toHaveAttribute(
      "required",
      /.*/,
    );
    await expect(page.locator('label[for="new-route-short"]')).toHaveText(
      "Route number",
    );
    await expect(page.locator('label[for="new-route-long"]')).toHaveText(
      "Route name",
    );

    // The three modes this version uses most are one keyboard radio group, and
    // every accepted mode the chips leave out stays reachable behind the
    // "Other mode…" select, which shares the same field name.
    const group = page.locator("#new-route-mode-group");
    await expect(group).toHaveAttribute("id", "new-route-mode-group");
    await expect(group.locator("legend")).toHaveText("Mode");

    const chips = group.locator("input[type='radio']");
    expect(await chips.count()).toBeGreaterThan(0);
    for (const name of await chips.evaluateAll((nodes) =>
      nodes.map((n) => n.name),
    )) {
      expect(name).toBe("route[route_type]");
    }
    await expect(page.locator("#new-route-mode-other")).toHaveAttribute(
      "name",
      "route[route_type]",
    );

    // Arrow keys move between chips, and the agency control is a labelled
    // control in every one of the zero/one/many presentations.
    await page.locator("#new-route-mode-3").focus();
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#new-route-mode-other")).toBeVisible();
    await expect(
      page
        .locator("#new-route-agency-label, label[for='new-route-agency']")
        .first(),
    ).toHaveText("Agency");

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("identity fields on route Details show the saved values in the same controls", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(
      page.locator("#route-details-form #route-details-identity"),
    ).toBeVisible();

    await expect(page.locator("#route-details-short")).toHaveValue(/\S/);
    await expect(page.locator("#route-details-long")).toHaveValue(/\S/);

    // The same chips, the same other-mode select, and one checked chip for the
    // route's saved mode; the drawer and Details share one field grammar.
    await expect(page.locator("#route-details-mode-group legend")).toHaveText(
      "Mode",
    );
    // Scoped to the mode group: the Details color fields carry their own
    // text-mode radio set (step 20), which is checked independently.
    await expect(
      page.locator("#route-details-mode-group input[type='radio'][checked]"),
    ).toHaveCount(1);
    await expect(page.locator("#route-details-mode-other")).toHaveAttribute(
      "name",
      "route[route_type]",
    );

    // `new-route` and `route-details` must not collide when both forms are on
    // one page, which is what the prefix exists for.
    const ids = await page
      .locator("[id]")
      .evaluateAll((nodes) => nodes.map((n) => n.id));
    expect(new Set(ids).size).toBe(ids.length);

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("create identity error state announces the shared at-least-one-name rule without saving", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();

    // Submitting with both names blank is rejected, and the one message names
    // both fields instead of repeating inside the route-number column.
    await page
      .locator("#new-route-form")
      .evaluate((form) => form.requestSubmit());

    const error = page.locator("#new-route-names-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText(
      "Enter a route number, a route name, or both.",
    );
    await expect(page.locator("#new-route-short")).toHaveAttribute(
      "aria-invalid",
      "true",
    );
    await expect(page.locator("#new-route-long")).toHaveAttribute(
      "aria-describedby",
      "new-route-names-error",
    );

    // The draft is still on screen: a rejected save never clears the fields.
    await expect(page.locator("#new-route-form")).toBeVisible();
  });
});

test.describe("Route color field", () => {
  test("create drawer colors picker and hex stay in step without a round trip", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();
    await expect(
      page.locator("#new-route-form #new-route-color-fields"),
    ).toBeVisible();

    // The picker is local: it carries no name attribute at all, so the hex
    // field is the one `route[route_color]` value that reaches the server (R7).
    expect(
      await page.locator("#new-route-color-picker").getAttribute("name"),
    ).toBeNull();
    await expect(page.locator("#new-route-color")).toHaveAttribute(
      "name",
      "route[route_color]",
    );

    // Typing a hex updates the swatch and the readout without any request, so
    // the preview is local feedback rather than a save.
    let requests = 0;
    page.on("request", () => (requests += 1));

    await page.locator("#new-route-color").fill("5BC5F2");
    await expect(page.locator("#new-route-color-picker")).toHaveValue(
      "#5bc5f2",
    );
    // The automatic text for a light fill is the dark pick, so the readout
    // reports that pair's ratio (the landed RouteIdentity math).
    await expect(page.locator("#new-route-contrast-ratio")).toHaveText(
      /10\.7:1 contrast/,
    );

    // The Automatic chip resolves the text color server-side, so the custom
    // field is not part of the layout until the operator asks for one.
    await expect(page.locator("#new-route-text-mode-automatic")).toBeChecked();
    await expect(page.locator("#new-route-text-wrap")).toBeHidden();

    // The mode radios are sr-only chips; the label is the click target
    // (step-33 fix 6's idiom for the drawer's mode chip).
    await page.locator("label[for='new-route-text-mode-custom']").click();
    await expect(page.locator("#new-route-text-wrap")).toBeVisible();
    await page.locator("#new-route-text").fill("FFFFFF");
    await expect(page.locator("#new-route-contrast-verdict-text")).toHaveText(
      "Hard to read",
    );
    await expect(page.locator("#new-route-contrast-ratio")).toHaveText(
      "2.0:1 contrast, below 4.5:1",
    );

    expect(requests).toBe(0);
    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("create low contrast stays saveable and the automatic fix is a focusable button", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();

    await page.locator("#new-route-color").fill("5BC5F2");
    await page.locator("label[for='new-route-text-mode-custom']").click();
    await page.locator("#new-route-text").fill("FFFFFF");

    // The warning is advisory: nothing is disabled, so the save stays possible.
    const advice = page.locator("#new-route-contrast-advice");
    await expect(advice).toBeVisible();
    await expect(advice).toContainText("exports keep what you enter");
    await expect(page.locator("#new-route-text")).toBeEnabled();

    // The fix is a real button, keyboard reachable, and it leaves focus on the
    // chip it selected so the change is visible.
    const fix = page.locator("#new-route-use-automatic");
    await fix.focus();
    await expect(fix).toBeFocused();
    await page.keyboard.press("Enter");

    await expect(page.locator("#new-route-text-mode-automatic")).toBeChecked();
    await expect(page.locator("#new-route-text-mode-automatic")).toBeFocused();
    await expect(page.locator("#new-route-contrast-verdict-text")).toHaveText(
      "Easy to read",
    );
  });

  test("colors on route Details keep an imported custom text color across an unrelated edit", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(
      page.locator("#route-details-form #route-details-color-fields"),
    ).toBeVisible();

    // Whichever mode the saved colors imply, the hex fields hold the saved
    // values and the readout describes them.
    const text = page.locator("#route-details-text");
    await expect(text).toHaveValue(/^[0-9A-Fa-f]{0,6}$/);

    const checked = page.locator(
      "#route-details-text-mode-group input[type='radio'][checked]",
    );
    await expect(checked).toHaveCount(1);
    await expect(page.locator("#route-details-color-picker")).toHaveValue(
      /^#[0-9a-f]{6}$/,
    );

    // Switching the mode and back leaves the saved value in the field, so an
    // unrelated edit cannot rewrite a custom text color. The mode radios are
    // sr-only chips; the labels are the click targets (step-33 fix 6).
    const saved = await text.inputValue();
    await page.locator("label[for='route-details-text-mode-custom']").click();
    await expect(text).toHaveValue(saved);
    await page
      .locator("label[for='route-details-text-mode-automatic']")
      .click();
    await expect(text).toHaveValue(saved);

    const ids = await page
      .locator("[id]")
      .evaluateAll((nodes) => nodes.map((n) => n.id));
    expect(new Set(ids).size).toBe(ids.length);

    expect(await bodyFitsViewport(page)).toBe(true);
  });
});

/**
 * Route > Details workspace (spec 16, step 22).
 *
 * `GtfsPlannerWeb.Gtfs.RouteDetailLive` mounts the step-5 workspace read through
 * `Gtfs.load_route_editor/3` -> the default catalog adapter and renders the
 * reference's Details composition: the saved-identity header, Name and
 * appearance, Rider information, and a collapsed Additional details disclosure
 * that still states its values. The map column is reserved for step 30 and the
 * sticky save bar for step 23, so this step claims the form region only.
 *
 * Stable ids this step publishes:
 *   #route-details-workspace / #route-details-form
 *   #route-details-header / #route-badge / #route-title
 *   #route-mode / #route-identifier
 *   #route-details-rider / #route-details-desc / #route-details-url
 *   #route-details-additional / #route-details-additional-summary
 *   #route-details-sort / #route-details-pickup / #route-details-dropoff
 *   #route-details-network / #route-details-route-id
 *   #route-details-map-region (reserved for step 30)
 */
test.describe("Route details workspace", () => {
  test("details workspace states the saved values, the read-only route ID and the last-saved actor", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    // Saved identity, not a draft: the heading, the badge, the mode chip and the
    // attribution line all describe the stored route.
    await expect(page.locator("#route-title")).not.toBeEmpty();
    await expect(page.locator("#route-badge")).toBeVisible();
    await expect(page.locator("#route-mode")).not.toBeEmpty();

    const identity = page.locator("#route-identifier");
    await expect(identity).toContainText(`Route ID ${DETAILS_ROUTE}`);
    await expect(identity).toContainText("Last saved");

    // The natural ID is creation-only (R1): it is stated, never editable.
    await expect(page.locator("#route-details-route-id")).toHaveText(
      DETAILS_ROUTE,
    );
    await expect(page.locator('input[name="route[route_id]"]')).toHaveCount(0);

    // Additional details starts collapsed and still summarizes its values.
    const additional = page.locator("#route-details-additional");
    await expect(additional).not.toHaveAttribute("open", /.*/);
    await expect(
      page.locator("#route-details-additional-summary"),
    ).toContainText("Display order");
    await expect(
      page.locator("#route-details-additional-summary"),
    ).toContainText(`Route ID ${DETAILS_ROUTE}`);

    // Opening it is a keyboard-operable disclosure with labelled controls.
    await page.locator("#route-details-additional summary").click();
    await expect(additional).toHaveAttribute("open", /.*/);
    await expect(page.locator("label[for='route-details-sort']")).toBeVisible();
    await expect(page.locator("#route-details-sort")).toBeVisible();
    await expect(
      page.locator("label[for='route-details-pickup']"),
    ).toBeVisible();
    await expect(
      page.locator("label[for='route-details-dropoff']"),
    ).toBeVisible();
    await expect(
      page.locator("label[for='route-details-network']"),
    ).toBeVisible();

    // The map column is reserved here; step 30 fills it.
    await expect(page.locator("#route-details-map-region")).toBeAttached();

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("details stacks at 375px with readable fields and the later actions still reachable", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    await expect(page.locator("#route-details-form")).toBeVisible();
    await expect(page.locator("#route-title")).toBeVisible();
    await expect(page.locator("#route-details-short")).toBeVisible();
    await expect(page.locator("#route-details-desc")).toBeVisible();

    // The disclosure's summary is a 44px standalone target at every width.
    const summary = await page
      .locator("#route-details-additional summary")
      .boundingBox();
    expect(summary.height).toBeGreaterThanOrEqual(44);

    // The transfer action below the form stays reachable at 375px.
    await expect(page.locator("#route-transfers-link")).toBeVisible();

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("details warnings appear for changed conflicting values and stay quiet for unchanged ones", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    const short = page.locator("#route-details-short");

    // The seeded BROWSER_PATTERNS_EMPTY route already uses "PE". Typing it as
    // this route's number warns against that saved route, not this one.
    await short.fill("PE");
    await short.blur();

    const shortWarn = page.locator("#route-details-short-warn");
    await expect(shortWarn).toBeVisible();
    await expect(shortWarn).toContainText("Route BROWSER_PATTERNS_EMPTY");
    await expect(shortWarn).toContainText("already uses the number “PE”");
    await expect(shortWarn).toContainText("You can still save.");
    await expect(short).toHaveAttribute("aria-describedby", /short-warn/);

    // One step from the seeded LONG_ROUTE_1 color, the draft warns about map
    // confusion, still as an advisory.
    const color = page.locator("#route-details-color");
    await color.fill("FF5734");
    await color.blur();

    const colorWarn = page.locator("#route-details-color-warn");
    await expect(colorWarn).toBeVisible();
    await expect(colorWarn).toContainText(
      "Looks like Route LONG_ROUTE_1 (#FF5733)",
    );

    // The agency home page is not a route page: case and trailing slash do not
    // matter. BROWSER_AGENCY is the version's only agency, so it is the
    // comparison for this route's draft page.
    const url = page.locator("#route-details-url");
    await url.fill("https://EXAMPLE.test/");
    await url.blur();

    const urlWarn = page.locator("#route-details-url-warn");
    await expect(urlWarn).toBeVisible();
    await expect(urlWarn).toContainText(
      "This is Browser Test Transit’s home page",
    );

    // None of the advisories blocks the save: the button stays enabled.
    await expect(page.locator("#route-save")).toBeEnabled();

    // Discarding restores the saved row: no warnings, nothing written.
    await page.locator("#route-details-discard").click();

    await expect(page.locator("#route-details-short-warn")).toHaveCount(0);
    await expect(page.locator("#route-details-color-warn")).toHaveCount(0);
    await expect(page.locator("#route-details-url-warn")).toHaveCount(0);
    await expect(short).toHaveValue("PR");
  });

  test("details boarding warns with the seeded missing paths and located geometry stays unreported", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    const unlocatedRoute = "BROWSER_ROUTE16_UNLOCATED";
    await page.goto(`/gtfs/${version}/routes/${unlocatedRoute}`);
    await awaitConnected(page);

    // BROWSER_ROUTE16_UNLOCATED's pattern runs over two stops stored without
    // coordinates, so the saved geometry itself reports a known-missing path.
    // With boarding untouched, the imported values warn nothing.
    await expect(page.locator("#route-details-cont-warn")).toHaveCount(0);

    await page.locator("#route-details-additional summary").click();

    const pickup = page.locator("#route-details-pickup");
    await pickup.selectOption({ label: "Anywhere along the route" });
    await pickup.blur();

    const contWarn = page.locator("#route-details-cont-warn");
    await expect(contWarn).toBeVisible();
    await expect(contWarn).toContainText(
      "1 pattern has sections without a path",
    );
    await expect(contWarn).toContainText(
      "boarding between stops applies there",
    );
    await expect(contWarn.locator("a")).toHaveAttribute(
      "href",
      `/gtfs/${version}/routes/${unlocatedRoute}/patterns`,
    );

    // Advisory, not a rejection: Save stays enabled while the warning stands.
    await expect(page.locator("#route-save")).toBeEnabled();

    await page.locator("#route-details-discard").click();
    await expect(contWarn).toHaveCount(0);

    // The control: every stop of BROWSER_PATTERNS_READY carries coordinates, so
    // the same boarding change reports no missing path and warns nothing.
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await page.locator("#route-details-additional summary").click();
    await page
      .locator("#route-details-pickup")
      .selectOption({ label: "Anywhere along the route" });
    await page.locator("#route-details-pickup").blur();
    // The save bar shows once the server has validated the changed draft, so
    // the absence below is the server's answer and not a read before it.
    await expect(page.locator("#route-details-save-bar")).toBeVisible();
    await expect(page.locator("#route-save")).toBeEnabled();
    await expect(page.locator("#route-details-cont-warn")).toHaveCount(0);
  });
});

/**
 * Route > Details draft preview (spec 16, step 23).
 *
 * `RouteDetailLive` re-validates every form change through the same
 * `Route.editor_changeset/3` a save will use, previews the valid draft in the
 * header and names the changed fields in the sticky save bar; the
 * `RouteDetailsEditor` hook repaints the heading badge locally and wires
 * Ctrl/Cmd+S to the form's ordinary submit. The cases below drive the real
 * Details form: nothing is persisted here, because step 24 owns the save.
 *
 * Stable ids this step publishes:
 *   #route-details-save-bar / #route-details-save-bar-text / #route-save
 *   #route-details-discard / #route-unsaved-preview
 */
test.describe("Route details draft preview", () => {
  test("a draft preview repaints the heading badge and names the changed fields", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    const routeUrl = `/gtfs/${version}/routes/${DETAILS_ROUTE}`;
    await page.goto(routeUrl);
    await awaitConnected(page);

    const badge = page.locator("#route-badge > span");
    const bar = page.locator("#route-details-save-bar");
    const color = page.locator("#route-details-color");
    const savedColor = await color.inputValue();
    const savedBadge = await badge.evaluate(
      (el) => getComputedStyle(el).backgroundColor,
    );

    // A saved row is not a draft: no bar, no chip, and the saved identity.
    await expect(bar).toBeHidden();
    await expect(page.locator("#route-unsaved-preview")).toHaveCount(0);

    // The colour the operator types reaches the route's own badge at once, with
    // no request: the picker feedback stays local (AC-19).
    let requests = 0;
    page.on("request", () => (requests += 1));

    await color.fill("5BC5F2");

    await expect
      .poll(() => badge.evaluate((el) => getComputedStyle(el).backgroundColor))
      .toBe("rgb(91, 197, 242)");
    expect(requests).toBe(0);
    expect(savedBadge).not.toBe("rgb(91, 197, 242)");

    // The server then acknowledges the draft: the chip marks the header as a
    // preview and the bar names the fields a save would change.
    await color.blur();
    await expect(page.locator("#route-unsaved-preview")).toBeVisible();
    await expect(bar).toBeVisible();
    await expect(page.locator("#route-details-save-bar-text")).toContainText(
      "Unsaved: Route color",
    );
    await expect(page.locator("#route-details-save-bar-text")).toContainText(
      "Press Ctrl+S or ⌘S to save.",
    );
    await expect(page.locator("#route-save")).toBeEnabled();

    // Cancel restores the saved values and the saved identity, and the row is
    // still the saved one after a reload.
    await page.locator("#route-details-discard").click();

    await expect(color).toHaveValue(savedColor);
    await expect
      .poll(() => badge.evaluate((el) => getComputedStyle(el).backgroundColor))
      .toBe(savedBadge);
    await expect(bar).toBeHidden();
    await expect(page.locator("#route-unsaved-preview")).toHaveCount(0);

    await page.goto(routeUrl);
    await awaitConnected(page);
    await expect(color).toHaveValue(savedColor);

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("the draft preview shortcut emits one normal submit and stays put when nothing changed", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    const routeUrl = `/gtfs/${version}/routes/${DETAILS_ROUTE}`;
    await page.goto(routeUrl);
    await awaitConnected(page);
    const originalName = await page.locator("#route-details-long").inputValue();

    // Count the form's own submit events, wherever they come from.
    await page.evaluate(() => {
      window.__routeSubmits = 0;
      document.addEventListener(
        "submit",
        () => {
          window.__routeSubmits += 1;
        },
        true,
      );
    });

    // Nothing differs from the saved row, so the shortcut has nothing to submit.
    await page.keyboard.press("Control+s");
    await expect(page.locator("#route-details-save-bar")).toBeHidden();
    expect(await page.evaluate(() => window.__routeSubmits)).toBe(0);

    await page.locator("#route-details-long").fill("Preview rename");
    await page.locator("#route-details-long").blur();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    // Ctrl+S is one normal submit of the same draft, not a second save path.
    await page.keyboard.press("Control+s");
    await expect.poll(() => page.evaluate(() => window.__routeSubmits)).toBe(1);
    await expect(page.locator("#route-details-form")).toBeVisible();

    // The draft survives on screen: Ctrl+S is one ordinary submit, so the
    // ordinary save outcome follows — the bar clears and the save is announced.
    await expect(page.locator("#route-details-long")).toHaveValue(
      "Preview rename",
    );
    await expect(page.locator("#route-details-save-bar")).toBeHidden();
    await expect(page.locator("#route-details-saved")).toContainText("saved");

    // Reload proves the submit persisted through the ordinary read, then the
    // seeded name is restored so later cases meet the seeded route.
    await page.reload();
    await awaitConnected(page);
    await expect(page.locator("#route-details-long")).toHaveValue(
      "Preview rename",
    );
    await page.locator("#route-details-long").fill(originalName);
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();
    await page.locator("#route-save").click();
    await expect(page.locator("#route-details-saved")).toContainText("saved");
  });
});

/**
 * Create route drawer (spec 16, step 21).
 *
 * `GtfsPlannerWeb.Gtfs.RoutesLive` composes the shared identity and color
 * controls (steps 18 and 20) into the 520px Create route drawer and saves
 * through the concrete audited command:
 * `handle_event("open_new_route"/"save_new_route")` -> `Gtfs.create_editor_route/3`
 * -> `GtfsPlanner.Gtfs.Routes.create_editor_route/3` -> `ReviewedApplyTransaction.Repo`
 * / `Repo`. The server issues the signed creation attempt when the drawer opens;
 * the browser only ever carries it.
 *
 * Stable ids this step publishes:
 *   #new-route-trigger / #new-route-drawer / -overlay   the drawer and its trigger
 *   #new-route-preview / #new-route-preview-name        the live draft preview
 *   #new-route-identity-fields / #new-route-id-value    the generated identifier
 *   #new-route-id-reason / #new-route-id-edit           the reason and the override
 *   #new-route-id-manual / #new-route-id-error          the manual override
 *   #new-route-unsaved / #new-route-discard             draft and discard confirm
 *   #new-route-failure                                  a refused create
 *   #new-route-submit / #new-route-cancel               the drawer's actions
 */
test.describe("Create route drawer", () => {
  test("create drawer opens at 520px with a preview and a generated identifier", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes`);
    await awaitConnected(page);

    // The ordinary list trigger is the only entrypoint; nothing else opens it.
    const trigger = page.locator("#new-route-trigger");
    await expect(trigger).toBeVisible();
    await trigger.click();

    const overlay = page.locator("#new-route-drawer-overlay");
    await expect(overlay).toHaveAttribute("data-open", "true");
    await expect(page.locator("#new-route-drawer")).toHaveClass(/520px/);
    await expect(page.locator("#new-route-drawer-title")).toHaveText(
      "Create route",
    );

    // The header preview reads the draft alone and never a saved row.
    await expect(page.locator("#new-route-preview-name")).toHaveText(
      "Name appears here",
    );

    // A clean opening is not a draft, so nothing is marked unsaved.
    await expect(page.locator("#new-route-unsaved")).toHaveCount(0);

    // The identifier block shows what the command will allocate, with the
    // reason, and offers the manual override (R1: creation-only natural ID).
    await expect(page.locator("#new-route-id-value")).toBeVisible();
    await expect(page.locator("#new-route-id-reason")).toBeVisible();
    await expect(page.locator("#new-route-id-edit")).toBeVisible();
    await expect(page.locator("#new-route-id-manual")).toHaveCount(0);

    // A clean cancel closes without asking, and writes nothing.
    await page.locator("#new-route-cancel").click();
    await expect(overlay).toHaveAttribute("data-open", "false");
    await expect(page.locator("#new-route-discard")).toHaveCount(0);
  });

  test("create drawer previews the generated id, saves through the audited command and opens the saved route", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();

    const number = `E2E-${Date.now().toString().slice(-6)}`;

    await page.locator("#new-route-short").fill(number);
    await page
      .locator("#new-route-long")
      .fill("Create drawer regression route");
    // The visible chip is the input's label: clicking it is the production
    // interaction (the input itself is sr-only).
    await page.locator("label:has(#new-route-mode-3)").click();
    await expect(page.locator("#new-route-mode-3")).toBeChecked();
    await page.locator("#new-route-color").fill("0055A4");

    // The preview is the domain's own inference, and the drawer is now a draft.
    await expect(page.locator("#new-route-unsaved")).toBeVisible();
    const previewed = (
      await page.locator("#new-route-id-value").innerText()
    ).trim();
    expect(previewed.length).toBeGreaterThan(0);
    await expect(page.locator("#new-route-preview-name")).toHaveText(
      "Create drawer regression route",
    );

    // A changed draft asks before it is discarded; keeping it costs nothing.
    await page.locator("#new-route-cancel").click();
    await expect(page.locator("#new-route-discard")).toBeVisible();
    await page.locator("#new-route-discard-cancel").click();
    await expect(page.locator("#new-route-form")).toBeVisible();

    await page.locator("#new-route-submit").click();

    // Success navigates to the saved route's own Details, and the heading is
    // the value that was persisted, not the preview.
    await page.waitForURL(/\/gtfs\/[^/]+\/routes\/[^/]+\?created=1$/);
    const savedId = decodeURIComponent(
      page.url().split("/routes/")[1].split("?")[0],
    );
    expect(savedId.length).toBeGreaterThan(0);
    await expect(page.locator("#route-title")).toHaveText(
      "Create drawer regression route",
    );
    await expect(page.locator("#route-details-workspace")).toHaveAttribute(
      "data-focus-on-mount",
      "route-title",
    );

    // The saved identifier is what the list shows afterwards.
    await page.goto(`/gtfs/${version}/routes?search=${savedId}`);
    await awaitConnected(page);
    await expect(page.locator("#routes a").first()).toContainText(savedId);
  });
});

/**
 * Route › Details save and merge outcomes (spec 16, step 24).
 *
 * `RouteDetailLive#save_route_details` submits the draft through the audited
 * `Gtfs.update_route/5` command carrying the trusted base source. A clean
 * save persists and reloads saved values; another session's committed save
 * turns a stale submission into the merge comparison (`#route-conflict`):
 * disjoint changes get one deliberate "Save both changes", overlapping
 * fields get keep-mine/use-saved radios, and discarding loads the latest
 * saved route.
 *
 * Stable ids this step publishes:
 *   #route-details-form-message / #route-details-saved
 *   #route-details-save-error / #route-conflict / #route-conflict-table
 *   #route-conflict-save / #route-conflict-discard
 */
test.describe("Route details save and merge", () => {
  test("a clean save persists the values and reloads them as saved truth", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    const long = page.locator("#route-details-long");
    const saved = (await long.inputValue()) || "Route";
    const renamed = `${saved} extended`;

    await long.fill(renamed);
    // The shared name input debounces on blur; leave the field to push the draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();
    await page.locator("#route-save").click();

    await expect(page.locator("#route-details-saved")).toContainText("saved");
    await expect(page.locator("#route-details-save-bar")).toBeHidden();
    await expect(long).toHaveValue(renamed);

    // Reload proves persistence through the ordinary read, not just echo.
    await page.reload();
    await awaitConnected(page);
    await expect(page.locator("#route-details-long")).toHaveValue(renamed);

    // Leave the seeded route as it was found.
    await long.fill(saved);
    await page.locator("#route-title").click();
    await page.locator("#route-save").click();
    await expect(page.locator("#route-details-saved")).toContainText("saved");
  });

  test("another session's disjoint save offers Save both and merges both sets", async ({
    browser,
  }) => {
    const sessionA = await browser.newContext();
    const pageA = await sessionA.newPage();
    await logIn(pageA);
    const version = await versionId(pageA);
    await pageA.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(pageA);

    // Session B is an ordinary second session of the same editor: it saves a
    // disjoint field through the same Details surface while A is editing.
    const sessionB = await browser.newContext();
    const pageB = await sessionB.newPage();
    await logIn(pageB);
    await pageB.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(pageB);
    const descB = pageB.locator("#route-details-desc");
    const theirDesc = `Saved by session B ${Date.now()}`;
    await descB.fill(theirDesc);
    await pageB.locator("#route-save").click();
    await expect(pageB.locator("#route-details-saved")).toContainText("saved");
    await sessionB.close();

    // A's stale submission is compared, not written: the conflict surface
    // names the merge and offers one deliberate Save both.
    const longA = pageA.locator("#route-details-long");
    const originalName = await longA.inputValue();
    await longA.fill("Session A rename");
    await pageA.locator("#route-title").click();
    await pageA.locator("#route-save").click();

    const conflict = pageA.locator("#route-conflict");
    await expect(conflict).toBeVisible();
    // The landed surface names the saving actor and time beside the merge:
    // "<actor> saved this route at HH:MM while you were editing".
    await expect(conflict).toContainText(
      /\S+ saved this route at \d{2}:\d{2} while you were editing/,
    );
    await expect(pageA.locator("#route-conflict-table")).toContainText(
      theirDesc,
    );
    await expect(conflict).toContainText("Session A rename");

    await pageA.locator("#route-conflict-save").click();
    await expect(pageA.locator("#route-details-saved")).toContainText("saved");
    await expect(longA).toHaveValue("Session A rename");
    await expect(pageA.locator("#route-details-desc")).toHaveValue(theirDesc);

    // Leave the seeded route as it was found.
    await longA.fill(originalName);
    await pageA.locator("#route-title").click();
    await pageA.locator("#route-save").click();
    await expect(pageA.locator("#route-details-saved")).toContainText("saved");
    await sessionA.close();
  });
});

/**
 * Route › Details dirty navigation (spec 16, step 25).
 *
 * `RouteDetailsEditor`'s guard intercepts tabs, internal links, browser back
 * and version selection while the Details draft is dirty, and the server owns
 * the "Leave without saving?" dialog. Keep editing restores the page untouched,
 * Discard leaves writing nothing, and Save and continue commits the draft and
 * only then navigates. A cancelled version change never dispatches the
 * switcher's selected-version global state (localStorage) or the URL (AC-22).
 *
 * Stable ids this step publishes:
 *   #route-details-leave / #route-details-leave-body
 *   #route-details-leave-discard / #route-details-leave-cancel
 *   #route-details-leave-save
 */
test.describe("Route details dirty navigation", () => {
  test("cancelling a version change keeps the URL and the selected-version state intact", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    const long = page.locator("#route-details-long");
    const saved = await long.inputValue();
    await long.fill(`${saved} navigation draft`);
    // The shared name input debounces on blur; leave the field to push the draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    const organizationId = await page
      .locator("#gtfs-version-switcher")
      .getAttribute("data-organization-id");
    const storageKey = `gtfs_version_${organizationId}`;

    // Pick any other published version from the switcher panel.
    const options = page.locator("#gtfs-version-panel [data-version-option]");
    const count = await options.count();
    let targetIndex = -1;
    for (let i = 0; i < count; i++) {
      if ((await options.nth(i).getAttribute("data-version-id")) !== version) {
        targetIndex = i;
        break;
      }
    }
    expect(
      targetIndex,
      "the lane seeds a second version to switch to",
    ).toBeGreaterThanOrEqual(0);

    // The option list lives in the switcher's panel; open it first.
    await page.locator("#gtfs-version-trigger").click();
    await expect(page.locator("#gtfs-version-panel")).toBeVisible();
    await options.nth(targetIndex).click();

    // The guard intercepts the option before the version hook dispatches: the
    // dialog opens, and the URL and the stored selection both still name the
    // version the page is on.
    const leave = page.locator("#route-details-leave[data-open='true']");
    await expect(leave).toBeVisible();
    await expect(page.locator("#route-details-leave-title")).toHaveText(
      "Leave without saving?",
    );
    expect(new URL(page.url()).pathname).toBe(
      `/gtfs/${version}/routes/${DETAILS_ROUTE}`,
    );
    expect(
      await page.evaluate((key) => localStorage.getItem(key), storageKey),
    ).toBe(version);

    // Keep editing: nothing is dispatched and the draft is still on screen.
    await page.locator("#route-details-leave-cancel").click();
    await expect(page.locator("#route-details-leave")).toBeHidden();
    expect(new URL(page.url()).pathname).toBe(
      `/gtfs/${version}/routes/${DETAILS_ROUTE}`,
    );
    expect(
      await page.evaluate((key) => localStorage.getItem(key), storageKey),
    ).toBe(version);
    await expect(long).toHaveValue(`${saved} navigation draft`);
  });

  test("a tab and browser back ask before discarding, and discard writes nothing", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    // Reach Details through the route tabs, so the previous history entry is
    // this same document: Back is then an in-app popstate the guard can hold.
    // After a `goto`, Back would leave the document and only the browser's own
    // beforeunload dialog could answer.
    await routeTab(page, "Patterns").click();
    await awaitRouteTab(page, "/patterns", "#pattern-editor");
    await routeTab(page, "Details").click();
    await awaitRouteTab(
      page,
      `/routes/${DETAILS_ROUTE}`,
      "#route-details-form",
    );

    const long = page.locator("#route-details-long");
    const saved = await long.inputValue();
    const draft = `${saved} nav discard draft`;
    await long.fill(draft);
    // The shared name input debounces on blur; leave the field to push the draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    // A route tab holds behind the dialog; Keep editing keeps the draft here.
    await page
      .locator('nav[aria-label="Route navigation"]')
      .getByRole("link", { name: "Patterns" })
      .click();
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-details-leave-cancel").click();
    await expect(page).toHaveURL(new RegExp(`/routes/${DETAILS_ROUTE}$`));
    await expect(long).toHaveValue(draft);

    // Browser back asks the same way, and the restored URL keeps the editor.
    await page.goBack();
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/routes/${DETAILS_ROUTE}$`));
    await page.locator("#route-details-leave-cancel").click();
    await expect(long).toHaveValue(draft);

    // Discard navigates without a write: the route keeps its saved value.
    await page
      .locator('nav[aria-label="Route navigation"]')
      .getByRole("link", { name: "Patterns" })
      .click();
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-details-leave-discard").click();
    await expect(page).toHaveURL(/\/patterns$/);

    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(long).toHaveValue(saved);
  });

  test("save and continue navigates only after the save commits", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    const long = page.locator("#route-details-long");
    const saved = await long.inputValue();
    const draft = `${saved} saved and continued`;
    await long.fill(draft);
    // The shared name input debounces on blur; leave the field to push the draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    await page
      .locator('nav[aria-label="Route navigation"]')
      .getByRole("link", { name: "Schedules" })
      .click();
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-details-leave-save").click();
    // The landed save-and-continue lands on the route's schedules tab with
    // its preselected service in the query.
    await expect(page).toHaveURL(/\/schedules(\?.*)?$/);

    // The commit landed before the navigation: the route now holds the draft.
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(long).toHaveValue(draft);

    // Leave the seeded route as it was found.
    await long.fill(saved);
    await page.locator("#route-title").click();
    await page.locator("#route-save").click();
    await expect(page.locator("#route-details-saved")).toContainText("saved");
  });
});

/**
 * Route connectivity recovery (spec 16, step 26).
 *
 * Both route forms carry `data-recovery`: the RouteDetailsEditor hook blocks
 * the form's commit controls locally the moment the socket drops, leaves every
 * entry untouched, and re-enables nothing by itself — reconnect asks the
 * server, and only the server's post-revalidation `retryable` answer clears
 * the block. `context.setOffline(true)` severs the LiveView socket the same
 * way a dropped network does, so the recovery cycle runs against the real
 * page: disable on drop, ask on reconnect, re-enable only after the answer.
 */
test.describe("Route connectivity recovery", () => {
  test("a dropped create drawer keeps its entries and re-enables only after revalidation", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes`);
    await awaitConnected(page);
    await page.locator("#new-route-trigger").click();
    await expect(page.locator("#new-route-form")).toBeVisible();

    await page.fill("#new-route-short", "R9");
    // A real socket disconnect, the repository's offline-editor idiom.
    await page.evaluate(() => window.liveSocket.disconnect());

    const submit = page.locator("#new-route-submit");
    await expect(submit).toBeDisabled();
    await expect(page.locator("#new-route-recovery")).toContainText(
      "Connection lost",
    );
    await expect(page.locator("#new-route-short")).toHaveValue("R9");

    await page.evaluate(() => window.liveSocket.connect());
    // The reconnect roundtrip re-joins the socket and revalidates the signed
    // attempt server-side; foreign-lane load can stretch it past the default.
    await expect(page.locator("#new-route-recovery")).toContainText(
      "Connection restored",
      { timeout: 15_000 },
    );
    await expect(submit).toBeEnabled();
    await expect(page.locator("#new-route-short")).toHaveValue("R9");
  });

  test("a dropped Details workspace preserves the draft and clears the block after revalidation", async ({
    page,
  }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(page.locator("#route-details-form")).toBeVisible();

    await page.fill("#route-details-long", "Renamed while offline");
    // A real socket disconnect, the repository's offline-editor idiom.
    await page.evaluate(() => window.liveSocket.disconnect());

    await expect(page.locator("#route-details-recovery")).toContainText(
      "Connection lost",
    );
    await expect(page.locator("#route-save")).toBeDisabled();
    await expect(page.locator("#route-details-long")).toHaveValue(
      "Renamed while offline",
    );

    await page.evaluate(() => window.liveSocket.connect());
    await expect(page.locator("#route-details-recovery")).toContainText(
      "Connection restored",
    );
    await expect(page.locator("#route-save")).toBeEnabled();
  });
});

/**
 * Route status actions (spec 16, step 28).
 *
 * Route › Details owns the deactivate confirmation, Reactivate and Undo; the
 * shared `route_sub_nav/1` inactive banner shows on every route tab for an
 * explicitly inactive saved row and never for NULL or true (AC-11/12). The
 * status write is the step-9 command with the saved identity, so a real
 * browser run proves the production composition end to end.
 */
test.describe("Route status actions", () => {
  // The cases below deactivate the shared seeded route. A failure mid-case must
  // not leave it inactive, or every later case that needs an active
  // BROWSER_PATTERNS_READY (and the composed export journey) fails with it.
  test.afterEach(async ({ page }) => {
    await logIn(page);
    await page.goto(`/gtfs/${await versionId(page)}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    if ((await page.locator("#route-reactivate").count()) > 0) {
      await page.locator("#route-reactivate").click();
      await expect(page.locator("#route-inactive-banner")).toHaveCount(0);
    }
  });

  test("deactivate confirms, the banner follows the saved row, and Undo restores", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    // An eligible route: no banner or chip anywhere, active status row.
    await expect(page.locator("#route-inactive-banner")).toHaveCount(0);
    await expect(page.locator("#route-status-section")).toContainText(
      "Included when you export this version.",
    );

    // The review names what the next export leaves out, what stays editable,
    // and says exports already run are unchanged.
    await page.locator("#route-deactivate").click();
    const review = page.locator("#route-status-confirm[data-open='true']");
    await expect(review).toContainText("Deactivate Route PR?");
    await expect(review).toContainText("The next export leaves out Route PR");
    await expect(review).toContainText("stay in this version");
    await expect(review).toContainText("Exports you already ran keep the route");
    await expect(page.locator("#route-status-keep")).toBeFocused();

    await page.locator("#route-status-confirm-go").click();

    await expect(page.locator("#route-inactive-banner")).toContainText(
      "is inactive.",
    );
    await expect(page.locator("#route-inactive")).toContainText(
      "Inactive",
    );
    await expect(page.locator("#route-status-outcome")).toContainText(
      "deactivated. The next export leaves it out.",
    );
    await expect(page.locator("#route-status-undo")).toBeVisible();

    // Deactivation retains editing: the tabs and the shared controls stay.
    await expect(page.locator("#route-details-short")).toBeEnabled();
    await expect(page.locator("#route-details-form")).toBeVisible();

    // The boolean persisted: the banner survives an ordinary reload.
    await page.reload();
    await expect(page.locator("#route-inactive-banner")).toContainText(
      "The next export leaves it out",
    );

    // The banner follows the saved row to the other tabs, and its Reactivate
    // action persists through the same command (the seed stays eligible).
    await page
      .locator(
        `nav[aria-label='Route navigation'] a[href='/gtfs/${version}/routes/${DETAILS_ROUTE}/patterns']`,
      )
      .click();
    await awaitRouteTab(page, "/patterns", "#pattern-editor");
    await expect(page.locator("#route-inactive-banner")).toBeVisible();
    await page.locator("#route-reactivate").click();
    await expect(page.locator("#flash-info")).toContainText("reactivated");
    await expect(page.locator("#route-inactive-banner")).toHaveCount(0);
  });

  test("a dirty draft resolves before the review opens, and Keep active writes nothing", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    await page.fill("#route-details-long", "Renamed before review");
    // The shared name input debounces on blur; leave the field to push the draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    await page.locator("#route-deactivate").click();

    // The leave dialog resolves the draft first; the review is not open yet.
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toContainText("Leave without saving?");
    await expect(
      page.locator("#route-status-confirm[data-open='true']"),
    ).toHaveCount(0);

    // Discard resolves the draft and opens the review; Keep active then
    // closes it without any write, so the banner never appears.
    await page.locator("#route-details-leave-discard").click();
    await expect(
      page.locator("#route-status-confirm[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-status-keep").click();

    await expect(page.locator("#route-inactive-banner")).toHaveCount(0);
    await expect(page.locator("#route-details-long")).not.toHaveValue(
      "Renamed before review",
    );
  });
});

/**
 * Reviewed deletion (spec 16, step 29).
 *
 * Route › Details owns the Delete route row and the reviewed-deletion dialog:
 * the step-11 review names the affected categories with their identities and
 * the retained resources, the step-12 command applies the cascade through the
 * Gtfs facade, and a stale apply is explained with the acknowledgement
 * re-cleared (AC-13/14/24). An empty entire plan gets the simple
 * confirmation; everything else gets the complete review.
 */
test.describe("Reviewed route deletion", () => {
  test("delete review names the impact, requires the acknowledgement, and returns to the scoped list", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_DELETE`);
    await awaitConnected(page);

    // The reviewed impact opens from the Delete route row: affected
    // categories with identities and the retained resources, never a bare
    // count-only confirm.
    await page.locator("#route-delete").click();
    const review = page.locator("#route-delete-review[data-open='true']");
    await expect(review).toContainText("Delete Route D16?");
    await expect(review).toContainText("This permanently deletes:");
    await expect(page.locator("#route-delete-keep")).toBeFocused();

    // The design system's count table leads; every record and its identifiers
    // stay one disclosure away.
    await expect(page.locator("#route-delete-summary")).toContainText("Trips");
    await expect(page.locator("#route-delete-summary")).not.toContainText(
      "Stop times",
    );
    await expect(page.locator("#route-delete-impact")).toBeHidden();
    await page.locator("#route-delete-details summary").click();
    await expect(page.locator("#route-delete-impact")).toBeVisible();
    await expect(page.locator("#route-delete-impact")).toContainText("Trips");
    await expect(page.locator("#route-delete-impact")).toContainText(
      "BROWSER_D16A, BROWSER_D16B",
    );
    await expect(page.locator("#route-delete-impact")).toContainText(
      "Stop times",
    );
    await expect(page.locator("#route-delete-retained")).toContainText(
      "Shared stops retained",
    );
    await expect(page.locator("#route-delete-deactivate")).toContainText(
      "deactivate it instead",
    );

    // The acknowledgement is required: Delete route stays unavailable until
    // the box is checked, so an unchecked box deletes nothing.
    await expect(page.locator("#route-delete-ack")).not.toBeChecked();
    await expect(page.locator("#route-delete-go")).toBeDisabled();
    await expect(page.locator("#route-delete-review-title")).toBeVisible();

    // Acknowledging and confirming applies the cascade and returns to the
    // scoped list with the real counts, and focus lands on the list's
    // primary action. The acknowledgement's phx-change must land before the
    // submit: the server reads the checkbox from the form's serialized
    // params, and the same change clears the shown acknowledgement error.
    await page.locator("#route-delete-ack").check();
    await expect(page.locator("#route-delete-ack-error")).toHaveCount(0);
    await expect(page.locator("#route-delete-go")).toBeEnabled();
    await page.locator("#route-delete-go").click();

    await expect(page).toHaveURL(new RegExp(`/routes\\?deleted=1$`));
    await expect(page.locator("#flash-info")).toContainText(
      "deleted, with its 2 trips",
    );
    await expect(page.locator("#new-route-trigger")).toBeFocused();
    await expect(
      page.locator(`a[href='/gtfs/${version}/routes/BROWSER_ROUTE16_DELETE']`),
    ).toHaveCount(0);
  });

  test("an empty entire plan deletes through the simple confirmation", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_EMPTY`);
    await awaitConnected(page);

    // Nothing beyond the route row itself exists, so the simple confirmation
    // is allowed and there is no acknowledgement checkbox (R5).
    await page.locator("#route-delete").click();
    const simple = page.locator("#route-delete-review[data-open='true']");
    await expect(simple).toContainText("Delete Route E16?");
    await expect(simple).toContainText("has no patterns or trips");
    await expect(page.locator("#route-delete-form")).toHaveCount(0);

    await page.locator("#route-delete-go").click();
    await expect(page).toHaveURL(new RegExp(`/routes\\?deleted=1$`));
    await expect(page.locator("#flash-info")).toContainText(
      "Route E16 deleted.",
    );
    await expect(
      page.locator(`a[href='/gtfs/${version}/routes/BROWSER_ROUTE16_EMPTY']`),
    ).toHaveCount(0);
  });

  test("a dirty draft resolves before the delete review opens", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    // This case only keeps the route, so it uses one no journey deletes:
    // BROWSER_ROUTE16_DELETE is gone once the review case above applies.
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);

    await page.fill("#route-details-long", "Renamed before delete");
    // The shared name input debounces on blur; leave the field to push the
    // draft.
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    await page.locator("#route-delete").click();

    // The leave dialog resolves the draft first; the review is not open yet.
    await expect(
      page.locator("#route-details-leave[data-open='true']"),
    ).toContainText("Leave without saving?");
    await expect(
      page.locator("#route-delete-review[data-open='true']"),
    ).toHaveCount(0);

    // Discard resolves the draft and opens the review; Keep route then
    // closes it and the route and its draft resolution are observable.
    await page.locator("#route-details-leave-discard").click();
    await expect(
      page.locator("#route-delete-review[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-delete-keep").click();

    await expect(
      page.locator("#route-delete-review[data-open='true']"),
    ).toHaveCount(0);
    await expect(page.locator("#route-details-long")).not.toHaveValue(
      "Renamed before delete",
    );
  });
});

/**
 * Saved route map (spec 16, step 30).
 *
 * The Details page's `#route-map` ignored container draws the step-17
 * projection (`GtfsPlanner.Gtfs.Routes.Map.route_map/3`) through the
 * RouteDetailsMap hook and vendored Leaflet, over the authenticated
 * /map/tiles/osm-bright/:z/:x/:y proxy. These cases treat the tile HTTP as
 * the only double (stubbed or aborted); everything else — payload, list,
 * controls, degraded states — is the production page.
 *
 * Stable ids this step publishes:
 *   #route-details-map-region / #route-map-frame / #route-map
 *   #route-map-alt / #route-map-zoom-in / #route-map-zoom-out / #route-map-fit
 *   #route-map-card / #route-map-hint / #route-map-tiles-unavailable
 *   #route-map-tiles-retry / #route-map-pattern-list / #route-map-variant-list
 *   #route-map-unavailable / #route-map-retry / #route-map-first-pattern
 */
test.describe("Saved route map", () => {
  const TILE_PATTERN = /\/map\/tiles\//;

  function pngTile() {
    // One grey 2x2 PNG; the pixels do not matter, only that the layer loads.
    return Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP8z8DwnwEJMDEgAQBe" +
        "4QEKd3hXFAAAAABJRU5ErkJggg==",
      "base64",
    );
  }

  async function openDetailsMap(page) {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(page.locator("#route-map-frame")).toBeVisible();
  }

  test("saved map draws the seeded sections, the labelled variant and the pattern list", async ({
    page,
  }) => {
    await page.route(TILE_PATTERN, (route) =>
      route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
    );
    await openDetailsMap(page);

    // The projection reached the hook: saved sections with coordinates and
    // the distinct imported shape as one labelled variant.
    const payload = JSON.parse(
      await page.locator("#route-map").getAttribute("data-map-payload"),
    );
    expect(payload.patterns).toHaveLength(2);
    expect(
      payload.patterns.every((pattern) =>
        pattern.sections.every(
          (section) =>
            section.source === "stop_pair" && section.status === "saved",
        ),
      ),
    ).toBe(true);
    expect(payload.imported_shape_variants).toHaveLength(1);
    expect(payload.imported_shape_variants[0].label).toBe("Variant 1");

    // The list is the text equivalent; the controls, legend and attribution
    // are present, and the served tiles keep the degraded banner hidden.
    await expect(
      page.locator("#route-map-pattern-list [data-map-highlight]"),
    ).toHaveCount(2);
    await expect(
      page.locator("#route-map-variant-list [data-map-kind='variant']"),
    ).toHaveCount(1);
    await expect(page.locator("#route-map-zoom-in")).toBeVisible();
    await expect(page.locator("#route-map-fit")).toBeVisible();
    await expect(
      page.locator("#route-details-map-region", { hasText: "Path saved" }),
    ).toBeVisible();
    await expect(page.locator("#route-map-tiles-unavailable")).toBeHidden();

    // Leaflet actually drew the vectors over the basemap.
    await expect(page.locator("#route-map path")).not.toHaveCount(0);

    expect(await bodyFitsViewport(page)).toBe(true);
  });

  test("tile failure keeps the vectors, the list and the retry affordance", async ({
    page,
  }) => {
    await page.route(TILE_PATTERN, (route) => route.abort());
    await openDetailsMap(page);

    // The street map is lost, the route geometry and its text equivalent are
    // not: nothing erases service when tiles fail (AC-26).
    await expect(page.locator("#route-map-tiles-unavailable")).toBeVisible();
    await expect(page.locator("#route-map path")).not.toHaveCount(0);
    await expect(
      page.locator("#route-map-pattern-list [data-map-highlight]"),
    ).toHaveCount(2);
    await expect(page.locator("#route-details-form")).toBeVisible();

    await page.locator("#route-map-tiles-retry").click();
    await expect(page.locator("#route-map-tiles-unavailable")).toBeVisible();
  });

  test("color preview changes the line color without resetting pan or zoom", async ({
    page,
  }) => {
    await page.route(TILE_PATTERN, (route) =>
      route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
    );
    await openDetailsMap(page);

    await page.locator("#route-map-zoom-in").click();
    await page.locator("#route-map-zoom-in").click();
    const pane = page.locator("#route-map .leaflet-map-pane");
    const beforeTransform = await pane.evaluate((el) => el.style.transform);
    const beforeStroke = await page
      .locator("#route-map path[stroke]")
      .first()
      .getAttribute("stroke");

    // Local preview (C-2): the hex field repaints the lines immediately,
    // with no server round trip and no fit.
    await page.fill("#route-details-color", "C81870");
    await page
      .locator("#route-details-color")
      .dispatchEvent("input")
      .catch(() => {});
    await expect(
      page.locator("#route-map path[stroke]").first(),
    ).not.toHaveAttribute("stroke", beforeStroke);

    const afterTransform = await pane.evaluate((el) => el.style.transform);
    expect(afterTransform).toBe(beforeTransform);
  });

  test("pattern rows highlight their occurrence geometry on hover and focus", async ({
    page,
  }) => {
    await page.route(TILE_PATTERN, (route) =>
      route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
    );
    await openDetailsMap(page);

    const firstRow = page
      .locator("#route-map-pattern-list [data-map-highlight]")
      .first();

    await firstRow.hover();
    await expect(firstRow).toHaveAttribute("data-on", "true");
    await expect(page.locator("#route-map-card")).toBeVisible();
    await expect(page.locator("#route-map-card")).toContainText(
      await firstRow.locator("span span").first().textContent(),
    );

    await page.locator("#route-map-title").hover();
    await expect(firstRow).toHaveAttribute("data-on", "false");
    await expect(page.locator("#route-map-card")).toBeHidden();

    await firstRow.focus();
    await expect(firstRow).toHaveAttribute("data-on", "true");
  });

  test("empty route map names the no-pattern state instead of drawing anything", async ({
    page,
  }) => {
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/BROWSER_PATTERNS_EMPTY`);
    await awaitConnected(page);

    await expect(page.locator("#route-details-map-region")).toContainText(
      "No patterns yet",
    );
    await expect(page.locator("#route-map-first-pattern")).toBeVisible();
    await expect(page.locator("#route-map")).toHaveCount(0);
  });
});

test.describe("Other routes context", () => {
  // Local copies of the saved-route-map describe's harness helpers: describe
  // blocks do not share function scope.
  const TILE_PATTERN = /\/map\/tiles\//;

  // The seeded context total for BROWSER_PATTERNS_READY's viewport: every other
  // route of the version whose geometry falls in it. A seed change that adds or
  // moves a route in that corner changes this number on purpose.
  const SEEDED_CONTEXT_TOTAL = 66;

  function pngTile() {
    return Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP8z8DwnwEJMDEgAQBe" +
        "4QEKd3hXFAAAAABJRU5ErkJggg==",
      "base64",
    );
  }

  async function openContextMap(page) {
    await page.route(TILE_PATTERN, (route) =>
      route.fulfill({ status: 200, body: pngTile(), contentType: "image/png" }),
    );
    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes/${DETAILS_ROUTE}`);
    await awaitConnected(page);
    await expect(page.locator("#route-map-frame")).toBeVisible();
  }

  test("show other routes draws context geometry and the current route stays complete", async ({
    page,
  }) => {
    await openContextMap(page);

    // Off by default: the toggle exists, nothing else does.
    await expect(page.locator("#route-map-context-toggle")).toBeVisible();
    await expect(page.locator("#route-map-context-toggle")).not.toBeChecked();
    await expect(page.locator("#route-map-context-status")).toHaveCount(0);

    await page.locator("#route-map-context-toggle").check();
    await expect(page.locator("#route-map-context-status")).toContainText(
      "Showing the first 50 nearby routes",
    );

    // The context payload carries this version's other routes only, in
    // deterministic order, never the current route.
    const context = JSON.parse(
      await page.locator("#route-map").getAttribute("data-map-context"),
    );
    expect(context.routes.length).toBe(50);
    expect(
      context.routes.every((route) => route.route_id !== DETAILS_ROUTE),
    ).toBe(true);
    const ids = context.routes.map((route) => route.route_id);
    expect(ids).toEqual([...ids].sort());

    // Context lines and badges actually drew, including the dashed inactive
    // route; the current route's own list is untouched beside them.
    await expect(
      page.locator(".route-map-context-badge").first(),
    ).toBeVisible();
    await expect(
      page.locator("#route-map path[stroke-dasharray]").first(),
    ).toBeVisible();
    await expect(
      page.locator("#route-map-pattern-list [data-map-highlight]"),
    ).toHaveCount(2);

    // Highlighting a current-route pattern dims the context layer.
    const contextLine = page
      .locator("#route-map path[stroke-dasharray]")
      .first();
    await page
      .locator("#route-map-pattern-list [data-map-highlight]")
      .first()
      .hover();
    await expect
      .poll(() =>
        contextLine.evaluate((el) => el.getAttribute("stroke-opacity")),
      )
      .toBe("0.12");

    // Turning it off discards the layer and the strip; nothing stale survives.
    await page.locator("#route-map-context-toggle").uncheck();
    await expect(page.locator("#route-map-context-status")).toHaveCount(0);
    await expect(page.locator(".route-map-context-badge")).toHaveCount(0);
    await expect(
      await page.locator("#route-map").getAttribute("data-map-context"),
    ).toBeNull();
  });

  test("context pages load more routes and mark partial until exhausted", async ({
    page,
  }) => {
    await openContextMap(page);

    await page.locator("#route-map-context-toggle").check();
    await expect(page.locator("#route-map-context-status")).toContainText(
      "Showing the first 50 nearby routes. More are in this view.",
    );
    await expect(page.locator("#route-map-context-more")).toBeVisible();

    await page.locator("#route-map-context-more").click();

    // The status line announces the exhausted total once the second page has
    // landed; the payload is read only after that, because it holds 50 routes
    // until the page arrives. The total is the seeded one: the 55
    // BROWSER_CTX_* routes plus the other seeded routes whose geometry falls in
    // the viewport (see SEEDED_CONTEXT_TOTAL).
    await expect(page.locator("#route-map-context-status")).toContainText(
      `Showing all ${SEEDED_CONTEXT_TOTAL} nearby routes in this view.`,
    );
    const context = JSON.parse(
      await page.locator("#route-map").getAttribute("data-map-context"),
    );
    const total = context.routes.length;
    expect(total).toBe(SEEDED_CONTEXT_TOTAL);

    const ids = context.routes.map((route) => route.route_id);
    expect(ids).toEqual([...ids].sort());
    expect(new Set(ids).size).toBe(total);
    await expect(page.locator("#route-map-context-more")).toHaveCount(0);
  });
});

/**
 * Complete browser workflow journeys (spec 16, step 33 — EV-5).
 *
 * The earlier describes pin the individual controls; these journeys compose
 * them into the ordinary authenticated lifecycle: create → Details →
 * pattern → schedule → deactivate/export/reactivate → reviewed delete, plus
 * the denied, stale and recovered states around it. Everything runs through
 * the production entrypoints — /gtfs/:version/routes (RoutesLive),
 * /gtfs/:version/routes/:route_id (RouteDetailLive), the pattern and
 * schedules tabs, Gtfs.ExportLive and the GtfsExportDownloadController
 * download — with concrete internal adapters and no injected assigns. The
 * only double is the tile HTTP boundary, stubbed before any Details page
 * opens, so the map keeps its vectors without an upstream tile fetch.
 *
 * The journeys are stateful like the rest of the suite: the journey route is
 * created and deleted by its own journey, the stale journey deletes the
 * seeded BROWSER_ROUTE16_FLOW, and the membership journey restores the
 * revoked member before it ends. A freshly seeded database restores
 * every record (the lane contract in spec.md).
 *
 * Seeded records consumed, from test/support/browser_seed.exs:
 *   BROWSER_ROUTE16_FLOW     one pattern + one linked trip, deleted by the
 *                            stale journey's final apply
 *   BROWSER_ROUTE16_INACTIVE explicitly active: false, never mutated — the
 *                            archive assertions use it as the unrelated
 *                            excluded route in every snapshot
 *   route16-admin@…          org admin whose /users surface revokes and
 *                            restores the editor's membership
 */

const PATHWAYS_USER = {
  email: "pathways-editor@gtfs-planner.test",
  password: "PathwaysEditor123!",
};

const ROUTE16_ADMIN_USER = {
  email: "route16-admin@gtfs-planner.test",
  password: "route16-admin-browser-pass",
};

function pngTileStep033() {
  // One grey 2x2 PNG; the pixels do not matter, only that the layer loads.
  return Buffer.from(
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP8z8DwnwEJMDEgAQBe" +
      "4QEKd3hXFAAAAABJRU5ErkJggg==",
    "base64",
  );
}

function stubTiles(page) {
  return page.route(/\/map\/tiles\//, (route) =>
    route.fulfill({
      status: 200,
      body: pngTileStep033(),
      contentType: "image/png",
    }),
  );
}

async function awaitConnectedStep033(page) {
  await page.waitForSelector("[data-phx-main].phx-connected");
}

function csvValues(text, column) {
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const header = lines[0].split(",");
  const index = header.indexOf(column);
  expect(
    index,
    `${column} is a column of the exported file`,
  ).toBeGreaterThanOrEqual(0);
  return lines.slice(1).map((line) => line.split(",")[index]);
}

test.describe("Complete route lifecycle journey", () => {
  test.use({ viewport: { width: 1440, height: 1000 } });

  // Runs one ordinary full-profile export through ExportLive and returns the
  // downloaded archive bytes from the GtfsExportDownloadController response.
  async function runExportZip(page, version) {
    await page.goto(`/gtfs/${version}/export`);
    await awaitConnectedStep033(page);
    await expect(page.locator("#export-type-full")).toBeChecked();

    const previousHref = await page
      .locator("#export-download-link")
      .getAttribute("href");
    await page.locator("#start-export").click();
    await expect
      .poll(() => page.locator("#export-download-link").getAttribute("href"), {
        timeout: 120_000,
      })
      .not.toBe(previousHref);

    const responsePromise = page.waitForResponse((response) =>
      /\/export-runs\/[^/]+\/download$/.test(new URL(response.url()).pathname),
    );
    const downloadPromise = page.waitForEvent("download");
    await page.locator("#export-download-link").click();
    const [response, download] = await Promise.all([
      responsePromise,
      downloadPromise,
    ]);

    expect(response.status()).toBe(200);
    expect(await response.headerValue("content-disposition")).toMatch(
      /^attachment; filename=/,
    );
    expect(download.suggestedFilename()).toMatch(/\.zip$/);

    return readFileSync(await download.path());
  }

  test("create, edit, schedule, deactivate, export, reactivate and reviewed delete complete through ordinary routes", async ({
    page,
  }) => {
    test.setTimeout(420_000);
    await stubTiles(page);

    await logIn(page);
    const version = await versionId(page);
    await page.goto(`/gtfs/${version}/routes`);
    await awaitConnectedStep033(page);

    // Only the seeded explicit-false twin reads as Inactive in the ordinary
    // filtered list; its active sibling does not (INV-4's render half).
    await page.goto(`/gtfs/${version}/routes?search=BROWSER_ROUTE16_INACTIVE`);
    await awaitConnectedStep033(page);
    await expect(
      page
        .locator("#routes tr")
        .filter({ hasText: "BROWSER_ROUTE16_INACTIVE" }),
    ).toContainText("Inactive");
    await captureShot(page, "step-033-journey-list-inactive-1440");

    await page.goto(`/gtfs/${version}/routes?search=BROWSER_ROUTE16_FLOW`);
    await awaitConnectedStep033(page);
    const flowRow = page
      .locator("#routes tr")
      .filter({ hasText: "BROWSER_ROUTE16_FLOW" });
    await expect(flowRow).toHaveCount(1);
    await expect(flowRow).not.toContainText("Inactive");

    // Create through the ordinary drawer; the saved route's Details takes
    // the focus (AC-7's keyboard path). The command allocates the identifier,
    // so the URL — not the draft's preview — is the saved truth.
    await page.goto(`/gtfs/${version}/routes`);
    await awaitConnectedStep033(page);
    await page.locator("#new-route-trigger").click();
    await page.locator("#new-route-short").fill("L33");
    await page.locator("#new-route-long").fill("Browser Route16 Journey");
    // The visible chip is the input's label: clicking it is the production
    // interaction (the input itself is sr-only).
    await page.locator("label:has(#new-route-mode-3)").click();
    await expect(page.locator("#new-route-mode-3")).toBeChecked();
    await page.locator("#new-route-submit").click();
    await page.waitForURL(/\/gtfs\/[^/]+\/routes\/[^/]+\?created=1$/);
    await awaitConnectedStep033(page);
    const routeId = decodeURIComponent(
      page.url().split("/routes/")[1].split("?")[0],
    );
    expect(routeId.length).toBeGreaterThan(0);
    await expect(page.locator("#route-title")).toHaveText(
      "Browser Route16 Journey",
    );
    await expect(page.locator("#route-title")).toBeFocused();

    // A recovered connection inside the journey: the socket drops with a
    // dirty draft, the entries and the commit block survive, revalidation
    // clears the block, and only then does Save commit (AC-23).
    const desc = page.locator("#route-details-desc");
    await desc.fill("Journeys composed end to end");
    await page.locator("#route-title").click();
    await expect(page.locator("#route-details-save-bar")).toBeVisible();

    // The repository's established idiom for an offline editor: a real socket
    // disconnect, which is what a lost connection looks like to the client.
    await page.evaluate(() => window.liveSocket.disconnect());
    await expect(page.locator("#route-details-recovery")).toContainText(
      "Connection lost",
    );
    await expect(page.locator("#route-save")).toBeDisabled();
    await expect(desc).toHaveValue("Journeys composed end to end");

    await page.evaluate(() => window.liveSocket.connect());
    await expect(page.locator("#route-details-recovery")).toContainText(
      "Connection restored",
    );
    await expect(page.locator("#route-save")).toBeEnabled();

    await page.locator("#route-save").click();
    await expect(page.locator("#route-details-saved")).toContainText("saved");

    // Persistence through the ordinary read, not just the form echo.
    await page.reload();
    await expect(desc).toHaveValue("Journeys composed end to end");

    // The first pattern is created through the Patterns tab's own editor:
    // named in the details task, staged from the scoped stop search.
    await page
      .locator('nav[aria-label="Route navigation"]')
      .getByRole("link", { name: "Patterns" })
      .click();
    await expect(page.locator("#patterns-empty")).toContainText(
      "Add the first pattern",
    );
    await page.locator("#patterns-create-empty").click();

    await page.waitForSelector("#pattern-task-details", { timeout: 10_000 });
    await awaitConnectedStep033(page);
    await page.locator("#pattern-task-details").click();
    await page.locator("#pattern-details-name").fill("Journey Loop");
    await page.locator("#pattern-task-stops").click();

    const searchInput = page.locator('#pattern-stop-search input[type="text"]');
    for (const stopId of ["BROWSER_PATTERN_STOP_1", "BROWSER_PATTERN_STOP_2"]) {
      await searchInput.fill(`Pattern Stop ${stopId.slice(-1)}`);
      await page.waitForSelector(`#pattern-stop-option-${stopId}`, {
        timeout: 10_000,
      });
      await searchInput.press("ArrowDown");
      await searchInput.press("Enter");
    }

    await expect(page.locator("#pattern-stops-empty")).toHaveCount(0);
    await page.locator("#pattern-create").click();
    await expect(page.locator("#flash-info")).toContainText(
      "Pattern created with its first timing",
    );
    await page.waitForURL(/\/patterns\/[^/?]+\?task=timings$/);
    const patternId = new URL(page.url()).pathname.split("/").pop();
    await expect(page.locator("#timing-row-1")).toBeVisible();

    // One trip is added to the new pattern through the schedules drawer,
    // opened with the keyboard only. The pattern editor's location trail has no
    // Schedules link, so the schedules page is opened by its address.
    await page.goto(`/gtfs/${version}/routes/${routeId}/schedules`);
    await awaitConnectedStep033(page);
    await expect(page.locator("#schedules-add-trips")).toBeVisible();
    await page.locator("#schedules-add-trips").focus();
    await page.keyboard.press("Enter");
    await page.locator("#trip-drawer").waitFor({ state: "visible" });
    await page.selectOption("#trip-pattern", { label: "Journey Loop" });
    await page.fill("#trip-start", "06:00");
    await expect(page.locator("#trip-drawer-save")).toHaveText("Add 1 trip");
    await page.locator("#trip-drawer-save").click();
    await page.locator("#trip-drawer").waitFor({ state: "hidden" });
    await expect(page).toHaveURL(/pattern=/);

    // The trip is on the created pattern, not merely announced. (The drawer's
    // focus return to #schedules-add-trips is pinned by the schedules suite's
    // own journey; this first-add patch re-renders the workspace, so the
    // focus-restored button is replaced before it can hold focus here.)
    await expect(
      page.locator(`#section-${patternId}-table tbody tr`),
    ).toHaveCount(1);

    // The composed workspace at the desktop breakpoint, before any status
    // change: draft-free Details with its pattern and trip behind the tabs.
    await page
      .locator('nav[aria-label="Route navigation"]')
      .getByRole("link", { name: "Details" })
      .click();
    await awaitConnectedStep033(page);
    await expect(page.locator("#route-status-section")).toContainText(
      "Included when you export this version.",
    );
    await captureShot(page, "step-033-journey-details-1440");

    // Deactivation is the reversible status write: the banner follows the
    // saved row and survives an ordinary reload (INV-4: explicit false).
    await page.locator("#route-deactivate").click();
    await expect(
      page.locator("#route-status-confirm[data-open='true']"),
    ).toBeVisible();
    await page.locator("#route-status-confirm-go").click();
    await expect(page.locator("#route-inactive-banner")).toContainText(
      "is inactive.",
    );
    await expect(page.locator("#route-inactive")).toContainText(
      "Inactive",
    );
    await page.reload();
    await expect(page.locator("#route-inactive-banner")).toContainText(
      "The next export leaves it out",
    );

    // The same composed workspace stays usable at 375x812 without horizontal
    // overflow (AC-28's narrow-layout contract).
    await page.setViewportSize({ width: 375, height: 812 });
    expect(await bodyFitsViewport(page)).toBe(true);
    await captureShot(page, "step-033-journey-details-inactive-375");
    await page.setViewportSize({ width: 1440, height: 1000 });

    // The inactive snapshot leaves the route and its dependent service out of
    // the archive while eligible service stays (AC-16/17, actual bytes).
    const inactiveZip = await runExportZip(page, version);
    const inactiveRoutes = csvValues(
      readZipTextMember(inactiveZip, "routes.txt"),
      "route_id",
    );
    expect(inactiveRoutes).not.toContain(routeId);
    expect(inactiveRoutes).not.toContain("BROWSER_ROUTE16_INACTIVE");
    expect(inactiveRoutes).toContain("BROWSER_PATTERNS_READY");

    const inactiveTrips = csvValues(
      readZipTextMember(inactiveZip, "trips.txt"),
      "route_id",
    );
    expect(inactiveTrips).not.toContain(routeId);
    expect(inactiveTrips).not.toContain("BROWSER_ROUTE16_INACTIVE");
    expect(inactiveTrips).toContain("BROWSER_PATTERNS_READY");

    // Reactivation restores the export inclusion of exactly this route; the
    // unrelated explicit-false twin stays excluded in the same snapshot.
    await page.goto(`/gtfs/${version}/routes/${routeId}`);
    await awaitConnectedStep033(page);
    await page.locator("#route-reactivate").click();
    await expect(page.locator("#route-status-outcome")).toContainText(
      "reactivated. The next export includes it",
    );
    await expect(page.locator("#route-inactive-banner")).toHaveCount(0);

    const activeZip = await runExportZip(page, version);
    const activeRoutes = csvValues(
      readZipTextMember(activeZip, "routes.txt"),
      "route_id",
    );
    expect(activeRoutes).toContain(routeId);
    expect(activeRoutes).not.toContain("BROWSER_ROUTE16_INACTIVE");

    const activeTrips = csvValues(
      readZipTextMember(activeZip, "trips.txt"),
      "route_id",
    );
    expect(activeTrips).toContain(routeId);
    expect(activeTrips).not.toContain("BROWSER_ROUTE16_INACTIVE");

    // The reviewed deletion closes the composed lifecycle: the review names
    // the created pattern and trip, the acknowledgement gates the apply, and
    // the scoped list reports the real counts with the focused trigger.
    await page.goto(`/gtfs/${version}/routes/${routeId}`);
    await awaitConnectedStep033(page);
    await page.locator("#route-delete").click();
    const review = page.locator("#route-delete-review[data-open='true']");
    await expect(review).toContainText("Delete Route ");
    await expect(page.locator("#route-delete-impact")).toContainText(patternId);
    await expect(page.locator("#route-delete-ack")).not.toBeChecked();
    await captureShot(page, "step-033-journey-delete-review-1440", {
      fullPage: false,
    });

    await page.locator("#route-delete-ack").check();
    await page.locator("#route-delete-go").click();
    await expect(page).toHaveURL(new RegExp(`/routes\\?deleted=1$`));
    await expect(page.locator("#flash-info")).toContainText(
      "deleted, with its 1 pattern and 1 trip",
    );
    await expect(page.locator("#new-route-trigger")).toBeFocused();

    // The cascade is observable persistence: the ordinary scoped list holds
    // no row, and the direct entrypoint denies the dead route.
    await page.goto(`/gtfs/${version}/routes?search=${routeId}`);
    await awaitConnected(page);
    await expect(page.locator("#routes-constrained-empty")).toBeVisible();
    await page.goto(`/gtfs/${version}/routes/${routeId}`);
    await awaitConnected(page);
    await expect(page.locator("#flash-error")).toContainText("Route not found");
  });
});

test.describe("Lifecycle denial and stale review", () => {
  test.use({ viewport: { width: 1440, height: 1000 } });

  test("another tenant's editor is denied at the ordinary entrypoint without seeing the route", async ({
    browser,
  }) => {
    test.setTimeout(120_000);

    // The owner's session supplies the scoped URL under test.
    const owner = await browser.newContext();
    const ownerPage = await owner.newPage();
    await logIn(ownerPage);
    const version = await versionId(ownerPage);
    await owner.close();

    const outsider = await browser.newContext();
    const outsiderPage = await outsider.newPage();
    await logInAs(outsiderPage, PATHWAYS_USER);

    // Another tenant's editor requesting the foreign route through the
    // ordinary entrypoint is refused at the version boundary itself: the URL's
    // version does not belong to their organization, so the mount hook pushes
    // the dashboard with the truthful flash and nothing of the foreign
    // version — its routes least of all — is rendered (AC-6).
    await outsiderPage.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_FLOW`);
    await expect(outsiderPage.locator("#flash-error")).toContainText(
      "GTFS version not found",
    );
    expect(new URL(outsiderPage.url()).pathname).toBe("/");
    await expect(outsiderPage.locator("body")).not.toContainText(
      "Browser Route16 Flow",
    );
    await expect(outsiderPage.locator("body")).not.toContainText(
      "BROWSER_ROUTE16_FLOW",
    );
    await captureShot(outsiderPage, "step-033-denied-foreign-1440");
    await outsider.close();
  });

  test("a concurrent edit turns the delete review stale, and nothing deletes until the fresh review is re-acknowledged", async ({
    browser,
  }) => {
    test.setTimeout(180_000);

    const sessionA = await browser.newContext();
    const pageA = await sessionA.newPage();
    await stubTiles(pageA);
    await logIn(pageA);
    const version = await versionId(pageA);
    await pageA.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_FLOW`);
    await awaitConnectedStep033(pageA);

    // The complete review names the seeded pattern and trip identities.
    await pageA.locator("#route-delete").click();
    const review = pageA.locator("#route-delete-review[data-open='true']");
    await expect(review).toContainText("Delete Route F16?");
    await expect(pageA.locator("#route-delete-impact")).toContainText(
      "BROWSER-F16-P1",
    );
    await expect(pageA.locator("#route-delete-impact")).toContainText(
      "BROWSER_F16_T1",
    );

    // A second ordinary session renames the route while the review is open.
    const sessionB = await browser.newContext();
    const pageB = await sessionB.newPage();
    await stubTiles(pageB);
    await logIn(pageB);
    await pageB.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_FLOW`);
    await awaitConnectedStep033(pageB);
    const longB = pageB.locator("#route-details-long");
    await longB.fill("Browser Route16 Flow renamed");
    await pageB.locator("#route-title").click();
    await pageB.locator("#route-save").click();
    await expect(pageB.locator("#route-details-saved")).toContainText("saved");

    // The acknowledged confirm is refused: the totals match, the contents
    // moved, the fresh review says so, and the acknowledgement is cleared.
    await pageA.locator("#route-delete-ack").check();
    await pageA.locator("#route-delete-go").click();
    await expect(pageA.locator("#route-delete-impact")).toContainText(
      "contents changed",
    );
    await expect(pageA.locator("#route-delete-ack")).not.toBeChecked();
    await captureShot(pageA, "step-033-stale-contents-changed-1440", {
      fullPage: false,
    });

    // Nothing was deleted: the second session still reads the renamed route.
    await pageB.reload();
    await expect(pageB.locator("#route-details-long")).toHaveValue(
      "Browser Route16 Flow renamed",
    );

    // The re-acknowledged fresh review applies the reviewed cascade.
    await pageA.locator("#route-delete-ack").check();
    await pageA.locator("#route-delete-go").click();
    await expect(pageA).toHaveURL(/\/routes\?deleted=1$/);
    await expect(pageA.locator("#flash-info")).toContainText(
      "deleted, with its 1 pattern and 1 trip",
    );

    // The dead route is gone for the other session too.
    await pageB.reload();
    await expect(pageB.locator("#flash-error")).toContainText(
      "Route not found",
    );

    await sessionA.close();
    await sessionB.close();
  });

  test("a deactivated membership ends the session without writing the draft, and restores cleanly", async ({
    browser,
  }) => {
    test.setTimeout(180_000);

    // The never-mutated inactive twin hosts this journey: a refused save
    // writes nothing, so the seeded row survives it untouched. The stale
    // journey before this one deleted BROWSER_ROUTE16_FLOW.
    const editor = await browser.newContext();
    const editorPage = await editor.newPage();
    await stubTiles(editorPage);
    await logIn(editorPage);
    const version = await versionId(editorPage);
    await editorPage.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_INACTIVE`);
    await awaitConnectedStep033(editorPage);

    const long = editorPage.locator("#route-details-long");
    const savedName = await long.inputValue();
    await long.fill("Revoked draft rename");
    await editorPage.locator("#route-title").click();
    await expect(editorPage.locator("#route-details-save-bar")).toBeVisible();

    // The org admin removes the editor's membership through the real /users
    // surface while the editor holds the dirty draft.
    const admin = await browser.newContext();
    const adminPage = await admin.newPage();
    await logInAs(adminPage, ROUTE16_ADMIN_USER);
    await adminPage.goto("/admin/users");
    await awaitConnectedStep033(adminPage);
    const memberRow = adminPage
      .locator("tbody#members tr")
      .filter({ hasText: "diagram-test@gtfs-planner.test" });
    await memberRow
      .locator('[aria-label="Deactivate diagram-test@gtfs-planner.test"]')
      .click();
    await adminPage.locator("#deactivate-user-dialog-confirm").click();
    await expect(adminPage.locator("#member-action-feedback")).toContainText(
      "diagram-test@gtfs-planner.test deactivated.",
    );

    // Deactivation ends the editor's sessions and closes their open LiveViews,
    // so the dirty page cannot write: the socket's reconnect is refused and the
    // page lands on the ordinary login. The refusal with the draft kept on a
    // still-open page (a role revoked while the session lives) is covered by the
    // route Details and status ExUnit cases.
    await expect(editorPage.locator('input[name="user[email]"]')).toBeVisible();

    // Restore access, then prove nothing was written: the saved row still
    // holds the name the draft never overwrote.
    await memberRow
      .locator('[aria-label="Activate diagram-test@gtfs-planner.test"]')
      .click();
    await expect(adminPage.locator("#member-action-feedback")).toContainText(
      "diagram-test@gtfs-planner.test activated.",
    );
    await admin.close();

    // Signing back in shows the saved row still holding the name the abandoned
    // draft never overwrote.
    await logIn(editorPage);
    await editorPage.goto(`/gtfs/${version}/routes/BROWSER_ROUTE16_INACTIVE`);
    await awaitConnectedStep033(editorPage);
    await expect(editorPage.locator("#route-details-long")).toHaveValue(
      savedName,
    );
    await editor.close();
  });
});
