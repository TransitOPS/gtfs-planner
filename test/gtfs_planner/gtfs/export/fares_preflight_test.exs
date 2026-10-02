defmodule GtfsPlanner.Gtfs.Export.FaresPreflightTest do
  @moduledoc """
  Merge evidence (EV-30) for the fare preflight check: `Fares.Checks` repair and
  review items reaching a full export as `fares_` warnings (AC-32, R16, FH-30,
  CL-30, INV-5).

  Every expected value is worked by hand from
  `test/fixtures/gtfs/fares/north_coast_v2` and the GTFS reference, never read
  back from the code under test (CR-2):

  - the fixture declares two networks, `N_LOCAL` "Local routes" and
    `N_INTERCITY` "Intercity". `N_LOCAL` prices the pairs `NPT↔NPT`, `TOL↔TOL`,
    `CST↔CST`, `NPT↔TOL`, `NPT↔CST` and `TOL↔CST`, so its nine-cell matrix is
    full; clearing `CST→TOL` leaves the one gap the check names, whose title is
    "1 ride between zones on Local routes has no fare" and whose body is
    "Coast zone → Toledo and valley. Trip planners show no price for these
    rides."
  - every route sits in one of the two groups, and after the production v2
    conversion every `fare_leg_rule` names a network, so the sample prices every
    route. Dropping route 40 from "Local routes" leaves "1 route is in no route
    group" as its body names Route 40.
  - the four `rider_categories.txt` rows hold exactly one default, `adult`, every
    fare is charged by a rule, and the two passes are passes, so the clean sample
    has no other repair or review item to warn about.
  - the pathways profile carries stops, levels and pathways only, so it writes no
    fare file and must not run the fare check.

  The version enters rows through the production importer and the production v2
  conversion, and the gaps are opened through the production writers
  `Fares.set_zone_fare/7` and `Fares.save_route_group/2`, which run inside
  `Fares.VersionLock.transact/2` and end with `Fares.Normalize.run!/2` (INV-1).
  The warnings are read back from a run the production `Export.Worker` built with
  the configured `:otp_preflight_module`, so the path under test is the one an
  export takes (EV-30).
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.FaresFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export.Preflight
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Worker
  alias GtfsPlanner.Gtfs.ExportRuns, as: Runs
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Repo

  setup do
    # The worker publishes bytes, so the run writes into this case's own
    # directory rather than the shared test artifacts path.
    root = Path.join(System.tmp_dir!(), "fares-preflight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous)
    end)

    organization =
      organization_fixture(%{alias: "fares-preflight-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      editor_fixture(organization, %{
        email: "fares-preflight-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares preflight"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      actor: actor,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "Preflight.run/3 on a version with fare gaps" do
    test "reports one issue per repair item, under its own code", context do
      open_gaps(context)

      assert {:error, issues} = Preflight.run(context.organization.id, context.version.id, :full)

      assert fare_issues(issues) == [
               %{
                 code: "fares_zone_pair_without_fare",
                 message:
                   "1 ride between zones on Local routes has no fare. " <>
                     "Coast zone → Toledo and valley. " <>
                     "Trip planners show no price for these rides."
               },
               %{
                 code: "fares_route_without_fare",
                 message:
                   "1 route is in no route group. " <>
                     "Route 40 40 has no fare. Add it to a route group."
               }
             ]
    end

    test "leaves a version with no fare gap without a fares issue", context do
      assert fare_issues_for(context, :full) == []
    end

    test "a pathways run reads no fares at all", context do
      open_gaps(context)

      assert fare_issues_for(context, :pathways) == []
    end
  end

  describe "an export run" do
    test "stores the fare items as warnings and still builds the export", context do
      open_gaps(context)
      {run, claimed, generation, token} = claim_run(context, :full)

      assert :ok = Worker.build(claimed, generation, token, Runs.topic(run))

      ready = Repo.get!(Run, run.id)

      assert ready.state == :ready

      warnings = Enum.filter(ready.warnings, &String.starts_with?(&1["code"], "fares_"))

      assert [
               %{
                 "code" => "fares_zone_pair_without_fare",
                 "detail" => zone_detail
               },
               %{"code" => "fares_route_without_fare", "detail" => route_detail}
             ] = warnings

      assert zone_detail ==
               "1 ride between zones on Local routes has no fare. " <>
                 "Coast zone → Toledo and valley. Trip planners show no price for these rides."

      assert route_detail ==
               "1 route is in no route group. Route 40 40 has no fare. Add it to a route group."
    end

    test "stores no fare warning for a version with no fare gap", context do
      {run, claimed, generation, token} = claim_run(context, :full)

      assert :ok = Worker.build(claimed, generation, token, Runs.topic(run))

      ready = Repo.get!(Run, run.id)

      assert ready.state == :ready
      assert Enum.all?(ready.warnings, &(not String.starts_with?(&1["code"], "fares_")))
    end
  end

  # -- The version's gaps, opened through the production writers ---------------------

  # The two repair items the preflight check turns into warnings. `CST→TOL` is
  # the one cell the sample's matrix is emptied of, and route 40 is the one route
  # dropped from "Local routes".
  defp open_gaps(context) do
    {:ok, _cleared} =
      Fares.set_zone_fare(
        context.scope,
        "N_LOCAL",
        "CST",
        "TOL",
        nil,
        false,
        reviewed_cell(context, "CST", "TOL")
      )

    :ok = classify_blanket_month_passes(context)

    {:ok, _saved} =
      FaresFixtures.save_route_group(context.scope, %{
        network_id: "N_LOCAL",
        name: "Local routes",
        route_ids: Enum.reject(local_routes(context), &(&1 == "40"))
      })
  end

  defp classify_blanket_month_passes(context) do
    month_pass_ids = ~w(month_pass_adult_app month_pass_reduced_app month_pass_youth_app)

    assert {3, nil} =
             Repo.update_all(
               from(detail in FareProductDetail,
                 where:
                   detail.organization_id == ^context.organization.id and
                     detail.gtfs_version_id == ^context.version.id and
                     detail.fare_product_id in ^month_pass_ids
               ),
               set: [kind: "pass"]
             )

    :ok
  end

  # The product ids `CST → TOL` holds as the matrix shows it, which is the fence
  # `set_zone_fare/7` reviews (R15).
  defp reviewed_cell(context, from, to) do
    Fares.Interpreter.load_rows(context.organization.id, context.version.id).fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == "N_LOCAL" and rule.from_area_id == from and rule.to_area_id == to
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp local_routes(context) do
    organization_id = context.organization.id
    gtfs_version_id = context.version.id

    RouteNetwork
    |> where(
      [row],
      row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
        row.network_id == "N_LOCAL"
    )
    |> select([row], row.route_id)
    |> Repo.all()
    |> Enum.sort()
  end

  # -- Helpers ------------------------------------------------------------------------

  # The `fares_` issues `run/3` reported for this version and export type, in the
  # order `Fares.Checks` reports them. `:ok` is the clean answer, so this is the
  # empty list either way rather than a match on a particular shape.
  defp fare_issues_for(context, export_type) do
    case Preflight.run(context.organization.id, context.version.id, export_type) do
      :ok -> []
      {:error, issues} -> fare_issues(issues)
    end
  end

  # The issues this check contributed, in the order `Fares.Checks` reports them.
  defp fare_issues(issues) do
    issues
    |> Enum.filter(&String.starts_with?(&1.code, "fares_"))
    |> Enum.map(&Map.take(&1, [:code, :message]))
  end

  defp claim_run(context, export_type) do
    actor = %{id: context.actor.id, email: context.actor.email}

    {:ok, run} =
      Runs.create_pending(context.organization.id, context.version.id, actor, export_type)

    {:ok, claimed, generation, token} = Runs.claim(context.organization.id, run.id, :build)
    {run, claimed, generation, token}
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end
end
