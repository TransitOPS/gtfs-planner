# OTP Data Requirements

This document defines practical data checks that prevent OpenTripPlanner (OTP) failures during graph build, startup, and reachability/routing tests.

## Section A — Must-block requirements (high confidence)

### 1) CSV formatting errors (truncated/misaligned rows)

- **Why it breaks:** OTP reads GTFS as strict CSV. A truncated row or shifted delimiter can move values into the wrong columns, causing parse failures or silently corrupted entities.

**Bad (truncated/misaligned `stops.txt`)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.881,-87.627,1,
platform_nb,Platform NB,41.8812,-87.6271,0,STATION_ID
entrance_a,Entrance A,41.8813,-87.6272,2
node_1,Node 1,41.8814,-87.6273,3,STATION_ID,EXTRA_FIELD
```

**Good (consistent column count and quoting)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.881,-87.627,1,
platform_nb,Platform NB,41.8812,-87.6271,0,STATION_ID
entrance_a,Entrance A,41.8813,-87.6272,2,STATION_ID
node_1,Node 1,41.8814,-87.6273,3,STATION_ID
```

---

### 2) Missing/invalid coordinates for station-related entities (stops/platforms/entrances/nodes/boarding areas)

- **Why it breaks:** OTP needs valid lat/lon to place entities on the street/transit graph. Missing, non-numeric, or out-of-range coordinates cause import/linking failures and unroutable stops.

**Bad (`stops.txt` with missing/invalid coordinates)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,,,1,
platform_nb,Platform NB,NaN,-87.6271,0,STATION_ID
entrance_a,Entrance A,95.0000,-87.6272,2,STATION_ID
node_1,Node 1,41.8814,-190.0000,3,STATION_ID
boarding_a,Boarding Area A,41.8815,-87.6274,4,platform_nb
```

**Good (numeric and in range: lat -90..90, lon -180..180)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.8810,-87.6270,1,
platform_nb,Platform NB,41.8812,-87.6271,0,STATION_ID
entrance_a,Entrance A,41.8813,-87.6272,2,STATION_ID
node_1,Node 1,41.8814,-87.6273,3,STATION_ID
boarding_a,Boarding Area A,41.8815,-87.6274,4,platform_nb
```

---

### 3) Wrong longitude sign (positive vs negative)

- **Why it breaks:** A sign error can place stops on the wrong side of the world, outside the OSM extract. OTP cannot link those stops to streets, so transit access fails.

**Bad (`stops.txt`)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.8810,87.6270,1,
```

**Good (`stops.txt`)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.8810,-87.6270,1,
```

---

### 4) Boarding areas (`location_type=4`) missing/invalid `parent_station`

- **Why it breaks:** Boarding areas must attach to a valid parent hierarchy. Missing or bad `parent_station` prevents OTP from constructing valid station topology.

**Bad (`stops.txt`)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.8810,-87.6270,1,
platform_nb,Platform NB,41.8812,-87.6271,0,STATION_ID
boarding_a,Boarding Area A,41.8813,-87.6272,4,
boarding_b,Boarding Area B,41.8814,-87.6273,4,MISSING_PLATFORM
```

**Good (`stops.txt`)**

```csv
stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station
STATION_ID,Central Station,41.8810,-87.6270,1,
platform_nb,Platform NB,41.8812,-87.6271,0,STATION_ID
boarding_a,Boarding Area A,41.8813,-87.6272,4,platform_nb
boarding_b,Boarding Area B,41.8814,-87.6273,4,platform_nb
```

---

### 5) OSM coverage/bounds mismatch (stops outside OSM extract)

- **Why it breaks:** OTP links transit stops to streets from OSM. If stops are outside OSM bounds (or too close to edge with no nearby walkable graph), linking fails and itineraries are unroutable.

**Bad (stop outside extract bounds)**

```text
OSM extract bounds:
  lat: 41.70 .. 41.95
  lon: -87.80 .. -87.50

Stop:
  stop_id=STATION_ID lat=42.50 lon=-87.62
