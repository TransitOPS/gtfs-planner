INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001',
  'Main Street Station',
  40.7128,
  -74.0060,
  0,
  1,
  NULL,
  NULL,
  now(),
  now()
);

-- ============================================================================
-- GTFS Sample Data: Levels, Child Stops, and Pathways for Main Street Station
-- Parent Station: stop_id = 'STOP_001' (already inserted)
-- Organization ID: 648fe251-d505-4103-85de-13d54f9f4f7f
-- GTFS Version ID: 56c61ede-b296-4a2f-a9d2-6dba87f73fa7
-- ============================================================================

-- ============================================================================
-- LEVELS (2 levels)
-- ============================================================================

-- Street Level (ground floor)
INSERT INTO levels (
  id,
  organization_id,
  gtfs_version_id,
  level_id,
  level_index,
  level_name,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'LEVEL_STREET',
  0.0,
  'Street Level',
  now(),
  now()
);

-- Platform Level (underground)
INSERT INTO levels (
  id,
  organization_id,
  gtfs_version_id,
  level_id,
  level_index,
  level_name,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'LEVEL_PLATFORM',
  -1.0,
  'Platform Level',
  now(),
  now()
);

-- ============================================================================
-- CHILD STOPS (10 entities within the station)
-- All reference the parent station (STOP_001) via parent_station_id
-- ============================================================================

-- 1. North Entrance (location_type: 2 = Entrance/Exit) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_ENT_N',
  'North Entrance',
  40.7130,
  -74.0060,
  2,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 2. South Entrance (location_type: 2 = Entrance/Exit) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_ENT_S',
  'South Entrance',
  40.7126,
  -74.0060,
  2,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 3. Fare Gate North (location_type: 3 = Generic Node) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_FARE_N',
  'Fare Gate North',
  40.7129,
  -74.0060,
  3,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 4. Fare Gate South (location_type: 3 = Generic Node) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_FARE_S',
  'Fare Gate South',
  40.7127,
  -74.0060,
  3,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 5. Mezzanine (location_type: 3 = Generic Node) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_MEZZ',
  'Mezzanine',
  40.7128,
  -74.0060,
  3,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 6. Stair/Escalator Landing (location_type: 3 = Generic Node) - Platform Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_STAIR',
  'Stair/Escalator Landing',
  40.7128,
  -74.0060,
  3,
  0,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_PLATFORM' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 7. Platform 1 - Northbound (location_type: 0 = Stop/Platform) - Platform Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  platform_code,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_PLAT_1',
  'Platform 1 - Northbound',
  40.7128,
  -74.0062,
  0,
  1,
  '1',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_PLATFORM' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 8. Platform 2 - Southbound (location_type: 0 = Stop/Platform) - Platform Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  platform_code,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_PLAT_2',
  'Platform 2 - Southbound',
  40.7128,
  -74.0058,
  0,
  1,
  '2',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_PLATFORM' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 9. Elevator - Street Level (location_type: 3 = Generic Node) - Street Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_ELEV_ST',
  'Elevator (Street Level)',
  40.7128,
  -74.0061,
  3,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_STREET' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 10. Elevator - Platform Level (location_type: 3 = Generic Node) - Platform Level
