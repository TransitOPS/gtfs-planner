defmodule GtfsPlanner.Repo.StopTimesStopTripIndexTest do
  use GtfsPlanner.DataCase, async: true

  # `priv/repo/migrations/*_cover_stop_times_stop_trip_sequence.exs` builds the index
  # concurrently, so `mix ecto.migrate` must have run before these catalog reads.
  describe "stop_times_stop_trip_incl_seq_idx" do
    test "keys a stop's stop times by trip and stores the sequence for index-only scans" do
      assert index_definition("stop_times_stop_trip_incl_seq_idx") ==
               "CREATE INDEX stop_times_stop_trip_incl_seq_idx ON public.stop_times " <>
                 "USING btree (organization_id, gtfs_version_id, stop_id, trip_id) " <>
                 "INCLUDE (stop_sequence)"
    end

    test "replaces the index without the stored sequence" do
      assert is_nil(index_definition("stop_times_org_version_stop_trip_idx"))
    end
  end

  defp index_definition(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1",
        [name]
      )

    case List.flatten(rows) do
      [definition] -> definition
      [] -> nil
    end
  end
end
