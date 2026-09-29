defmodule GtfsPlannerWeb.Gtfs.FaresLiveChecksTest do
  @moduledoc """
  Merge evidence (EV-24) for the Checks tab.

  Every case mounts the real route and reads the version's real rows through the
  default `CatalogReadAdapter.Repo` adapter, so each row comes from
  `FareZones.checks/2` over the version's own `fare_zones`, `stops` and
  `fare_rules` data, not from the component's output. The fixture carries the
  shapes the acceptance criteria name: an undeclared zone a fare rule references
  with no stops at all, a declared zone carried only by a station (which must
  still read as stopless, CR-5), a declared zone with nothing in it, boardable
  stops without a zone, and a rule that references no zone at all - so the
  conditional Source check row has both a present and an absent case.

  The tab's DOM IDs are asserted against the contract rather than the render: rows
  are named by their index and links by the row they act for, so no DOM ID carries
  a zone ID (CR-7). Links are read as the page rendered them and patched through
  that exact href, so the test cannot pass by encoding a zone ID its own way; the
  byte-exact case keeps a stored ID holding a space and a stopless zone whose ID is
  literally `unassigned`, which proves `zone` stays a separate query key from
  `filter`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @checks_path "/settings/fares/checks"
  @zones_path "/settings/fares"

  # Every DOM ID the Checks tab may render: the tab and its heading, one row per
  # index, and one link or disclosure inside a row. Nothing here is derived from
  # a zone ID.
  @panel_id_pattern ~r/\Afare-check(s-(tab|heading|subtitle|counts|count-(repair|review|note|passed)|passed(-summary)?)|-(clean|unassigned|empty|source|stopless-\d+|combine-\d+)(-link|-detail|-zone-id|-export)?|-empty-\d+-link)?\z/

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # "A" Central carries boardable stops, "D" Airport is declared with nothing in
    # it, and "S" Southport is declared and carried only by a station - so it has
    # no boardable stop and a rule that references it is a needs-repair row (CR-5).
    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "D", "Airport", "ochre")
    insert_zone(organization, version, "S", "Southport", "teal")

    insert_stops(organization, version, [
      {"STOP_CENTRAL_1", 0, "A"},
      {"STOP_CENTRAL_2", 0, "A"},
      {"STOP_BAY_1", 0, nil},
      {"STOP_BAY_2", 0, nil},
      {"STOP_BAY_3", 0, nil},
      {"STOP_BAY_4", 0, nil},
      {"STOP_SOUTHPORT_STATION", 1, "S"}
    ])

    # "C" is referenced by a rule and declared by nothing: a stopless referenced
    # zone with no record. "S" is declared and stopless. The last rule references
    # no zone at all, so `rules_reference_zones?` is true because of the other
    # three, not because every rule uses a zone.
    insert_rules(organization, version, [
      {"CITY", nil, "A", "A", nil},
      {"CITY", nil, "C", "A", nil},
      {"CROSS", nil, "S", "A", nil},
      {"CITY", nil, nil, nil, nil}
    ])

    %{user: user, organization: organization, version: version}
  end

  describe "issue rows" do
    test "lists one Needs repair row per stopless referenced zone, with its copy and link", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      # Two zones fare rules use have no boardable stops: the undeclared "C" and
      # the declared station-only "S", in the inventory's sort order.
      assert stopless_row_ids(view) == ["fare-check-stopless-0", "fare-check-stopless-1"]

      assert has_element?(
               view,
               "#fare-check-stopless-0",
               "Fare rules use C, which has no stops"
             )

      assert has_element?(
               view,
               "#fare-check-stopless-0",
               "Trip planners can’t match any stop to this zone, so the fares that use it never apply. Assign stops to the zone or change the rules that use it."
             )

      assert has_element?(view, "#fare-check-stopless-0", "Needs repair")

      # An undeclared zone is named by its ID already, so the row states no second
      # one.
      refute has_element?(view, "#fare-check-stopless-0-zone-id")

      # A declared stopless zone is named by its record, with its exact ID beside
      # the name as the detail that travels with the feed.
      assert has_element?(
               view,
               "#fare-check-stopless-1",
               "Fare rules use Southport, which has no stops"
             )

      assert has_element?(view, "#fare-check-stopless-1-zone-id", "Zone ID S")

      # The action names the zone the way the row does.
      assert has_element?(view, "#fare-check-stopless-0-link", "Show C")
      assert has_element?(view, "#fare-check-stopless-1-link", "Show Southport")

      # Each row's link opens that zone's own filter in the Zones tab.
      assert row_href(view, "#fare-check-stopless-0-link") ==
               "/gtfs/#{version.id}#{@zones_path}?zone=C"

      assert row_href(view, "#fare-check-stopless-1-link") ==
               "/gtfs/#{version.id}#{@zones_path}?zone=S"

      # The zone with stops and the rule that references no zone produce no row.
      refute has_element?(view, "#fare-checks-tab", "Fare rules use Central")
      refute has_element?(view, "#fare-checks-tab", "Fare rules use A")
    end

    test "states the unassigned stop count and links to the unassigned filter", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      assert has_element?(view, "#fare-check-unassigned", "Review")
      assert has_element?(view, "#fare-check-unassigned", "4 stops have no fare zone")

      assert has_element?(
               view,
               "#fare-check-unassigned",
               "Journeys that use these stops won’t get a zone-based fare."
             )

      assert has_element?(view, "#fare-check-unassigned-link", "Review stops with no zone")

      # The filter is its own query key: patching this link asks for unassigned
      # stops, not for a zone named "unassigned".
      assert row_href(view, "#fare-check-unassigned-link") ==
               "/gtfs/#{version.id}#{@zones_path}?filter=unassigned"

      # The four stations/entrances in zone "S" are not unassigned stops (CR-5):
      # the count is the four boardable rows with no zone and nothing else.
      refute has_element?(view, "#fare-check-unassigned", "5 stops")
    end

    test "states the empty declared zone count in the singular", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      # "D" Airport is declared and has nothing in it; "S" is declared but a rule
      # references it, so it is a needs-repair row rather than a note.
      assert has_element?(view, "#fare-check-empty", "Note")
      assert has_element?(view, "#fare-check-empty", "1 empty zone: Airport")

      assert has_element?(
               view,
               "#fare-check-empty",
               "Empty zones stay in this workspace. Your feed records zones on stops, so a zone with no stops isn’t exported."
             )

      # A note asks for nothing, but it names where the zone is: one link per empty
      # zone, into that zone's own filter.
      assert has_element?(view, "#fare-check-empty-0-link", "Show Airport")

      assert row_href(view, "#fare-check-empty-0-link") ==
               "/gtfs/#{version.id}#{@zones_path}?zone=D"
    end

    test "counts every empty declared zone when more than one has nothing in it", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      empty_version = gtfs_version_fixture(organization.id, %{name: "Two empty zones version"})

      # A declared zone with no stops and no rules, and a declared zone carried
      # only by a station: both are empty declared zones.
      insert_zone(organization, empty_version, "D", "Airport", "ochre")
      insert_zone(organization, empty_version, "P", "Pier", "plum")
      insert_stops(organization, empty_version, [{"STOP_PIER_GATE", 1, "P"}])

      {:ok, view, _html} = mount_checks(conn, user, organization, empty_version)

      assert has_element?(view, "#fare-check-empty", "2 empty zones: Airport and Pier")
      refute has_element?(view, "#fare-check-empty", "1 empty zone")
    end

    test "states one unassigned stop in the singular", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      one_version = gtfs_version_fixture(organization.id, %{name: "One unassigned version"})

      insert_zone(organization, one_version, "A", "Central", "ocean")

      insert_stops(organization, one_version, [{"STOP_CENTRAL_1", 0, "A"}, {"STOP_BAY_1", 0, nil}])

      {:ok, view, _html} = mount_checks(conn, user, organization, one_version)

      assert has_element?(view, "#fare-check-unassigned", "1 stop has no fare zone")
      refute has_element?(view, "#fare-check-unassigned", "1 stops have no fare zone")

      assert has_element?(view, "#fares-checks-count", "1")
    end

    test "renders the Source check row only while fare rules reference zones", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      assert has_element?(view, "#fare-check-source", "Source check")

      assert has_element?(
               view,
               "#fare-check-source",
               "Compare zone assignments with your source feed"
             )

      assert has_element?(
               view,
               "#fare-check-source",
               "If this version was imported before stop zone IDs were kept, some stops may have lost their zones. Fare rules alone can’t show which stops belonged to which zone."
             )

      # The disclosure states what to compare, and stays a native `<details>` so
      # it is keyboard-operable without new markup.
      assert has_element?(view, "#fare-check-source-detail", "What to compare")

      assert has_element?(
               view,
               "#fare-check-source-detail",
               "Check that each stop has the same zone as in your original feed. Importing the original feed again creates a new version that keeps its stop zones."
             )

      # A version whose only rule references no zone has nothing to check against
      # a source feed, so the row is absent.
      no_reference_version =
        gtfs_version_fixture(organization.id, %{name: "No zone references version"})

      insert_zone(organization, no_reference_version, "A", "Central", "ocean")
      insert_stops(organization, no_reference_version, [{"STOP_CENTRAL_1", 0, "A"}])
      insert_rules(organization, no_reference_version, [{"CITY", nil, nil, nil, nil}])

      {:ok, no_reference_view, _html} =
        mount_checks(conn, user, organization, no_reference_version)

      refute has_element?(no_reference_view, "#fare-check-source")
      assert has_element?(no_reference_view, "#fare-check-clean")

      # A version with no rules at all has none either.
      empty_version = gtfs_version_fixture(organization.id, %{name: "No rules at all version"})

      {:ok, empty_view, _html} = mount_checks(conn, user, organization, empty_version)

      refute has_element?(empty_view, "#fare-check-source")
    end
  end

  describe "fares whose rules trip planners combine" do
    setup %{organization: organization} do
      combine_version = gtfs_version_fixture(organization.id, %{name: "Combined rules version"})

      # Two zones with stops and no unassigned stop, so the only issues are the
      # fares below. CITY names a route on one of its rules, CROSS lists through
      # zones on one of its rules, and LOCAL's rules agree.
      insert_zone(organization, combine_version, "A", "Central", "ocean")
      insert_zone(organization, combine_version, "B", "Uplands", "teal")

      insert_stops(organization, combine_version, [
        {"STOP_CENTRAL_1", 0, "A"},
        {"STOP_UPLANDS_1", 0, "B"}
      ])

      insert_rules(organization, combine_version, [
        {"CITY", nil, "A", "A", nil},
        {"CITY", "R1", "B", "A", nil},
        {"CROSS", nil, "A", "B", nil},
        {"CROSS", nil, "B", "A", "A"},
        {"CROSS", nil, "B", "A", "B"},
        {"LOCAL", "R1", "A", "A", nil},
        {"LOCAL", "R1", "A", "B", nil}
      ])

      %{combine_version: combine_version}
    end

    test "lists one Review row per disagreeing fare and names only what disagrees", %{
      conn: conn,
      user: user,
      organization: organization,
      combine_version: combine_version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, combine_version)

      assert has_element?(
               view,
               "#fare-check-combine-0",
               "Rules for fare CITY combine in trip planners"
             )

      assert has_element?(view, "#fare-check-combine-0", "Review")

      assert has_element?(
               view,
               "#fare-check-combine-0",
               "This fare names route R1 on some rules, so every rule of the fare applies only on that route."
             )

      refute has_element?(view, "#fare-check-combine-0", "pass-through")

      assert has_element?(
               view,
               "#fare-check-combine-1",
               "Rules for fare CROSS combine in trip planners"
             )

      assert has_element?(
               view,
               "#fare-check-combine-1",
               "This fare lists pass-through zones A, B across its rules, so every rule of the fare requires a journey that touches exactly those zones."
             )

      refute has_element?(view, "#fare-check-combine-1", "names route")

      # LOCAL's rules share one route, so it has no row.
      refute has_element?(view, "#fare-check-combine-2")
      refute has_element?(view, "#fare-checks-tab", "fare LOCAL")
    end

    test "counts the rows in the tab badge and replaces the all-clear line", %{
      conn: conn,
      user: user,
      organization: organization,
      combine_version: combine_version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, combine_version)

      refute has_element?(view, "#fare-check-clean")
      assert badge_count(view) == 2
    end

    test "adds no row to a version whose fares agree", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      refute has_element?(view, "#fare-check-combine-0")
    end
  end

  describe "all-clear line" do
    test "replaces the Needs repair and Review rows when both are clean", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      clean_version = gtfs_version_fixture(organization.id, %{name: "Clean version"})

      # One zone with stops, one rule that uses it, and no stop without a zone.
      insert_zone(organization, clean_version, "A", "Central", "ocean")
      insert_stops(organization, clean_version, [{"STOP_CENTRAL_1", 0, "A"}])
      insert_rules(organization, clean_version, [{"CITY", nil, "A", "A", nil}])

      {:ok, view, _html} = mount_checks(conn, user, organization, clean_version)

      assert has_element?(
               view,
               "#fare-check-clean",
               "Every zone used by a fare rule has stops, and every stop has a fare zone."
             )

      assert stopless_row_ids(view) == []
      refute has_element?(view, "#fare-check-unassigned")

      # The clean line states membership and references, not the whole setup: the
      # Source check row still reports while rules reference zones.
      assert has_element?(view, "#fare-check-source")
      refute has_element?(view, "#fare-check-empty")

      # The four counts read the same rows, and the checks that passed fold into
      # one disclosure that names each of them.
      assert has_element?(view, "#fare-checks-count-repair", "0")
      assert has_element?(view, "#fare-checks-count-review", "0")
      assert has_element?(view, "#fare-checks-count-passed", "4")
      assert has_element?(view, "#fare-checks-passed-summary", "4 checks passed")

      assert has_element?(
               view,
               "#fare-checks-passed",
               "Every zone used by a fare rule has stops."
             )

      assert has_element?(view, "#fare-checks-passed", "Every stop has a fare zone.")
      assert has_element?(view, "#fare-checks-passed", "No zone is empty.")

      assert has_element?(
               view,
               "#fare-checks-passed",
               "No fare has rules that disagree on route or pass-through zones."
             )

      # A clean version points on to export.
      assert row_href(view, "#fare-check-clean-export") == "/gtfs/#{clean_version.id}/export"
    end

    test "is the whole Checks tab for a version with no zones, stops or rules", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      bare_version = gtfs_version_fixture(organization.id, %{name: "Bare version"})

      {:ok, view, _html} = mount_checks(conn, user, organization, bare_version)

      assert has_element?(
               view,
               "#fare-check-clean",
               "Every zone used by a fare rule has stops, and every stop has a fare zone."
             )

      assert stopless_row_ids(view) == []
      refute has_element?(view, "#fare-check-unassigned")
      refute has_element?(view, "#fare-check-empty")
      refute has_element?(view, "#fare-check-source")
      assert has_element?(view, "#fares-checks-count", "0")
    end
  end

  describe "tab badge" do
    test "equals the Needs repair rows plus the Review row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      # Two stopless referenced zones and one unassigned-stops row.
      assert has_element?(view, "#fares-tab-checks #fares-checks-count", "3")

      rows = length(stopless_row_ids(view))
      review = if has_element?(view, "#fare-check-unassigned"), do: 1, else: 0

      assert badge_count(view) == rows + review

      # A zone fare rules use with no stops needs repair, so the count reads in the
      # error tone; a clean one reads as available rather than reusing it.
      assert badge_class(view) =~ "text-error-fg"
    end

    test "carries the same count on the other two tabs", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, zones_view, _html} = mount_zones(conn, user, organization, version)
      assert has_element?(zones_view, "#fares-tab-checks #fares-checks-count", "3")

      {:ok, rules_view, _html} = mount_rules(conn, user, organization, version)
      assert has_element?(rules_view, "#fares-tab-checks #fares-checks-count", "3")
    end

    test "reads as a warning while only stops with no zone need review", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      review_version = gtfs_version_fixture(organization.id, %{name: "Review only version"})

      insert_zone(organization, review_version, "A", "Central", "ocean")

      insert_stops(organization, review_version, [
        {"STOP_CENTRAL_1", 0, "A"},
        {"STOP_BAY_1", 0, nil}
      ])

      {:ok, view, _html} = mount_checks(conn, user, organization, review_version)

      # Nothing needs repair, so the one finding is a review and the mark says so
      # in the warning tone, not the error one.
      assert has_element?(view, "#fares-checks-count", "1")
      assert badge_class(view) =~ "text-warning-fg"
      refute badge_class(view) =~ "text-error-fg"

      assert has_element?(view, "#fare-checks-count-review", "1")
      assert has_element?(view, "#fare-checks-count-repair", "0")
    end

    test "marks a clean version's zero as available", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      clean_version = gtfs_version_fixture(organization.id, %{name: "Clean badge version"})

      {:ok, view, _html} = mount_checks(conn, user, organization, clean_version)

      assert has_element?(view, "#fares-checks-count", "0")
      assert badge_class(view) =~ "text-success"
    end
  end

  describe "identity and scope" do
    test "keeps a zone ID's exact bytes in the row and its link, and never in a DOM ID", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      # A stored ID holding a space is never trimmed, and a stopless zone whose ID
      # is literally "unassigned" must still link with the `zone` key.
      exact_version = gtfs_version_fixture(organization.id, %{name: "Exact IDs version"})

      insert_zone(organization, exact_version, "A", "Central", "ocean")
      insert_stops(organization, exact_version, [{"STOP_CENTRAL_1", 0, "A"}])

      insert_rules(organization, exact_version, [
        {"CITY", nil, "Z ", "A", nil},
        {"CITY", nil, "unassigned", "A", nil}
      ])

      {:ok, view, _html} = mount_checks(conn, user, organization, exact_version)
      doc = LazyHTML.from_fragment(render(view))

      # Sorted by the stored bytes: "Z " before "unassigned".
      assert stopless_row_ids(view) == ["fare-check-stopless-0", "fare-check-stopless-1"]

      # The two spaces the padded ID leaves are asserted from the element's own
      # text, because `has_element?/3` normalizes whitespace before matching.
      assert element_text(view, "#fare-check-stopless-0 h3") ==
               "Fare rules use Z , which has no stops"

      assert has_element?(
               view,
               "#fare-check-stopless-1",
               "Fare rules use unassigned, which has no stops"
             )

      # Both IDs survive into the query string unchanged; "unassigned" travels
      # under the `zone` key, so it cannot be read as the unassigned filter.
      assert row_href(view, "#fare-check-stopless-0-link") ==
               "/gtfs/#{exact_version.id}#{@zones_path}?zone=Z+"

      assert row_href(view, "#fare-check-stopless-1-link") ==
               "/gtfs/#{exact_version.id}#{@zones_path}?zone=unassigned"

      # Patching the padded ID's own link keeps the filter on that exact zone:
      # the stage names the ID's stored bytes, not a trimmed version of them.
      render_patch(view, row_href(view, "#fare-check-stopless-0-link"))

      assert has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-checks-panel")

      assert element_text(view, "#fare-zone-stage-subtitle") ==
               "0 stops · Empty zone · used by 1 fare rule · Zone ID Z "

      # The zone literally named "unassigned" opens that zone, not the unassigned
      # stops filter (CR-7).
      render_patch(view, "/gtfs/#{exact_version.id}#{@zones_path}?zone=unassigned")

      assert element_text(view, "#fare-zone-stage-subtitle") ==
               "0 stops · Empty zone · used by 1 fare rule · Zone ID unassigned"

      refute has_element?(view, "#fare-zone-stage-title", "Stops with no zone")

      # Every ID in the panel is the contract's own vocabulary, so no zone ID
      # names a DOM node: the set is exactly the rows this version renders.
      panel_ids = LazyHTML.attribute(LazyHTML.query(doc, "#fare-checks-panel [id]"), "id")

      assert Enum.all?(panel_ids, &Regex.match?(@panel_id_pattern, &1))

      assert panel_ids == [
               "fare-checks-tab",
               "fare-checks-heading",
               "fare-checks-subtitle",
               "fare-checks-counts",
               "fare-checks-count-repair",
               "fare-checks-count-review",
               "fare-checks-count-note",
               "fare-checks-count-passed",
               "fare-check-stopless-0",
               "fare-check-stopless-0-link",
               "fare-check-stopless-1",
               "fare-check-stopless-1-link",
               "fare-check-source",
               "fare-check-source-detail",
               "fare-checks-passed",
               "fare-checks-passed-summary"
             ]
    end

    test "renders only this version's checks", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      twin_version = gtfs_version_fixture(organization.id, %{name: "Twin checks version"})
      insert_rules(organization, twin_version, [{"CITY", nil, "T", "A", nil}])

      {:ok, view, _html} = mount_checks(conn, user, organization, version)

      # The twin version's stopless referenced zone is not this version's.
      refute has_element?(view, "#fare-checks-tab", "Fare rules use T,")
      assert has_element?(view, "#fare-check-stopless-0", "Fare rules use C,")
    end
  end

  defp mount_checks(conn, user, organization, version) do
    mount_tab(conn, user, organization, version, @checks_path)
  end

  defp mount_zones(conn, user, organization, version) do
    mount_tab(conn, user, organization, version, @zones_path)
  end

  defp mount_rules(conn, user, organization, version) do
    mount_tab(conn, user, organization, version, "#{@zones_path}/rules")
  end

  defp mount_tab(conn, user, organization, version, path) do
    conn
    |> log_in_user(user, organization: organization)
    |> live("/gtfs/#{version.id}#{path}")
  end

  # The rendered href of one link. The tab owns the encoding, so the test reads
  # what the page wrote rather than building the query itself.
  defp row_href(view, selector) do
    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  # The exact rendered text of one element. `has_element?/3` collapses whitespace
  # before matching, so a stored ID's own bytes are asserted from this instead.
  defp element_text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
  end

  defp stopless_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fare-checks-panel [id]")
    |> LazyHTML.attribute("id")
    |> Enum.filter(&Regex.match?(~r/\Afare-check-stopless-\d+\z/, &1))
  end

  defp badge_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fares-checks-count")
    |> LazyHTML.text()
    |> String.trim()
    |> String.to_integer()
  end

  defp badge_class(view) do
    [class] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#fares-checks-count")
      |> LazyHTML.attribute("class")

    class
  end

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

  # Rule rows are inserted with exact values, never through `FareRule.changeset/2`,
  # so a rule can reference a zone ID the workspace's own validation would refuse
  # to create - which is exactly the imported state the Checks tab reports.
  defp insert_rules(organization, version, rules) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(rules, fn {fare_id, route_id, origin_id, destination_id, contains_id} ->
        %{
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

    {count, nil} = Repo.insert_all(FareRule, rows)
    assert count == length(rows)
  end
end
