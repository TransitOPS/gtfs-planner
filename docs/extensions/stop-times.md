# Stop Times Specification

## Overview

`stop_times.txt` is a **required** GTFS file that defines the times that a vehicle arrives at and departs from stops for each trip.

**Primary Key:** `trip_id`, `stop_sequence`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Foreign ID referencing `trips.trip_id` | **Required** | Identifies a trip. |
| `arrival_time` | Time | **Conditionally Required** | Arrival time at the stop (defined by `stop_times.stop_id`) for a specific trip (defined by `stop_times.trip_id`) in the time zone specified by `agency.agency_timezone`, not `stops.stop_timezone`. If there are not separate times for arrival and departure at a stop, `arrival_time` and `departure_time` should be the same. For times occurring after midnight on the service day, enter the time as a value greater than 24:00:00 in HH:MM:SS.<br><br>**Conditionally Required:**<br>- **Required** for the first and last stop in a trip (defined by `stop_times.stop_sequence`).<br>- **Required** for `timepoint=1`.<br>- **Forbidden** when `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `departure_time` | Time | **Conditionally Required** | Departure time from the stop (defined by `stop_times.stop_id`) for a specific trip (defined by `stop_times.trip_id`) in the time zone specified by `agency.agency_timezone`, not `stops.stop_timezone`. If there are not separate times for arrival and departure at a stop, `arrival_time` and `departure_time` should be the same. For times occurring after midnight on the service day, enter the time as a value greater than 24:00:00 in HH:MM:SS.<br><br>**Conditionally Required:**<br>- **Required** for `timepoint=1`.<br>- **Forbidden** when `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `stop_id` | Foreign ID referencing `stops.stop_id` | **Conditionally Required** | Identifies the serviced stop. All stops serviced during a trip must have a record in stop_times.txt. Referenced locations must be stops/platforms, i.e. their `stops.location_type` value must be `0` or empty. A stop may be serviced multiple times in the same trip, and multiple trips and routes may service the same stop.<br><br>**Conditionally Required:**<br>- **Required** if `stop_times.location_group_id` AND `stop_times.location_id` are NOT defined.<br>- **Forbidden** if `stop_times.location_group_id` or `stop_times.location_id` are defined. |
| `location_group_id` | Foreign ID referencing `location_groups.location_group_id` | **Conditionally Forbidden** | Identifies the serviced location group that indicates groups of stops where riders may request pickup or drop off.<br><br>**Conditionally Forbidden:**<br>- **Forbidden** if `stop_times.stop_id` or `stop_times.location_id` are defined. |
| `location_id` | Foreign ID referencing `id` from `locations.geojson` | **Conditionally Forbidden** | Identifies the GeoJSON location that corresponds to serviced zone where riders may request pickup or drop off.<br><br>**Conditionally Forbidden:**<br>- **Forbidden** if `stop_times.stop_id` or `stop_times.location_group_id` are defined. |
| `stop_sequence` | Non-negative integer | **Required** | Order of stops, location groups, or GeoJSON locations for a particular trip. The values must increase along the trip but do not need to be consecutive. |
| `stop_headsign` | Text | Optional | Text that appears on signage identifying the trip's destination to riders. This field overrides the default `trips.trip_headsign` when the headsign changes between stops. If the headsign is displayed for an entire trip, `trips.trip_headsign` should be used instead. A `stop_headsign` value specified for one `stop_time` does not apply to subsequent `stop_time`s in the same trip. |
| `start_pickup_drop_off_window` | Time | **Conditionally Required** | Time that on-demand service becomes available in a GeoJSON location, location group, or stop.<br><br>**Conditionally Required:**<br>- **Required** if `stop_times.location_group_id` or `stop_times.location_id` is defined.<br>- **Required** if `end_pickup_drop_off_window` is defined.<br>- **Forbidden** if `arrival_time` or `departure_time` is defined.<br>- Optional otherwise. |
| `end_pickup_drop_off_window` | Time | **Conditionally Required** | Time that on-demand service ends in a GeoJSON location, location group, or stop.<br><br>**Conditionally Required:**<br>- **Required** if `stop_times.location_group_id` or `stop_times.location_id` is defined.<br>- **Required** if `start_pickup_drop_off_window` is defined.<br>- **Forbidden** if `arrival_time` or `departure_time` is defined.<br>- Optional otherwise. |
| `pickup_type` | Enum | **Conditionally Forbidden** | Indicates pickup method. Valid options are:<br>`0` or empty - Regularly scheduled pickup.<br>`1` - No pickup available.<br>`2` - Must phone agency to arrange pickup.<br>`3` - Must coordinate with driver to arrange pickup.<br><br>**Conditionally Forbidden:**<br>- `pickup_type=0` **forbidden** if `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- `pickup_type=3` **forbidden** if `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `drop_off_type` | Enum | **Conditionally Forbidden** | Indicates drop off method. Valid options are:<br>`0` or empty - Regularly scheduled drop off.<br>`1` - No drop off available.<br>`2` - Must phone agency to arrange drop off.<br>`3` - Must coordinate with driver to arrange drop off.<br><br>**Conditionally Forbidden:**<br>- `drop_off_type=0` **forbidden** if `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `continuous_pickup` | Enum | **Conditionally Forbidden** | Indicates that the rider can board the transit vehicle at any point along the vehicle's travel path as described by shapes.txt, from this `stop_time` to the next `stop_time` in the trip's `stop_sequence`. Valid options are:<br>`0` - Continuous stopping pickup.<br>`1` or empty - No continuous stopping pickup.<br>`2` - Must phone agency to arrange continuous stopping pickup.<br>`3` - Must coordinate with driver to arrange continuous stopping pickup.<br><br>If this field is populated, it overrides any continuous pickup behavior defined in routes.txt. If this field is empty, the `stop_time` inherits any continuous pickup behavior defined in routes.txt.<br><br>**Conditionally Forbidden:**<br>- Any value other than `1` or empty is **Forbidden** if `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `continuous_drop_off` | Enum | **Conditionally Forbidden** | Indicates that the rider can alight from the transit vehicle at any point along the vehicle's travel path as described by shapes.txt, from this `stop_time` to the next `stop_time` in the trip's `stop_sequence`. Valid options are:<br>`0` - Continuous stopping drop off.<br>`1` or empty - No continuous stopping drop off.<br>`2` - Must phone agency to arrange continuous stopping drop off.<br>`3` - Must coordinate with driver to arrange continuous stopping drop off.<br><br>If this field is populated, it overrides any continuous drop-off behavior defined in routes.txt. If this field is empty, the `stop_time` inherits any continuous drop-off behavior defined in routes.txt.<br><br>**Conditionally Forbidden:**<br>- Any value other than `1` or empty is **Forbidden** if `start_pickup_drop_off_window` or `end_pickup_drop_off_window` are defined.<br>- Optional otherwise. |
| `shape_dist_traveled` | Non-negative float | Optional | Actual distance traveled along the associated shape, from the first stop to the stop specified in this record. This field specifies how much of the shape to draw between any two stops during a trip. Must be in the same units used in shapes.txt. Values used for `shape_dist_traveled` must increase along with `stop_sequence`; they must not be used to show reverse travel along a route. |
| `timepoint` | Enum | Optional | Indicates if arrival and departure times for a stop are strictly adhered to by the vehicle or if they are instead approximate and/or interpolated times. Valid options are:<br>`0` - Times are considered approximate.<br>`1` - Times are considered exact.<br><br>All records of stop_times.txt with defined arrival or departure times should have timepoint values populated. If no timepoint values are provided, all times are considered exact. |
| `pickup_booking_rule_id` | Foreign ID referencing `booking_rules.booking_rule_id` | Optional | Identifies the boarding booking rule at this stop time. Recommended when `pickup_type=2`. |
| `drop_off_booking_rule_id` | Foreign ID referencing `booking_rules.booking_rule_id` | Optional | Identifies the alighting booking rule at this stop time. Recommended when `drop_off_type=2`. |

## Time Format Notes

- Time is in the HH:MM:SS format (H:MM:SS is also accepted).
- The time is measured from "noon minus 12h" of the service day (effectively midnight except for days on which daylight savings time changes occur).
- For times occurring after midnight on the service day, enter the time as a value greater than 24:00:00 in HH:MM:SS.
- Example: `14:30:00` for 2:30PM or `25:35:00` for 1:35AM on the next day.

## Example

```csv
trip_id,arrival_time,departure_time,stop_id,stop_sequence,pickup_type,drop_off_type
trip_001,08:00:00,08:00:00,stop_A,1,0,0
trip_001,08:15:00,08:15:00,stop_B,2,0,0
trip_001,08:30:00,08:30:00,stop_C,3,0,0
trip_001,08:45:00,08:45:00,stop_D,4,0,0
```

## Reference

- [Official GTFS Specification - stop_times.txt](https://gtfs.org/schedule/reference/#stop_timestxt)