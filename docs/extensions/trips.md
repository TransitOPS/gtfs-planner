# Trips Specification

## Overview

`trips.txt` is a **required** GTFS file that defines trips for each route. A trip is a sequence of two or more stops that occur during a specific time period.

**Primary Key:** `trip_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `route_id` | Foreign ID referencing `routes.route_id` | **Required** | Identifies a route. |
| `service_id` | Foreign ID referencing `calendar.service_id` or `calendar_dates.service_id` | **Required** | Identifies a set of dates when service is available for one or more routes. |
| `trip_id` | Unique ID | **Required** | Identifies a trip. |
| `trip_headsign` | Text | Optional | Text that appears on signage identifying the trip's destination to riders. This field is recommended for all services with headsign text displayed on the vehicle which may be used to distinguish amongst trips in a route. If the headsign changes during a trip, values for `trip_headsign` may be overridden by defining values in `stop_times.stop_headsign` for specific `stop_time`s along the trip. |
| `trip_short_name` | Text | Optional | Public facing text used to identify the trip to riders, for instance, to identify train numbers for commuter rail trips. If riders do not commonly rely on trip names, `trip_short_name` should be empty. A `trip_short_name` value, if provided, should uniquely identify a trip within a service day; it should not be used for destination names or limited/express designations. |
| `direction_id` | Enum | Optional | Indicates the direction of travel for a trip. This field should not be used in routing; it provides a way to separate trips by direction when publishing time tables. Valid options are:<br>`0` - Travel in one direction (e.g. outbound travel).<br>`1` - Travel in the opposite direction (e.g. inbound travel). |
| `block_id` | ID | Optional | Identifies the block to which the trip belongs. A block consists of a single trip or many sequential trips made using the same vehicle, defined by shared service days and `block_id`. A `block_id` may have trips with different service days, making distinct blocks. To provide in-seat transfers information, transfers of `transfer_type` `4` should be provided instead. |
| `shape_id` | Foreign ID referencing `shapes.shape_id` | **Conditionally Required** | Identifies a geospatial shape describing the vehicle travel path for a trip.<br><br>**Conditionally Required:**<br>- **Required** if the trip has a continuous pickup or drop-off behavior defined either in routes.txt or in stop_times.txt.<br>- Optional otherwise. |
| `wheelchair_accessible` | Enum | Optional | Indicates wheelchair accessibility. Valid options are:<br>`0` or empty - No accessibility information for the trip.<br>`1` - Vehicle being used on this particular trip can accommodate at least one rider in a wheelchair.<br>`2` - No riders in wheelchairs can be accommodated on this trip. |
| `bikes_allowed` | Enum | Optional | Indicates whether bikes are allowed. Valid options are:<br>`0` or empty - No bike information for the trip.<br>`1` - Vehicle being used on this particular trip can accommodate at least one bicycle.<br>`2` - No bicycles are allowed on this trip. |
| `cars_allowed` | Enum | Optional | Indicates whether cars are allowed. Valid options are:<br>`0` or empty - No car information for the trip.<br>`1` - Vehicle being used on this particular trip can accommodate at least one car.<br>`2` - No cars are allowed on this trip. |

## Example: Blocks and Service Day

The example below is valid, with distinct blocks every day of the week.

| route_id | trip_id | service_id | block_id | (first stop time) | (last stop time) |
|----------|---------|------------|----------|-------------------|------------------|
| red | trip_1 | mon-tues-wed-thurs-fri-sat-sun | red_loop | 22:00:00 | 22:55:00 |
| red | trip_2 | fri-sat-sun | red_loop | 23:00:00 | 23:55:00 |
| red | trip_3 | fri-sat | red_loop | 24:00:00 | 24:55:00 |
| red | trip_4 | mon-tues-wed-thurs | red_loop | 20:00:00 | 20:50:00 |
| red | trip_5 | mon-tues-wed-thurs | red_loop | 21:00:00 | 21:50:00 |

**Notes:**

- On Friday into Saturday morning, for example, a single vehicle operates `trip_1`, `trip_2`, and `trip_3` (10:00 PM through 12:55 AM). Note that the last trip occurs on Saturday, 12:00 AM to 12:55 AM, but is part of the Friday "service day" because the times are 24:00:00 to 24:55:00.
- On Monday, Tuesday, Wednesday, and Thursday, a single vehicle operates `trip_1`, `trip_4`, and `trip_5` in a block from 8:00 PM to 10:55 PM.

## Reference

- [Official GTFS Specification - trips.txt](https://gtfs.org/schedule/reference/#tripstxt)