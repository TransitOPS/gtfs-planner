defmodule GtfsPlannerWeb.Gtfs.FaresLiveRuleEditorTest do
  @moduledoc """
  Merge evidence (EV-23) for the fare rule drawer and rule removal.

  Every case mounts the real route and drives the drawer through the elements the
  page renders: the header's `Add fare rule`, a card's `Edit rule`, the form
  itself, `Reload rule` and the removal confirm. The reviewed group is never
  constructed by the test - the drawer opens from the card's own DOM ID and the
  LiveView resolves that ID back to the rule list it read, so every save and
  removal runs against rows the page itself loaded (INV-4).

  The fixture carries what the criteria name: two fares, a route with both names
  and one with only a long name, four zones (two with boardable stops, a declared
  zone with none, and an imported ID holding a leading space), and one rule of
  each shape - a key another rule holds, an unknown fare, a two-row through-zone
  rule, and a rule whose route has no `routes` row. The same keys exist in the
  organization's other version, so a save that is not fenced to one version is
  visible.

  Field errors are asserted on the element the contract names
  (`#<field>-error`), retained input and the plain-language summary are read as
  raw text through `LazyHTML` so a byte difference cannot pass as a match, and
  the stored rows are read from `fare_rules` again, so no assertion is satisfied
  by the drawer's markup alone.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @rules_path "/settings/fares/rules"

  @no_fares_reason "This version has no fares. Import fare_attributes.txt to add fares."
  @key_message "A rule with this fare, route, start and end already exists. Edit that rule instead."
  @stopless_message "This zone has no stops yet. Assign stops before using it in a fare rule."
  @stale_message "This rule changed since you opened it."
  @missing_message "This rule no longer exists."
  @save_failed_message "Changes couldn’t be saved. Your edits are still here."

  # The zone options in the inventory's own byte order: " A" sorts before "A",
  # and the imported ID's leading space is part of the label it renders.
  @zone_labels ["Padded ·  A", "Central · A", "Uplands · B", "Airport · D · no stops"]

  # The five fields the domain casts, as a browser would send them for one change
  # or submit.
  @form %{
    "fare_id" => "CITY",
    "route_id" => "",
    "origin_id" => "",
    "destination_id" => "",
    "contains" => [""]
  }

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Uplands", "teal")
    insert_zone(organization, version, "D", "Airport", "ochre")
    # Declared, with the byte-exact imported ID every path must keep.
    insert_zone(organization, version, " A", "Padded", "plum")

    insert_stops(organization, version, [
      {"CENTRAL_1", "Central 1", 0, "A"},
      {"CENTRAL_2", "Central 2", 0, "A"},
      {"UPLANDS_1", "Uplands 1", 0, "B"},
      {"PADDED_1", "Padded 1", 0, " A"},
      {"CENTRAL_STATION", "Central Union", 1, "A"}
    ])

    insert_routes(organization, version, [
      %{route_id: "ROUTE_10", short_name: "10", long_name: "Crosstown"},
      %{route_id: "ROUTE_EXPRESS", short_name: nil, long_name: "Airport Express"}
    ])

    insert_fares(organization, version, [
      %{fare_id: "CITY", price: "2.50"},
      %{fare_id: "CROSS", price: "3.75"}
    ])

    row_ids =
      insert_rules(organization, version, [
        # The key a new rule collides with: same fare, route, start and end.
        {:collision, {"CITY", "ROUTE_10", "A", "B", nil}},
        # A fare with no fare_attributes row.
        {:unknown_fare, {"GONE", nil, "A", "B", nil}},
        # One through-zone rule in two rows.
        {:through, {"CROSS", nil, nil, nil, "A"}},
        {:through, {"CROSS", nil, nil, nil, "B"}},
        # An imported ID with a space, and a route that has no routes row.
        {:padded, {"CITY", "ROUTE_MISSING", " A", "B", nil}}
      ])

    # The organization's other version carries its own rule under the same key.
    other_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, other_version, "A", "Central", "ocean")
    insert_stops(organization, other_version, [{"OTHER_1", "Other 1", 0, "A"}])
    insert_fares(organization, other_version, [%{fare_id: "CITY", price: "9.99"}])

    other_rows =
      insert_rules(organization, other_version, [{:other, {"CITY", "ROUTE_10", "A", "B", nil}}])

    empty_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, empty_version, "A", "Central", "ocean")
    insert_stops(organization, empty_version, [{"NO_FARE_1", "No fare 1", 0, "A"}])

    %{
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      empty_version: empty_version,
      cards: Map.new(row_ids, fn {label, ids} -> {label, card_id(ids)} end),
      other_card: card_id(other_rows.other),
      row_ids: row_ids
    }
  end

  describe "the header action" do
    test "is disabled with its reason in a version with no fares", %{
      conn: conn,
      user: user,
      organization: organization,
      empty_version: empty_version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, empty_version)

      assert has_element?(view, "#add-fare-rule[disabled]")
      assert text_exact(view, "#add-fare-rule-reason") == @no_fares_reason
    end

    test "opens the create drawer when the version has fares", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      refute has_element?(view, "#add-fare-rule[disabled]")
      refute has_element?(view, "#add-fare-rule-reason")

      view |> element("#add-fare-rule") |> render_click()

      assert drawer_open?(view)
      assert text_exact(view, "#fare-rule-drawer-title") == "Add a fare rule"
      assert has_element?(view, "#fare-rule-form")
    end
  end

  describe "creating a rule" do
    test "offers this version's fares, zones and routes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("#add-fare-rule") |> render_click()

      assert option_labels(view, "#fare-rule-fare") == ["CITY · $2.50", "CROSS · $3.75"]
      assert option_labels(view, "#fare-rule-origin") == ["Any origin" | @zone_labels]
      assert option_labels(view, "#fare-rule-destination") == ["Any destination" | @zone_labels]

      assert option_labels(view, "#fare-rule-route") == [
               "All routes",
               "10 · Crosstown",
               "Airport Express"
             ]

      # The through-zone checkboxes are named by their own position, never by a
      # zone ID (CR-7), and there is one per inventory zone.
      assert node_attribute(view, "#fare-rule-contains input[type=checkbox]", "id") ==
               [
                 "fare-rule-contains-0",
                 "fare-rule-contains-1",
                 "fare-rule-contains-2",
                 "fare-rule-contains-3"
               ]

      assert node_attribute(view, "#fare-rule-contains input[type=checkbox]", "value") ==
               [" A", "A", "B", "D"]

      assert text_exact(view, "#fare-rule-contains-help") ==
               "The journey must visit every checked zone. Leave all unchecked for no through-zone requirement."

      assert text_exact(view, "#fare-rule-fare-help") ==
               "Existing fares in this version. Prices are shown for context."
    end

    test "saves the chosen journey, closes the drawer and shows the new card", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("#add-fare-rule") |> render_click()
      submit_rule(view, %{@form | "origin_id" => "A", "destination_id" => "B"})

      refute drawer_open?(view)
      assert text_exact(view, "#fare-zone-notice") == "Fare rule saved."
      assert has_element?(view, "#fare-rule-list article", "From Central → Uplands")

      assert [row] = rules(organization, version, "CITY", nil, "A", "B")

      assert %{route_id: nil, contains_id: nil} = Map.take(row, [:route_id, :contains_id])
    end

    test "keeps the chosen values and names the collision when the key is another rule's", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      before = all_rule_ids(organization, version)

      view |> element("#add-fare-rule") |> render_click()

      submit_rule(view, %{
        @form
        | "origin_id" => "A",
          "destination_id" => "B",
          "route_id" => "ROUTE_10"
      })

      assert drawer_open?(view)
      assert text_exact(view, "#fare-rule-fare-error") == @key_message

      # The chosen journey is still the form's: the summary is rendered from the
      # form's own current values, so it cannot read right unless they survived.
      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from Central to Uplands on 10 · Crosstown."

      assert selected_option(view, "#fare-rule-fare") == "CITY"
      assert selected_option(view, "#fare-rule-route") == "ROUTE_10"
      assert all_rule_ids(organization, version) == before
    end

    test "refuses a new reference to a zone with no stops beside the field that chose it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("#add-fare-rule") |> render_click()

      submit_rule(view, %{
        @form
        | "origin_id" => "A",
          "destination_id" => "D",
          "contains" => ["D"]
      })

      assert drawer_open?(view)
      assert text_exact(view, "#fare-rule-destination-error") == @stopless_message
      assert text_exact(view, "#fare-rule-contains-error") == @stopless_message
      refute has_element?(view, "#fare-rule-origin-error")
      refute has_element?(view, "#fare-rule-fare-error")

      # Nothing was written and the chosen values are still on screen.
      assert MapSet.size(all_rule_ids(organization, version)) == 5
      assert selected_option(view, "#fare-rule-destination") == "D"
      assert checked?(view, "fare-rule-contains-3")
    end
  end

  describe "the plain-language summary" do
    test "follows the form's own values, including the through zones and the route", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("#add-fare-rule") |> render_click()

      # A create starts on the version's first fare, so the summary describes a
      # rule that can actually be saved.
      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from any zone to any zone on all routes."

      change_rule(view, %{@form | "origin_id" => "A", "destination_id" => "B"})

      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from Central to Uplands on all routes."

      change_rule(view, %{
        @form
        | "origin_id" => "A",
          "destination_id" => "B",
          "route_id" => "ROUTE_10"
      })

      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from Central to Uplands on 10 · Crosstown."

      change_rule(view, %{
        @form
        | "origin_id" => "A",
          "destination_id" => "B",
          "route_id" => "ROUTE_10",
          "contains" => ["A", "B"]
      })

      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from Central to Uplands on 10 · Crosstown, visiting Central and Uplands."

      # The zone whose ID has a leading space keeps its bytes in the option and
      # is named by the inventory's own record.
      change_rule(view, %{@form | "origin_id" => " A"})

      assert selected_option(view, "#fare-rule-origin") == " A"

      assert text_exact(view, "#fare-rule-summary") ==
               "Use CITY · $2.50 for journeys from Padded to any zone on all routes."
    end
  end

  describe "editing a rule" do
    test "keeps an unknown fare through another change and rewrites only its own rows", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.unknown_fare}-edit") |> render_click()

      assert drawer_open?(view)
      assert text_exact(view, "#fare-rule-drawer-title") == "Edit fare rule"

      assert option_labels(view, "#fare-rule-fare") == [
               "Unknown fare GONE",
               "CITY · $2.50",
               "CROSS · $3.75"
             ]

      assert selected_option(view, "#fare-rule-fare") == "GONE"
      assert selected_option(view, "#fare-rule-origin") == "A"
      assert selected_option(view, "#fare-rule-destination") == "B"

      submit_rule(view, %{
        @form
        | "fare_id" => "GONE",
          "origin_id" => "B",
          "destination_id" => "B"
      })

      refute drawer_open?(view)
      assert text_exact(view, "#fare-zone-notice") == "Fare rule saved."

      # The fare the rule already named survives a save that never touched it,
      # and the group is now the one journey the form chose.
      assert [%{contains_id: nil}] = rules(organization, version, "GONE", nil, "B", "B")

      assert rules(organization, version, "GONE", nil, "A", "B") == []
    end

    test "replaces exactly the reviewed group and leaves every other row alone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards,
      row_ids: row_ids,
      other_version: other_version
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      before = all_rule_ids(organization, version)
      untouched = MapSet.difference(before, MapSet.new(row_ids.through))

      view |> element("##{cards.through}-edit") |> render_click()

      assert checked?(view, "fare-rule-contains-1")
      assert checked?(view, "fare-rule-contains-2")
      refute checked?(view, "fare-rule-contains-0")
      refute checked?(view, "fare-rule-contains-3")

      # One of the two through zones is dropped: the group's rows are rewritten,
      # never merged into another key and never extended by a cross-group write.
      submit_rule(view, %{@form | "fare_id" => "CROSS", "contains" => ["B"]})

      assert text_exact(view, "#fare-zone-notice") == "Fare rule saved."

      rows = rules(organization, version, "CROSS", nil, nil, nil)

      assert Enum.map(rows, & &1.contains_id) == ["B"]

      # Every row that is not the rewritten group's is exactly where it was, and
      # the other version's rule is untouched.
      assert MapSet.difference(all_rule_ids(organization, version), MapSet.new(rows, & &1.id)) ==
               untouched

      assert MapSet.size(all_rule_ids(organization, other_version)) == 1
    end

    test "keeps an imported zone ID's bytes and an unknown route through an untouched save", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.padded}-edit") |> render_click()

      assert selected_option(view, "#fare-rule-origin") == " A"

      assert option_labels(view, "#fare-rule-route") == [
               "All routes",
               "Unknown route ROUTE_MISSING",
               "10 · Crosstown",
               "Airport Express"
             ]

      assert selected_option(view, "#fare-rule-route") == "ROUTE_MISSING"

      submit_rule(view, %{
        @form
        | "fare_id" => "CITY",
          "route_id" => "ROUTE_MISSING",
          "origin_id" => " A",
          "destination_id" => "B"
      })

      assert text_exact(view, "#fare-zone-notice") == "Fare rule saved."

      # The stored bytes are the imported ID, never a trimmed one.
      assert length(rules(organization, version, "CITY", "ROUTE_MISSING", " A", "B")) == 1
    end

    test "ignores an edit for a rule of another version", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      other_card: other_card
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      # The card ID of the other version's rule is not in this page's own read,
      # so nothing opens and neither version's rows can be written from it.
      render_click(view, "open_rule_drawer", %{"rule_id" => other_card})

      refute drawer_open?(view)
      assert MapSet.size(all_rule_ids(organization, version)) == 5
    end
  end

  describe "a rule that changed under the drawer" do
    test "refuses the save, offers Reload rule and reloads the rule it was opened on", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards,
      row_ids: row_ids
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.collision}-edit") |> render_click()
      assert text_exact(view, "#fare-rule-drawer-title") == "Edit fare rule"

      # Another editor renames the zone the rule starts in. The rule's rows keep
      # their IDs and move to another key, which is exactly what the fence is for.
      {:ok, _zone} =
        FareZones.update_zone(organization.id, version.id, "A", %{
          "zone_id" => "A2",
          "name" => "Central",
          "color" => "ocean"
        })

      submit_rule(view, %{
        @form
        | "origin_id" => "A2",
          "destination_id" => "B",
          "route_id" => "ROUTE_10"
      })

      assert drawer_open?(view)
      assert text_exact(view, "#fare-rule-stale") =~ @stale_message
      assert has_element?(view, "#fare-rule-reload", "Reload rule")

      # Nothing was written under the reviewed key, and the rule rows are still
      # the ones the drawer opened on.
      assert rules(organization, version, "CITY", "ROUTE_10", "A", "B") == []

      assert rules(organization, version, "CITY", "ROUTE_10", "A2", "B")
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort(row_ids.collision)

      view |> element("#fare-rule-reload") |> render_click()

      refute has_element?(view, "#fare-rule-stale")
      assert drawer_open?(view)
      assert selected_option(view, "#fare-rule-origin") == "A2"

      # The reloaded rule is the renamed one, and it is savable again.
      submit_rule(view, %{
        @form
        | "origin_id" => "A2",
          "destination_id" => "B",
          "route_id" => "ROUTE_10"
      })

      assert text_exact(view, "#fare-zone-notice") == "Fare rule saved."
      assert length(rules(organization, version, "CITY", "ROUTE_10", "A2", "B")) == 1
    end

    test "closes with what happened when the reloaded rule is gone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.unknown_fare}-edit") |> render_click()

      delete_rule_rows(organization, version, "GONE")

      submit_rule(view, %{
        @form
        | "fare_id" => "GONE",
          "origin_id" => "B",
          "destination_id" => "B"
      })

      assert text_exact(view, "#fare-rule-stale") =~ @stale_message

      view |> element("#fare-rule-reload") |> render_click()

      refute drawer_open?(view)
      assert text_exact(view, "#fare-zone-notice") == @missing_message
    end
  end

  describe "removing a rule" do
    test "confirms with the consequence, deletes exactly the rule's rows and keeps the fare", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      assert length(rules(organization, version, "CROSS", nil, nil, nil)) == 2

      view |> element("##{cards.through}-edit") |> render_click()
      view |> element("#fare-rule-remove") |> render_click()

      assert text_exact(view, "#fare-rule-remove-dialog-title") == "Remove this fare rule?"

      assert text_exact(view, "#fare-rule-remove-consequence") ==
               "The fare itself will remain. Journeys covered by this rule may no longer receive that fare."

      assert text_exact(view, "#fare-rule-remove-dialog-confirm") == "Remove rule"
      assert text_exact(view, "#fare-rule-remove-dialog-cancel") == "Keep rule"

      # Keep rule leaves the rule, the drawer and the list exactly as they were.
      view |> element("#fare-rule-remove-dialog-cancel") |> render_click()

      assert length(rules(organization, version, "CROSS", nil, nil, nil)) == 2
      assert drawer_open?(view)
      refute has_element?(view, "#fare-rule-remove-dialog")

      view |> element("#fare-rule-remove") |> render_click()
      assert has_element?(view, "#fare-rule-remove-dialog")

      view |> element("#fare-rule-remove-dialog-confirm") |> render_click()

      refute has_element?(view, "#fare-rule-remove-dialog")
      refute drawer_open?(view)
      assert text_exact(view, "#fare-zone-notice") == "Fare rule removed."

      assert rules(organization, version, "CROSS", nil, nil, nil) == []
      assert has_element?(view, "#fare-rule-list article", "From Central → Uplands")

      # The fare attribute is untouched: only the rule's rows go.
      assert Repo.get_by(FareAttribute,
               organization_id: organization.id,
               gtfs_version_id: version.id,
               fare_id: "CROSS"
             )
    end

    test "refuses a stale confirmation, keeps the dialog open and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.through}-edit") |> render_click()
      view |> element("#fare-rule-remove") |> render_click()

      # Another editor adds a third through zone to the same rule.
      insert_rules(organization, version, [{:through, {"CROSS", nil, nil, nil, "D"}}])

      view |> element("#fare-rule-remove-dialog-confirm") |> render_click()

      assert has_element?(view, "#fare-rule-remove-dialog")
      assert text_exact(view, "#fare-rule-remove-error") == @stale_message

      # Every row of the rule is still there.
      assert length(rules(organization, version, "CROSS", nil, nil, nil)) == 3
    end

    test "keeps the dialog open with the save-failure message when the pair is not published", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      view |> element("##{cards.through}-edit") |> render_click()
      view |> element("#fare-rule-remove") |> render_click()

      set_status(organization, version, "staging")

      view |> element("#fare-rule-remove-dialog-confirm") |> render_click()

      assert has_element?(view, "#fare-rule-remove-dialog")
      assert text_exact(view, "#fare-rule-remove-error") == @save_failed_message

      # Nothing was written.
      assert length(rules(organization, version, "CROSS", nil, nil, nil)) == 2

      set_status(organization, version, "published")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp mount_rules(conn, user, organization, version) do
    conn
    |> log_in_user(user, organization: organization)
    |> live("/gtfs/#{version.id}#{@rules_path}")
  end

  defp change_rule(view, params) do
    view |> element("#fare-rule-form") |> render_change(%{"rule" => params})
  end

  defp submit_rule(view, params) do
    view |> element("#fare-rule-form") |> render_submit(%{"rule" => params})
  end

  defp nodes(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  # The element's text as rendered: only the line's own indentation is trimmed,
  # never whitespace inside it, so a byte difference in a zone ID or a price
  # fails the assertion while the template's line breaks do not.
  defp text_exact(view, selector) do
    view |> nodes(selector) |> LazyHTML.text() |> String.trim()
  end

  defp node_attribute(view, selector, name),
    do: view |> nodes(selector) |> LazyHTML.attribute(name)

  defp option_labels(view, selector),
    do: view |> nodes("#{selector} option") |> Enum.map(&LazyHTML.text/1)

  defp selected_option(view, selector) do
    view
    |> nodes("#{selector} option[selected]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp checked?(view, id), do: node_attribute(view, "##{id}", "checked") != []

  defp drawer_open?(view),
    do: node_attribute(view, "#fare-rule-drawer-overlay", "data-open") == ["true"]

  defp card_id(row_ids), do: "fare-rule-" <> Enum.min(row_ids)

  defp rules(organization, version, fare_id, route_id, origin_id, destination_id) do
    conditions =
      dynamic(
        [r],
        r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
          r.fare_id == ^fare_id and ^eq_or_nil(:route_id, route_id) and
          ^eq_or_nil(:origin_id, origin_id) and ^eq_or_nil(:destination_id, destination_id)
      )

    Repo.all(
      from(r in FareRule,
        where: ^conditions,
        select: %{id: r.id, contains_id: r.contains_id, route_id: r.route_id}
      )
    )
  end

  # A nil lookup means "that column is unset", not "no filter": Ecto rejects
  # `column == nil`, so the clause has to be built for each case.
  defp eq_or_nil(field, nil), do: dynamic([r], is_nil(field(r, ^field)))
  defp eq_or_nil(field, value), do: dynamic([r], field(r, ^field) == ^value)

  defp all_rule_ids(organization, version) do
    Repo.all(
      from(r in FareRule,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        select: r.id
      )
    )
    |> MapSet.new()
  end

  defp delete_rule_rows(organization, version, fare_id) do
    Repo.delete_all(
      from(r in FareRule,
        where:
          r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id and
            r.fare_id == ^fare_id
      )
    )
  end

  defp set_status(organization, version, status) do
    Repo.update_all(
      from(v in GtfsVersion,
        where: v.id == ^version.id and v.organization_id == ^organization.id
      ),
      set: [
        publication_status: status,
        published_at: if(status == "published", do: DateTime.utc_now(), else: nil)
      ]
    )
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn {stop_id, stop_name, location_type, zone_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: location_type,
          zone_id: zone_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
  end

  defp insert_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_routes(organization, version, routes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(routes, fn route ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: route.route_id,
          route_type: 3,
          route_short_name: route.short_name,
          route_long_name: route.long_name,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Route, rows)
    assert count == length(rows)
  end

  defp insert_fares(organization, version, fares) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(fares, fn fare ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare.fare_id,
          price: Decimal.new(fare.price),
          currency_type: "USD",
          payment_method: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(FareAttribute, rows)
    assert count == length(rows)
  end

  # Rule rows carry their own IDs so a card ID can be computed from the fixture
  # rather than read back from the page.
  defp insert_rules(organization, version, rules) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(rules, fn {label, {fare_id, route_id, origin_id, destination_id, contains_id}} ->
        %{
          label: label,
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          route_id: route_id,
          origin_id: origin_id,
          destination_id: destination_id,
          contains_id: contains_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(FareRule, Enum.map(rows, &Map.delete(&1, :label)))
    assert count == length(rows)

    rows
    |> Enum.group_by(& &1.label, & &1.id)
    |> Map.new()
  end
end
