defmodule GtfsPlannerWeb.Gtfs.FaresLiveRulesTest do
  @moduledoc """
  Merge evidence (EV-22) for the Fare rules tab's rule list.

  Every case mounts the real route and reads the version's real `fare_rules` rows
  through the default `CatalogReadAdapter.Repo` adapter, so the cards come from
  `FareZones.list_rule_groups/2` and not from the component's own output. The
  fixture carries the shapes the criteria name: all four journey forms, a
  through-zone rule, a rule whose fare has no `fare_attributes` row, a rule whose
  route has no `routes` row, a long-name-only route, a rule that repeats its key,
  and rules that reference a zone with no boardable stops (an empty declared zone,
  a zone carried only by a station, and a zone no record declares).

  Each card's DOM ID is computed here from the row UUIDs the fixture inserted -
  `"fare-rule-" <> hd(Enum.sort(row_ids))` - so a card is found by the ID the
  contract names rather than by whatever the implementation rendered, and no
  assertion depends on a zone ID appearing in a DOM ID. Zone names and IDs are
  asserted from the inventory's own bytes, including an ID that holds a space.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @rules_path "/settings/fares/rules"

  # A card's DOM ID is its first row's own ID, never a zone ID. The pattern is
  # the contract, so an ID built from anything else fails the check below.
  @card_id_pattern ~r/\Afare-rule-[0-9a-fA-F-]{36}\z/

  # The fixture's 14 rule groups: two of them carry two rows each, so the tab
  # must render 14 cards from 16 rows.
  @group_count 14

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # Zone metadata is inserted directly, standing in for an imported feed: a
    # stored ID is byte-exact and never revalidated. "A" and "B" carry boardable
    # stops, " A" carries one boardable stop, "S" is carried only by a station,
    # and "D" is a declared zone with nothing in it.
    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Eastbank", "teal")
    insert_zone(organization, version, " A", "Padded", "plum")
    insert_zone(organization, version, "S", "Station only", "green")
    insert_zone(organization, version, "D", "Airport", "ochre")

    insert_stops(organization, version, [
      {"STOP_CENTRAL_1", 0, "A"},
      {"STOP_CENTRAL_2", 0, "A"},
      {"STOP_CENTRAL_STATION", 1, "A"},
      {"STOP_EASTBANK_1", 0, "B"},
      {"STOP_PADDED_1", 0, " A"},
      {"STOP_STATION_ONLY", 1, "S"}
    ])

    # "10 · Crosstown" and "20 · Riverside" carry both names, "ROUTE_EXPRESS"
    # only a long one, and no route row exists for the rule that names
    # "ROUTE_MISSING".
    insert_routes(organization, version, [
      %{route_id: "ROUTE_10", short_name: "10", long_name: "Crosstown"},
      %{route_id: "ROUTE_EXPRESS", short_name: nil, long_name: "Airport Express"}
    ])

    insert_fares(organization, version, [
      %{fare_id: "CITY", price: "2.50"},
      %{fare_id: "CROSS", price: "3.75"}
    ])

    rule_ids =
      insert_rules(organization, version, [
        # Two rows with the same key: one rule, and never two cards.
        {:city_a_b, {"CITY", nil, "A", "B", nil}},
        {:city_a_b, {"CITY", nil, "A", "B", nil}},
        {:city_route_10, {"CITY", "ROUTE_10", "A", "B", nil}},
        {:city_route_express, {"CITY", "ROUTE_EXPRESS", "A", "B", nil}},
        {:city_unknown_route, {"CITY", "ROUTE_MISSING", "A", "B", nil}},
        {:city_from_only, {"CITY", nil, "A", nil, nil}},
        {:city_to_only, {"CITY", nil, nil, "B", nil}},
        {:city_any_journey, {"CITY", nil, nil, nil, nil}},
        {:city_within_a, {"CITY", nil, "A", "A", nil}},
        # A declared zone with no stop of any kind, a zone carried only by a
        # station, and a zone no record declares: all three have stop_count 0.
        {:cross_airport, {"CROSS", nil, "D", "A", nil}},
        {:cross_station_only, {"CROSS", nil, "S", "A", nil}},
        {:city_undeclared_zone, {"CITY", nil, "Z ", "B", nil}},
        # An imported ID holding a space, declared as "Padded".
        {:city_padded, {"CITY", nil, " A", "B", nil}},
        # Two rows of one through-zone rule.
        {:cross_through, {"CROSS", nil, nil, nil, "A"}},
        {:cross_through, {"CROSS", nil, nil, nil, "B"}},
        # A fare with no fare_attributes row.
        {:gone_fare, {"GONE", nil, "A", "B", nil}}
      ])

    %{
      user: user,
      organization: organization,
      version: version,
      cards: Map.new(rule_ids, fn {label, row_ids} -> {label, card_id(row_ids)} end)
    }
  end

  describe "rule list" do
    test "renders one card per rule group with the fare, journey and route", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)
      doc = LazyHTML.from_fragment(render(view))

      assert card_ids(doc) |> length() == @group_count

      # The fare's own line: the fare ID with the price its row holds.
      assert has_element?(view, "##{cards.city_a_b}-fare", "CITY · $2.50")
      assert has_element?(view, "##{cards.gone_fare}-fare", "Unknown fare GONE")

      # All four journey forms, plus a rule whose ends are the same zone.
      assert has_element?(view, "##{cards.city_a_b}-journey", "From Central → Eastbank")

      assert has_element?(
               view,
               "##{cards.city_from_only}-journey",
               "From Central · Any destination"
             )

      assert has_element?(view, "##{cards.city_to_only}-journey", "Any origin → Eastbank")
      assert has_element?(view, "##{cards.city_any_journey}-journey", "Any journey")
      assert has_element?(view, "##{cards.city_within_a}-journey", "From Central → Central")

      # The route's own line, then how the journey reads.
      assert has_element?(view, "##{cards.city_a_b}-route", "All routes · One direction")
      assert has_element?(view, "##{cards.city_route_10}-route", "10 · Crosstown · One direction")

      assert has_element?(
               view,
               "##{cards.city_route_express}-route",
               "Airport Express · One direction"
             )

      assert has_element?(
               view,
               "##{cards.city_unknown_route}-route",
               "Unknown route ROUTE_MISSING · One direction"
             )

      assert has_element?(
               view,
               "##{cards.city_within_a}-route",
               "One direction · within the same zone"
             )

      assert has_element?(
               view,
               "##{cards.cross_through}-route",
               "Every listed zone must be visited"
             )
    end

    test "renders a rule's rows as one card and keeps rules with different keys apart", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)
      doc = LazyHTML.from_fragment(render(view))

      ids = card_ids(doc)

      # 16 rows, 14 rules: the duplicate row and the two through-zone rows never
      # become cards of their own, and the stream's IDs are unique.
      assert length(ids) == @group_count
      assert ids == Enum.uniq(ids)

      # The two-row rule renders once, with the zones it must visit named in the
      # order the domain sorted them, appended to the journey the rule applies to.
      assert has_element?(view, "##{cards.cross_through}-journey", "Through Central + Eastbank")

      assert LazyHTML.text(LazyHTML.query(doc, "##{cards.cross_through}-journey")) ==
               "Any journey · Through Central + Eastbank"

      # A through-zone rule and the same fare and route without one are two
      # rules, and the page renders both.
      refute cards.cross_through == cards.city_a_b
      assert has_element?(view, "##{cards.city_a_b}-journey", "From Central → Eastbank")
    end

    test "marks only the rules that reference a zone with no boardable stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      # A declared zone with nothing in it, a zone carried only by a station
      # (CR-5: only location_type 0 counts), and a zone no record declares.
      for card <- [cards.cross_airport, cards.cross_station_only, cards.city_undeclared_zone] do
        assert has_element?(view, "##{card}-stopless", "Zone used without stops")
      end

      for card <- [cards.city_a_b, cards.cross_through, cards.city_padded] do
        refute has_element?(view, "##{card}-stopless")
      end
    end

    test "names zones byte-for-byte, including an ID that holds a space", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)
      doc = LazyHTML.from_fragment(render(view))

      # A declared zone takes its record's name; an undeclared one is named by its
      # exact stored ID, so "Z " is not trimmed to "Z".
      assert LazyHTML.text(LazyHTML.query(doc, "##{cards.city_padded}-journey")) ==
               "From Padded → Eastbank"

      assert LazyHTML.text(LazyHTML.query(doc, "##{cards.city_undeclared_zone}-journey")) ==
               "From Z  → Eastbank"

      # The padded declared zone keeps its own bytes in the badge's rule: it has
      # a boardable stop, so it is not the rule the warning marks.
      refute has_element?(view, "##{cards.city_padded}-stopless")
    end

    test "streams the cards with DOM IDs built from their own rows, never from a zone ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)
      doc = LazyHTML.from_fragment(render(view))

      ids = card_ids(doc)

      assert Enum.all?(ids, &Regex.match?(@card_id_pattern, &1))

      # Every card is the ID its own first sorted row gives it, and the elements
      # inside a card hang off that ID, so a zone ID never names a DOM node.
      assert MapSet.new(ids) == MapSet.new(Map.values(cards))

      panel_ids = LazyHTML.attribute(LazyHTML.query(doc, "#fare-rules-panel [id]"), "id")
      inner_pattern = ~r/\Afare-rule-[0-9a-fA-F-]{36}-(fare|journey|route|stopless)\z/

      assert panel_ids != []

      assert Enum.all?(panel_ids, fn id ->
               Regex.match?(@card_id_pattern, id) or Regex.match?(inner_pattern, id)
             end)
    end

    test "renders the intro callout and the footer note on the tab", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      cards: cards
    } do
      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      assert has_element?(view, "#fare-rules-intro", "Define the journey, then choose the fare.")

      assert has_element?(
               view,
               "#fare-rules-intro",
               "Use existing fares. Prices and payment settings are managed separately."
             )

      assert has_element?(
               view,
               "#fare-rules-note",
               "“Any origin” and “Any destination” leave that end of the journey unrestricted. A reverse journey needs its own rule."
             )

      # The intro and the note are not rules: they render beside the cards.
      assert has_element?(view, "##{cards.city_a_b}")
      refute has_element?(view, "#fare-rules-empty")
    end

    test "renders the empty state when the version has no rules", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      # A version with a zone but no fare_rules row: the tab's own empty state,
      # not the Zones tab's first use.
      empty_version = gtfs_version_fixture(organization.id, %{name: "No rules version"})
      insert_zone(organization, empty_version, "A", "Central", "ocean")
      insert_stops(organization, empty_version, [{"STOP_ONLY", 0, "A"}])

      {:ok, view, _html} = mount_rules(conn, user, organization, empty_version)

      assert has_element?(view, "#fare-rules-empty", "No fare rules yet")

      assert has_element?(
               view,
               "#fare-rules-empty",
               "Add a rule to charge a fare for journeys between zones."
             )

      refute has_element?(view, "#fare-rule-list")
    end

    test "renders only this version's rules", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      twin_version = gtfs_version_fixture(organization.id, %{name: "Twin rules version"})

      twin_ids =
        insert_rules(organization, twin_version, [
          {:twin, {"CITY", nil, "A", "B", nil}},
          {:twin_only, {"TWIN", nil, "A", "B", nil}}
        ])

      {:ok, view, _html} = mount_rules(conn, user, organization, version)

      # The twin version holds a rule with the same natural key as one of this
      # version's rules and one fare this version does not have; neither shows.
      refute has_element?(view, "#fare-rule-list", "TWIN")
      refute has_element?(view, "##{card_id(twin_ids.twin)}")
      refute has_element?(view, "##{card_id(twin_ids.twin_only)}")
      assert has_element?(view, "#fare-rule-list article")
    end
  end

  describe "rule order" do
    test "renders the rules in the order the workspace read returns them", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      order_version = gtfs_version_fixture(organization.id, %{name: "Order version"})

      rule_ids =
        insert_rules(organization, order_version, [
          {:c_origin, {"CITY", nil, "C", "A", nil}},
          {:a_origin, {"CITY", nil, "A", "A", nil}}
        ])

      {:ok, view, _html} = mount_rules(conn, user, organization, order_version)
      doc = LazyHTML.from_fragment(render(view))

      # `list_rule_groups/2` sorts by fare, then origin, destination, route and
      # through-zone presence; the page renders that order rather than its own.
      assert card_ids(doc) == [card_id(rule_ids.a_origin), card_id(rule_ids.c_origin)]
    end
  end

  defp mount_rules(conn, user, organization, version) do
    conn
    |> log_in_user(user, organization: organization)
    |> live("/gtfs/#{version.id}#{@rules_path}")
  end

  defp card_ids(doc) do
    doc |> LazyHTML.query("#fare-rule-list article") |> LazyHTML.attribute("id")
  end

  defp card_id(row_ids), do: "fare-rule-" <> Enum.min(row_ids)

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn {stop_id, location_type, zone_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop_id,
          stop_name: "Stop #{stop_id}",
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

  # Rule rows are inserted with exact values and their own IDs, so a test can
  # compute the card ID a group must render from the rows it wrote. The labels
  # group the rows the way a UI rule does, which is what lets one label carry two
  # rows.
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
