# Seed Olney Transportation Center station from the bundled GTFS export.
#
# Reads the canonical Olney delivery from `priv/repo/seed_data/olney/` —
# stops.txt, pathways.txt, levels.txt, the pathways extensions manifest, and
# the three diagram PNGs — and produces a fully populated station with
# diagrams, stop coordinates, and every applicable pathway field. The PNG
# bytes are loaded via `GtfsPlanner.Gtfs.Extensions.Import.import_extensions/5`,
# which writes them to the configured uploads dir under
# `diagrams/<org_id>/32095/` and upserts the `stop_levels` table with the
# scale calibration from the manifest.
#
# The bundled data is pre-filtered to only Olney-related stops + the canonical
# 3-level structure (BUSWAY / MEZZANINE / PLATFORM) that matches the March 16
# delivery to Noah. To refresh from a new Pathways Studio export, replace the
# files under priv/repo/seed_data/olney/ with the new export's contents,
# applying the same filtering and any level_id remap needed to keep the
# canonical naming.
#
# Idempotent: re-runs upsert and skip duplicate rows.
#
# Prerequisites:
#
#     mix run priv/repo/create_admin_user.exs
#
# Run:
#
#     mix run priv/repo/seed_olney_station.exs

alias GtfsPlanner.{Repo, Gtfs, Versions, Organizations}
alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}
alias GtfsPlanner.Gtfs.Extensions

# ── Configuration ──────────────────────────────────────────────────────────

data_dir = Path.join(__DIR__, "seed_data/olney")

unless File.dir?(data_dir) do
  IO.puts("ERROR: bundled seed data not found at #{Path.relative_to_cwd(data_dir)}")
  System.halt(1)
end

station_stop_id = "32095"

# ── Tiny CSV parser (RFC-4180-ish) ──────────────────────────────────────────
#
# Handles quoted fields with embedded commas and "" escape sequences. Does
# not handle embedded newlines inside quoted fields — the GTFS files we read
# here do not contain those.

defmodule SeedCsv do
  def parse_file(path) do
    path
    |> File.read!()
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
    |> rows_to_maps()
  end

  defp rows_to_maps([header_row | data_rows]) do
    Enum.map(data_rows, fn fields ->
      header_row
      |> Enum.zip(fields ++ List.duplicate("", max(0, length(header_row) - length(fields))))
      |> Enum.into(%{})
    end)
  end

  defp rows_to_maps([]), do: []

  defp parse_line(line), do: parse_line(line, [], "", false)

  defp parse_line("", acc, current, _in_quotes), do: Enum.reverse([current | acc])

  defp parse_line("\"\"" <> rest, acc, current, true),
    do: parse_line(rest, acc, current <> "\"", true)

  defp parse_line("\"" <> rest, acc, current, false),
    do: parse_line(rest, acc, current, true)

  defp parse_line("\"" <> rest, acc, current, true),
    do: parse_line(rest, acc, current, false)

  defp parse_line("," <> rest, acc, current, false),
    do: parse_line(rest, [current | acc], "", false)

  defp parse_line(<<ch::utf8, rest::binary>>, acc, current, in_quotes),
    do: parse_line(rest, acc, current <> <<ch::utf8>>, in_quotes)
end

# ── Coercion helpers ───────────────────────────────────────────────────────

blank_to_nil = fn
  nil -> nil
  "" -> nil
  v -> v
end

parse_int = fn
  nil ->
    nil

  "" ->
    nil

  v ->
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
end

parse_decimal = fn
  nil ->
    nil

  "" ->
    nil

  v ->
    case Decimal.parse(v) do
      {d, ""} -> d
      _ -> nil
    end
end

parse_bool = fn
  "1" -> true
  "0" -> false
  "true" -> true
  "false" -> false
  _ -> nil
end

# ── Org + version ──────────────────────────────────────────────────────────

org =
  case Organizations.get_organization_by_alias("pathwaysstudio") do
    nil ->
      IO.puts("ERROR: Organization 'pathwaysstudio' not found. Run create_admin_user.exs first.")
      System.halt(1)

    org ->
      org
  end

IO.puts("Org: #{org.name} (#{org.id})")

version_name = "Olney Seed"

