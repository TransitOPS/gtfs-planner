defmodule GtfsPlannerWeb.Gtfs.RostersExportLiveTest do
  @moduledoc """
  The export section at the foot of the Rosters page: the planned-data note, the
  warnings, the first rows of `employee_run_dates.txt` and the link to the
  operations export.

  ## The section is a reading of the file, not a second export

  Every figure on screen is `AssignmentsExport.rows/1` over the page's own
  composition with `services: nil`, which is the export's own pure function
  (INV-14). So the cases here assert against the function's own result rather
  than against hard-coded figures wherever a hard-coded figure would only be a
  copy of it: the preview's first row is compared with
  `AssignmentsExport.rows/1`'s first row, and the warning sentences with the
  sentences that same function produces. What the cases pin literally is what
  production cannot supply twice: the section's own ids, the column headings, the
  date format the page prints where the ZIP prints ISO, the 20-row cap and the
  link's target.

  ## The world

  `RunsFixtures.runs_version_fixture/1` plus a Saturday and a Sunday day type
  and runs `2001`, `2002`, `2004`, `6001`, `7001` — the same world the pick and
  open-work tests build — and, where a case needs a date running other service,
  a dates-only "Holiday" service on Mondays with a trip of its own. Lines are
  written through `Gtfs.create_roster_line/2`, `Gtfs.set_roster_slot/5` and
  `Gtfs.assign_roster_operator/4`, so the roster the section reads is a roster
  that really exists.

  A stale slot is made the way the export test makes one: a run is renamed
  through `Gtfs.rename_run/5`, so the stored times no longer match.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Rosters.AssignmentsExport
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  setup :verify_on_exit!

  # One Monday that no other calendar in the fixture runs, so adding it makes the
  # Monday run different service rather than adding a second day to an existing
  # one. 2026-10-12 is a Monday.
  @holiday ~D[2026-10-12]

  defp editor_setup(_context), do: %{user: user_fixture()}

  defp world do
    world = runs_version_fixture()

    for {service_id, name, flag} <- [
          {"SAT", "Saturday", :saturday},
          {"SUN", "Sunday", :sunday}
        ] do
      calendar_service_fixture(world.organization.id, world.version.id, %{
        service_id: service_id,
        name: name,
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: if(flag == :saturday, do: 1, else: 0),
        sunday: if(flag == :sunday, do: 1, else: 0),
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      })
    end

    keys = day_type_keys(world)

    for {block_id, label, run_id} <- [
          {"201", "Weekday", "2001"},
          {"202", "Weekday", "2002"},
          {"401", "Saturday", "6001"}
        ],
        {trip_id, first, last} <- block_trips(block_id),
        trip =
          blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
            trip_id: trip_id,
            service_id: service_id(block_id),
            block_id: block_id,
            first_arrival: first,
            last_arrival: last
          }) do
      trip_run_fixture(world.organization.id, world.version.id, %{
        trip: trip,
        day_type_key: Map.fetch!(keys, label),
        run_id: run_id
      })
    end

    world
  end

  defp day_type_keys(world) do
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)

    Map.new(day.day_types, fn day_type -> {day_type.label, day_type.key} end)
  end

  defp service_id(block_id) when block_id in ["201", "202"], do: "WK"
  defp service_id("401"), do: "SAT"

  defp block_trips("201"),
    do: [
      {"w201a", "05:50:00", "06:50:00"},
      {"w201b", "07:00:00", "08:00:00"},
      {"w201c", "09:00:00", "13:00:00"},
      {"w201d", "13:30:00", "15:30:00"}
    ]

  defp block_trips("202"),
    do: [{"w202a", "12:00:00", "12:30:00"}, {"w202b", "12:40:00", "13:10:00"}]

  defp block_trips("401"),
    do: [{"w401a", "07:00:00", "07:30:00"}, {"w401b", "07:45:00", "08:15:00"}]

  # A date that runs a service of its own, with one trip, so that day type has a
  # run to export and the Monday it lands on is not the Monday base.
  defp add_holiday_service(world) do
    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "HOL",
      name: "Holiday",
      dates: [@holiday]
    })

    trip =
      blocked_trip_fixture(world.organization.id, world.version.id, world.route.route_id, %{
        trip_id: "h1",
        service_id: "HOL",
        block_id: "901",
        first_stop: "BAY_A",
        last_stop: "BAY_B",
        first_departure: "06:00:00",
        last_arrival: "07:00:00"
      })

    # Named by the service it contains rather than by its label: the label is a
    # presentation of the same fact and the key is what the stored row carries.
    {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)
    [holiday] = Enum.filter(day.day_types, &("HOL" in &1.service_ids))

    trip_run_fixture(world.organization.id, world.version.id, %{
      trip: trip,
      day_type_key: holiday.key,
      run_id: "9001"
    })

    world
  end

  defp signed_in(context, world \\ nil) do
    world = world || world()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: context.user.id,
        organization_id: world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp path(world), do: "/gtfs/#{world.version.id}/rosters"

  defp line(world, days, operator \\ nil) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world.organization.id, world.version.id)

    for {weekday, run_id} <- days do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world.organization.id,
                 world.version.id,
                 line_id,
                 weekday,
                 run_id
               )
    end

    if operator do
      assert {:ok, _} =
               Gtfs.assign_roster_operator(
                 world.organization.id,
                 world.version.id,
                 line_id,
                 operator.id
               )
    end

    line_id
  end

  defp operator(world, employee_id, display_name) do
    Repo.insert!(
      %Operator{organization_id: world.organization.id}
      |> Operator.changeset(%{employee_id: employee_id, display_name: display_name})
    )
  end

  # The composition's own export rows, read through the same public path the page
  # reads them, so "the preview's first row is the export's first row" is a claim
  # about two independent reads of one snapshot (INV-14).
  defp assignments(world) do
    {:ok, view} = Gtfs.load_roster(world.organization.id, world.version.id)

    AssignmentsExport.rows(%{
      roster: view.roster,
      day_types: view.day_types,
      run_days: view.run_days,
      services: nil
    })
  end

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> squish()
  end

  defp squish(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp attr_of(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  defp headers(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#{selector} thead th")
    |> Enum.map(&squish(LazyHTML.text(&1)))
  end

  defp cells(row) do
    row
    |> LazyHTML.query("td")
    |> Enum.map(&squish(LazyHTML.text(&1)))
  end

  describe "the export section" do
    setup :editor_setup

    test "says what the file is even before any line has an operator", context do
      {conn, world} = signed_in(context)
      _line = line(world, [{1, "2002"}])

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-export")

      # The note is unconditional: a roster the export loses nothing from still
      # needs a planner to know the file is planned.
      assert text_of(view, "#rosters-export-note") ==
               "Planned from the pick. Vacations, sick days and extraboard are not included."
    end

    test "warns about the dates that run other service, with the computed open run-days",
         context do
      {conn, world} = signed_in(context)
      add_holiday_service(world)

      line(world, [{1, "2001"}], operator(world, "E4101", "Aurelia Nowak"))

      {:ok, view, _html} = live(conn, path(world))

      # One Holiday Monday and one run on it, so the count is one open run-day.
      # The date is the page's own format where the export's report prints ISO,
      # and the rest of the sentence is `AssignmentsExport`'s own text verbatim,
      # which is what INV-14's wording parity asks for.
      assert text_of(view, "#rosters-export-warnings") =~
               "1 date runs different service: Oct 12, 2026. " <>
                 "No assignment is exported for it; 1 run-day stays open."
    end

    test "warns about the open line and the stale slot the roster actually has", context do
      {conn, world} = signed_in(context)

      # One picked line, one open line, and one stale slot: the Saturday run the
      # third line holds is renamed under it, so its stored times no longer match.
      # A run on its own day type, so renaming it makes exactly one slot stale.
      line(world, [{1, "2001"}], operator(world, "E4101", "Aurelia Nowak"))
      line(world, [{2, "2002"}])

      line(world, [{6, "6001"}], operator(world, "E4108", "Bram Osei"))

      {:ok, day} = Blocking.load_day(world.organization.id, world.version.id, nil)
      saturday = Enum.find(day.day_types, &("SAT" in &1.service_ids))

      assert {:ok, _} = Gtfs.rename_run(world.audit, saturday.key, "6001", "9")

      {:ok, view, _html} = live(conn, path(world))

      warnings = text_of(view, "#rosters-export-warnings")

      assert warnings =~ "1 line has no operator."
      assert warnings =~ "1 stale slot was skipped."
    end

    test "previews the export's own rows, capped at twenty", context do
      {conn, world} = signed_in(context)

      # A weekday run worked on all five weekdays: one row per date of the base
      # week, which is far more than the preview shows.
      line(
        world,
        [{1, "2001"}, {2, "2001"}, {3, "2001"}, {4, "2001"}, {5, "2001"}],
        operator(world, "E4101", "Aurelia Nowak")
      )

      {:ok, view, _html} = live(conn, path(world))

      assert headers(view, "#rosters-export-preview") ==
               ["Date", "Run", "Employee ID", "Operator"]

      result = assignments(world)
      assert length(result.rows) > 20, "the fixture must produce more rows than the preview shows"

      rows =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#rosters-export-preview tbody tr")
        |> Enum.to_list()

      assert length(rows) == 20

      [first | _rest] = Enum.map(rows, &cells/1)
      [expected | _more] = result.rows

      assert first == [
               Calendar.strftime(expected.date, "%b %-d, %Y"),
               expected.run_id,
               expected.employee_id,
               expected.operator_name
             ]
    end

    test "shows no service ID anywhere in the preview", context do
      {conn, world} = signed_in(context)

      line(world, [{1, "2001"}], operator(world, "E4101", "Aurelia Nowak"))

      {:ok, view, _html} = live(conn, path(world))

      # `services: nil` is what makes every row's service ID nil, and the file's
      # own service IDs are this ZIP's business (INV-14).
      refute text_of(view, "#rosters-export-preview") =~ "WK"
      assert Enum.all?(assignments(world).rows, &is_nil(&1.service_id))
    end

    test "links to the operations export", context do
      {conn, world} = signed_in(context)
      line(world, [{1, "2001"}], operator(world, "E4101", "Aurelia Nowak"))

      {:ok, view, _html} = live(conn, path(world))

      assert attr_of(view, "#rosters-export-link", "href") ==
               "/gtfs/#{world.version.id}/export?type=operations"
    end

    test "is not drawn for a version with no runs", context do
      # The bare fixture has calendars but no run: the no-runs state, which has
      # nothing to describe and has already said why.
      {conn, world} = signed_in(context, runs_version_fixture())

      {:ok, view, _html} = live(conn, path(world))

      assert has_element?(view, "#rosters-no-runs")
      refute has_element?(view, "#rosters-export")
    end
  end
end