```

**Bad (typical runtime warning)**

```text
WARN  [GraphBuilder] Couldn't link transit stop STATION_ID to street network
```

**Good (extract covers all stops with buffer)**

```text
OSM extract bounds (with buffer) include all GTFS stop coordinates.
No critical stop-linking warnings during build.
```

---

### 6) Service period/calendar issues (no active service for query date)

- **Why it breaks:** OTP may build successfully but return no transit options if no trips are active at the query date/time. Reachability tests then appear “broken” even when graph build passed.

**Bad (`calendar.txt` has no active service on test date)**

```csv
service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
WKD,0,0,0,0,0,0,0,20260101,20261231
```

**Good (`calendar.txt` supports test date)**

```csv
service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
WKD,1,1,1,1,1,0,0,20260101,20261231
```

---

### 7) Referential integrity across GTFS files (`stop_times`/`trips`/`routes`/`stops`)

- **Why it breaks:** Broken ID references cause entities to be dropped or trips to become invalid. OTP can fail build or load partial data that is effectively unroutable.

**Bad (`stop_times.txt` references missing trip/stop)**

```csv
trip_id,arrival_time,departure_time,stop_id,stop_sequence
TRIP_100,08:00:00,08:00:00,STOP_A,1
TRIP_MISSING,08:05:00,08:05:00,STOP_B,2
TRIP_100,08:10:00,08:10:00,STOP_MISSING,3
```

**Bad (`trips.txt` references missing route/service)**

```csv
route_id,service_id,trip_id
ROUTE_1,WKD,TRIP_100
ROUTE_MISSING,WKD,TRIP_200
ROUTE_2,SVC_MISSING,TRIP_300
```

**Good (all IDs resolve)**

```csv
# stops.txt includes STOP_A, STOP_B, STOP_C
# routes.txt includes ROUTE_1
# calendar.txt includes WKD

# trips.txt
route_id,service_id,trip_id
ROUTE_1,WKD,TRIP_100

# stop_times.txt
trip_id,arrival_time,departure_time,stop_id,stop_sequence
TRIP_100,08:00:00,08:00:00,STOP_A,1
TRIP_100,08:05:00,08:05:00,STOP_B,2
TRIP_100,08:10:00,08:10:00,STOP_C,3
```

---

### 8) Stop-to-street linking failures (runtime “Couldn’t link … NaN” warnings)

- **Why it breaks:** These warnings indicate OTP could not attach stops to the walk network, often due to invalid coordinates, bad geometry, or OSM mismatch. Routing from/to those stops will fail.

**Bad (runtime warning snippet)**

```text
WARN  [StreetLinkerModule] Couldn't link stop platform_nb at (NaN, NaN)
WARN  [StreetLinkerModule] Couldn't link stop STATION_ID to street network
```

**Good (runtime signal)**

```text
INFO  [StreetLinkerModule] Linked transit stops to street network
WARN  count for critical stations: 0
```

## Section B — Additional common failure causes (expand coverage)

### 1) Missing/inconsistent agency data (`agency.txt`, `agency_id` references)

- **Why it breaks:** Routes/trips may reference agencies that do not exist, causing validation errors or dropped routes.

**Bad**

```csv
# agency.txt
agency_id,agency_name,agency_url,agency_timezone
AGENCY_A,Demo Agency,https://example.org,America/Chicago

# routes.txt
route_id,agency_id,route_short_name,route_type
R1,AGENCY_MISSING,10,3
```

**Good**

```csv
# agency.txt
agency_id,agency_name,agency_url,agency_timezone
AGENCY_A,Demo Agency,https://example.org,America/Chicago

# routes.txt
route_id,agency_id,route_short_name,route_type
R1,AGENCY_A,10,3
```

---

### 2) Invalid time formats / `stop_times` inconsistencies (bad `HH:MM:SS`, `stop_sequence` ordering)

- **Why it breaks:** OTP expects parseable times and coherent stop order. Invalid times or unordered sequences can invalidate trip patterns.

**Bad (`stop_times.txt`)**

```csv
trip_id,arrival_time,departure_time,stop_id,stop_sequence
TRIP_100,8:0:0,08:00:00,STOP_A,1
TRIP_100,08:05:00,08:04:00,STOP_B,3
TRIP_100,08:10:00,08:10:00,STOP_C,2
```

**Good (`stop_times.txt`)**

```csv
trip_id,arrival_time,departure_time,stop_id,stop_sequence
TRIP_100,08:00:00,08:00:00,STOP_A,1
TRIP_100,08:05:00,08:05:00,STOP_B,2
TRIP_100,08:10:00,08:10:00,STOP_C,3
```

---

### 3) `transfers.txt` / `pathways.txt` referencing missing `stop_id`

- **Why it breaks:** Missing endpoint IDs break transfer/pathway edges, which can disconnect station internals and reduce or eliminate valid itineraries.

**Bad (`pathways.txt`)**

```csv
pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional
P1,platform_nb,node_missing,2,1
```

**Good (`pathways.txt`)**

```csv
pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional
P1,platform_nb,node_1,2,1
```

---

### 4) Per-station feed slicing creates an “empty” feed (no trips/`stop_times` in service window)

- **Why it breaks:** A sliced feed can still look structurally valid while containing no active transit data for the test window, producing no transit itineraries.

**Bad (effective empty feed)**

```text
After slicing for STATION_ID:
  trips.txt rows: 0
  stop_times.txt rows: 0
  active services on test date: 0
