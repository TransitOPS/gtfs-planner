defmodule GtfsPlanner.Gtfs.PathwayEvolutions.PathwayDeletionTest do
  @moduledoc """
  Pathway deletion boundaries through the trusted pathway import and the scoped station
  commands (`Stations.delete_child_stop/3`,
  `Stations.remove_child_stop_from_diagram/3`): a closure-backed pathway returns
  `{:error, :pathway_in_use}` instead of raising the step-1
  `ON DELETE RESTRICT` violation, and every refusal preserves stop
  coordinates, stops, pathways and closures. Expectations are hand-authored
  from the acceptance cases (AC-12, FH-4 rejection for CL-2).
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Stations
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    organization_membership_fixture(actor, organization)

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})

    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "ENT_1",
        location_type: 2,
        parent_station: "STN_1",
        level_id: "L_STREET",
        diagram_coordinate: %{"x" => 12.5, "y" => 34.0}
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "PLAT_1",
        location_type: 0,
        parent_station: "STN_1",
        level_id: "L_PLAT",
        diagram_coordinate: %{"x" => 40.0, "y" => 10.0}
      })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_ENTRY",
      pathway_mode: 2
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_FREE",
      pathway_mode: 1
    })

    calendar_fixture(organization.id, version.id, %{service_id: "SVC_WEEK"})

    %{
      organization: organization,
      version: version,
      actor: actor,
      entrance: entrance,
      platform: platform,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "STN_1",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "Gtfs.delete_pathway/1" do
    test "returns pathway_in_use and preserves the pathway and its closures", context do
      create_closure(context, "PW_ENTRY")

      pathway =
        Gtfs.get_pathway_by_pathway_id(context.organization.id, context.version.id, "PW_ENTRY")

      assert {:error, :pathway_in_use} = Gtfs.apply_import_entity(:remove, :pathway, pathway, %{})

      assert %Pathway{pathway_id: "PW_ENTRY"} =
               Gtfs.get_pathway_by_pathway_id(
                 context.organization.id,
                 context.version.id,
                 "PW_ENTRY"
               )

      assert closure_count(context) == 1
    end

    test "deletes a closure-free pathway", context do
      pathway =
        Gtfs.get_pathway_by_pathway_id(context.organization.id, context.version.id, "PW_FREE")

      assert {:ok, %Pathway{pathway_id: "PW_FREE"}} =
               Gtfs.apply_import_entity(:remove, :pathway, pathway, %{})

      assert Gtfs.get_pathway_by_pathway_id(
               context.organization.id,
               context.version.id,
               "PW_FREE"
             ) ==
               nil
    end
  end

  describe "Stations.delete_child_stop/3" do
    test "returns pathway_in_use and preserves coordinates, stops, pathways and closures",
         context do
      create_closure(context, "PW_ENTRY")

      assert {:error, :pathway_in_use} =
               Stations.delete_child_stop(
                 context.audit,
                 context.entrance.id,
                 context.entrance.lock_version
               )

      entrance = Repo.get!(Stop, context.entrance.id)
      assert entrance.diagram_coordinate == %{"x" => 12.5, "y" => 34.0}

      assert %Pathway{} =
               Gtfs.get_pathway_by_pathway_id(
                 context.organization.id,
                 context.version.id,
                 "PW_ENTRY"
               )

      assert %Pathway{} =
               Gtfs.get_pathway_by_pathway_id(
                 context.organization.id,
                 context.version.id,
                 "PW_FREE"
               )

      assert closure_count(context) == 1
    end

    test "deletes the stop and its pathways when no closure references them", context do
      assert {:ok, _deleted} =
               Stations.delete_child_stop(
                 context.audit,
                 context.entrance.id,
                 context.entrance.lock_version
               )

      assert Repo.get(Stop, context.entrance.id) == nil

      assert Gtfs.get_pathway_by_pathway_id(
               context.organization.id,
               context.version.id,
               "PW_ENTRY"
             ) ==
               nil

      assert Gtfs.get_pathway_by_pathway_id(
               context.organization.id,
               context.version.id,
               "PW_FREE"
             ) ==
               nil
    end
  end

  describe "Stations.remove_child_stop_from_diagram/3" do
    test "returns pathway_in_use and preserves coordinates, stops, pathways and closures",
         context do
      create_closure(context, "PW_ENTRY")

      assert {:error, :pathway_in_use} =
               Stations.remove_child_stop_from_diagram(
                 context.audit,
                 context.entrance.id,
                 context.entrance.lock_version
               )

      entrance = Repo.get!(Stop, context.entrance.id)
      assert entrance.diagram_coordinate == %{"x" => 12.5, "y" => 34.0}
      assert entrance.level_id == "L_STREET"

      assert %Pathway{} =
               Gtfs.get_pathway_by_pathway_id(
                 context.organization.id,
                 context.version.id,
                 "PW_ENTRY"
               )

      assert closure_count(context) == 1
    end

    test "clears the diagram fields when no closure references the pathways", context do
      assert {:ok, updated} =
               Stations.remove_child_stop_from_diagram(
                 context.audit,
                 context.entrance.id,
                 context.entrance.lock_version
               )

      assert updated.diagram_coordinate == nil
      assert updated.level_id == nil

      assert Gtfs.get_pathway_by_pathway_id(
               context.organization.id,
               context.version.id,
               "PW_ENTRY"
             ) ==
               nil
    end
  end

  defp create_closure(context, pathway_id) do
    assert {:ok, _result} =
             Gtfs.create_pathway_evolution(
               %{
                 pathway_id: pathway_id,
                 service_id: "SVC_WEEK",
                 start_time: "09:00",
                 end_time: "15:00"
               },
               context.audit
             )
  end

  defp closure_count(context) do
    Repo.aggregate(
      from(e in PathwayEvolution,
        where:
          e.organization_id == ^context.organization.id and
            e.gtfs_version_id == ^context.version.id
      ),
      :count
    )
  end
end
