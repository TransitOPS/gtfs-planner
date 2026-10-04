defmodule GtfsPlanner.Gtfs.FareZones.PreparedAssignmentTest do
  @moduledoc """
  Merge evidence (EV-3) for the selection fence of `FareZones.apply_assignment/3`.

  A prepared assignment carries the route predicate, the selection fingerprint
  and the explicit stop IDs it was built from. The apply recomputes the selection
  inside the version-locked transaction and refuses with zero writes on any
  difference: a stop joining the route, a zone change on a selected or a
  non-selected served stop, a deleted route, or a stop set that is not the
  selection. A change outside the prepared stops is an invalid selection. The
  two-argument path, Undo and the revoked-editor refusal behave as before.

  Every refusal re-reads the stored zones and `updated_at` and compares them with
  the rows read before the call. The expected zones are hand-written from
  `GtfsPlanner.FareSelectionFixtures`. Lock waiting against a competing writer is
  step 4's independent-connection test; this file runs on one sandbox connection.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  @predicate %{route_ids: ["R6"], only_unzoned?: true, exclude_stop_ids: ["AIR1"]}

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    stops = FareSelectionFixtures.insert_network!(organization, version)
    FareSelectionFixtures.declare_zone!(organization, version, "C")
    actor = AccountsFixtures.user_fixture()
    membership = AccountsFixtures.organization_membership_fixture(actor, organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    {:ok, selection} =
      FareZones.route_selection(organization.id, version.id, @predicate)

    prepared = %{
      predicate: @predicate,
      fingerprint: selection.fingerprint,
      stop_ids: Enum.map(selection.stops, & &1.id)
    }

    %{
      organization: organization,
      version: version,
      stops: stops,
      audit: audit,
      membership: membership,
      prepared: prepared,
      changes: [
        %{id: stops["A1"].id, from: nil, to: "B"},
        %{id: stops["A3"].id, from: nil, to: "B"}
      ]
    }
  end

  defp stored(version) do
    Repo.all(
      from(s in Stop,
        where: s.gtfs_version_id == ^version.id,
        order_by: s.stop_id,
        select: {s.stop_id, s.zone_id, s.updated_at}
      )
    )
  end

  defp zones(version),
    do: for({stop_id, zone_id, _} <- stored(version), into: %{}, do: {stop_id, zone_id})

  test "a matching selection writes exactly the changes", ctx do
    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

    assert applied == ctx.changes

    assert zones(ctx.version) == %{
             "A1" => "B",
             "A2" => "B",
             "A3" => "B",
             "AIR1" => nil,
             "AIR2" => nil,
             "U1" => nil,
             "S1" => nil
           }
  end

  describe "a changed selection refuses with zero writes" do
    test "a stop joins the route (U1 called at by T6)", ctx do
      before = stored(ctx.version)

      GtfsFixtures.stop_time_fixture(ctx.organization.id, ctx.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      assert {:error, :selection_changed} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

      assert stored(ctx.version) == before
    end

    test "a non-selected served stop loses its zone (A2 cleared)", ctx do
      Repo.update_all(from(s in Stop, where: s.id == ^ctx.stops["A2"].id), set: [zone_id: nil])
      before = stored(ctx.version)

      assert {:error, :selection_changed} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

      assert stored(ctx.version) == before
    end

    test "a selected stop's zone changes (A1 to C)", ctx do
      Repo.update_all(from(s in Stop, where: s.id == ^ctx.stops["A1"].id), set: [zone_id: "C"])
      before = stored(ctx.version)

      assert {:error, :selection_changed} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

      assert stored(ctx.version) == before
    end

    test "a predicate naming a deleted route no longer resolves", ctx do
      Repo.delete_all(
        from(r in Route, where: r.gtfs_version_id == ^ctx.version.id and r.route_id == "R6")
      )

      before = stored(ctx.version)

      assert {:error, :selection_changed} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

      assert stored(ctx.version) == before
    end

    test "stop IDs that are not the recomputed selection", ctx do
      before = stored(ctx.version)
      prepared = %{ctx.prepared | stop_ids: [ctx.stops["A1"].id]}

      assert {:error, :selection_changed} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: prepared)

      assert stored(ctx.version) == before
    end
  end

  test "a change outside the prepared stops is an invalid selection", ctx do
    before = stored(ctx.version)
    outside = ctx.changes ++ [%{id: ctx.stops["A2"].id, from: "B", to: "C"}]

    assert {:error, :invalid_selection} =
             FareZones.apply_assignment(ctx.audit, outside, selection: ctx.prepared)

    assert stored(ctx.version) == before
  end

  describe "the paths without a selection are unchanged" do
    test "apply_assignment/2 still succeeds after the membership changed, and Undo restores",
         ctx do
      GtfsFixtures.stop_time_fixture(ctx.organization.id, ctx.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      before = zones(ctx.version)

      assert {:ok, %{applied: applied}} = FareZones.apply_assignment(ctx.audit, ctx.changes)
      assert %{"A1" => "B", "A3" => "B"} = zones(ctx.version)

      assert {:ok, _} = FareZones.undo_assignment(ctx.audit, applied)
      assert zones(ctx.version) == before
    end

    test "a revoked editor is refused before the selection is checked", ctx do
      GtfsFixtures.stop_time_fixture(ctx.organization.id, ctx.version.id, "T6", "U1", %{
        stop_sequence: 9
      })

      AccountsFixtures.deactivate_membership_fixture(ctx.membership)
      before = stored(ctx.version)

      assert {:error, :forbidden} =
               FareZones.apply_assignment(ctx.audit, ctx.changes, selection: ctx.prepared)

      assert stored(ctx.version) == before
    end
  end
end
