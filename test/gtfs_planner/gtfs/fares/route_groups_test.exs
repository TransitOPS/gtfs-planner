defmodule GtfsPlanner.Gtfs.Fares.RouteGroupsTest do
  @moduledoc """
  Merge evidence (EV-19) for `Fares.save_route_group/2`,
  `Fares.delete_route_group/3` and the inverse `Fares.undo/3` applies (AC-19,
  AC-26, R3, R4, R8, R15, FH-19).

  Every expected value is worked by hand from the fixture and from the rules,
  never read back from the code under test (CR-2):

  - `test/fixtures/gtfs/fares/north_coast_v2` declares two `networks` rows,
    `N_LOCAL` "Local routes" and `N_INTERCITY` "Intercity", and thirteen
    `route_networks` rows: routes 1–7, 11, 12, 20, 21, 30 and 40 are in
    `N_LOCAL`, and route 10 alone is in `N_INTERCITY`.
  - the converted version's leg rules are the fixture's forty-six: 39 naming
    `N_LOCAL`, 4 naming `N_INTERCITY` (the Intercity ride's four rider types)
    and 3 naming no network (the 31-day pass's three riders). `leg_group_id` is
    the network id for each of them (R3), so moving a route moves no rule.
  - the fixture's three `fare_transfer_rules` rows name `LG_LOCAL` and
    `LG_INTERCITY` in their leg group columns, which are the imported groups'
    own ids and not either network id, so on this version they reference no
    route group and no delete settles them.
  - no `fare_product_details` row of this version has `kind = "pass"`, so the
    pass acceptance of a group is only reached by a test that makes one: saving
    the Day pass as a pass through `Fares.save_fare/2`, the same way an operator
    would.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/2` with
  `Fares.Normalize.run!/2` before the commit, which is the path every writer of
  this package takes. `Normalize.run!/2` is also what rebuilds a pass's mirrored
  rows after a delete drops a group from its accepted networks (R4), and what
  would raise on a version left with two default rider types (R8).
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Repo

  # The thirteen routes of `N_LOCAL` in the fixture, sorted as the read model
  # sorts them, and the same list once route 10 has been added.
  @local_routes ~w(1 11 12 2 20 21 3 30 4 40 5 6 7)
  @local_routes_with_ten ~w(1 10 11 12 2 20 21 3 30 4 40 5 6 7)

  setup do
    organization =
      organization_fixture(%{alias: "fares-route-groups-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      editor_fixture(organization, %{
        email: "fares-route-groups-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "adding a route to a route group" do
    test "moves it out of the group that held it and answers which one", context do
      assert {:ok, result} =
               Fares.save_route_group(context.scope, local_form(@local_routes ++ ["10"]))

      # AC-19: the routes it moved, and the group each came from.
      assert result.moved == [%{route_id: "10", from_network_id: "N_INTERCITY"}]

      assert group_routes(context, "N_LOCAL") == @local_routes_with_ten
      assert group_routes(context, "N_INTERCITY") == []

      # A route is in at most one group, which is the rule the move exists for.
      assert duplicated_routes(context) == []

      {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert Enum.find(workspace.groups, &(&1.network_id == "N_LOCAL")).route_ids ==
               @local_routes_with_ten
    end

    test "a route the form leaves out is removed from the group", context do
      assert {:ok, result} = Fares.save_route_group(context.scope, local_form(["1", "2"]))

      assert result.moved == []
      assert group_routes(context, "N_LOCAL") == ["1", "2"]
      assert group_routes(context, "N_INTERCITY") == ["10"]

      # The group's leg rules are not this writer's to change (R3, INV-4): they
      # still name the group, which is what its zone matrix is built from.
      assert leg_rule_networks(context) == %{nil => 3, "N_INTERCITY" => 4, "N_LOCAL" => 39}
    end

    test "renaming leaves the id every rule names alone, and records one entry", context do
      assert {:ok, result} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_LOCAL",
                 name: "Local and near",
                 route_ids: @local_routes
               })

      assert result.moved == []
      assert network_name(context, "N_LOCAL") == "Local and near"
      assert leg_group_ids(context, "N_LOCAL") == MapSet.new(["N_LOCAL"])

      assert [entry] = group_writes(context, "updated")
      assert entry.id == result.operation_id
      assert entry.changed_fields["summary"] == "Updated the route group \"Local and near\""

      # A repeated save of what is already stored is still one operation, with
      # no route moved and nothing written.
      assert {:ok, repeat} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_LOCAL",
                 name: "Local and near",
                 route_ids: @local_routes
               })

      assert repeat.moved == []
      assert length(group_writes(context, "updated")) == 2
    end

    test "a name this version already holds, a blank name and an unknown id are refused",
         context do
      # A group's GTFS id is its name as an id, so an operator naming
      # "Coast runs" again is creating a second group with the first's id.
      assert {:ok, _created} =
               Fares.save_route_group(context.scope, %{name: "Coast runs", route_ids: []})

      assert {:error, :duplicate_route_group} =
               Fares.save_route_group(context.scope, %{name: "Coast runs", route_ids: []})

      assert {:error, changeset} =
               Fares.save_route_group(context.scope, %{name: "   ", route_ids: []})

      assert "can't be blank" in errors_on(changeset).name

      assert {:error, :not_found} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_NOWHERE",
                 name: "Nowhere",
                 route_ids: []
               })

      # A route this version does not hold is another version's route, which is
      # never written into this one's `route_networks` (INV-5).
      assert {:error, :not_found} =
               Fares.save_route_group(context.scope, local_form(@local_routes ++ ["9999"]))

      assert {:error, :unmanaged} =
               Fares.save_route_group(unmanaged_scope(context), %{name: "Somewhere"})

      assert {:error, :not_found} =
               Fares.save_route_group(staging_scope(context), %{name: "Somewhere"})

      assert group_names(context) == [
               {"N_INTERCITY", "Intercity"},
               {"N_LOCAL", "Local routes"},
               {"coast_runs", "Coast runs"}
             ]

      assert group_routes(context, "N_LOCAL") == @local_routes
      assert group_routes(context, "coast_runs") == []
    end
  end

  describe "deleting a route group" do
    test "a group its leg rules name is refused and nothing is deleted", context do
      # The prepared case: N_INTERCITY names four leg rules, so deleting it
      # without settling them would leave rules naming a group that is gone.
      assert {:error, :rules_reference_group} =
               Fares.delete_route_group(context.scope, "N_INTERCITY", %{name: "Intercity"})

      assert group_names(context) == [{"N_INTERCITY", "Intercity"}, {"N_LOCAL", "Local routes"}]
      assert leg_rule_networks(context) == %{nil => 3, "N_INTERCITY" => 4, "N_LOCAL" => 39}
    end

    test "a name the drawer reviewed is the fence", context do
      assert {:error, {:stale, details}} =
               Fares.delete_route_group(context.scope, "N_INTERCITY", %{name: "Intercity plus"})

      assert details == [
               %{field: :name, reviewed: "Intercity plus", stored: "Intercity"}
             ]

      assert group_names(context) == [{"N_INTERCITY", "Intercity"}, {"N_LOCAL", "Local routes"}]
    end

    test "`:remove_rules` deletes the group's own rules with the group", context do
      assert {:ok, _result} =
               Fares.delete_route_group(context.scope, "N_INTERCITY", %{
                 name: "Intercity",
                 remove_rules: true
               })

      assert network_row(context, "N_INTERCITY") == nil
      assert group_routes(context, "N_INTERCITY") == []

      # Four Intercity rows went with the group; the other forty-two stayed.
      assert leg_rule_networks(context) == %{nil => 3, "N_LOCAL" => 39}
    end

    test "a group nothing names is deleted whole, and one a pass accepts is not", context do
      assert {:ok, _created} =
               Fares.save_route_group(context.scope, %{name: "Coast runs", route_ids: ["1", "2"]})

      assert {:ok, _pass} =
               Fares.save_fare(context.scope, %{
                 fare_product_id: "day_pass_adult_cash",
                 name: "Day pass",
                 kind: "pass",
                 media_ids: ["cash"],
                 prices: %{"adult" => "4.00", "reduced" => "2.00", "youth" => "2.00"},
                 accepted_network_ids: ["N_LOCAL", "coast_runs"]
               })

      assert {:error, :group_accepted_by_pass} =
               Fares.delete_route_group(context.scope, "coast_runs", %{name: "Coast runs"})

      assert {:ok, _deleted} =
               Fares.delete_route_group(context.scope, "coast_runs", %{
                 name: "Coast runs",
                 remove_rules: true
               })

      assert network_row(context, "coast_runs") == nil
      assert group_routes(context, "coast_runs") == []

      # The routes went back to being in no group rather than to another group:
      # only this writer's own group held them.
      assert group_routes(context, "N_LOCAL") == @local_routes -- ["1", "2"]

      # R4: the pass no longer accepts a group that is gone, so Normalize
      # writes no pass row of it back.
      assert accepted_networks(context, "day_pass_adult_cash") == ["N_LOCAL"]
    end

    test "an unknown group, an unmanaged version and a version that is not published", context do
      assert {:error, :not_found} =
               Fares.delete_route_group(context.scope, "N_NOWHERE", %{name: "Nowhere"})

      assert {:error, :unmanaged} =
               Fares.delete_route_group(unmanaged_scope(context), "N_LOCAL", %{
                 name: "Local routes"
               })

      assert {:error, :not_found} =
               Fares.delete_route_group(staging_scope(context), "N_LOCAL", %{name: "Local routes"})

      assert group_names(context) == [{"N_INTERCITY", "Intercity"}, {"N_LOCAL", "Local routes"}]
    end
  end

  describe "undoing a route group change" do
    test "a move goes back where it came from, and its rename with it", context do
      assert {:ok, moved} =
               Fares.save_route_group(context.scope, local_form(@local_routes ++ ["10"]))

      assert {:ok, _undone} = Fares.undo(context.scope, moved.operation_id, moved.inverse)

      assert group_routes(context, "N_LOCAL") == @local_routes
      assert group_routes(context, "N_INTERCITY") == ["10"]
      assert network_name(context, "N_LOCAL") == "Local routes"

      # R15: a second reversal of the same operation is stale, not applied
      # twice, and the rows are still the fixture's.
      assert {:error, :stale} = Fares.undo(context.scope, moved.operation_id, moved.inverse)
      assert group_routes(context, "N_INTERCITY") == ["10"]
    end

    test "a move whose route has been moved since is stale", context do
      assert {:ok, moved} =
               Fares.save_route_group(context.scope, local_form(@local_routes ++ ["10"]))

      assert {:ok, _back} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_INTERCITY",
                 name: "Intercity",
                 route_ids: ["10"]
               })

      assert {:error, :stale} = Fares.undo(context.scope, moved.operation_id, moved.inverse)
      assert group_routes(context, "N_INTERCITY") == ["10"]
      assert group_routes(context, "N_LOCAL") == @local_routes
    end

    test "a created group is deleted again by its own inverse", context do
      assert {:ok, created} =
               Fares.save_route_group(context.scope, %{name: "Coast runs", route_ids: ["1"]})

      assert {:ok, _undone} = Fares.undo(context.scope, created.operation_id, created.inverse)

      assert network_row(context, "coast_runs") == nil
      assert group_routes(context, "coast_runs") == []
      assert group_routes(context, "N_LOCAL") == @local_routes
    end

    test "a deleted group comes back with its routes, its rules and its pass acceptance",
         context do
      {:ok, _pass} =
        Fares.save_fare(context.scope, %{
          fare_product_id: "day_pass_adult_cash",
          name: "Day pass",
          kind: "pass",
          media_ids: ["cash"],
          prices: %{"adult" => "4.00", "reduced" => "2.00", "youth" => "2.00"},
          accepted_network_ids: ["N_LOCAL", "N_INTERCITY"]
        })

      assert {:ok, deleted} =
               Fares.delete_route_group(context.scope, "N_INTERCITY", %{
                 name: "Intercity",
                 remove_rules: true
               })

      assert network_row(context, "N_INTERCITY") == nil
      assert accepted_networks(context, "day_pass_adult_cash") == ["N_LOCAL"]

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert network_name(context, "N_INTERCITY") == "Intercity"
      assert group_routes(context, "N_INTERCITY") == ["10"]

      # The four Intercity rows the delete took are back. The pass's own
      # mirrored rows (R4) are not counted here, because Normalize writes those
      # from the accepted networks rather than restoring them.
      assert intercity_ride_rules(context) == 4
      assert accepted_networks(context, "day_pass_adult_cash") == ["N_INTERCITY", "N_LOCAL"]

      assert {:error, :stale} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)
    end

    test "an operation id this version does not hold is stale", context do
      assert {:ok, created} =
               Fares.save_route_group(context.scope, %{name: "Coast runs", route_ids: ["1"]})

      assert {:error, :stale} =
               Fares.undo(context.scope, Ecto.UUID.generate(), created.inverse)

      assert network_row(context, "coast_runs") != nil
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # The route group drawer's form for `N_LOCAL`, which the fixture names "Local
  # routes"; a save states the whole set of routes in the group.
  defp local_form(route_ids) do
    %{network_id: "N_LOCAL", name: "Local routes", route_ids: route_ids}
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

  defp scope_for(context, gtfs_version_id) do
    %{
      context.scope
      | gtfs_version_id: gtfs_version_id,
        audit: %{context.scope.audit | gtfs_version_id: gtfs_version_id}
    }
  end

  # A second version of the same organization, imported but never converted, so a
  # refusal can be asked of a scope that names an unmanaged version.
  defp unmanaged_scope(context) do
    version = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged fares"})
    import!(context.organization, version, "north_coast_v2")
    scope_for(context, version.id)
  end

  defp staging_scope(context) do
    {:ok, staging} =
      GtfsPlanner.Versions.create_staging_gtfs_version(context.organization.id, %{
        name: "Staging fares"
      })

    scope_for(context, staging.id)
  end

  defp network_rows(context) do
    Network
    |> where(
      [network],
      network.organization_id == ^context.organization.id and
        network.gtfs_version_id == ^context.version.id
    )
    |> Repo.all()
  end

  defp network_row(context, network_id) do
    Enum.find(network_rows(context), &(&1.network_id == network_id))
  end

  defp network_name(context, network_id) do
    case network_row(context, network_id) do
      nil -> nil
      network -> network.network_name
    end
  end

  defp group_names(context) do
    context
    |> network_rows()
    |> Enum.map(&{&1.network_id, &1.network_name})
    |> Enum.sort()
  end

  defp membership_rows(context) do
    RouteNetwork
    |> where(
      [row],
      row.organization_id == ^context.organization.id and
        row.gtfs_version_id == ^context.version.id
    )
    |> Repo.all()
  end

  defp group_routes(context, network_id) do
    context
    |> membership_rows()
    |> Enum.filter(&(&1.network_id == network_id))
    |> Enum.map(& &1.route_id)
    |> Enum.sort()
  end

  # Every route in more than one group, which AC-19 says is never a state.
  defp duplicated_routes(context) do
    context
    |> membership_rows()
    |> Enum.frequencies_by(& &1.route_id)
    |> Enum.filter(fn {_route_id, count} -> count > 1 end)
    |> Enum.map(fn {route_id, _count} -> route_id end)
  end

  defp leg_rule_rows(context) do
    FareLegRule
    |> where(
      [rule],
      rule.organization_id == ^context.organization.id and
        rule.gtfs_version_id == ^context.version.id
    )
    |> Repo.all()
  end

  defp leg_rule_networks(context) do
    context
    |> leg_rule_rows()
    |> Enum.map(& &1.network_id)
    |> Enum.frequencies()
  end

  defp leg_group_ids(context, network_id) do
    context
    |> leg_rule_rows()
    |> Enum.filter(&(&1.network_id == network_id))
    |> Enum.map(& &1.leg_group_id)
    |> MapSet.new()
  end

  # The Intercity ride's own leg rules: the four rider types the fixture prices
  # it for, in the group the delete settled.
  defp intercity_ride_rules(context) do
    Enum.count(leg_rule_rows(context), fn rule ->
      rule.network_id == "N_INTERCITY" and
        String.starts_with?(rule.fare_product_id, "intercity_ride_")
    end)
  end

  defp accepted_networks(context, fare_product_id) do
    FareProductDetail
    |> where(
      [detail],
      detail.organization_id == ^context.organization.id and
        detail.gtfs_version_id == ^context.version.id and
        detail.fare_product_id == ^fare_product_id
    )
    |> Repo.one()
    |> Map.fetch!(:accepted_network_ids)
  end

  # The change-log entries whose summary names a route group, which are this
  # step's two writers' and their reversal. The conversion writes a `created`
  # entry of its own for the whole version, and a fare save names a fare.
  defp group_writes(context, action) do
    ChangeLog
    |> where(
      [log],
      log.organization_id == ^context.organization.id and
        log.gtfs_version_id == ^context.version.id and
        log.entity_type == "fare_version" and log.action == ^action
    )
    |> Repo.all()
    |> Enum.filter(&group_summary?(&1.changed_fields["summary"]))
  end

  defp group_summary?(summary) when is_binary(summary) do
    String.starts_with?(summary, "Created the route group ") or
      String.starts_with?(summary, "Updated the route group ") or
      String.starts_with?(summary, "Deleted the route group ") or
      String.starts_with?(summary, "Restored the route group ")
  end

  defp group_summary?(_summary), do: false
end
