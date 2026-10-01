defmodule GtfsPlannerWeb.Gtfs.RostersOperatorDeleteLiveTest do
  @moduledoc """
  Confirming and deleting an operator from the operators drawer.

  Every case here reaches the real writers — `Operations.delete_operator/3`
  through `RostersLive`'s `confirm_delete_operator` — and re-reads the stored rows
  afterwards, so "the confirmation named the lines" and "the lines are open" are
  two independent reads.

  ## The world

  The same fixture the operators, line-drawer, add-to-line and pick tests build:
  a weekday day type over Monday to Friday plus Saturday and Sunday day types,
  with runs `2001`, `2002`, `2004`, `6001` and `7001`. Operators are
  organization-wide and ignore versions, which is the point of this file: one
  operator holds a line here and a line in a second published version, and the
  confirmation has to name both.

  ## What each case is really asserting

  - The confirmation reads `Gtfs.roster_operator_holdings/2`, so it names lines
    in versions this page is not showing, with those versions' names.
  - The consequence and the permanence are the writer's own facts: the lines
    become Open (the foreign key nils the pick) and the operator's own three
    values are gone.
  - "Keep operator" writes nothing at all.
  - The delete is refused for an operator this drawer is not showing, for one of
    another organization, and for one that has gone — an id cast and looked up
    inside the caller's organization, never a cross-tenant write (domain rule
    13).
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo

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

  defp path(world), do: "/gtfs/#{world.version.id}/rosters"

  # An operator written through the production writer, so the row is one the
  # drawer's own save would have written.
  defp operator(organization_id, attrs) do
    {:ok, operator} =
      Operations.create_operator(
        organization_id,
        GtfsPlanner.OperationsFixtures.operations_actor(organization_id),
        Map.merge(
          %{"employee_id" => "E-0000", "display_name" => "Nobody", "seniority_number" => nil},
          attrs
        )
      )

    operator
  end

  defp line(world, days) do
    {:ok, %{id: line_id}} = Gtfs.create_roster_line(world_audit(world))

    for {weekday, run_id} <- days do
      assert {:ok, _result} =
               Gtfs.set_roster_slot(
                 world_audit(world),
                 line_id,
                 weekday,
                 run_id
               )
    end

    line_id
  end

  # A line of this version holding this operator's pick, written through the
  # facade writers the page calls.
  defp held_line(world, operator_id, days) do
    line_id = line(world, days)

    {:ok, %{line_number: number}} =
      Gtfs.assign_roster_operator(world_audit(world), line_id, operator_id)

    %{id: line_id, line_number: number}
  end

  # The pick as stored, read from the table rather than from a writer's answer.
  # The organization is checked here too, so a line of another tenant can never
  # answer one of this file's questions.
  defp stored_operator(organization_id, line_id) do
    case Repo.get(RosterLine, line_id) do
      %{organization_id: ^organization_id} = line -> line.operator_id
      _another_tenants_line -> nil
    end
  end

  defp stored_operators(organization_id) do
    Operations.list_operators(organization_id) |> Enum.map(& &1.employee_id)
  end

  # The element's own text, with the markup's line breaks collapsed to one
  # space, so an assertion can be written as the sentence a reader reads rather
  # than as the template's indentation.
  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Opens the operators drawer and the edit form for this operator, which is
  # where the delete control is.
  defp editing(view, operator_id) do
    view |> element("#rosters-operators-button") |> render_click()
    view |> element("#rosters-edit-operator-#{operator_id}") |> render_click()

    assert has_element?(view, "#rosters-delete-operator")
    view
  end

  defp confirm_body(view), do: text_of(view, "#rosters-delete-operator-body")

  describe "the delete-operator confirmation" do
    setup :editor_setup

    test "names the held lines of this version and of another, with their version names",
         context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak",
          "seniority_number" => 10
        })

      other_version = gtfs_version_fixture(world.organization.id, %{name: "2027 spring"})

      here = held_line(world, operator.id, [{2, "2002"}])
      there = held_line(%{world | version: other_version}, operator.id, [])

      # The line in the other version has no days of its own; what matters is
      # that the pick exists there and the confirmation can account for it.
      assert stored_operator(world.organization.id, there.id) == operator.id

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)

      view |> element("#rosters-delete-operator") |> render_click()

      assert has_element?(view, "#rosters-delete-operator-confirm")

      assert text_of(view, "#rosters-delete-operator-confirm-title") ==
               "Delete Aurelia Nowak?"

      # Both lines, each with the version it belongs to, because this page is
      # showing only one of them. The order is `roster_operator_holdings/2`'s —
      # by version name, then line number — and "2027 spring" sorts before
      # "Test Version …", so the other version's line is named first.
      body = confirm_body(view)

      assert body =~
               "Line #{there.line_number} in 2027 spring and line #{here.line_number} in #{world.version.name} become Open."

      assert body =~
               "Their name, employee ID and seniority number are removed from the app."

      # The buttons are the action and its way out, and the way out is the
      # secondary one.
      assert has_element?(view, "#rosters-delete-operator-confirm-confirm", "Delete operator")
      assert has_element?(view, "#rosters-delete-operator-confirm-cancel", "Keep operator")

      # Nothing has been written by asking.
      assert stored_operator(world.organization.id, here.id) == operator.id
      assert stored_operators(world.organization.id) == ["E4101"]
    end

    test "an operator holding one line here names it without the version", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte"
        })

      held = held_line(world, operator.id, [{6, "6001"}])

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()

      assert confirm_body(view) ==
               "Line #{held.line_number} becomes Open. Their name, employee ID and seniority number are removed from the app."
    end

    test "an operator with no line says only what is removed from them", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4300",
          "display_name" => "Ana Duarte"
        })

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()

      # No sentence about lines: there are none, and naming none would be worse
      # than saying nothing.
      assert confirm_body(view) ==
               "Their name, employee ID and seniority number are removed from the app."
    end

    test "Keep operator closes the confirmation and leaves the operator and the pick", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak"
        })

      held = held_line(world, operator.id, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()

      assert has_element?(view, "#rosters-delete-operator-confirm")

      view |> element("#rosters-delete-operator-confirm-cancel") |> render_click()

      refute has_element?(view, "#rosters-delete-operator-confirm", "Delete Aurelia Nowak?")
      assert stored_operator(world.organization.id, held.id) == operator.id
      assert stored_operators(world.organization.id) == ["E4101"]
    end
  end

  describe "deleting an operator" do
    setup :editor_setup

    test "the row is gone and every held line is open, in this version and in another", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak",
          "seniority_number" => 10
        })

      other_version = gtfs_version_fixture(world.organization.id, %{name: "2027 spring"})

      held = held_line(world, operator.id, [{2, "2002"}])
      elsewhere = held_line(%{world | version: other_version}, operator.id, [])

      _untouched =
        operator(world.organization.id, %{"employee_id" => "E4200", "display_name" => "Mira"})

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()
      view |> element("#rosters-delete-operator-confirm-confirm") |> render_click()

      refute has_element?(view, "#rosters-delete-operator-confirm")
      refute has_element?(view, "#rosters-operator-form")

      # The stored facts, read from the tables: the operator's row is gone and
      # both lines survive with no pick, so both show Open. The other operator is
      # untouched.
      assert Operations.get_operator(world.organization.id, operator.id) == nil
      assert stored_operator(world.organization.id, held.id) == nil
      assert stored_operator(world.organization.id, elsewhere.id) == nil
      assert stored_operators(world.organization.id) == ["E4200"]

      # The grid redrew from the composition: the line is still there and its
      # pick is gone, so the row reads Open.
      assert has_element?(view, "#rosters-grid")
      assert has_element?(view, "#rosters-line-#{held.line_number}")
      refute has_element?(view, "#rosters-line-#{held.line_number}", "Aurelia Nowak")
      assert has_element?(view, "#rosters-toast", "Aurelia Nowak deleted.")
    end

    test "the operators list is refreshed and the organization-wide count with it", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4300",
          "display_name" => "Ana Duarte"
        })

      _kept =
        operator(world.organization.id, %{"employee_id" => "E4010", "display_name" => "Zoe"})

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()
      view |> element("#rosters-delete-operator-confirm-confirm") |> render_click()

      # The drawer returns to its list rather than to the form, and the deleted
      # operator is not in it.
      assert has_element?(view, "#rosters-operators-table")
      assert has_element?(view, "#rosters-operators-lede", "1 operator")
      refute has_element?(view, "#rosters-operator-#{operator.id}")

      # The scope bar's organization-wide count follows the same delete.
      # The scope bar's own count is the organization's, and the delete moved it.
      assert has_element?(view, "#rosters-scope", "Operators")
      assert text_of(view, "#rosters-scope") =~ ~r/Operators\s*·\s*1\b/
    end

    test "an operator another organization holds cannot be deleted from here", context do
      {conn, world} = signed_in(context)

      theirs = runs_version_fixture()

      foreign =
        operator(theirs.organization.id, %{
          "employee_id" => "E4200",
          "display_name" => "Bo Lindqvist"
        })

      # The other organization's own line, holding the same pick: an empty week
      # is enough to make the row exist, which is all this case needs.
      theirs_held = held_line(theirs, foreign.id, [])

      {:ok, view, _html} = live(conn, path(world))

      # A hand-built event naming an operator this drawer never offered opens
      # nothing, so there is no confirmation to press.
      render_click(view, "ask_delete_operator", %{"id" => foreign.id})
      refute has_element?(view, "#rosters-delete-operator-confirm")

      render_click(view, "confirm_delete_operator", %{})
      assert Operations.get_operator(theirs.organization.id, foreign.id).id == foreign.id
      assert stored_operator(theirs.organization.id, theirs_held.id) == foreign.id
    end

    test "a malformed or unknown id opens nothing and writes nothing", context do
      {conn, world} = signed_in(context)

      kept = operator(world.organization.id, %{"employee_id" => "E4010", "display_name" => "Zoe"})

      {:ok, view, _html} = live(conn, path(world))

      for bad_id <- ["not-a-uuid", Ecto.UUID.generate(), 42] do
        render_click(view, "ask_delete_operator", %{"id" => bad_id})
        refute has_element?(view, "#rosters-delete-operator-confirm")
      end

      render_click(view, "confirm_delete_operator", %{})

      assert stored_operators(world.organization.id) == ["E4010"]
      assert Operations.get_operator(world.organization.id, kept.id).id == kept.id
    end

    test "an operator that went while the confirmation was up is refused, not crashed", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak"
        })

      held = held_line(world, operator.id, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()

      assert has_element?(view, "#rosters-delete-operator-confirm")

      # Another session deletes the row the confirmation named.
      assert {:ok, _deleted} =
               Operations.delete_operator(
                 world.organization.id,
                 %{id: world.audit.actor_id},
                 operator.id
               )

      view |> element("#rosters-delete-operator-confirm-confirm") |> render_click()

      # Both overlays close and the page says why in its own toast, because
      # there is no drawer left to own the sentence.
      refute has_element?(view, "#rosters-delete-operator-confirm")
      refute has_element?(view, "#rosters-operator-form")
      assert has_element?(view, "#rosters-toast", "no longer on this organization's list")

      # The line the deleted operator held is open, and stays.
      assert stored_operator(world.organization.id, held.id) == nil
      assert stored_operators(world.organization.id) == []
    end

    test "a lost editor role refuses the delete and writes nothing", context do
      {conn, world} = signed_in(context)

      operator =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak"
        })

      held = held_line(world, operator.id, [{2, "2002"}])

      {:ok, view, _html} = live(conn, path(world))
      view = editing(view, operator.id)
      view |> element("#rosters-delete-operator") |> render_click()

      # The membership is re-read before the write, the way `RunsLive` does it.
      Accounts.get_user_org_membership(context.user.id, world.organization.id)
      |> deactivate_membership_fixture()

      view |> element("#rosters-delete-operator-confirm-confirm") |> render_click()

      assert has_element?(view, "#rosters-toast", "You no longer have editor access")
      assert Operations.get_operator(world.organization.id, operator.id).id == operator.id
      assert stored_operator(world.organization.id, held.id) == operator.id
    end
  end
end
