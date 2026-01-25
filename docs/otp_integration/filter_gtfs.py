import pandas as pd
import os
import shutil

# --- CONFIGURATION ---
INPUT_DIR = 'data/mbta_gtfs'
OUTPUT_DIR = 'data/mbta_gtfs_filtered'

# Regional bounds
MIN_LAT, MAX_LAT = 42.41, 42.44
MIN_LON, MAX_LON = -71.09, -71.05

# --- HELPER FUNCTIONS ---
def clean_int_column(df, col_name):
    # Ensures columns like 'location_type' are 0 or 1, not 1.0
    if col_name in df.columns:
        df[col_name] = df[col_name].fillna(-1).astype(int).astype(str).replace('-1', '')
    return df

def load_csv(filename):
    path = os.path.join(INPUT_DIR, filename)
    if os.path.exists(path):
        print(f"Loading {filename}...")
        return pd.read_csv(path, dtype=str)
    return None

def save_csv(df, filename):
    if df is not None:
        print(f"Saving filtered {filename}...")
        df.to_csv(os.path.join(OUTPUT_DIR, filename), index=False)

# Create Output Directory
if os.path.exists(OUTPUT_DIR):
    shutil.rmtree(OUTPUT_DIR)
os.makedirs(OUTPUT_DIR)

# --- STEP 1: LOAD & FILTER STOPS ---
stops = load_csv('stops.txt')

# Convert lat/lon to numeric for filtering
stops['lat_f'] = pd.to_numeric(stops['stop_lat'], errors='coerce')
stops['lon_f'] = pd.to_numeric(stops['stop_lon'], errors='coerce')

# Filter by Box
mask_in_box = (
    (stops['lat_f'] > MIN_LAT) & (stops['lat_f'] < MAX_LAT) &
    (stops['lon_f'] > MIN_LON) & (stops['lon_f'] < MAX_LON)
)
initial_stops = stops[mask_in_box]
valid_stop_ids = set(initial_stops['stop_id'])

# Keep Parent Stations
parents = initial_stops['parent_station'].dropna().unique()
valid_stop_ids.update([p for p in parents if p.strip()])

# Final Stops DataFrame
final_stops = stops[stops['stop_id'].isin(valid_stop_ids)].copy()

# Clean types and drop helper columns
final_stops = clean_int_column(final_stops, 'location_type')
final_stops = clean_int_column(final_stops, 'wheelchair_boarding')
final_stops = final_stops.drop(columns=['lat_f', 'lon_f'])

# Identify valid IDs
valid_level_ids = set(final_stops['level_id'].dropna())
valid_zone_ids = set(final_stops['zone_id'].dropna())

save_csv(final_stops, 'stops.txt')


# --- STEP 2: FILTER STOP TIMES & TRIPS ---
stop_times = load_csv('stop_times.txt')

# Keep times only for valid stops
stop_times = stop_times[stop_times['stop_id'].isin(valid_stop_ids)]

# Identify valid Trips (must have at least 2 stops)
trip_counts = stop_times.groupby('trip_id').size()
valid_trip_ids = set(trip_counts[trip_counts >= 2].index)

# Filter Stop Times by valid Trips
final_stop_times = stop_times[stop_times['trip_id'].isin(valid_trip_ids)]
save_csv(final_stop_times, 'stop_times.txt')

# Filter Trips
trips = load_csv('trips.txt')
final_trips = trips[trips['trip_id'].isin(valid_trip_ids)]
save_csv(final_trips, 'trips.txt')

# Identify IDs for next steps
valid_route_ids = set(final_trips['route_id'])
valid_service_ids = set(final_trips['service_id'])
valid_shape_ids = set(final_trips['shape_id'].dropna())


# --- STEP 3: FILTER DEPENDENT FILES ---

# Routes
routes = load_csv('routes.txt')
if routes is not None:
    final_routes = routes[routes['route_id'].isin(valid_route_ids)]
    save_csv(final_routes, 'routes.txt')

# Shapes
shapes = load_csv('shapes.txt')
if shapes is not None:
    final_shapes = shapes[shapes['shape_id'].isin(valid_shape_ids)]
    save_csv(final_shapes, 'shapes.txt')

# Calendar & Calendar Dates
calendar = load_csv('calendar.txt')
if calendar is not None:
    final_calendar = calendar[calendar['service_id'].isin(valid_service_ids)]
    save_csv(final_calendar, 'calendar.txt')

calendar_dates = load_csv('calendar_dates.txt')
if calendar_dates is not None:
    final_calendar_dates = calendar_dates[calendar_dates['service_id'].isin(valid_service_ids)]
    save_csv(final_calendar_dates, 'calendar_dates.txt')

# Levels
levels = load_csv('levels.txt')
if levels is not None:
    final_levels = levels[levels['level_id'].isin(valid_level_ids)]
    save_csv(final_levels, 'levels.txt')

# Pathways
pathways = load_csv('pathways.txt')
if pathways is not None:
    final_pathways = pathways[
        pathways['from_stop_id'].isin(valid_stop_ids) & 
        pathways['to_stop_id'].isin(valid_stop_ids)
    ].copy()
    final_pathways = clean_int_column(final_pathways, 'pathway_mode')
    final_pathways = clean_int_column(final_pathways, 'is_bidirectional')
    save_csv(final_pathways, 'pathways.txt')

# Transfers
transfers = load_csv('transfers.txt')
if transfers is not None:
    final_transfers = transfers[
        transfers['from_stop_id'].isin(valid_stop_ids) & 
        transfers['to_stop_id'].isin(valid_stop_ids)
    ].copy()
    final_transfers = clean_int_column(final_transfers, 'transfer_type')
    save_csv(final_transfers, 'transfers.txt')

# Facilities
facilities = load_csv('facilities.txt')
valid_facility_ids = set()

if facilities is not None:
    
    mask_valid_facility = (
        facilities['stop_id'].isin(valid_stop_ids) | 
        facilities['stop_id'].isna() | 
        (facilities['stop_id'] == '')
    )
    
    final_facilities = facilities[mask_valid_facility]
    valid_facility_ids = set(final_facilities['facility_id'])
    save_csv(final_facilities, 'facilities.txt')

# Facilities Properties (Links to facility_id)
fac_props = load_csv('facilities_properties.txt')
if fac_props is not None:
    final_fac_props = fac_props[fac_props['facility_id'].isin(valid_facility_ids)]
    save_csv(final_fac_props, 'facilities_properties.txt')


# --- STEP 5: COPY REMAINING FILES ---
processed_files = {
    'stops.txt', 'stop_times.txt', 'trips.txt', 'routes.txt', 
    'shapes.txt', 'calendar.txt', 'calendar_dates.txt', 
    'levels.txt', 'pathways.txt', 'transfers.txt',
    'facilities.txt', 'facilities_properties.txt'
}

for filename in os.listdir(INPUT_DIR):
    if filename not in processed_files and filename.endswith('.txt'):
        print(f"Copying {filename} (Unmodified)...")
        shutil.copy(
            os.path.join(INPUT_DIR, filename), 
            os.path.join(OUTPUT_DIR, filename)
        )

print("\n All files processed.")