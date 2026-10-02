defmodule GtfsPlannerWeb.Gtfs.RouteDetailFaresTest do
  @moduledoc """
  Merge evidence (EV-41) for the route's read-only fare summary and the
  server-owned managed route-group display.

  Fares enter through the production staged importer and conversion. The stale
  page case converts the version only after the route form has mounted, then
  sends a forged `network_id` with a legitimate route edit.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures,
    only: [route_pattern_fixture: 3, route_pattern_stop_fixture: 3]

  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport

  setup context do
    organization =
      organization_fixture(%{alias: "route-fares-#{System.unique_integer([:positive])}"})

    user =
      user_fixture(%{
        email: "route-fares-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
      })

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

  test "managed Route 4 shows its fares and a read-only route group", ctx do
    version = managed(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/routes/4")

    assert has_element?(view, "#route-fares")
    assert has_element?(view, "#route-fares-group", "Local routes")
    refute has_element?(view, "#route-fares-provisional")
    assert has_element?(view, "#route-fares-rides", "Within Toledo and valley")
    assert has_element?(view, "#route-fares-rides", "Within Newport local")
    assert has_element?(view, "#route-fares-rides", "$1.50")
    assert has_element?(view, "#route-fares-rides", "Newport local ↔ Toledo and valley")
    assert has_element?(view, "#route-fares-rides", "$2.50")
    refute has_element?(view, "#route-fares-rides", "Coast zone")
    assert has_element?(view, "#route-fares-passes", "Day pass")
    assert has_element?(view, "#route-fares-transfers", "Pay the difference to Intercity")

    assert has_element?(
             view,
             "#route-fares-edit[href='/gtfs/#{version.id}/settings/fares/where']"
           )

    refute has_element?(view, "#route-details-network")
    assert has_element?(view, "#route-details-network-value", "Local routes")
  end

  test "an unmanaged imported version keeps its fare network input", ctx do
    version = imported(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/routes/4")

    refute has_element?(view, "#route-fares")
    assert has_element?(view, "#route-details-network")
  end

  test "an ungrouped route shows a managed blanket fare", ctx do
    version = gtfs_version_fixture(ctx.organization.id, %{name: "Flat fare"})
    FaresFixtures.import!(ctx.organization, version, "no_fare")

    assert {:ok, _} =
             Conversion.setup(scope(ctx, version), %{kind: :flat, adult: Decimal.new("2.00")})

    pattern =
      route_pattern_fixture(ctx.organization.id, version.id, %{
        route_id: "4",
        route_pattern_id: "blanket-route-4"
      })

    route_pattern_stop_fixture(pattern, "NTC", 1)
    route_pattern_stop_fixture(pattern, "TOLEDO", 2)

    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/routes/4")
    assert has_element?(view, "#route-fares-rides", "$2.00")
    assert has_element?(view, "#route-fares-group", "No route group")
  end

  test "a managed route without patterns labels its group fares as provisional", ctx do
    version = imported(ctx)
    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    {:ok, _conversion} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/routes/4")

    assert has_element?(view, "#route-fares-provisional", "Route patterns aren’t set yet")
    assert has_element?(view, "#route-fares-provisional", "Local routes")
  end

  test "a stale form rechecks managed scope and ignores forged network membership", ctx do
    version = imported(ctx)
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{version.id}/routes/4")
    assert has_element?(view, "#route-details-network")

    convert!(ctx, version)
    {:ok, before} = Fares.load_workspace(ctx.organization.id, version.id)
    assert Enum.any?(before.groups, &(&1.network_id == "N_LOCAL" and "4" in &1.route_ids))

    render_submit(view, "save_route_details", %{
      "route" => %{"route_long_name" => "Toledo – Newport edited", "network_id" => "N_INTERCITY"}
    })

    {:ok, after_save} = Fares.load_workspace(ctx.organization.id, version.id)
    assert Enum.any?(after_save.groups, &(&1.network_id == "N_LOCAL" and "4" in &1.route_ids))
    refute Enum.any?(after_save.groups, &(&1.network_id == "N_INTERCITY" and "4" in &1.route_ids))
    refute has_element?(view, "#route-details-network")
    assert has_element?(view, "#route-details-network-value", "Local routes")

    saved =
      Repo.get_by!(Route,
        organization_id: ctx.organization.id,
        gtfs_version_id: version.id,
        route_id: "4"
      )

    assert saved.network_id == nil
    assert saved.route_long_name == "Toledo – Newport edited"
  end

  defp imported(ctx) do
    version =
      gtfs_version_fixture(ctx.organization.id, %{
        name: "North Coast #{System.unique_integer([:positive])}"
      })

    fixture_path = FaresFixtures.fixture_path!("north_coast_v2")

    files =
      fixture_path
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) == ".txt"))
      |> Enum.sort()
      |> Enum.map(fn filename ->
        %{filename: filename, content: File.read!(Path.join(fixture_path, filename))}
      end)

    assert {:ok, _result} = StagedImport.import_files(ctx.organization.id, version.id, files)
    version
  end

  defp managed(ctx) do
    version = imported(ctx)
    convert!(ctx, version)

    Repo.all(
      from detail in FareProductDetail,
        where:
          detail.organization_id == ^ctx.organization.id and
            detail.gtfs_version_id == ^version.id
    )
    |> Enum.each(fn detail ->
      base = detail.fare_product_id |> String.split("_adult_") |> hd()

      accepted =
        case base do
          "day_pass" -> ["N_LOCAL"]
          "month_pass" -> ["all_routes"]
          _other -> nil
        end

      if accepted do
        Repo.update!(
          Ecto.Changeset.change(detail, %{kind: "pass", accepted_network_ids: accepted})
        )
      end
    end)

    scope = scope(ctx, version)

    {:ok, _result} =
      Transfers.save(scope, "N_LOCAL", "N_INTERCITY", %{pay: :difference, minutes: 90}, nil)

    version
  end

  defp convert!(ctx, version) do
    {:ok, plan} = Conversion.preview(ctx.organization.id, version.id)
    {:ok, _result} = Conversion.apply(scope(ctx, version), plan.fingerprint, [])

    pattern =
      route_pattern_fixture(ctx.organization.id, version.id, %{
        route_id: "4",
        route_pattern_id: "step42-route-4"
      })

    route_pattern_stop_fixture(pattern, "NTC", 1)
    route_pattern_stop_fixture(pattern, "TOLEDO", 2)
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
end