version =
  case Enum.find(Versions.list_gtfs_versions(org.id), &(&1.name == version_name)) do
    nil ->
      {:ok, v} = Versions.create_gtfs_version(org.id, %{name: version_name})
      v

    existing ->
      existing
  end

IO.puts("Version: #{version.name} (#{version.id})")

# ── Parent station ──────────────────────────────────────────────────────────

stops_path = Path.join(data_dir, "stops.txt")
all_stop_rows = SeedCsv.parse_file(stops_path)

parent_row =
  Enum.find(all_stop_rows, fn r ->
    r["stop_id"] == station_stop_id and r["location_type"] == "1"
  end)

unless parent_row do
  IO.puts("ERROR: parent station #{station_stop_id} not found in stops.txt")
  System.halt(1)
end

parent_attrs = %{
  stop_id: parent_row["stop_id"],
  stop_name: parent_row["stop_name"],
  stop_desc: blank_to_nil.(parent_row["stop_desc"]),
  stop_lat: parse_decimal.(parent_row["stop_lat"]),
  stop_lon: parse_decimal.(parent_row["stop_lon"]),
  location_type: 1,
  wheelchair_boarding: parse_int.(parent_row["wheelchair_boarding"]),
  organization_id: org.id,
  gtfs_version_id: version.id
}

station =
  case Gtfs.get_stop_by_stop_id(org.id, version.id, station_stop_id) do
    nil ->
      {:ok, s} =
        %Stop{}
        |> Stop.import_changeset(parent_attrs)
        |> Repo.insert()

      s

    existing ->
      {:ok, s} =
        existing
        |> Stop.import_changeset(parent_attrs)
        |> Repo.update()

      s
  end

IO.puts("Station: #{station.stop_name} (#{station.id})")

# ── Levels ──────────────────────────────────────────────────────────────────

IO.puts("\nUpserting levels...")

level_rows = SeedCsv.parse_file(Path.join(data_dir, "levels.txt"))

for row <- level_rows do
  attrs = %{
    level_id: row["level_id"],
    level_name: row["level_name"],
    level_index:
      case Float.parse(row["level_index"] || "") do
        {f, _} -> f
        _ -> 0.0
      end,
    organization_id: org.id,
    gtfs_version_id: version.id
  }

  case Repo.get_by(Level,
         organization_id: org.id,
         gtfs_version_id: version.id,
         level_id: row["level_id"]
       ) do
    nil ->
      {:ok, _} = Gtfs.create_level(attrs)
      IO.puts("  + #{row["level_id"]} (#{row["level_name"]})")

    existing ->
      {:ok, _} =
        existing
        |> Level.changeset(attrs)
        |> Repo.update()

      IO.puts("  ~ #{row["level_id"]} (refreshed)")
  end
end

# ── Child stops ────────────────────────────────────────────────────────────
#
# All non-parent rows in the bundled stops.txt belong to Olney (the bundle
# was pre-filtered when it was copied into the repo).

child_rows = Enum.reject(all_stop_rows, fn r -> r["stop_id"] == station_stop_id end)

IO.puts("\nUpserting #{length(child_rows)} child stops...")

upsert_stop = fn row ->
  attrs = %{
    stop_id: row["stop_id"],
    stop_name: blank_to_nil.(row["stop_name"]),
    stop_desc: blank_to_nil.(row["stop_desc"]),
    stop_lat: parse_decimal.(row["stop_lat"]),
    stop_lon: parse_decimal.(row["stop_lon"]),
    location_type: parse_int.(row["location_type"]) || 0,
    wheelchair_boarding: parse_int.(row["wheelchair_boarding"]),
    platform_code: blank_to_nil.(row["platform_code"]),
    parent_station: blank_to_nil.(row["parent_station"]),
    level_id: blank_to_nil.(row["level_id"]),
    organization_id: org.id,
    gtfs_version_id: version.id
  }

  case Gtfs.get_stop_by_stop_id(org.id, version.id, row["stop_id"]) do
    nil ->
      %Stop{}
      |> Stop.import_changeset(attrs)
      |> Repo.insert()

    existing ->
      existing
      |> Stop.import_changeset(attrs)
      |> Repo.update()
  end
end

stop_results = Enum.map(child_rows, upsert_stop)

stop_failures =
  Enum.filter(stop_results, fn
    {:ok, _} -> false
    {:error, _} -> true
  end)

