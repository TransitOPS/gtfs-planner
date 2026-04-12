# Seed Olney Transportation Center station data scraped from dev environment.
#
# Prerequisites: run create_admin_user.exs first to create the org and user.
#
#     mix run priv/repo/create_admin_user.exs
#     mix run priv/repo/seed_olney_station.exs
#
# Data sourced from: https://dev.gtfs-planner.transitops.tech
# Station: Olney Transportation Center (stop 32095)
# GTFS Version: GTFS Bus (faef3382-c3e2-46e0-b75e-1f23731dd05c)

alias GtfsPlanner.{Repo, Gtfs, Versions, Organizations}
alias GtfsPlanner.Gtfs.{Stop, Level, Pathway}
alias GtfsPlanner.Versions.GtfsVersion

# ── Configuration ──────────────────────────────────────────

data_dir = Path.join(File.cwd!(), ".scratch/olney-data")

level_config = [
  %{name: "busway", level_id: "busway", level_name: "Busway", level_index: -1.0},
  %{name: "mezzanine", level_id: "mezzanine", level_name: "Mezzanine", level_index: 0.0},
  %{name: "platform", level_id: "platform", level_name: "Platform", level_index: 1.0}
]

# Pathway mode labels → GTFS pathway_mode integers
mode_map = %{
  "Walkway" => 1,
  "Stairs" => 2,
  "Moving Sidewalk" => 3,
  "Escalator" => 4,
  "Elevator" => 5,
  "Fare Gate" => 6,
  "Exit Gate" => 7
}

# ── Helpers ────────────────────────────────────────────────

defmodule SeedParser do
  @doc "Parse a TSV file with backslash-escaped tabs from chrome-devtools-axi"
  def parse_tsv(path) do
    path
    |> File.read!()
    |> String.replace("\\t", "\t")
    |> String.replace("\\n", "\n")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\", "")
    |> String.trim()
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      line
      |> String.split("\t")
      |> Enum.map(&String.trim/1)
    end)
  end
end

# ── Get or create org ──────────────────────────────────────

org =
  case Organizations.get_organization_by_alias("pathwaysstudio") do
    nil ->
      IO.puts("ERROR: Organization not found. Run create_admin_user.exs first.")
      System.halt(1)

    org ->
      org
  end

IO.puts("Using organization: #{org.name} (#{org.id})")

# ── Get or create GTFS version ─────────────────────────────

version =
  case Versions.list_gtfs_versions(org.id) |> Enum.find(&(&1.name == "Olney Seed")) do
    nil ->
      {:ok, v} = Versions.create_gtfs_version(org.id, %{name: "Olney Seed"})
      v

    existing ->
      existing
  end

IO.puts("Using GTFS version: #{version.name} (#{version.id})")

# ── Create station (parent stop) ──────────────────────────

station_attrs = %{
  stop_id: "32095",
  stop_name: "Olney Transportation Center",
  location_type: 1,
  organization_id: org.id,
  gtfs_version_id: version.id
}

station =
  case Gtfs.get_stop_by_stop_id(org.id, version.id, "32095") do
    nil ->
      {:ok, s} = Gtfs.create_stop(station_attrs)
      s

    existing ->
      existing
  end

IO.puts("Station: #{station.stop_name} (#{station.id})")

# ── Create levels ──────────────────────────────────────────

levels =
  for cfg <- level_config, into: %{} do
    level =
      case Repo.get_by(Level,
             organization_id: org.id,
             gtfs_version_id: version.id,
             level_id: cfg.level_id
           ) do
        nil ->
          {:ok, l} =
            Gtfs.create_level(%{
              level_id: cfg.level_id,
              level_name: cfg.level_name,
              level_index: cfg.level_index,
              organization_id: org.id,
              gtfs_version_id: version.id
            })

          l

        existing ->
          existing
      end

    IO.puts("  Level: #{level.level_name} (#{level.id})")
    {cfg.name, level}
  end

# ── Create stops ───────────────────────────────────────────

IO.puts("\nCreating stops...")

