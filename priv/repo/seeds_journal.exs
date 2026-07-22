# Dev seed: station journal entries for a real diagram'd station.
#
#     mix run priv/repo/seeds_journal.exs
#
# Populates the station journal panel with a full spread of states so the
# Floorplans view can be exercised locally: all four target types (station,
# node, pathway, pin), open and closed entries, and an entry with photos.
#
# Idempotent — every record uses a fixed UUID, so re-running replaces the seed
# set in place rather than accumulating duplicates. Targets the station the
# reviewer is working against:
#
#     /gtfs/1a510bea-b5e5-492e-831f-9ac824e55867/stops/32095/diagram
#
# Resolves org / level / author / node / pathway IDs from the database at run
# time, so it stays correct if those internal IDs differ from any snapshot.

alias GtfsPlanner.Repo
alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
alias GtfsPlanner.Gtfs.Extensions.PathSafety
import Ecto.Query

version_id = "1a510bea-b5e5-492e-831f-9ac824e55867"
station_stop_id = "32095"

fail = fn message ->
  IO.puts(:stderr, "\n[seeds_journal] #{message}")
  System.halt(1)
end

# ── Resolve the scaffold from real data ──────────────────────────────────────

station =
  Repo.one(
    from s in "stops",
      where:
        s.gtfs_version_id == type(^version_id, :binary_id) and s.stop_id == ^station_stop_id,
      select: %{id: s.id, org_id: s.organization_id, name: s.stop_name}
  )

station ||
  fail.("Station stop_id=#{station_stop_id} not found in version #{version_id}. " <>
          "Check the version/stop against your dev database.")

# Schemaless selects return raw 16-byte binaries; schema structs and file paths
# both want the canonical string UUID form.
u = &Ecto.UUID.cast!/1
org_id = u.(station.org_id)
station_uuid = u.(station.id)

level =
  Repo.one(
    from sl in "stop_levels",
      where: sl.stop_id == type(^station_uuid, :binary_id) and not is_nil(sl.diagram_filename),
      select: %{id: sl.id, filename: sl.diagram_filename},
      order_by: sl.id,
      limit: 1
  )

level || fail.("Station #{station_stop_id} has no stop_level with a diagram; nothing to pin against.")

author =
  Repo.one(
    from m in "user_org_memberships",
      join: usr in "users",
      on: usr.id == m.user_id,
      where: m.organization_id == type(^org_id, :binary_id),
      select: %{id: usr.id, email: usr.email},
      order_by: m.inserted_at,
      limit: 1
  )

author || fail.("No user is a member of the station's organization; cannot set an author.")

nodes =
  Repo.all(
    from s in "stops",
      where:
        s.gtfs_version_id == type(^version_id, :binary_id) and
          s.parent_station == ^station_stop_id,
      select: %{id: s.id, name: s.stop_name},
      order_by: s.stop_id,
      limit: 3
  )

length(nodes) >= 3 ||
  fail.("Expected at least 3 child stops under #{station_stop_id}, found #{length(nodes)}.")

child_stop_ids =
  Repo.all(
    from s in "stops",
      where:
        s.gtfs_version_id == type(^version_id, :binary_id) and
          s.parent_station == ^station_stop_id,
      select: s.stop_id
  )

pathway =
  Repo.one(
    from p in "pathways",
      where:
        p.gtfs_version_id == type(^version_id, :binary_id) and
          (p.from_stop_id in ^child_stop_ids or p.to_stop_id in ^child_stop_ids),
      select: %{id: p.id, pathway_id: p.pathway_id},
      order_by: p.id,
      limit: 1
  )

pathway || fail.("No pathway touches station #{station_stop_id}; cannot seed a pathway entry.")

[node_a, node_b, node_c] = Enum.take(nodes, 3)

# ── Diagram dimensions (to center the pin on the canvas) ─────────────────────

uploads_path = Application.fetch_env!(:gtfs_planner, :uploads_path)
station_dir = PathSafety.stop_storage_dir(station_stop_id)

diagram_path =
  Path.join([uploads_path, "diagrams", org_id, version_id, station_dir, level.filename])

{pin_x, pin_y} =
  case File.read(diagram_path) do
    {:ok, <<_::binary-size(16), w::32, h::32, _::binary>>} -> {w / 2, h / 2}
    _ -> {480.0, 320.0}
  end

# ── Placeholder photo bytes (small solid-color PNGs) ─────────────────────────

png = fn {r, g, b} ->
  chunk = fn type, data ->
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  w = 16
  h = 12
  ihdr = <<w::32, h::32, 8, 2, 0, 0, 0>>
  row = <<0>> <> :binary.copy(<<r, g, b>>, w)
  idat = :zlib.compress(:binary.copy(row, h))

  <<137, 80, 78, 71, 13, 10, 26, 10>> <>
    chunk.("IHDR", ihdr) <> chunk.("IDAT", idat) <> chunk.("IEND", "")
end

