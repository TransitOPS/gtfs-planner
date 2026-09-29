defmodule GtfsPlanner.Repo.HomepageReadIndexesTest do
  use GtfsPlanner.DataCase, async: true

  # Both indexes are created concurrently by
  # `priv/repo/migrations/*_add_homepage_read_indexes.exs`, so `mix ecto.migrate`
  # must have run before these catalog reads.
  describe "change_logs_org_version_actor_inserted_index" do
    test "indexes an actor's changes within an organization and version by insert order" do
      assert index_definition("change_logs_org_version_actor_inserted_index") ==
               "CREATE INDEX change_logs_org_version_actor_inserted_index ON public.change_logs " <>
                 "USING btree (organization_id, gtfs_version_id, actor_id, inserted_at)"
    end
  end

  describe "gtfs_validation_runs_reachability_station_index" do
    test "indexes completed reachability runs by station key, newest first" do
      assert index_definition("gtfs_validation_runs_reachability_station_index") ==
               "CREATE INDEX gtfs_validation_runs_reachability_station_index " <>
                 "ON public.gtfs_validation_runs USING btree " <>
                 "(organization_id, gtfs_version_id, " <>
                 "(((result_json -> 'metadata'::text) ->> 'station_stop_id'::text)), " <>
                 "inserted_at DESC) " <>
                 "WHERE (((run_type)::text = 'station_reachability'::text) " <>
                 "AND ((status)::text = 'completed'::text))"
    end
  end

  defp index_definition(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1",
        [name]
      )

    assert [definition] = List.flatten(rows)
    definition
  end
end
