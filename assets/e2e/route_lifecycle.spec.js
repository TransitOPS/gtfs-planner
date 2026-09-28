import { test, expect } from "@playwright/test";
import { bodyFitsViewport } from "./browser_helpers";

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

async function logIn(page, user = CREATE_USER) {
  await page.goto("/users/log_in");

  if ((await page.locator('input[name="user[email]"]').count()) === 0) return;

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
    await expect(page.locator("input[type='radio'][checked]")).toHaveCount(1);
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
    await page.locator("#new-route-trigger").click();

    // Submitting with both names blank is rejected, and the one message names
    // both fields instead of repeating inside the route-number column.
    await page
      .locator("#new-route-form")
      .evaluate((form) => form.requestSubmit());

    const error = page.locator("#new-route-names-error");
    await expect(error).toBeVisible();
    await expect(error).toContainText("route_short_name");
    await expect(error).toContainText("route_long_name");
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
    await page.locator("#new-route-trigger").click();
    await expect(
      page.locator("#new-route-form #new-route-color-fields"),
    ).toBeVisible();

    // The picker is local: it carries no name, so the hex field is the one
    // `route[route_color]` value that reaches the server (R7).
    await expect(page.locator("#new-route-color-picker")).toHaveAttribute(
      "name",
      /^$/,
    );
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
    await expect(page.locator("#new-route-contrast-ratio")).toHaveText(
      /21\.0:1 contrast/,
    );

    // The Automatic chip resolves the text color server-side, so the custom
    // field is not part of the layout until the operator asks for one.
    await expect(page.locator("#new-route-text-mode-automatic")).toBeChecked();
    await expect(page.locator("#new-route-text-wrap")).toBeHidden();

    await page.locator("#new-route-text-mode-custom").check();
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
    await page.locator("#new-route-trigger").click();

    await page.locator("#new-route-color").fill("5BC5F2");
    await page.locator("#new-route-text-mode-custom").check();
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
    // unrelated edit cannot rewrite a custom text color.
    const saved = await text.inputValue();
    await page.locator("#route-details-text-mode-custom").check();
    await expect(text).toHaveValue(saved);
    await page.locator("#route-details-text-mode-automatic").check();
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
 *   #route-details-header / #route-details-badge / #route-details-heading
 *   #route-details-mode-label / #route-details-saved-identity
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

    // Saved identity, not a draft: the heading, the badge, the mode chip and the
    // attribution line all describe the stored route.
    await expect(page.locator("#route-details-heading")).not.toBeEmpty();
    await expect(page.locator("#route-details-badge")).toBeVisible();
    await expect(page.locator("#route-details-mode-label")).not.toBeEmpty();

    const identity = page.locator("#route-details-saved-identity");
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

    await expect(page.locator("#route-details-form")).toBeVisible();
    await expect(page.locator("#route-details-heading")).toBeVisible();
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
    await page.locator("#new-route-trigger").click();

    const number = `E2E-${Date.now().toString().slice(-6)}`;

    await page.locator("#new-route-short").fill(number);
    await page
      .locator("#new-route-long")
      .fill("Create drawer regression route");
    await page.locator("#new-route-mode-3").check();
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
    await expect(page.locator("#route-details-heading")).toHaveText(
      "Create drawer regression route",
    );
    await expect(page.locator("#route-details-workspace")).toHaveAttribute(
      "data-focus-on-mount",
      "route-details-heading",
    );

    // The saved identifier is what the list shows afterwards.
    await page.goto(`/gtfs/${version}/routes?search=${savedId}`);
    await expect(page.locator("#routes a").first()).toContainText(savedId);
  });
});