INSERT INTO stops (
  id,
  organization_id,
  gtfs_version_id,
  stop_id,
  stop_name,
  stop_lat,
  stop_lon,
  location_type,
  wheelchair_boarding,
  parent_station_id,
  level_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'STOP_001_ELEV_PL',
  'Elevator (Platform Level)',
  40.7128,
  -74.0061,
  3,
  1,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM levels WHERE level_id = 'LEVEL_PLATFORM' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- ============================================================================
-- PATHWAYS (connecting the station entities)
-- Pathway modes: 1=walkway, 2=stairs, 3=moving_sidewalk, 4=escalator, 5=elevator, 6=fare_gate, 7=exit_gate
-- ============================================================================

-- Helper: Define organization_id for all pathway subqueries
-- All pathways use organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'

-- 1. North Entrance -> Fare Gate North (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_ENT_N_FARE_N',
  1,
  true,
  15,
  10.0,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ENT_N' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_N' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 2. South Entrance -> Fare Gate South (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_ENT_S_FARE_S',
  1,
  true,
  15,
  10.0,
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ENT_S' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_S' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 3. Fare Gate North -> Mezzanine (fare gate, one-way entry)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  min_width,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_FARE_N_MEZZ',
  6,
  false,
  5,
  0.9,
  'Entry',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_N' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 4. Fare Gate South -> Mezzanine (fare gate, one-way entry)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  min_width,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_FARE_S_MEZZ',
  6,
  false,
  5,
  0.9,
  'Entry',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_S' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 5. Mezzanine -> Stair Landing (stairs, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  stair_count,
  signposted_as,
  reversed_signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_MEZZ_STAIR_STAIRS',
  2,
  true,
  45,
  24,
  'To Platforms',
  'To Exit',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_STAIR' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 6. Mezzanine -> Stair Landing (escalator, one-way down)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_MEZZ_STAIR_ESC',
  4,
  false,
  30,
  'Escalator to Platforms',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_STAIR' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 7. Mezzanine -> Elevator Street Level (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_MEZZ_ELEV_ST',
  1,
  true,
  20,
  15.0,
  'Elevator',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ELEV_ST' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 8. Elevator Street Level -> Elevator Platform Level (elevator, bidirectional, wheelchair accessible)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  min_width,
  signposted_as,
  reversed_signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_ELEV_ST_ELEV_PL',
  5,
  true,
  60,
  1.5,
  'Platform Level',
  'Street Level',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ELEV_ST' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ELEV_PL' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 9. Stair Landing -> Platform 1 (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_STAIR_PLAT_1',
  1,
  true,
  30,
  25.0,
  'Platform 1 - Northbound',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_STAIR' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_PLAT_1' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 10. Stair Landing -> Platform 2 (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_STAIR_PLAT_2',
  1,
  true,
  30,
  25.0,
  'Platform 2 - Southbound',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_STAIR' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_PLAT_2' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 11. Elevator Platform Level -> Stair Landing (walkway, bidirectional)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  length,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_ELEV_PL_STAIR',
  1,
  true,
  10,
  8.0,
  'To Platforms',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_ELEV_PL' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_STAIR' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 12. Mezzanine -> Fare Gate North (exit gate, one-way exit)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  min_width,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_MEZZ_FARE_N_EXIT',
  7,
  false,
  3,
  0.9,
  'Exit',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_N' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- 13. Mezzanine -> Fare Gate South (exit gate, one-way exit)
INSERT INTO pathways (
  id,
  organization_id,
  gtfs_version_id,
  pathway_id,
  pathway_mode,
  is_bidirectional,
  traversal_time,
  min_width,
  signposted_as,
  from_stop_id,
  to_stop_id,
  inserted_at,
  updated_at
) VALUES (
  gen_random_uuid(),
  '648fe251-d505-4103-85de-13d54f9f4f7f',
  '56c61ede-b296-4a2f-a9d2-6dba87f73fa7',
  'PW_MEZZ_FARE_S_EXIT',
  7,
  false,
  3,
  0.9,
  'Exit',
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_MEZZ' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  (SELECT id FROM stops WHERE stop_id = 'STOP_001_FARE_S' AND organization_id = '648fe251-d505-4103-85de-13d54f9f4f7f'),
  now(),
  now()
);

-- ============================================================================
-- Summary:
-- - 2 Levels: Street Level (0.0), Platform Level (-1.0)
-- - 10 Child Stops: 2 entrances, 2 fare gate areas, 1 mezzanine, 
--                   1 stair landing, 2 platforms, 2 elevator nodes
-- - 13 Pathways: walkways, stairs, escalator, elevator, fare gates, exit gates
-- 
-- Passenger flow:
-- Entry: Entrance -> Walkway -> Fare Gate -> Mezzanine -> Stairs/Escalator/Elevator -> Platform
-- Exit:  Platform -> Stairs/Elevator -> Mezzanine -> Exit Gate -> Fare Area -> Walkway -> Entrance
-- ============================================================================