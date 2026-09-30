defmodule GtfsPlannerWeb.Gtfs.BlocksRulesLiveTest do
  # The Block rules drawer, observed through the
  # ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo`, so a save reaches the real
  # `Gtfs.update_blocking_settings/3` → `Blocking.update_settings/3` upsert and
  # then `Gtfs.update_route_operating_settings/3` → the route writer's own
  # transaction. The fixture rows and the rows the
  # saves write are created inside the SQL Sandbox transaction and rolled back.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Repo

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    {:ok, membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id)

    main =
      route_fixture(organization.id, version.id, %{
        route_id: "30",
        route_short_name: "30",
        route_long_name: "Main"
      })

    cross =
      route_fixture(organization.id, version.id, %{
        route_id: "40",
        route_short_name: "40",
        route_long_name: "Cross"
      })

    garage = garage_fixture(organization.id, %{"name" => "Main garage"})
    vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

    # Another organization's garage and type, for the tampered-parameter case: the
    # route writer rejects both as not owned by this organization.
    other_organization =
      organization_fixture(%{alias: "other_org_#{System.unique_integer([:positive])}"})

    foreign_garage = garage_fixture(other_organization.id)

    %{
      user: user,
      organization: organization,
      version: version,
      main: main,
      cross: cross,
      garage: garage,
      vehicle_type: vehicle_type,
      other_organization: other_organization,
      foreign_garage: foreign_garage,
      membership: membership
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context),
    do: log_in_user(context.conn, context.user, organization: context.organization)

  # One day type with a single two-trip block on the Main route, so the page has
  # a loaded day to draw and a scope button that prints the stored minimum.
  defp day_scope(context) do
    calendar_service_fixture(context.organization.id, context.version.id, %{
      service_id: "WK",
      name: "Weekday"
    })

    stop =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "STOP_MAIN",
        stop_name: "Main St"
      })

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.main.route_id,
      %{
        service_id: "WK",
        trip_id: "a",
        block_id: "101",
        first_arrival: "08:00:00",
        last_arrival: "09:00:00",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id
      }
    )

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.main.route_id,
      %{
        service_id: "WK",
        trip_id: "b",
        block_id: "101",
        first_arrival: "09:07:00",
        last_arrival: "09:40:00",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id
      }
    )
  end

  defp open_day(context) do
    {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
    view
  end

  defp open_rules(view), do: view |> element("#blocks-block-rules") |> render_click()

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp settings(context),
    do: Gtfs.get_blocking_settings(context.organization.id, context.version.id)

  defp route_setting(context, route_id) do
    Repo.get_by(RouteOperatingSetting,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      route_id: route_id
    )
  end

  # The Route switches control is its own form, so the segment is chosen through
  # it and the drawer's state carries it into the save.
  defp choose_interlining(view, value) do
    view |> form("#block-rules-interlining-form", %{interlining: value}) |> render_change()
  end

  defp submit_rules(view, params) do
    view |> form("#block-rules-form", params) |> render_submit()
  end

  describe "the Block rules control" do
    setup :editor_scope

    test "the scope bar names the drawer and the old control is gone", context do
      day_scope(context)
      view = open_day(context)

      # The old Minimum layover button no longer
      # exists anywhere on the page.
      assert has_element?(view, "#blocks-block-rules", "Block rules · 5 min layover")
      refute has_element?(view, "#blocks-min-layover")
      refute render(view) =~ "Minimum layover ·"

      open_rules(view)

      assert has_element?(view, "#block-rules-drawer-overlay[data-open='true']")
      assert has_element?(view, "#block-rules-drawer", "Block rules")

      assert has_element?(
               view,
               "#block-rules-scope",
               "This version · applies to every service day"
             )
    end

    test "the drawer shows every setting with its value and help, in reading order",
         context do
      day_scope(context)
      view = open_day(context)
      open_rules(view)

      # The five numeric fields, with the stored defaults.
      assert has_element?(view, "#layover-minutes[value='5'][min='0'][max='120']")
      assert has_element?(view, "#block-rules-max-block[min='60'][max='1440']")
      assert has_element?(view, "#block-rules-pull-out-buffer[value='0'][min='0'][max='60']")
      assert has_element?(view, "#block-rules-speed[value='30'][min='5'][max='120']")
      assert has_element?(view, "#block-rules-road-factor[value='1.3'][min='1'][max='3']")

      # The optional longest-time field reads blank, which is “unset”.
      refute has_element?(view, "#block-rules-max-block[value]")

      # The labels and the help sentences.
      assert has_element?(view, "#block-rules-form label", "Minimum layover (min)")

      assert has_element?(
               view,
               "#layover-minutes-help",
               "Shorter waits between trips are flagged."
             )

      assert has_element?(
               view,
               "#block-rules-max-block-help",
               "Blank uses each vehicle type’s limit only."
             )

      assert has_element?(
               view,
               "#block-rules-pull-out-buffer-help",
               "Added to each pull-out for checks and sign-on."
             )

      assert has_element?(view, "#block-rules-form label", "Default garage")
      assert has_element?(view, "#block-rules-default-garage")

      assert has_element?(
               view,
               "#block-rules-driving-help",
               "Straight-line distance × road factor ÷ speed. Entered driving times always win."
             )

      # The Route switches control is the shared segmented control, with the
      # three labels and its stored value.
      assert has_element?(view, "#block-rules-interlining-form")
      assert has_element?(view, "#block-rules-interlining", "Route switches within a block")
      assert has_element?(view, "#block-rules-interlining", "Anywhere")
      assert has_element?(view, "#block-rules-interlining", "Same stop only")
      assert has_element?(view, "#block-rules-interlining", "Not allowed")
      assert has_element?(view, "#block-rules-interlining-help")

      # The footer note and the two buttons.
      assert has_element?(view, "#block-rules-note", "Changing these redraws every block.")
      assert has_element?(view, "#block-rules-submit", "Save block rules")
      assert has_element?(view, "#block-rules-cancel", "Cancel")

      # Reading the drawer stores nothing.
      assert Repo.aggregate(BlockingSetting, :count) == 0
    end

    test "the Route garages table has a row per route with both selects", context do
      day_scope(context)
      view = open_day(context)
      open_rules(view)

      assert has_element?(view, "#block-rules-routes", "Route garages")

      # One row per route of the version, whether or not a row is stored for it.
      ids =
        view
        |> doc()
        |> LazyHTML.query("tr[data-role='block-rules-route-row']")
        |> LazyHTML.attribute("data-route")

      assert Enum.sort(ids) == ["30", "40"]

      # The first row is the Main route, and both of its selects are named the way
      # the writer's entry is, with no stored value yet.
      row =
        view
        |> doc()
        |> LazyHTML.query("tr[data-route='30']")
        |> LazyHTML.to_html()

      assert row =~ "Main"
      assert row =~ ~s(name="route_settings[30][garage_id]")
      assert row =~ ~s(name="route_settings[30][required_vehicle_type_id]")
      assert row =~ context.garage.name
      assert row =~ context.vehicle_type.name
    end
  end

  describe "saving Block rules" do
    setup :editor_scope

    test "a valid save stores the settings and the route rows, redraws and flashes",
         context do
      day_scope(context)
      view = open_day(context)
      open_rules(view)

      # The segment is chosen through its own form, as a reader does.
      choose_interlining(view, "same_stop")

      # The settings form is then posted as the drawer's payload: the settings
      # map and the route table's entries.
      params = %{
        "block_rules" => %{
          "min_layover_minutes" => "7",
          "max_block_minutes" => "600",
          "pull_out_buffer_minutes" => "10",
          "default_garage_id" => context.garage.id,
          "deadhead_speed_kmh" => "25",
          "deadhead_circuity" => "1.5"
        },
        "route_settings" => %{
          "30" => %{
            "garage_id" => context.garage.id,
            "required_vehicle_type_id" => context.vehicle_type.id
          }
        }
      }

      html = submit_rules(view, params)

      assert html =~ "Block rules saved."

      stored = settings(context)

      assert stored.min_layover_minutes == 7
      assert stored.max_block_minutes == 600
      assert stored.pull_out_buffer_minutes == 10
      assert stored.interlining == :same_stop
      assert stored.default_garage_id == context.garage.id
      assert stored.deadhead_speed_kmh == 25
      assert stored.deadhead_circuity == 1.5

      # The route row is stored for the route the table named.
      route = route_setting(context, "30")
      assert route.garage_id == context.garage.id
      assert route.required_vehicle_type_id == context.vehicle_type.id

      # The drawer's own values are this version's: another version keeps the
      # defaults.
      other_version = gtfs_version_fixture(context.organization.id)

      assert Gtfs.get_blocking_settings(context.organization.id, other_version.id) == %{
               min_layover_minutes: 5,
               max_block_minutes: nil,
               pull_out_buffer_minutes: 0,
               interlining: :any,
               default_garage_id: nil,
               deadhead_speed_kmh: 30,
               deadhead_circuity: 1.3,
               max_piece_minutes: nil
             }

      # The drawer closes, the scope button prints the new minimum, and the day is
      # redrawn from the saved rules: the 7-minute handoff is now exactly the
      # minimum, so nothing is short.
      assert has_element?(view, "#block-rules-drawer-overlay[data-open='false']")
      assert has_element?(view, "#blocks-block-rules", "Block rules · 7 min layover")

      assert view
             |> doc()
             |> LazyHTML.query(
               "#blocks-summary-counts-item-problems [data-role='count-strip-value']"
             )
             |> LazyHTML.text()
             |> String.trim() == "0"
    end

    test "an out-of-range entry shows the error, keeps every entry and saves nothing",
         context do
      day_scope(context)
      view = open_day(context)
      open_rules(view)
      choose_interlining(view, "none")

      params = %{
        "block_rules" => %{
          "min_layover_minutes" => "150",
          "max_block_minutes" => "600",
          "pull_out_buffer_minutes" => "10",
          "default_garage_id" => context.garage.id,
          "deadhead_speed_kmh" => "25",
          "deadhead_circuity" => "1.5"
        },
        "route_settings" => %{
          "30" => %{
            "garage_id" => context.garage.id,
            "required_vehicle_type_id" => context.vehicle_type.id
          }
        }
      }

      submit_rules(view, params)

      # The context's own field error, the summary, and the drawer's own sentence
      # that the other entries are kept.
      assert has_element?(
               view,
               "#block-rules-form",
               "must be a whole number between 0 and 120"
             )

      assert has_element?(view, "#block-rules-errors", "1 entry needs fixing.")
      assert has_element?(view, "#block-rules-errors", "Your other entries are kept.")
      assert has_element?(view, "#layover-minutes[value='150'][aria-invalid='true']")

      # Every other entry is kept, including the route selects.
      assert has_element?(view, "#block-rules-max-block[value='600']")
      assert has_element?(view, "#block-rules-pull-out-buffer[value='10']")
      assert has_element?(view, "#block-rules-speed[value='25']")
      assert has_element?(view, "#block-rules-road-factor[value='1.5']")
      assert has_element?(view, "#block-rules-interlining input[value='none'][checked]")

      assert view
             |> doc()
             |> LazyHTML.query("tr[data-route='30']")
             |> LazyHTML.to_html() =~ context.vehicle_type.name

      # The drawer stays open and nothing is stored: neither the settings nor a
      # route row.
      assert has_element?(view, "#block-rules-drawer-overlay[data-open='true']")
      assert Repo.aggregate(BlockingSetting, :count) == 0
      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
      assert settings(context).min_layover_minutes == 5
      assert has_element?(view, "#blocks-block-rules", "Block rules · 5 min layover")
    end

    test "a route garage of another organization shows the row's error and stores nothing",
         context do
      day_scope(context)
      view = open_day(context)
      open_rules(view)

      params = %{
        "block_rules" => %{"min_layover_minutes" => "7"},
        "route_settings" => %{
          "30" => %{
            "garage_id" => context.foreign_garage.id,
            "required_vehicle_type_id" => context.vehicle_type.id
          }
        }
      }

      # A crafted payload rather than the form helper: the form helper refuses a
      # value the select does not offer, and a garage of another organization is
      # exactly the value a reader cannot pick.
      render_submit(view, "save_block_rules", params)

      # The refusal is on the row's own select, and the settings that were saved
      # first are named as saved rather than as a failed save.
      assert has_element?(
               view,
               "#block-rules-route-0-garage-error",
               "is not owned by this organization"
             )

      assert has_element?(view, "#flash-error", "Block rules saved; route garages need fixing.")
      assert has_element?(view, "#block-rules-drawer-overlay[data-open='true']")

      # The route batch is all-or-nothing: nothing was stored for that route or
      # any other.
      assert route_setting(context, "30") == nil
      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
    end

    test "a Block rules save keeps the relief limit the drawer does not show", context do
      day_scope(context)

      # The Operator changes drawer owns the relief limit, and the settings writer
      # replaces every column of the row, so a save from this drawer has to carry
      # the stored limit through rather than clearing it.
      {:ok, _setting} =
        Gtfs.update_blocking_settings(context.organization.id, context.version.id, %{
          "min_layover_minutes" => "5",
          "pull_out_buffer_minutes" => "0",
          "interlining" => "any",
          "deadhead_speed_kmh" => "30",
          "deadhead_circuity" => "1.3",
          "max_piece_minutes" => "330"
        })

      assert settings(context).max_piece_minutes == 330

      view = open_day(context)
      open_rules(view)

      assert has_element?(view, "#block-rules-drawer", "Block rules")

      submit_rules(view, %{
        "block_rules" => %{"min_layover_minutes" => "7"},
        "route_settings" => %{"30" => %{"garage_id" => context.garage.id}}
      })

      stored = settings(context)

      assert stored.min_layover_minutes == 7
      assert stored.max_piece_minutes == 330
    end

    test "a revoked editor role writes nothing", %{membership: membership} = context do
      day_scope(context)
      view = open_day(context)

      open_rules(view)

      # No viewer role exists; a revoked editor is a membership with no roles.
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      submit_rules(view, %{
        "block_rules" => %{"min_layover_minutes" => "7"},
        "route_settings" => %{"30" => %{"garage_id" => context.garage.id}}
      })

      assert has_element?(
               view,
               "#block-rules-error",
               "You don't have permission to change blocks in this version."
             )

      assert Repo.aggregate(BlockingSetting, :count) == 0
      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
      assert has_element?(view, "#blocks-block-rules", "Block rules · 5 min layover")
    end
  end
end