# ── Timeline helpers ─────────────────────────────────────────────────────────

now = DateTime.utc_now()
days_ago = fn n -> DateTime.add(now, -n * 86_400, :second) end

# ── The seed set ─────────────────────────────────────────────────────────────
# Fixed UUIDs keep re-runs idempotent.

e_pin = "0da70000-0000-4000-8000-000000000001"
e_node_a = "0da70000-0000-4000-8000-000000000002"
e_node_b = "0da70000-0000-4000-8000-000000000003"
e_pathway = "0da70000-0000-4000-8000-000000000004"
e_station = "0da70000-0000-4000-8000-000000000005"
e_node_c = "0da70000-0000-4000-8000-000000000006"

photo_1 = "0da70000-0000-4000-8000-0000000000a1"
photo_2 = "0da70000-0000-4000-8000-0000000000a2"

entries = [
  %{
    id: e_pin,
    target_type: "pin",
    stop_level_id: level.id,
    diagram_x: pin_x,
    diagram_y: pin_y,
    body:
      "Water leak above the east stair — ceiling tiles missing, floor wet near the gate line. " <>
        "Maintenance ticket filed; check whether the stair should be marked temporarily " <>
        "impassable before export.",
    captured_at: days_ago.(6)
  },
  %{
    id: e_node_a,
    target_type: "node",
    target_id: node_a.id,
    body: ~s(Signage reads "Bay C" here, not "Central" — confirm signposted_as before export.),
    captured_at: days_ago.(2)
  },
  %{
    id: e_node_b,
    target_type: "node",
    target_id: node_b.id,
    body:
      "North elevator out of service during the visit; posted return date Aug 1. " <>
        "Recheck wheelchair_boarding on the affected platforms.",
    captured_at: days_ago.(5)
  },
  %{
    id: e_pathway,
    target_type: "pathway",
    target_id: pathway.id,
    body: "Stair count is 14, not 12 — corrected in the field.",
    captured_at: days_ago.(13),
    closed_at: days_ago.(11)
  },
  %{
    id: e_station,
    target_type: "station",
    body:
      "Station-wide accessibility sweep complete. Two entrances still need tactile-paving " <>
        "photos; everything else matches the current export.",
    captured_at: days_ago.(1)
  },
  %{
    id: e_node_c,
    target_type: "node",
    target_id: node_c.id,
    body: "Corridor width measured at 2.4 m — min_width updated to match.",
    captured_at: days_ago.(15),
    closed_at: days_ago.(14)
  }
]

photos = [
  %{id: photo_1, journal_entry_id: e_pin, color: {148, 163, 184}},
  %{id: photo_2, journal_entry_id: e_pin, color: {100, 116, 139}}
]

# ── Write ────────────────────────────────────────────────────────────────────

entry_ids = Enum.map(entries, & &1.id)
photo_ids = Enum.map(photos, & &1.id)

{deleted_photos, _} =
  Repo.delete_all(from p in JournalPhoto, where: p.id in ^photo_ids)

{deleted_entries, _} =
  Repo.delete_all(from e in JournalEntry, where: e.id in ^entry_ids)

Enum.each(entries, fn attrs ->
  Repo.insert!(%JournalEntry{
    id: attrs.id,
    organization_id: org_id,
    gtfs_version_id: version_id,
    station_id: station_uuid,
    author_id: u.(author.id),
    target_type: attrs.target_type,
    target_id: attrs[:target_id] && u.(attrs[:target_id]),
    stop_level_id: attrs[:stop_level_id] && u.(attrs[:stop_level_id]),
    diagram_x: attrs[:diagram_x],
    diagram_y: attrs[:diagram_y],
    body: attrs.body,
    captured_at: attrs.captured_at,
    closed_at: attrs[:closed_at],
    closed_by: attrs[:closed_at] && u.(author.id)
  })
end)

photo_dir = Path.join([uploads_path, "field-captures", org_id, station_dir])
File.mkdir_p!(photo_dir)

Enum.each(photos, fn %{id: id, journal_entry_id: entry_id, color: color} ->
  filename = "seed-#{id}.png"
  bytes = png.(color)
  File.write!(Path.join(photo_dir, filename), bytes)

  Repo.insert!(%JournalPhoto{
    id: id,
    journal_entry_id: entry_id,
    filename: filename,
    content_type: "image/png",
    byte_size: byte_size(bytes),
    sha256: :crypto.hash(:sha256, bytes),
    width: 16,
    height: 12,
    captured_at: days_ago.(6)
  })
end)

IO.puts("""
[seeds_journal] Seeded #{length(entries)} journal entries (replaced #{deleted_entries}) \
and #{length(photos)} photos (replaced #{deleted_photos}) on #{station.name} (#{station_stop_id}).
  open: 4 · closed: 2 · types: station, node, pathway, pin · author: #{author.email}
  View: /gtfs/#{version_id}/stops/#{station_stop_id}/diagram
""")
