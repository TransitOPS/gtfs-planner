defmodule GtfsPlannerWeb.Gtfs.FareEditorWhereTest do
  @moduledoc """
  Merge evidence (EV-36) for the Where fares apply tab: the route groups table
  and its drawer, the zone matrix and its cell dialog, and the passes table
  (AC-39, AC-19, AC-20, AC-21).

  Every case drives the real page against the real writers — through
  `GtfsPlanner.Gtfs.Fares.set_zone_fare/7`, `Fares.save_route_group/2` and
  `Fares.set_pass_acceptance/5` — and asserts on the elements the states are
  required to carry rather than on the words they happen to read.

  The version enters its rows the way a user's version does: through the
  production importer (`north_coast_v2` is the prototype's sample) and the
  production conversion that makes it editable.

  The expected amounts are worked by hand from that feed: `north_coast_v2`
  prices `Local ride` at $1.50 on board, `Valley-coast ride` at $5.00 and
  `Coast ride` at $3.50, its `N_LOCAL` group holds routes 1–7, 11, 12, 20, 21,
  30 and 40, and its zones are NPT, TOL and CST. The gaps version is that same
  version after the two writes the gaps are: the `CST → TOL` cell cleared and
  route 40 removed from `N_LOCAL`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  # The four rider-type products of each fare the North Coast sample prices for
  # a zone pair, worked from `test/fixtures/gtfs/fares/north_coast_v2`.
  @valley_coast ~w(valley_coast_ride_adult_cash valley_coast_ride_child_cash
                    valley_coast_ride_reduced_cash valley_coast_ride_youth_cash)
  @local ~w(local_ride_adult_cash local_ride_child_cash local_ride_reduced_cash
             local_ride_youth_cash)
  @coast ~w(coast_ride_adult_cash coast_ride_child_cash coast_ride_reduced_cash
            coast_ride_youth_cash)

  setup context do
    organization =
      organization_fixture(%{alias: "fare-where-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: editor_email()})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    {:ok,
     conn: log_in_user(context.conn, user, organization: organization),
     organization: organization,
     user: user}
  end

  describe "the route groups table" do
    test "draws each group with its route badges and how a ride is charged", ctx do
      view = open_where(ctx, managed(ctx))

      assert has_element?(view, "#where-lede")
      assert has_element?(view, "#route-groups")

      # The two networks the sample holds, named, and the one that is
      # zone-priced (its own rules name a departure and an arrival area).
      assert has_element?(view, "#route-group-N_LOCAL")
      assert has_element?(view, "#route-group-N_INTERCITY")

      row = view |> element("#route-group-N_LOCAL") |> render()
      assert row =~ "Local routes"
      assert row =~ "13 routes"
      assert row =~ "By zone"

      # A group with no zone pair is charged by its own group-wide rule, which
      # the sample states for `N_INTERCITY`.
      intercity = view |> element("#route-group-N_INTERCITY") |> render()
      assert intercity =~ "Intercity"
      assert intercity =~ "Intercity ride"
      assert intercity =~ "any stops"

      # Every route in the group is badged, so a group is worked from the
      # version's own `route_networks` rows rather than from a count.
      # Every route in the group is badged, so the group's whole route set is
      # visible rather than summarised by a count.
      assert has_element?(view, "[data-group-badge='40']")
      assert has_element?(view, "[data-group-badge='1']")
      refute has_element?(view, "#route-groups-unassigned")
    end

    test "warns about the routes no group holds", ctx do
      version = managed(ctx)

      {:ok, _saved} =
        Fares.save_route_group(scope(ctx, version), %{
          network_id: "N_LOCAL",
          name: "Local routes",
          route_ids: Enum.reject(local_route_ids(ctx, version), &(&1 == "40"))
        })

      view = open_where(ctx, version)

      assert has_element?(view, "#route-groups-unassigned")
      unassigned = view |> element("#route-groups-unassigned") |> render()
      assert unassigned =~ "In no group"
      assert unassigned =~ "No fare"
      assert has_element?(view, "#add-unassigned-to-group")
    end

    test "a version with no groups at all still asks for one", ctx do
      version = version(ctx, "No group version", "no_fare")
      view = open_where(ctx, version)

      # The table is empty rather than absent, and the create action is the
      # one answer it offers.
      assert has_element?(view, "#route-groups")
      assert has_element?(view, "#create-route-group")
      refute has_element?(view, "#route-group-N_LOCAL")
      # Every route of the version is in no group, so the warning row names
      # them all.
      assert has_element?(view, "#route-groups-unassigned")
    end
  end

  describe "the route group drawer" do
    test "adding a route from another group warns that it moves, and saves", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      # Route 10 is the sample's only Intercity route, so ticking it in the
      # Local group is the move the warning names.
      view
      |> element("#edit-group-N_LOCAL")
      |> render_click()

      assert has_element?(view, "#group-drawer")
      assert has_element?(view, "#group-name")
      assert view |> element("#group-name") |> render() =~ "Local routes"
      assert has_element?(view, "#group-route-10")
      assert has_element?(view, "#group-route-40")

      # The prototype's route list says which group a route is in besides this
      # one, so the move is visible before the box is ticked.
      assert view |> element("label[for='group-route-10']") |> render() =~ "In Intercity"

      refute has_element?(view, "#group-moving")

      view
      |> element("#group-form")
      |> render_change(%{
        "group" => %{
          "name" => "Local routes",
          "route_ids" => local_route_ids(ctx, version) ++ ["10"]
        }
      })

      moving = view |> element("#group-moving") |> render()
      assert moving =~ "Route 10"
      assert moving =~ "moves from Intercity"

      view |> element("#group-form") |> render_submit(%{"group" => %{"name" => "Local routes"}})

      refute has_element?(view, "#group-drawer")
      assert has_element?(view, "#fare-note", "saved")

      # The write is the writer's, so the route is in the group and no longer in
      # the one it came from (AC-19).
      assert route_in_group(ctx, version, "N_LOCAL", "10")
      refute route_in_group(ctx, version, "N_INTERCITY", "10")

      # And the table the operator came from now shows the route in the group
      # they moved it to.
      assert has_element?(view, "[data-group-badge='10']")
    end

    test "unticking a route warns that it will be in no group, and saves", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("#edit-group-N_LOCAL") |> render_click()
      assert has_element?(view, "#group-drawer")

      view
      |> element("#group-form")
      |> render_change(%{
        "group" => %{
          "name" => "Local routes",
          "route_ids" => Enum.reject(local_route_ids(ctx, version), &(&1 == "40"))
        }
      })

      leaving = view |> element("#group-leaving") |> render()
      assert leaving =~ "Route 40"
      assert leaving =~ "no group"

      view |> element("#group-form") |> render_submit(%{"group" => %{"name" => "Local routes"}})

      refute has_element?(view, "#group-drawer")
      refute route_in_group(ctx, version, "N_LOCAL", "40")
      assert has_element?(view, "#route-groups-unassigned")
    end

    test "a second group with a name the version already holds is refused", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("#create-route-group") |> render_click()

      view
      |> element("#group-form")
      |> render_submit(%{"group" => %{"name" => "Commuter", "route_ids" => ["40"]}})

      refute has_element?(view, "#group-drawer")
      assert has_element?(view, "#fare-note", "saved")

      # The id the writer derives from that name is the one this version now
      # holds, so creating it again is refused rather than silently renaming
      # the group just written.
      view |> element("#create-route-group") |> render_click()

      view
      |> element("#group-form")
      |> render_submit(%{"group" => %{"name" => "Commuter", "route_ids" => []}})

      assert has_element?(view, "#group-drawer")
      assert has_element?(view, "#error-summary")
      assert render(view) =~ "already holds a group"
    end

    test "a blank name is refused by the writer and nothing is written", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("#create-route-group") |> render_click()
      view |> element("#group-form") |> render_submit(%{"group" => %{"name" => "  "}})

      assert has_element?(view, "#group-drawer")
      assert render(view) =~ "can&#39;t be blank"
      assert length(networks(ctx, version)) == 2
    end

    test "cancelling the drawer leaves the groups as they were", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("#edit-group-N_LOCAL") |> render_click()
      assert has_element?(view, "#group-drawer")

      view |> element("#group-drawer #group-drawer-close") |> render_click()

      refute has_element?(view, "#group-drawer")
      assert route_in_group(ctx, version, "N_LOCAL", "40")
    end
  end

  describe "the zone matrix" do
    # Both directions of one pair cleared, which is the state the browser seed's
    # gaps version is in. The fence for each direction is read after the other
    # direction's write, because Normalize's mirror runs inside every write.
    defp clear_pair(ctx, version, from, to) do
      for {a, b} <- [{from, to}, {to, from}] do
        {:ok, _cleared} =
          Fares.set_zone_fare(
            scope(ctx, version),
            "N_LOCAL",
            a,
            b,
            nil,
            false,
            cell_products(ctx, version, a, b)
          )
      end
    end

    test "draws one matrix per zone-priced group with a cell for every pair", ctx do
      view = open_where(ctx, managed(ctx))

      # Only `N_LOCAL` names a zone pair, so only it has a matrix.
      assert has_element?(view, "#zone-matrix-N_LOCAL")
      assert has_element?(view, "#zone-matrix-N_LOCAL", "Zone fares on Local routes")

      # The three zones the sample prices for, each ordered pair a cell: 3 × 3.
      for from <- ~w(NPT TOL CST), to <- ~w(NPT TOL CST) do
        assert has_element?(view, "[data-cell='#{from}-#{to}']")
      end

      # A priced cell shows the fare's adult price and its name; a pair nobody
      # priced is present and says so.
      priced = view |> element("[data-cell='CST-CST']") |> render()
      assert priced =~ "$1.50"
      assert priced =~ "Local ride"

      intercity = view |> element("[data-cell='TOL-CST']") |> render()
      assert intercity =~ "$5.00"
      assert intercity =~ "Valley-coast ride"
    end

    test "a pair nobody priced is a No fare cell that opens the cell dialog", ctx do
      version = managed(ctx)

      {:ok, _cleared} =
        Fares.set_zone_fare(
          scope(ctx, version),
          "N_LOCAL",
          "CST",
          "TOL",
          nil,
          false,
          cell_products(ctx, version, "CST", "TOL")
        )

      view = open_where(ctx, version)

      cell = view |> element("[data-cell='CST-TOL']") |> render()
      assert cell =~ "No fare"
      assert cell =~ "Set fare"

      view |> element("[data-cell='CST-TOL']") |> render_click()

      assert has_element?(view, "#cell-dialog")

      assert view |> element("#cell-dialog") |> render() =~
               "Fare from Coast zone to Toledo and valley"

      assert has_element?(view, "#cell-fare-none")
    end

    test "setting a fare on a gap with both fills both cells", ctx do
      version = managed(ctx)

      clear_pair(ctx, version, "CST", "TOL")

      view = open_where(ctx, version)
      view |> element("[data-cell='CST-TOL']") |> render_click()
      assert has_element?(view, "#cell-dialog")

      # The pair is different zones, so the reverse cell is offered, and it is
      # offered ticked: the reverse cell held the same fare, so setting this one
      # can set it too without hiding a different price.
      assert has_element?(view, "#cell-return")
      assert has_element?(view, "#cell-both")
      assert view |> element("#cell-both") |> render() =~ "checked=\"\""

      # The sample's Valley-coast ride is the fare the fixture cleared, so
      # choosing it puts
      # the sample's own price back.
      view
      |> element("#cell-form")
      |> render_submit(%{
        "cell" => %{
          "from" => "CST",
          "to" => "TOL",
          "both" => "true",
          "fare_product_id" => "valley_coast_ride_adult_cash"
        }
      })

      refute has_element?(view, "#cell-dialog")
      assert has_element?(view, "#fare-note", "Valley-coast ride")

      # AC-20: both cells now hold the whole fare, one row per rider type.
      assert cell_products(ctx, version, "CST", "TOL") == @valley_coast
      assert cell_products(ctx, version, "TOL", "CST") == @valley_coast
      assert has_element?(view, "[data-cell='CST-TOL']", "Valley-coast ride")
    end

    test "a cell can be given a different fare and its reverse left alone", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("[data-cell='TOL-CST']") |> render_click()
      assert has_element?(view, "#cell-dialog")

      view
      |> element("#cell-form")
      |> render_submit(%{
        "cell" => %{
          "from" => "TOL",
          "to" => "CST",
          "both" => "false",
          "fare_product_id" => "coast_ride_adult_cash"
        }
      })

      refute has_element?(view, "#cell-dialog")
      assert cell_products(ctx, version, "TOL", "CST") == @coast
      assert cell_products(ctx, version, "CST", "TOL") == @valley_coast
    end

    test "No fare clears a cell and the note says what happened", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("[data-cell='CST-CST']") |> render_click()

      view
      |> element("#cell-form")
      |> render_submit(%{
        "cell" => %{"from" => "CST", "to" => "CST", "both" => "false", "fare_product_id" => ""}
      })

      refute has_element?(view, "#cell-dialog")
      assert has_element?(view, "#fare-note", "Removed the fare")
      assert cell_products(ctx, version, "CST", "CST") == []
      assert has_element?(view, "[data-cell='CST-CST']", "No fare")
    end

    test "a pass is refused for a cell and nothing is written", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      view |> element("[data-cell='CST-CST']") |> render_click()

      view
      |> element("#cell-form")
      |> render_submit(%{
        "cell" => %{
          "from" => "CST",
          "to" => "CST",
          "both" => "false",
          "fare_product_id" => "day_pass_adult_cash"
        }
      })

      # A pass is not offered as a cell fare, so this is only reachable by a
      # stale dialog: the dialog stays open with the reason.
      assert has_element?(view, "#cell-dialog")
      assert has_element?(view, "#cell-error")
      # The cell still holds what it held: `N_LOCAL`'s own within-CST fare.
      assert cell_products(ctx, version, "CST", "CST") == @local
    end

    test "closing the cell dialog writes nothing", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      before = cell_products(ctx, version, "CST", "CST")
      view |> element("[data-cell='CST-CST']") |> render_click()
      assert has_element?(view, "#cell-dialog")

      view |> element("#cell-dialog-cancel") |> render_click()

      refute has_element?(view, "#cell-dialog")
      assert cell_products(ctx, version, "CST", "CST") == before
    end
  end

  describe "the passes table" do
    test "draws a row per pass and a checkbox per route group", ctx do
      view = open_where(ctx, managed(ctx))

      assert has_element?(view, "#passes")
      assert has_element?(view, "#passes", "Day pass")

      # The Day pass starts accepting `N_LOCAL`, so that box is ticked and
      # Intercity's is not.
      assert view |> element("#pass-day_pass_adult_cash-N_LOCAL") |> render() =~ ~s(checked)
      refute view |> element("#pass-day_pass_adult_cash-N_INTERCITY") |> render() =~ ~s(checked)
    end

    test "unchecking a pass on a group removes that acceptance, and Undo puts it back", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      assert pass_accepts?(ctx, version, "day_pass_adult_cash", "N_LOCAL")

      view
      |> element("#pass-form-day_pass_adult_cash-N_LOCAL")
      |> render_change(%{"pass" => %{"accepted" => "false"}})

      # AC-21: the network is out of the pass's accepted list, and the note says
      # so with the write's own inverse behind Undo.
      refute pass_accepts?(ctx, version, "day_pass_adult_cash", "N_LOCAL")
      assert has_element?(view, "#fare-note", "no longer accepted")
      assert has_element?(view, "#undo-prices")

      view |> element("#undo-prices") |> render_click()

      assert pass_accepts?(ctx, version, "day_pass_adult_cash", "N_LOCAL")
      assert has_element?(view, "#fare-note", "undone")
    end

    test "ticking a pass on a group it did not accept adds it", ctx do
      version = managed(ctx)
      view = open_where(ctx, version)

      refute pass_accepts?(ctx, version, "month_pass_adult_app", "N_LOCAL")

      view
      |> element("#pass-form-month_pass_adult_app-N_LOCAL")
      |> render_change(%{
        "pass" => %{"accepted" => "true"}
      })

      assert pass_accepts?(ctx, version, "month_pass_adult_app", "N_LOCAL")
      assert has_element?(view, "#fare-note", "is now accepted")
    end

    test "a version with no pass carries no passes table", ctx do
      view = open_where(ctx, version(ctx, "No pass version", "no_fare"))

      refute has_element?(view, "#passes")
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "fare-where-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
  end

  defp version(ctx, name, fixture) do
    version = gtfs_version_fixture(ctx.organization.id, %{name: name})
    import!(ctx.organization, version, fixture)
    version
  end

  # The sample through the production conversion that makes a version editable,
  # which is what the Where tab's writers require.
  #
  # `Conversion` classifies a product by R12 — every rule it uses must share its
  # conditions with a rule of a *differently named* fare — and the sample's two
  # passes each stand alone, so the conversion leaves all seven fares as single
  # rides. The passes table reads a product's kind from `fare_product_details`,
  # so the fixture records the two names that are passes the same way a version
  # whose operator has since said so would hold them.
  defp managed(ctx) do
    version = version(ctx, "North Coast #{System.unique_integer([:positive])}", "north_coast_v2")
    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])
    record_pass_kinds!(ctx, version, %{"day_pass" => ["N_LOCAL"], "month_pass" => ["all_routes"]})
    version
  end

  defp record_pass_kinds!(ctx, version, passes) do
    organization_id = ctx.organization.id

    Repo.all(
      from(detail in FareProductDetail,
        where:
          detail.organization_id == ^organization_id and
            detail.gtfs_version_id == ^version.id
      )
    )
    |> Enum.each(fn detail ->
      base = detail.fare_product_id |> String.split("_adult_") |> hd()

      case Map.fetch(passes, base) do
        {:ok, accepted} ->
          {:ok, _updated} =
            detail
            |> Ecto.Changeset.change(%{kind: "pass", accepted_network_ids: accepted})
            |> Repo.update()

        :error ->
          :ok
      end
    end)
  end

  defp open_where(ctx, version) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/settings/fares/where")

    # The shell's connected mount owns the load, so the tab body only renders
    # once the workspace has arrived.
    assert render(view) =~ "fare-editor-panel"
    view
  end

  defp scope(ctx, version) do
    %{
      organization_id: ctx.organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: ctx.organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: ctx.user.id,
        actor_email: ctx.user.email
      }
    }
  end

  defp local_route_ids(ctx, version) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
    workspace.groups |> Enum.find(&(&1.network_id == "N_LOCAL")) |> Map.fetch!(:route_ids)
  end

  defp route_in_group(ctx, version, network_id, route_id) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)

    Enum.any?(workspace.groups, fn group ->
      group.network_id == network_id and route_id in group.route_ids
    end)
  end

  # The version's networks, read through the workspace the page itself reads, so
  # the assertion is about the same rows the table drew.
  defp networks(ctx, version) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)
    workspace.groups
  end

  # The single-ride products that price one cell, read through the workspace
  # matrix the page itself draws, so the fence a write carries is the list the
  # matrix showed. The list is read per direction because Normalize's mirror runs
  # inside every write: clearing one direction can add rows to the other.
  defp cell_products(ctx, version, from, to) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)

    workspace.matrices
    |> Enum.find(&(&1.network_id == "N_LOCAL"))
    |> Map.fetch!(:cells)
    |> Map.fetch!({from, to})
    |> Map.fetch!(:products)
    |> Enum.sort()
  end

  defp pass_accepts?(ctx, version, product_id, network_id) do
    {:ok, workspace} = Fares.load_workspace(ctx.organization.id, version.id)

    Enum.any?(workspace.fares, fn fare ->
      product_id in fare.product_ids and network_id in fare.accepted_network_ids
    end)
  end
end
