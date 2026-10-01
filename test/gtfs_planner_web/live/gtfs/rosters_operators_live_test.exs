defmodule GtfsPlannerWeb.Gtfs.RostersOperatorsLiveTest do
  @moduledoc """
  The operators drawer: the list an editor reads, and the form that adds and
  edits an operator.

  Every case here reaches the real writers — `Operations.create_operator/3` and
  `Operations.update_operator/4` through `RostersLive`'s `save_operator` — and the
  stored `operators` row is re-read straight out of the database afterwards. "The
  list shows the operator" and "the database holds that operator" are therefore
  two independent reads rather than one rendering.

  ## The world

  The same fixture the line-drawer, add-to-line and pick tests build: a weekday
  day type over Monday to Friday plus Saturday and Sunday day types, with runs
  `2001`, `2002`, `2004`, `6001` and `7001`. Operators are organization-wide and
  ignore versions, so the roster's own day types matter here only to give the
  Line column a line to name; the version the operators belong to is the point.

  ## What each case is really asserting

  - The list is `Operations.list_operators/1` in that function's own order, so
    the drawer and the pick select cannot disagree about who is most senior
    (domain rule 11, AC-4).
  - Validation happens on blur and on submit, and the errors are the writer's own
    changeset — the page invents no rule of its own.
  - A duplicate employee ID is refused with the holder's name, and nothing is
    written.
  - The actor's id is recorded on the row, because `updated_by_id` is what makes
    a change attributable.
  - An operator belongs to the organization: a submitted id from another tenant
    reaches nothing, and a malformed id is not a crash.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Operator
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

  # An operator written through the production writer, so the row carries
  # `updated_by_id` and the trimming the writer does.
  defp operator(organization_id, attrs) do
    {:ok, operator} =
      Operations.create_operator(
        organization_id,
        GtfsPlanner.OperationsFixtures.operations_actor(organization_id),
        %{
          "employee_id" => "E-0000",
          "display_name" => "Nobody"
        }
        |> Map.merge(attrs)
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

  # A re-read, so the claim is about the table. `Repo.all/1` has no `order_by`
  # and Postgres makes no promise about the order rows come back in, so a
  # two-row assertion against it was asserting an accident of the heap and
  # passed or failed with the seed. The order on screen is `drawn_rows/1`'s
  # job; this one only has to say which rows are stored, so it sorts them.
  # The sort is on the whole tuple, and `nil` is an atom, so an operator
  # without a seniority number sorts after the numbered ones.
  defp stored_operators(organization_id) do
    Operator
    |> Repo.all()
    |> Enum.filter(&(&1.organization_id == organization_id))
    |> Enum.map(&{&1.seniority_number, &1.employee_id, &1.display_name})
    |> Enum.sort()
  end

  defp stored_operator(organization_id, employee_id) do
    Repo.get_by(Operator, organization_id: organization_id, employee_id: employee_id)
  end

  defp text_of(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  # The rows of the drawer table in the order they are drawn, one cell list per
  # operator, so the order under test is the order on screen rather than a set.
  defp drawn_rows(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#rosters-operators-rows tr")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("td")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))
    end)
  end

  defp field_value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  describe "the operators list" do
    setup :editor_setup

    test "the scope bar button opens the drawer with the organization's order", context do
      {conn, world} = signed_in(context)

      # Unnumbered operators sort by name, then employee ID; equal numbers by
      # employee ID. This is `Operations.list_operators/1`'s order and the
      # drawer's is the same computation, not a second one.
      unnumbered_a =
        operator(world.organization.id, %{
          "employee_id" => "E4300",
          "display_name" => "Ana Duarte"
        })

      unnumbered_b =
        operator(world.organization.id, %{
          "employee_id" => "E4010",
          "display_name" => "Zoe Marchetti"
        })

      senior_b =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      senior_a =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak",
          "seniority_number" => 10
        })

      most =
        operator(world.organization.id, %{
          "employee_id" => "E4200",
          "display_name" => "Mira Silva",
          "seniority_number" => 3
        })

      first = line(world, [{2, "2002"}])

      assert {:ok, _result} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 first,
                 senior_a.id
               )

      {:ok, view, _html} = live(conn, path(world))
      refute has_element?(view, "#rosters-operators-drawer")

      view |> element("#rosters-operators-button") |> render_click()

      assert has_element?(view, "#rosters-operators-drawer")
      assert has_element?(view, "#rosters-operators-table")
      assert has_element?(view, "#rosters-operators-lede", "5 operators")

      # Seniority · Employee ID · Name · Line, in `list_operators/1`'s order. The
      # one operator holding a line in this version says so; the rest say
      # "No line" rather than an empty cell.
      assert drawn_rows(view) == [
               ["3", "E4200", "Mira Silva", "No line"],
               ["10", "E4101", "Aurelia Nowak", "Line 1"],
               ["10", "E4157", "Ines Duarte", "No line"],
               ["—", "E4300", "Ana Duarte", "No line"],
               ["—", "E4010", "Zoe Marchetti", "No line"]
             ]

      # The drawer is organization-wide, and says so where a reader looks first.
      assert text_of(view, "#rosters-operators-lede") =~ "1 hold a line in this version"

      # Selecting a name is how an operator is edited, and the row's own name is
      # the identifier.
      assert has_element?(
               view,
               "#rosters-edit-operator-#{senior_a.id}",
               "Aurelia Nowak"
             )

      assert has_element?(
               view,
               "#rosters-edit-operator-#{unnumbered_a.id}",
               "Ana Duarte"
             )

      assert has_element?(view, "#rosters-edit-operator-#{unnumbered_b.id}")
      assert has_element?(view, "#rosters-edit-operator-#{most.id}")
      assert has_element?(view, "#rosters-edit-operator-#{senior_b.id}")
    end

    test "an organization with no operators says so instead of drawing an empty table", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()

      assert has_element?(view, "#rosters-operators-empty", "No operators yet")
      refute has_element?(view, "#rosters-operators-table")
    end

    test "the Close control in the drawer header closes it", context do
      {conn, world} = signed_in(context)

      _operator =
        operator(world.organization.id, %{"employee_id" => "E1", "display_name" => "Ada"})

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      assert has_element?(view, "#rosters-operators-table")

      view |> element("#rosters-operators-drawer-close") |> render_click()

      refute has_element?(view, "#rosters-operators-drawer")
      # The page under the drawer is untouched: the roster is still on screen.
      assert has_element?(view, "#rosters-page")
    end
  end

  describe "adding an operator" do
    setup :editor_setup

    test "a valid submit writes the operator and the list shows it in order", context do
      {conn, world} = signed_in(context)

      operator(world.organization.id, %{
        "employee_id" => "E4157",
        "display_name" => "Ines Duarte",
        "seniority_number" => 10
      })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      assert has_element?(view, "#rosters-operator-form")
      assert has_element?(view, "#rosters-operator-form-lede", "shared by every version")

      # The form opens blank, and says what is stored.
      assert field_value(view, "#operator_employee_id") in [nil, ""]
      assert text_of(view, "#rosters-operator-form") =~ "Only these three values are stored."

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Aurelia Nowak"}
      )
      |> render_submit()

      # The stored row is re-read, so the claim is about the database and not
      # about the rendering that claimed it.
      assert stored_operators(world.organization.id) == [
               {10, "E4157", "Ines Duarte"},
               {nil, "E4101", "Aurelia Nowak"}
             ]

      # The form is gone and the list is back, with the new operator in the
      # organization's own order: unnumbered operators follow the numbered ones,
      # by name.
      refute has_element?(view, "#rosters-operator-form")

      assert drawn_rows(view) == [
               ["10", "E4157", "Ines Duarte", "No line"],
               ["—", "E4101", "Aurelia Nowak", "No line"]
             ]

      assert has_element?(view, "#rosters-toast", "Aurelia Nowak added.")

      # Focus returns to the list, because the form is gone and the control that
      # opened it may be too.
      assert_push_event(view, "focus_scoped_target", %{id: "rosters-operators-drawer-title"})
    end

    test "the acting user is recorded on the row the save created", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Aurelia Nowak"}
      )
      |> render_submit()

      stored = stored_operator(world.organization.id, "E4101")
      assert stored.updated_by_id == context.user.id
    end

    test "a blank employee ID is refused on blur, on submit, and writes nothing", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      # A blur that leaves an empty employee ID is the moment the page believes
      # the field is finished, so its error is drawn then — and only for it.
      render_change(view, "validate_operator", %{
        "operator" => %{"employee_id" => "", "display_name" => "Amina Okafor"},
        "_target" => ["operator", "employee_id"]
      })

      assert has_element?(view, "#operator_employee_id[aria-invalid='true']")
      assert text_of(view, "#operator_employee_id-error") =~ "can't be blank"
      refute has_element?(view, "#operator_display_name[aria-invalid='true']")

      # The same empty field on submit is refused with every error at once and
      # the first invalid field takes focus.
      view
      |> form("#rosters-operator-form", operator: %{employee_id: "", display_name: ""})
      |> render_submit()

      assert has_element?(view, "#rosters-operator-form-errors")
      assert text_of(view, "#rosters-operator-form-errors") =~ "Fix these to save the operator"
      assert text_of(view, "#rosters-operator-form-errors") =~ "Employee ID: can't be blank"

      assert_push_event(view, "focus_form_error", %{
        form_id: "rosters-operator-form",
        fallback_id: "rosters-operator-form-errors"
      })

      # Nothing was written, and the drawer is still the form rather than a list
      # that would claim otherwise.
      assert stored_operators(world.organization.id) == []
      assert has_element?(view, "#rosters-operator-form")
    end

    test "a duplicate employee ID is refused with the holder's name and writes nothing",
         context do
      {conn, world} = signed_in(context)

      operator(world.organization.id, %{
        "employee_id" => "E4101",
        "display_name" => "Aurelia Nowak",
        "seniority_number" => 10
      })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Amina Okafor"}
      )
      |> render_submit()

      # The refusal is the writer's own sentence, under the field it names, and
      # what the editor typed is still there to correct.
      assert text_of(view, "#operator_employee_id-error") =~
               "E4101 is already used by Aurelia Nowak."

      assert field_value(view, "#operator_display_name") == "Amina Okafor"
      assert field_value(view, "#operator_employee_id") == "E4101"

      # Nothing was written: the organization still holds exactly one operator.
      assert stored_operators(world.organization.id) == [{10, "E4101", "Aurelia Nowak"}]
    end

    test "a seniority outside 1 to 99,999 is refused under its own field", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Aurelia Nowak", seniority_number: "0"}
      )
      |> render_submit()

      assert text_of(view, "#operator_seniority_number-error") =~
               "must be greater than or equal to 1"

      assert stored_operators(world.organization.id) == []
    end

    test "a blank seniority number is an absent one, not a zero", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{
          employee_id: "E4101",
          display_name: "Aurelia Nowak",
          seniority_number: ""
        }
      )
      |> render_submit()

      assert [{%{seniority_number: nil}, "Aurelia Nowak"}] =
               stored_operators(world.organization.id)
               |> Enum.map(fn {seniority, _id, name} ->
                 {%{seniority_number: seniority}, name}
               end)
    end

    test "the values are trimmed before they are stored", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "  E4101 ", display_name: "  Aurelia Nowak  "}
      )
      |> render_submit()

      assert stored_operators(world.organization.id) == [{nil, "E4101", "Aurelia Nowak"}]
    end

    test "cancelling returns to the list and writes nothing", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      view |> element("#rosters-operator-cancel") |> render_click()

      refute has_element?(view, "#rosters-operator-form")
      assert has_element?(view, "#rosters-operators-empty")
      assert stored_operators(world.organization.id) == []
    end
  end

  describe "editing an operator" do
    setup :editor_setup

    test "the form opens on the operator's own values", context do
      {conn, world} = signed_in(context)

      ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-edit-operator-#{ines.id}") |> render_click()

      assert has_element?(view, "#rosters-operator-form")
      assert has_element?(view, "#operator_employee_id[value='E4157']")
      assert has_element?(view, "#operator_display_name[value='Ines Duarte']")
      assert has_element?(view, "#operator_seniority_number[value='10']")
      assert has_element?(view, "#rosters-operator-save", "Save operator")
    end

    test "editing the seniority re-orders the list and records the actor", context do
      {conn, world} = signed_in(context)

      ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      _mira =
        operator(world.organization.id, %{
          "employee_id" => "E4200",
          "display_name" => "Mira Silva",
          "seniority_number" => 3
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-edit-operator-#{ines.id}") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{
          employee_id: "E4157",
          display_name: "Ines Duarte",
          seniority_number: "1"
        }
      )
      |> render_submit()

      # The stored row is re-read rather than the rendering trusted: the edit is
      # a fact about the row, and who made it is stored with it.
      stored = stored_operator(world.organization.id, "E4157")
      assert stored.seniority_number == 1
      assert stored.updated_by_id == context.user.id

      # And the list re-orders into the organization's order.
      assert drawn_rows(view) == [
               ["1", "E4157", "Ines Duarte", "No line"],
               ["3", "E4200", "Mira Silva", "No line"]
             ]

      assert has_element?(view, "#rosters-toast", "Ines Duarte saved.")
    end

    test "clearing the seniority number stores none, and validation does not bring the old one back",
         context do
      {conn, world} = signed_in(context)

      ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-edit-operator-#{ines.id}") |> render_click()
      assert has_element?(view, "#operator_seniority_number[value='10']")

      # Leaving the cleared field validates the form. The field has to stay
      # empty: a form that re-rendered the stored 10 would submit it back.
      view
      |> form("#rosters-operator-form", operator: %{seniority_number: ""})
      |> render_change(%{"_target" => ["operator", "seniority_number"]})

      refute has_element?(view, "#operator_seniority_number[value='10']")

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4157", display_name: "Ines Duarte", seniority_number: ""}
      )
      |> render_submit()

      assert stored_operator(world.organization.id, "E4157").seniority_number == nil
      assert has_element?(view, "#rosters-toast", "Ines Duarte saved.")

      # Opened again, the form carries the stored absence rather than the old number.
      view |> element("#rosters-edit-operator-#{ines.id}") |> render_click()
      refute has_element?(view, "#operator_seniority_number[value='10']")
    end

    test "an operator holding a line in this version is told which one", context do
      {conn, world} = signed_in(context)

      line_id = line(world, [{2, "2002"}])

      holder =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak",
          "seniority_number" => 4
        })

      assert {:ok, _result} =
               Gtfs.assign_roster_operator(
                 world_audit(world),
                 line_id,
                 holder.id
               )

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-edit-operator-#{holder.id}") |> render_click()

      assert has_element?(view, "#rosters-operator-holds-line", "Aurelia Nowak")
      assert text_of(view, "#rosters-operator-holds-line") =~ "line 1"
      assert text_of(view, "#rosters-operator-holds-line") =~ "Change the pick in the roster grid"
    end

    test "an employee ID another operator holds is refused and writes nothing", context do
      {conn, world} = signed_in(context)

      ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      operator(world.organization.id, %{
        "employee_id" => "E4101",
        "display_name" => "Aurelia Nowak"
      })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-edit-operator-#{ines.id}") |> render_click()

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Ines Duarte", seniority_number: "10"}
      )
      |> render_submit()

      assert text_of(view, "#operator_employee_id-error") =~ "is already used by Aurelia Nowak."

      # An edit to another operator's ID changes nothing about either row.
      assert stored_operators(world.organization.id) == [
               {10, "E4157", "Ines Duarte"},
               {nil, "E4101", "Aurelia Nowak"}
             ]
    end

    test "an operator of another organization cannot be edited or reached by id", context do
      {conn, world} = signed_in(context)
      other = organization_fixture()

      foreign =
        operator(other.id, %{
          "employee_id" => "E9999",
          "display_name" => "Foreign Operator",
          "seniority_number" => 1
        })

      _mine =
        operator(world.organization.id, %{
          "employee_id" => "E4101",
          "display_name" => "Aurelia Nowak"
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()

      # The drawer is organization-scoped in what it offers…
      refute has_element?(view, "#rosters-edit-operator-#{foreign.id}")

      # …and an id a hand-built event names anyway is not a choice, because it is
      # not one the drawer is showing.
      render_click(view, "edit_operator", %{"id" => foreign.id})
      refute has_element?(view, "#rosters-operator-form")

      # A submit with no form open is not a write at all: nothing about this
      # organization's operator or the other organization's row moves.
      render_submit(view, "save_operator", %{
        "operator" => %{"employee_id" => "E9999", "display_name" => "Hijacked"}
      })

      assert stored_operators(other.id) == [{1, "E9999", "Foreign Operator"}]
      assert stored_operators(world.organization.id) == [{nil, "E4101", "Aurelia Nowak"}]
    end

    test "a membership deactivated after the form opened refuses the save", context do
      {conn, world} = signed_in(context)

      _ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      membership = Accounts.get_user_org_membership(context.user.id, world.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      view
      |> form("#rosters-operator-form",
        operator: %{employee_id: "E4101", display_name: "Aurelia Nowak"}
      )
      |> render_submit()

      assert has_element?(view, "#rosters-toast", "You no longer have editor access")
      assert stored_operators(world.organization.id) == [{10, "E4157", "Ines Duarte"}]
    end
  end

  describe "the drawer's own copy" do
    setup :editor_setup

    test "the one primary in the list view is Add operator", context do
      {conn, world} = signed_in(context)

      _ines =
        operator(world.organization.id, %{
          "employee_id" => "E4157",
          "display_name" => "Ines Duarte",
          "seniority_number" => 10
        })

      {:ok, view, _html} = live(conn, path(world))
      view |> element("#rosters-operators-button") |> render_click()

      # A name in the table is an action, so it is a link-styled control and not
      # a second primary: the list's one primary is the control that starts a
      # change.
      assert has_element?(view, "#rosters-drawer-add-operator")
      assert text_of(view, "#rosters-drawer-add-operator") == "Add operator"

      assert [class] =
               view
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("#rosters-operators-rows button")
               |> LazyHTML.attribute("class")

      refute class =~ "btn-primary"
      assert class =~ "text-action"
    end

    test "the one primary in the form view is the save, after Cancel", context do
      {conn, world} = signed_in(context)
      {:ok, view, _html} = live(conn, path(world))

      view |> element("#rosters-operators-button") |> render_click()
      view |> element("#rosters-drawer-add-operator") |> render_click()

      assert text_of(view, "#rosters-operator-cancel") == "Cancel"
      assert text_of(view, "#rosters-operator-save") == "Add operator"
    end
  end
end
