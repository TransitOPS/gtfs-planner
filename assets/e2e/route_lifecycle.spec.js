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
 * Until one of those steps mounts the component there is no production URL
 * that renders it, and this step must not add a temporary endpoint or a second
 * route to preview a prerequisite. The cases below are therefore complete but
 * skipped: step 21 deletes the `test.skip` on the create cases, step 22 deletes
 * it on the details cases. They assert only the contract this step publishes.
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

function pendingUntil(owner) {
  return {
    reason: `${owner} mounts RouteFormComponents.identity_fields/1; no production URL renders it before then`,
  };
}

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
  test("identity fields in the create drawer are labelled, optional and reachable", async ({
    page,
  }) => {
    test.skip(pendingUntil("step 21"));

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
    test.skip(pendingUntil("step 22"));

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

  test("identity error state announces the shared at-least-one-name rule without saving", async ({
    page,
  }) => {
    test.skip(pendingUntil("step 21"));

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
