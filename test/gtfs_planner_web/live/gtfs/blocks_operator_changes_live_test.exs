defmodule GtfsPlannerWeb.Gtfs.BlocksOperatorChangesLiveTest do
  # EV-35, rejecting FH-35 for CL-35: the Operator changes drawer as a planner
  # sets it up — the limit, the day's candidate stops and stations with their
  # waits, a mark, and a limit that is turned off — read through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back; nothing here substitutes an adapter, a context or
  # a hand-built candidate.
  #
  # The fixture is the reference's own block 102 at its own geometry, with
  # Riverside Station a real station: two bays that name the station as their
  # `parent_station`, so marking it once covers both (AC-4, R5). One block of two
  # trips runs 06:00–08:00 — two hours — and the 06:30 → 07:30 connection is a
  # 3-minute drive and a 57-minute wait at the station, so with a 60-minute limit
  # the block's only stretch is 2 h and it is over the limit until the station is
  # marked: the destination window of that drive then opens a change at 07:00 and
  # both stretches are exactly 60 min, which the check does not report. The
  # candidates, their waits and their order are the ones
  # `Gtfs.list_relief_candidates/3` derives from that day.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_operator_changes_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    route = route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    # Riverside Station is a station with two bays, not two stops that happen to
    # share a name: the children name it as their `parent_station`, which is what
    # makes one mark cover both and what puts "Station · covers Bay A and Bay B"
    # on the drawer's row. Market Square sits north of the station, so the 06:30
    # → 07:30 connection is a real drive rather than a layover.
    stop_with_coordinates_fixture(organization.id, version.id, %{
      stop_id: "AB_RS",
      stop_name: "Riverside Station",
      stop_lat: Decimal.new("40.0100"),
      stop_lon: Decimal.new("-74.0000")
    })

    for {stop_id, stop_name, lat, parent} <- [
          {"AB_RS_A", "Bay A", "40.0100", "AB_RS"},
          {"AB_RS_B", "Bay B", "40.0100", "AB_RS"},
          {"AB_VALLEY", "Valley College", "40.0200", nil},
          {"AB_MKT", "Market Square", "40.0670", nil}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: stop_name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0000"),
        parent_station: parent
      })
    end

    %{
      organization: organization,
      user: user,
      version: version,
      route: route
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  # The reference's block 102: out of Riverside Station at 06:00, back into it at
  # 06:30, away again at 07:30 and into Market Square at 08:00.
  defp block_102!(context) do
    first =
      trip!(context, %{
        trip_id: "6101",
        first_stop: "AB_RS_A",
        last_stop: "AB_VALLEY",
        first: "06:00:00",
        last: "06:30:00"
      })

    second =
      trip!(context, %{
        trip_id: "6102",
        first_stop: "AB_RS_B",
        last_stop: "AB_MKT",
        first: "07:30:00",
        last: "08:00:00"
      })

    %{first: first, second: second}
  end

  defp trip!(context, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first)
    {last, attrs} = Map.pop(attrs, :last)

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      %{service_id: "WK", block_id: "102", first_stop: "AB_RS_A", last_stop: "AB_VALLEY"}
      |> Map.merge(attrs)
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_departure, last)
    )
  end

  # A stored limit turns the operator-change checks on, so the day carries the
  # `:no_relief_opportunity` finding this step's links open.
  defp relief_limit!(context, minutes) do
    assert {:ok, :ok} =
             Gtfs.update_relief_settings(
               context.organization.id,
               context.version.id,
               nil,
               %{max_piece_minutes: minutes, marked: []}
             )
  end

  # The stored limit and marks, as this transaction can see them: the drawer's
  # writes are the only ones in the case, so these are the write count read from
  # the rolled-back rows rather than from a mock.
  defp stored_limit(context) do
    Repo.one(
      from setting in BlockingSetting,
        where: setting.gtfs_version_id == ^context.version.id,
        select: setting.max_piece_minutes
    )
  end

  defp stored_marks(context) do
    Repo.all(
      from mark in ReliefPoint,
        where: mark.gtfs_version_id == ^context.version.id,
        select: mark.stop_id,
        order_by: [asc: mark.stop_id]
    )
  end

  defp open_drawer(view),
    do: view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

  # The drawer's own button, once the Plan summary is closed again.
  defp open_operator_drawer(view),
    do: view |> element("#plan-summary-relief-open") |> render_click()

  defp table_cells(view) do
    view
    |> doc()
    |> LazyHTML.query("#operator-changes tr")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("td")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
    end)
  end

  defp column(cells, index), do: Enum.map(cells, &Enum.at(&1, index))

  defp limit_value(view) do
    view
    |> doc()
    |> LazyHTML.query("#operator-changes-limit")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp limit_invalid(view) do
    view
    |> doc()
    |> LazyHTML.query("#operator-changes-limit")
    |> LazyHTML.attribute("aria-invalid")
    |> List.first()
  end

  defp checked_stops(view) do
    view
    |> doc()
    |> LazyHTML.query("#operator-changes input[type='checkbox']")
    |> Enum.filter(&(&1 |> LazyHTML.attribute("checked") |> List.first() == ""))
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first()))
  end

  describe "the links that open the drawer" do
    test "with no limit the Plan summary offers to set the checks up", context do
      block_102!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      assert has_element?(view, "#plan-summary-relief-off", "Not checked.")
      assert has_element?(view, "#plan-summary-relief-open", "Set up operator checks")

      open_operator_drawer(view)

      # A page drawer over the Plan summary rather than a second open panel.
      assert has_element?(view, "#operator-changes-drawer-overlay[data-open='true']")
      refute has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")
    end

    test "with a limit the same link offers to review them", context do
      block_102!(context)
      relief_limit!(context, 60)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      assert has_element?(view, "#plan-summary-relief-open", "Review operator changes")

      open_operator_drawer(view)

      assert has_element?(view, "#operator-changes-drawer-overlay[data-open='true']")
    end

    test "a No operator change callout in the block drawer offers the same drawer",
         context do
      block_102!(context)
      relief_limit!(context, 60)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), base <> "?block=102")

      assert has_element?(view, "#block-drawer", "Block 102")

      assert has_element?(
               view,
               "[data-role=block-open-operator-changes]",
               "Review operator changes"
             )

      view |> element("[data-role=block-open-operator-changes]") |> render_click()

      assert_patch(view, base <> "?drawer=operator_changes")
      assert has_element?(view, "#operator-changes-drawer-overlay[data-open='true']")
    end
  end

  describe "the drawer" do
    test "it lists the day's candidates with their waits, and pre-fills 330", context do
      block_102!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)
      open_operator_drawer(view)

      assert has_element?(view, "#operator-changes-drawer", "Operator changes")
      assert has_element?(view, "#operator-changes-scope", "This version · every day type")

      assert has_element?(
               view,
               "#operator-changes-intro",
               "A block longer than one operator’s shift needs a stop"
             )

      # The shared `input` renders its label as a wrapping `<span>` rather than a
      # labelled id, so the label is asserted on the form that holds it and the
      # help on the id the component derives for its own `aria-describedby`.
      assert has_element?(
               view,
               "form#operator-changes-form",
               "Longest time before an operator change (min)"
             )

      assert has_element?(
               view,
               "#operator-changes-limit-help",
               "Blank turns these checks off. 330 min is 5½ hours"
             )

      # The context's own order: waits descending, then name. The station's wait
      # and Valley College's are the two ends of the one feasible gap, and Market
      # Square is a candidate because a trip ends there — with no wait at all.
      assert column(table_cells(view), 0) == [
               "Riverside Station Station · covers Bay A and Bay B",
               "Valley College",
               "Market Square"
             ]

      assert column(table_cells(view), 1) == ["1", "1", "0"]

      # With no stored limit the field is pre-filled with the researched common
      # contract limit rather than blank, because blank is a real answer.
      assert limit_value(view) == "330"
      assert checked_stops(view) == []
    end

    test "a stored limit and its marks are what the drawer shows", context do
      block_102!(context)
      relief_limit!(context, 90)
      relief_point_fixture(context.organization.id, context.version.id, %{stop_id: "AB_RS"})

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)
      open_operator_drawer(view)

      assert limit_value(view) == "90"
      # The station's own row is the marked one: marking a station is one mark
      # that covers its bays, not one mark per bay (AC-4).
      assert checked_stops(view) == ["AB_RS"]
    end

    test "marking the station clears the block's No operator change and says so",
         context do
      block_102!(context)
      relief_limit!(context, 60)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), base)

      # Two hours with no place to change operators is the day's own finding, and
      # the timeline row carries it.
      assert has_element?(view, "#block-MTAy", "No operator change")

      open_drawer(view)
      open_operator_drawer(view)

      view
      |> form("#operator-changes-form", limit: "60", marked: ["AB_RS"])
      |> render_submit()

      # One write: the limit the reader sent and the one station they ticked.
      assert stored_limit(context) == 60
      assert stored_marks(context) == ["AB_RS"]
      assert render(view) =~ "Operator changes saved"

      # The save closes the drawer, so the flash is readable and the day behind it
      # is redrawn from the stored answer: the stretch is now two 60-minute runs.
      assert_patch(view, base)
      refute has_element?(view, "#operator-changes-drawer-overlay[data-open='true']")
      refute has_element?(view, "#block-MTAy", "No operator change")
    end

    test "a limit under the range is refused and every tick is kept", context do
      block_102!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)
      open_operator_drawer(view)

      view
      |> form("#operator-changes-form", limit: "30", marked: ["AB_VALLEY"])
      |> render_submit()

      # Nothing is written: one refused value does not store the marks beside it.
      assert stored_limit(context) == nil
      assert stored_marks(context) == []

      assert has_element?(
               view,
               "#operator-changes-limit-error",
               "Enter a whole number from 60 to 720, or leave it blank."
             )

      assert limit_value(view) == "30"
      assert checked_stops(view) == ["AB_VALLEY"]

      # The field is the drawer's own focus target: the shared component marked it
      # invalid, so focus lands on the field rather than on the summary above it.
      assert limit_invalid(view) == "true"
    end

    test "a limit over the range and a value that is not a whole number are refused the same way",
         context do
      block_102!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)
      open_operator_drawer(view)

      view |> form("#operator-changes-form", limit: "900") |> render_submit()

      assert has_element?(
               view,
               "#operator-changes-limit-error",
               "Enter a whole number from 60 to 720, or leave it blank."
             )

      assert stored_limit(context) == nil

      view |> form("#operator-changes-form", limit: "180.5") |> render_submit()

      assert has_element?(
               view,
               "#operator-changes-limit-error",
               "Enter a whole number from 60 to 720, or leave it blank."
             )

      assert stored_limit(context) == nil
    end

    test "a blank limit turns the checks off and the Plan summary says so", context do
      block_102!(context)
      relief_limit!(context, 60)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), base)

      assert has_element?(view, "#block-MTAy", "No operator change")

      open_drawer(view)
      open_operator_drawer(view)

      view |> form("#operator-changes-form", limit: "", marked: []) |> render_submit()

      assert stored_limit(context) == nil
      assert render(view) =~ "Operator checks turned off"
      assert_patch(view, base)

      # With no limit there is no stretch to check, so the day carries no relief
      # finding and the Plan summary reads Not checked again.
      refute has_element?(view, "#block-MTAy", "No operator change")

      open_drawer(view)

      assert has_element?(view, "#plan-summary-relief-off", "Not checked.")
      refute has_element?(view, "#plan-summary-relief-limit")
    end

    test "a crafted payload cannot mark a stop the day type does not offer", context do
      block_102!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)
      open_operator_drawer(view)

      view
      |> form("#operator-changes-form")
      |> render_submit(%{"limit" => "300", "marked" => ["AB_SOMEWHERE_ELSE"]})

      # The payload named a stop that is not a candidate of this day, so it was
      # dropped before the writer saw it and the limit is all that was stored.
      assert stored_limit(context) == 300
      assert stored_marks(context) == []
    end
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
end
