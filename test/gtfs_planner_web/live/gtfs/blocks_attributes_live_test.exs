defmodule GtfsPlannerWeb.Gtfs.BlocksAttributesLiveTest do
  # EV-31, rejecting FH-31 for CL-31: the block drawer's Garage and Vehicle type
  # form, its “Also changes” preview, the confirmation the context asks for and
  # the inline refusal on a block whose calendars disagree, read through the
  # ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes
  # an adapter, a context or a hand-built review.
  #
  # The fixture is the reference's shape: one garage per calendar to begin with,
  # a second garage to move the block to, a block that runs on three day types
  # (Weekday alone, Weekday with Saturday, Weekday with School), a block that
  # runs on one day type only, and a block whose two calendars name different
  # garages. The date counts in the assertions are the fixture's own calendar
  # dates, counted from the day load the page reads.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_attributes_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # Weekday runs every day of the fixture's four weeks, Saturday on three of
    # them and School on two weekdays plus one day of its own, so the version
    # derives four day types and one block can run in three of them.
    dates = for(offset <- 0..25, do: Date.add(~D[2026-10-05], offset))

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WK",
      name: "Weekday",
      dates: dates
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SAT",
      name: "Saturday",
      dates: for(offset <- [5, 12, 19], do: Date.add(~D[2026-10-05], offset))
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SCH",
      name: "School",
      dates: [Enum.at(dates, 1), Enum.at(dates, 2), Date.add(~D[2026-10-05], 27)]
    })

    route12 =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    route30 =
      route_fixture(organization.id, version.id, %{route_id: "R30", route_short_name: "30"})

    for {stop_id, name, lat} <- [
          {"AB_RS_A", "Riverside Station", "40.0100"},
          {"AB_VALLEY", "Valley College", "40.0200"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0000")
      })
    end

    main =
      garage_fixture(organization.id, %{"name" => "Main", "lat" => "40.0000", "lon" => "-74.0000"})

    north =
      garage_fixture(organization.id, %{
        "name" => "North",
        "lat" => "41.0000",
        "lon" => "-74.0000"
      })

    cutaway =
      vehicle_type_fixture(organization.id, %{"name" => "Cutaway", "max_out_hours" => 4})

    vehicle_type_fixture(organization.id, %{"name" => "Diesel"})

    # Every route pulls out of Main, and route 30 needs the Cutaway, so the type
    # help names a requirement rather than a bare list of limits.
    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: "R12",
      garage_id: main.id
    })

    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: "R30",
      garage_id: main.id,
      required_vehicle_type_id: cutaway.id
    })

    # Block 101 runs on Weekday, so it runs on the Saturday and School day types
    # too and a save to it reaches all three.
    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WK",
      block_id: "101",
      garage_id: main.id,
      vehicle_type_id: cutaway.id
    })

    # Block 103's two calendars disagree, which is the conflict R4 reports.
    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WK",
      block_id: "103",
      garage_id: main.id
    })

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "SCH",
      block_id: "103",
      garage_id: north.id
    })

    %{
      organization: organization,
      user: user,
      version: version,
      main: main,
      north: north,
      cutaway: cutaway,
      route12: route12,
      route30: route30
    }
  end

  defp trip!(context, service_id, block_id, route, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first)
    {last, attrs} = Map.pop(attrs, :last)

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route.route_id,
      Map.merge(
        %{
          service_id: service_id,
          block_id: block_id,
          first_stop: "AB_RS_A",
          last_stop: "AB_VALLEY"
        },
        attrs
      )
      |> Map.put(:first_arrival, first)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:last_departure, last)
    )
  end

  # 101 is a Weekday block (three day types), 102 runs on Saturday alone (one)
  # and 103 runs on the two services of the School + Weekday day type.
  defp trips!(context) do
    trip!(context, "WK", "101", context.route12, %{
      trip_id: "6101",
      first: "06:00:00",
      last: "06:35:00"
    })

    trip!(context, "WK", "101", context.route12, %{
      trip_id: "6102",
      first: "07:00:00",
      last: "07:35:00"
    })

    trip!(context, "SAT", "102", context.route12, %{
      trip_id: "S1201",
      first: "08:00:00",
      last: "08:35:00"
    })

    trip!(context, "WK", "103", context.route12, %{
      trip_id: "6103",
      first: "09:00:00",
      last: "09:35:00"
    })

    trip!(context, "SCH", "103", context.route30, %{
      trip_id: "SC103",
      first: "10:00:00",
      last: "10:35:00"
    })
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context),
    do: log_in_user(context.conn, context.user, organization: context.organization)

  # The day type the assertions read by name, so the fixture's own calendar
  # dates are what the day type's count is measured from.
  defp day_key!(context, label) do
    {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    case Enum.find(day.day_types, &(&1.label == label)) do
      nil -> raise "no #{label} day type in the fixture"
      day_type -> day_type.key
    end
  end

  defp open(context, block_id, label) do
    path =
      blocks_path(context.version.id) <> "?block=#{block_id}&day=#{day_key!(context, label)}"

    live(editor_conn(context), path)
  end

  defp attributes_params(view, params) do
    view |> element("#block-attributes-form") |> render_change(params)
  end

  describe "the block's garage and vehicle type" do
    test "the drawer opens on the block's resolved garage and type and says where they come from",
         context do
      trips!(context)
      {:ok, view, _html} = open(context, "101", "Weekday")

      assert has_element?(
               view,
               "#block-drawer #block-attributes-form[phx-submit='save_block_attributes']"
             )

      # The pickers carry the resolution the day load made, not a stored value
      # read again here (INV-9).
      assert view
             |> element("#block-attributes-form #block-garage option[selected]")
             |> render() =~ "Main"

      assert view
             |> element("#block-attributes-form #block-vehicle-type option[selected]")
             |> render() =~ "Cutaway"

      assert has_element?(view, "#block-garage-help", "Route 12's home garage is Main.")

      # Nothing has changed yet, so no day type is named as also changing.
      refute has_element?(view, "#block-also-changes")
      refute has_element?(view, "#block-attributes-note")
      assert has_element?(view, "#block-attributes-submit", "Save block settings")
    end

    test "choosing another garage previews every other day type the save reaches", context do
      trips!(context)
      {:ok, view, _html} = open(context, "101", "Weekday")

      attributes_params(view, %{"block_attributes" => %{"garage_id" => context.north.id}})

      # The block runs on three day types and the reader is on one, so the other
      # two are named with their own date counts and the value they get.
      assert has_element?(
               view,
               "#block-also-changes [data-day-type][data-role='block-also-changes']",
               "School + Weekday · 2 dates"
             )

      assert has_element?(
               view,
               "#block-also-changes [data-role='block-also-changes']",
               "Block 101 runs the same Weekday trips there. Its garage becomes North too."
             )

      assert has_element?(
               view,
               "#block-also-changes [data-role='block-also-changes']",
               "Saturday + Weekday · 3 dates"
             )

      assert has_element?(view, "#block-attributes-note", "Also changes School + Weekday")
      assert has_element?(view, "#block-attributes-note", "Saturday + Weekday")
    end

    test "a save that reaches another day type is confirmed, then the row shows the new garage",
         context do
      trips!(context)
      {:ok, view, _html} = open(context, "101", "Weekday")

      attributes_params(view, %{"block_attributes" => %{"garage_id" => context.north.id}})
      view |> element("#block-attributes-form") |> render_submit()

      # The context decides the confirmation, and this save reaches two other
      # day types, so the built review dialog opens and names them (AC-19).
      assert has_element?(view, "#block-review", "Review block changes")
      assert has_element?(view, "#block-review", "Save block settings")
      assert has_element?(view, "#block-review-attributes", "No trip changes block")

      assert has_element?(
               view,
               "#block-review [data-role='review-effect'][data-selected='false']"
             )

      # No trip changes block, so there is no assignment table to read.
      refute has_element?(view, "#block-review-changes-table")

      view |> element("#block-review-confirm") |> render_click()

      assert_patch(view, blocks_path(context.version.id))
      assert has_element?(view, "#flash-info", "Block 101 saved")

      # The row reads the row that was written, on every day type the block runs.
      assert has_element?(
               view,
               "#blocks-timeline tr[data-block='101'] .blocks-meta-garage",
               "North"
             )

      {:ok, saturday, _html} =
        live(
          editor_conn(context),
          blocks_path(context.version.id) <> "?day=#{day_key!(context, "Saturday")}"
        )

      assert has_element?(
               saturday,
               "#blocks-timeline tr[data-block='101'] .blocks-meta-garage",
               "North"
             )
    end

    test "a save that reaches only this day type and adds no problem saves directly", context do
      trips!(context)
      {:ok, view, _html} = open(context, "102", "Saturday + Weekday")

      refute has_element?(view, "#block-also-changes")

      view
      |> element("#block-attributes-form")
      |> render_submit(%{"block_attributes" => %{"garage_id" => context.north.id}})

      # One day type and no added problem is the case the context does not ask
      # to confirm (AC-19), so the save lands and the drawer closes.
      assert_patch(view, blocks_path(context.version.id))
      assert has_element?(view, "#flash-info", "Block 102 saved")
      refute has_element?(view, "#block-review")
    end

    test "a block whose calendars disagree asks for one garage and keeps focus on the picker",
         context do
      trips!(context)
      {:ok, view, _html} = open(context, "103", "School + Weekday")

      # The picker opens on the prompt and the help names every row that
      # disagrees, so the reader can see which calendar says what (AC-37).
      assert has_element?(view, "#block-garage option[value='']", "Choose one garage")

      assert has_element?(
               view,
               "#block-garage-help",
               "Set differently per calendar: North on School, Main on Weekday."
             )

      # Nothing has been decided yet, so no day type is previewed as changing
      # from a garage the block does not have.
      refute has_element?(view, "#block-also-changes")

      view |> element("#block-attributes-form") |> render_submit()

      # Nothing was written: the sentence is the field's own error, the select is
      # marked invalid, and the form's focus hook is told to land on it.
      assert has_element?(view, "#block-garage[aria-invalid='true']")
      assert has_element?(view, "#block-garage-error", "Choose one garage for this block.")
      refute has_element?(view, "#block-review")

      # Answering it clears the sentence and previews the reach of the answer.
      attributes_params(view, %{"block_attributes" => %{"garage_id" => context.north.id}})

      refute has_element?(view, "#block-garage[aria-invalid='true']")
      assert has_element?(view, "#block-attributes-form")

      # Answering it previews the reach of the answer, and the card names the
      # value the other day type gets.
      assert has_element?(
               view,
               "#block-also-changes [data-role='block-also-changes']",
               "Its garage becomes North too."
             )
    end

    test "a confirmation whose planning inputs changed is refused as stale", context do
      trips!(context)
      {:ok, view, _html} = open(context, "101", "Weekday")

      attributes_params(view, %{"block_attributes" => %{"garage_id" => context.north.id}})
      view |> element("#block-attributes-form") |> render_submit()

      assert has_element?(view, "#block-review")

      # A planning input moves under the review — a third vehicle type appears —
      # so the context's recomputed digest no longer matches the fingerprint the
      # reader confirmed, and nothing is written (INV-7).
      vehicle_type_fixture(context.organization.id, %{"name" => "Artic"})

      view |> element("#block-review-confirm") |> render_click()

      assert has_element?(view, "#block-review-stale", "Trips changed since you reviewed")
      refute has_element?(view, "#flash-info", "Block 101 saved")

      # The stale state keeps the form, so the reader can review the save again.
      assert has_element?(view, "#block-attributes-form")
    end
  end
end