```

**Good (minimum viable sliced feed)**

```text
After slicing for STATION_ID:
  trips.txt rows: > 0
  stop_times.txt rows: > 0
  active services on test date: >= 1
```

---

### 5) Missing/corrupt inputs, file layout/basePath issues, permissions issues

- **Why it breaks:** OTP cannot build/load if expected files are missing, unreadable, or not where startup config expects them.

**Bad (startup/build log snippets)**

```text
ERROR [DataSource] File not found: /path/to/basePath/gtfs.zip
ERROR [DataSource] Permission denied: /path/to/Graph.obj
ERROR [OtpStartup] No readable data sources found in basePath
```

**Good**

```text
All required input files exist, are readable, and match configured basePath/layout.
```

---

### 6) Memory/Java runtime incompatibility (`OutOfMemoryError`, wrong Java version)

- **Why it breaks:** OTP graph build is memory-intensive and version-sensitive. Insufficient heap or incompatible Java runtime can terminate build/startup.

**Bad (runtime snippets)**

```text
Exception in thread "main" java.lang.OutOfMemoryError: Java heap space
ERROR: Unsupported class file major version ...
```

**Good**

```text
Java version matches OTP requirement and heap settings are sufficient for build/load.
```

## Section C — Recommended preflight gates

### Must-block gates (fail fast)

1. **CSV parses cleanly**
   - **Gate:** Every required GTFS file parses with consistent headers/column counts.
   - **Fail if:** Any row is truncated, overlong, malformed, or unparseable.

2. **Coordinate sanity (range + correct sign)**
   - **Gate:** Station-related entities have numeric coordinates in valid ranges; longitude sign matches region.
   - **Fail if:** Any critical stop/station/platform/entrance/node/boarding area has missing, NaN, out-of-range, or sign-flipped coordinates.

3. **Boarding area integrity (`location_type=4 parent_station exists`)**
   - **Gate:** Each boarding area points to a valid parent entity in `stops.txt`.
   - **Fail if:** `location_type=4` has blank or unresolved `parent_station`.

4. **OSM bounds coverage (+ buffer)**
   - **Gate:** All required stop coordinates fall within OSM extract bounds plus a safety buffer.
   - **Fail if:** Any key point is outside coverage.

5. **Active service exists for chosen test date/time**
   - **Gate:** At least one relevant service/trip is active in the test window.
   - **Fail if:** Query date/time has zero active transit service.

6. **Referential integrity checks pass**
   - **Gate:** Foreign-key-style references resolve across `stop_times`, `trips`, `routes`, `stops`, and service IDs.
   - **Fail if:** Any required ID is missing or orphaned.

7. **No critical linking failures for key points**
   - **Gate:** Build/startup logs show no critical stop-to-street linking failures for required stations/platforms.
   - **Fail if:** Logs contain unresolved linking errors for key points (including NaN-based failures).

### Warn-but-allow gates

- Non-critical OTP warnings that do not affect key test stations or target itineraries.
- Minor optional GTFS field issues that do not break parsing, references, or routing.
- Low-frequency data anomalies outside current test scope (track and fix, but do not hard-block).

## Section D — Smoke checks (post-build)

- **Build succeeds:** Graph build completes and `Graph.obj` is created in expected output location.
- **Server responds:** OTP starts and responds to a basic request (health or router endpoint).
- **One walk-only plan succeeds:** Run one request expected to return a walk itinerary.
- **One transit plan succeeds (if expected):** Run one request expected to include transit legs for the active service window.

If any smoke check fails:

- Capture and retain `build.log`.
- Capture and retain OTP startup/runtime logs.
- Record failing request parameters (date/time, from/to, mode) for reproducibility.