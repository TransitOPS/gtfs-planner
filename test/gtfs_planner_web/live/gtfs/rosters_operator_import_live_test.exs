defmodule GtfsPlannerWeb.Gtfs.RostersOperatorImportLiveTest do
  @moduledoc """
  The operators drawer's import view: a CSV file, the review it produces, and the
  write the primary performs.

  Every case drives a real upload through `file_input/4` and `render_upload/2`,
  so the parse is `Tods.parse(:operators, …)` reading the bytes a browser would
  have sent, the review is `Operations.preview_operator_import/2`, and the write
  is `Operations.apply_operator_import/4`. The `operators` rows are re-read from
  the database afterwards rather than read back off the page, so "the review said
  Add" and "the row is there" stay two independent facts.

  ## What each case is really asserting

  - The file input takes the two extensions the import accepts, and the file
    input stays on screen after a parse error, because the editor's next move is
    to choose a different file.
  - The counts, the skipped reasons and the unused columns are
    `OperatorImport.classify/2`'s own output, quoted verbatim — the page invents
    no row of its own and stores nothing the file did not map (domain rule 12,
    the "Operator data stays minimal" criterion).
  - An apply that lost the race writes nothing: the context hands back a fresh
    preview, the drawer swaps it in and says why the counts moved.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Repo

  # The message the drawer shows when the organization's operators changed
  # between the review and the apply.
  @stale_message "Operators changed since the preview. Review the updated counts, then import again."

  # One existing operator (E4101), one to add (E4200), one with no display name
  # and one with a seniority the classifier refuses. `phone` maps to nothing.
  @csv """
  employee_id,display_name,seniority_number,phone
  E4101,Ana Nowak,12,555-0100
  E4200,Bo Silva,7,555-0101
  E4201,,3,555-0102
  E4202,Cara Diaz,12a,555-0103
  """

  defp editor_setup(_context), do: %{user: user_fixture()}

  defp world do
    world = runs_version_fixture()

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SAT",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    calendar_service_fixture(world.organization.id, world.version.id, %{
      service_id: "SUN",
      name: "Sunday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 0,
      sunday: 1,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })

    day_type_keys = day_type_keys(world)

    for {block_id, day_type_label, run_id} <- [
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
        day_type_key: Map.fetch!(day_type_keys, day_type_label),
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

  defp signed_in(context) do
    world = world()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: context.user.id,
        organization_id: world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    {log_in_user(context.conn, context.user, organization: world.organization), world}
  end

  defp operator(organization_id, attrs) do
    {:ok, operator} =
      Operations.create_operator(
        organization_id,
        %{id: Ecto.UUID.generate()},
        Map.merge(%{"employee_id" => "E-0000", "display_name" => "Nobody"}, attrs)
      )

    operator
  end

  # Enters through the router and opens the import through the drawer's own
  # secondary control, the way an editor does.
  defp open_import(context) do
    {conn, world} = signed_in(context)
    {:ok, view, _html} = live(conn, "/gtfs/#{world.version.id}/rosters")

    view |> element("#rosters-operators-button") |> render_click()
    assert has_element?(view, "#rosters-operators-drawer-overlay[data-open='true']")
    assert has_element?(view, "#rosters-import-operators")

    view |> element("#rosters-import-operators") |> render_click()

    assert has_element?(view, "#rosters-operators-drawer-overlay[data-open='true']")
    {view, world}
  end

  defp upload_csv(view, filename \\ "operators.csv", content \\ @csv) do
    upload =
      file_input(view, "#rosters-import-file", :operators_file, [
        %{name: filename, content: content, type: "text/csv"}
      ])

    render_upload(upload, filename)
  end

  defp stored_operator(organization_id, employee_id) do
    Repo.get_by(Operator, organization_id: organization_id, employee_id: employee_id)
  end

  defp stored_ids(organization_id) do
    organization_id
    |> Operations.list_operators()
    |> Enum.map(& &1.employee_id)
    |> Enum.sort()
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  describe "the import view" do
    setup :editor_setup

    test "Import operators opens the file input for the two accepted extensions",
         context do
      {view, _world} = open_import(context)

      assert has_element?(view, "#rosters-operator-import")
      assert has_element?(view, "#rosters-import-file-label", "Operators file")
      assert has_element?(view, "#rosters-import-file-help", "employee_id")
      assert has_element?(view, "#rosters-import-form")

      accept = attribute(view, "#rosters-import-file input[type=file]", "accept")
      assert accept =~ ".csv"
      assert accept =~ ".txt"

      # Nothing has been chosen, so the primary is unavailable and the reason
      # says which action would make it available.
      assert has_element?(view, "#rosters-import-apply[disabled][data-unavailable]")
      assert has_element?(view, "#rosters-import-reason", "Choose a CSV file to review.")
      assert has_element?(view, "#rosters-import-apply", "Import operators")

      # One primary, and Cancel before it.
      assert has_element?(view, "#rosters-import-cancel")
      refute has_element?(view, "#rosters-operators-table")
    end

    test "a reviewed file shows the counts, the skipped reasons and the unused column",
         context do
      {view, world} = open_import(context)
      operator(world.organization.id, %{"employee_id" => "E4101", "display_name" => "Ana Nowak"})
      upload_csv(view)

      assert has_element?(view, "#rosters-import-review", "Review operators.csv")
      assert has_element?(view, "#rosters-import-count-add", "1")
      assert has_element?(view, "#rosters-import-count-update", "1")
      assert has_element?(view, "#rosters-import-count-skipped", "2")

      # The reasons are `OperatorImport.classify/2`'s own sentences, with the
      # physical row numbers.
      assert has_element?(
               view,
               "#rosters-import-skipped",
               "Row 4 · E4201 · Display name is blank."
             )

      assert has_element?(
               view,
               "#rosters-import-skipped",
               "Row 5 · E4202 · Seniority number must be a whole number from 1 to 99,999."
             )

      refute has_element?(view, "#rosters-import-skipped", "E4200")

      # `phone` maps to nothing, so it is named and never stored.
      assert has_element?(view, "#rosters-import-ignored", "phone")
      refute has_element?(view, "#rosters-import-ignored", "employee_id")
      assert has_element?(view, "#rosters-import-apply:not([disabled])", "Import 2 operators")
    end

    test "the apply writes the adds and the updates and returns to the list",
         context do
      {view, world} = open_import(context)

      operator(world.organization.id, %{
        "employee_id" => "E4101",
        "display_name" => "Ana Nowak",
        "seniority_number" => 3
      })

      upload_csv(view)
      view |> element("#rosters-import-apply") |> render_click()

      # The drawer is the list again, re-read from the writers.
      assert has_element?(view, "#rosters-operators-table")
      refute has_element?(view, "#rosters-import-review")

      assert has_element?(
               view,
               "#rosters-toast",
               "1 operator added, 1 updated. 2 rows were skipped."
             )

      assert stored_ids(world.organization.id) == ["E4101", "E4200"]

      assert %Operator{} = added = stored_operator(world.organization.id, "E4200")
      assert added.display_name == "Bo Silva"
      assert added.seniority_number == 7
      assert added.updated_by_id

      # The file's own values overwrote the stored ones, and nothing else did.
      assert %Operator{} = updated = stored_operator(world.organization.id, "E4101")
      assert updated.display_name == "Ana Nowak"
      assert updated.seniority_number == 12

      # The skipped rows never reached storage.
      refute stored_operator(world.organization.id, "E4201")
      refute stored_operator(world.organization.id, "E4202")

      assert has_element?(view, "#rosters-operators-table", "E4200")
    end

    test "an operator created between the review and the apply refreshes the review and writes nothing",
         context do
      {view, world} = open_import(context)
      operator(world.organization.id, %{"employee_id" => "E4101", "display_name" => "Ana Nowak"})
      upload_csv(view)

      # Another session claims E4200 while the review is on screen. The plan the
      # editor agreed to — one add — is no longer what the file would do.
      operator(world.organization.id, %{
        "employee_id" => "E4200",
        "display_name" => "Bo Silva from the roster grid",
        "seniority_number" => 7
      })

      view |> element("#rosters-import-apply") |> render_click()

      assert has_element?(view, "#rosters-import-error", @stale_message)
      assert has_element?(view, "#rosters-import-review", "Review operators.csv")

      # The fresh review is the one on screen: E4200 is now an update, not an add.
      assert has_element?(view, "#rosters-import-count-add", "0")
      assert has_element?(view, "#rosters-import-count-update", "2")
      assert has_element?(view, "#rosters-import-apply:not([disabled])", "Import 2 operators")

      # Nothing was written: E4101 still holds the values the grid gave it.
      assert %Operator{} = unchanged = stored_operator(world.organization.id, "E4101")
      assert unchanged.display_name == "Ana Nowak"
      assert unchanged.seniority_number == nil
    end

    test "a file without an employee_id column shows the parse error and keeps the file input",
         context do
      {view, world} = open_import(context)
      upload_csv(view, "no_ids.csv", "display_name,seniority_number\nBo Silva,7\n")

      assert has_element?(
               view,
               "#rosters-import-error",
               "no_ids.csv is missing the employee_id column."
             )

      assert has_element?(view, "#rosters-import-file input[type=file]")
      refute has_element?(view, "#rosters-import-review")
      assert has_element?(view, "#rosters-import-reason", "Choose a different file to review.")
      assert has_element?(view, "#rosters-import-apply[disabled][data-unavailable]")

      assert stored_ids(world.organization.id) == []
    end
  end
end