IO.puts(
  "Stops upserted: #{length(stop_results) - length(stop_failures)} ok, #{length(stop_failures)} errors"
)

if stop_failures != [] do
  Enum.each(Enum.take(stop_failures, 5), fn {:error, cs} ->
    IO.puts("  stop error: #{inspect(cs.errors)}")
  end)
end

# ── Pathways ────────────────────────────────────────────────────────────────

IO.puts("\nUpserting pathways...")

pathway_rows = SeedCsv.parse_file(Path.join(data_dir, "pathways.txt"))

upsert_pathway = fn row ->
  attrs = %{
    pathway_id: row["pathway_id"],
    from_stop_id: row["from_stop_id"],
    to_stop_id: row["to_stop_id"],
    pathway_mode: parse_int.(row["pathway_mode"]),
    is_bidirectional: parse_bool.(row["is_bidirectional"]) || false,
    length: parse_decimal.(row["length"]),
    traversal_time: parse_int.(row["traversal_time"]),
    stair_count: parse_int.(row["stair_count"]),
    max_slope: parse_decimal.(row["max_slope"]),
    min_width: parse_decimal.(row["min_width"]),
    signposted_as: blank_to_nil.(row["signposted_as"]),
    reversed_signposted_as: blank_to_nil.(row["reversed_signposted_as"]),
    organization_id: org.id,
    gtfs_version_id: version.id
  }

  case Repo.get_by(Pathway,
         organization_id: org.id,
         gtfs_version_id: version.id,
         pathway_id: row["pathway_id"]
       ) do
    nil ->
      %Pathway{}
      |> Pathway.changeset(attrs)
      |> Repo.insert()

    existing ->
      existing
      |> Pathway.changeset(attrs)
      |> Repo.update()
  end
end

pathway_results = Enum.map(pathway_rows, upsert_pathway)

pathway_failures =
  Enum.filter(pathway_results, fn
    {:ok, _} -> false
    {:error, _} -> true
  end)

IO.puts(
  "Pathways upserted: #{length(pathway_results) - length(pathway_failures)} ok, #{length(pathway_failures)} errors"
)

if pathway_failures != [] do
  Enum.each(Enum.take(pathway_failures, 5), fn {:error, cs} ->
    IO.puts("  pathway error: #{inspect(cs.errors)}")
  end)
end

# ── Extensions: stop diagram coordinates + stop_levels + diagram PNGs ─────

IO.puts("\nLoading manifest + diagrams...")

manifest_path = Path.join(data_dir, "_pathways_extensions.json")
manifest_json = File.read!(manifest_path)
{:ok, raw_manifest} = Jason.decode(manifest_json)

diagram_images = Map.get(raw_manifest, "diagram_images", [])

image_files_by_zip_path =
  for entry <- diagram_images, into: %{} do
    abs_path = Path.join(data_dir, entry["zip_path"])

    unless File.exists?(abs_path) do
      IO.puts("ERROR: diagram PNG not found: #{Path.relative_to_cwd(abs_path)}")
      System.halt(1)
    end

    {entry["zip_path"], File.read!(abs_path)}
  end

IO.puts("Loaded #{map_size(image_files_by_zip_path)} diagram PNG file(s)")

case Extensions.Import.import_extensions(
       org.id,
       version.id,
       manifest_json,
       image_files_by_zip_path
     ) do
  {:ok, counts} ->
    IO.puts("  Extensions import OK: #{inspect(counts)}")

  {:error, reason} ->
    IO.puts("  Extensions import FAILED: #{inspect(reason)}")
    System.halt(1)
end

# ── Summary ────────────────────────────────────────────────────────────────

total_levels = Gtfs.list_levels_for_station(org.id, version.id, station.id) |> length()
total_stops = Gtfs.list_child_stops_for_parent(org.id, version.id, station.id) |> length()
total_pathways = Gtfs.list_pathways_for_station(org.id, version.id, station.id) |> length()

IO.puts("""

✓ Olney Transportation Center seed complete
  Organization:  #{org.name}
  GTFS Version:  #{version.name}
  Station:       #{station.stop_name} (#{station.stop_id})
  Levels:        #{total_levels}
  Child stops:   #{total_stops}
  Pathways:      #{total_pathways}
""")