stop_uuid_map =
  for cfg <- level_config, reduce: %{} do
    acc ->
      file = Path.join(data_dir, "stops_#{cfg.name}_full.tsv")

      if File.exists?(file) do
        rows = SeedParser.parse_tsv(file)

        for [server_uuid, stop_id, name, x_str, y_str | _rest] <- rows, into: acc do
          # Determine location_type from stop_id pattern
          location_type =
            cond do
              String.contains?(stop_id, "entrance") -> 2
              String.contains?(stop_id, "boarding") -> 4
              String.contains?(stop_id, "node") -> 3
              # Bus stops with numeric stop_ids
              String.match?(stop_id, ~r/^\d+$/) -> 0
              true -> 3
            end

          x = case Float.parse(x_str) do
            {v, _} -> v
            _ -> nil
          end

          y = case Float.parse(y_str) do
            {v, _} -> v
            _ -> nil
          end

          stop =
            case Gtfs.get_stop_by_stop_id(org.id, version.id, stop_id) do
              nil ->
                {:ok, s} =
                  Gtfs.create_stop(%{
                    stop_id: stop_id,
                    stop_name: name,
                    location_type: location_type,
                    level_id: cfg.level_id,
                    parent_station: "32095",
                    organization_id: org.id,
                    gtfs_version_id: version.id,
                    diagram_coordinate:
                      if x && y do
                        %{"x" => x, "y" => y}
                      else
                        nil
                      end
                  })

                s

              existing ->
                existing
            end

          {server_uuid, stop}
        end
      else
        IO.puts("  WARNING: #{file} not found, skipping")
        acc
      end
  end

IO.puts("Created #{map_size(stop_uuid_map)} stops")

# Build a lookup from server UUID to local stop_id (GTFS string)
uuid_to_stop_id =
  stop_uuid_map
  |> Enum.into(%{}, fn {uuid, stop} -> {uuid, stop.stop_id} end)

# ── Create pathways ────────────────────────────────────────

IO.puts("\nCreating pathways...")

pathway_count =
  for cfg <- level_config, reduce: 0 do
    count ->
      file = Path.join(data_dir, "pathways_#{cfg.name}_full.tsv")

      if File.exists?(file) do
        rows = SeedParser.parse_tsv(file)

        created =
          for [_pw_uuid, from_uuid, to_uuid, mode_label | _rest] <- rows, reduce: 0 do
            n ->
              from_stop_id = Map.get(uuid_to_stop_id, from_uuid)
              to_stop_id = Map.get(uuid_to_stop_id, to_uuid)
              pathway_mode = Map.get(mode_map, mode_label, 1)

              if from_stop_id && to_stop_id do
                pw_id = "pw_#{from_stop_id}_#{to_stop_id}"

                case Repo.get_by(Pathway,
                       organization_id: org.id,
                       gtfs_version_id: version.id,
                       pathway_id: pw_id
                     ) do
                  nil ->
                    {:ok, _} =
                      Gtfs.create_pathway(%{
                        pathway_id: pw_id,
                        pathway_mode: pathway_mode,
                        is_bidirectional: true,
                        from_stop_id: from_stop_id,
                        to_stop_id: to_stop_id,
                        organization_id: org.id,
                        gtfs_version_id: version.id
                      })

                    n + 1

                  _existing ->
                    n
                end
              else
                IO.puts("  WARNING: Could not resolve stops for pathway #{from_uuid} -> #{to_uuid}")
                n
              end
          end

        count + created
      else
        IO.puts("  WARNING: #{file} not found, skipping")
        count
      end
  end

IO.puts("Created #{pathway_count} pathways")

# ── Summary ────────────────────────────────────────────────

total_stops = Gtfs.list_child_stops_for_parent(org.id, version.id, station.id) |> length()
total_pathways = Gtfs.list_pathways_for_station(org.id, version.id, station.id) |> length()
total_levels = Gtfs.list_levels_for_station(org.id, version.id, station.id) |> length()

IO.puts("""

✓ Olney Transportation Center seed complete
  Organization: #{org.name}
  GTFS Version: #{version.name}
  Station: #{station.stop_name} (#{station.stop_id})
  Levels: #{total_levels}
  Stops: #{total_stops}
  Pathways: #{total_pathways}
""")
