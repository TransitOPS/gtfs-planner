# Routes Specification

## Overview

`routes.txt` is a **required** GTFS file that contains information about a transit organization's routes. A route is a group of trips that are displayed to riders as a single service.

**Primary Key:** `route_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `route_id` | Unique ID | **Required** | Identifies a route. |
| `agency_id` | Foreign ID | Optional | Identifies the agency for the specified route. Referenced from `agency.txt`. |
| `route_short_name` | Text | **Conditionally Required** | The short name of a route. This will often be a short, abstract identifier like "32", "100X", or "Green" that riders use to identify a route, but which doesn't give any indication of places or service. At least one of `route_short_name` or `route_long_name` must be specified. |
| `route_long_name` | Text | **Conditionally Required** | The full name of a route. This name is generally more descriptive than the `route_short_name` and will often include the route's destination or stop. At least one of `route_short_name` or `route_long_name` must be specified. |
| `route_desc` | Text | Optional | Description of a route that provides useful, quality information. Do not simply duplicate the name of the route. |
| `route_type` | Enum | **Required** | Indicates the type of transportation used on a route. Valid options include:<br>`0` - Tram, Streetcar, Light rail<br>`1` - Subway, Metro<br>`2` - Rail<br>`3` - Bus<br>`4` - Ferry<br>`5` - Cable Tram<br>`6` - Aerial Lift<br>`7` - Funicular<br>`11` - Trolleybus<br>`12` - Monorail |
| `route_url` | URL | Optional | URL of a web page about that particular route. |
| `route_color` | Color | Optional | In systems that have colors used in signage, the RGB color of this route. The color must be provided as a six-character hexadecimal number, including three pairs of hexadecimal digits. Default is `FFFFFF`. |
| `route_text_color` | Color | Optional | Legible color to use for text drawn against a background of `route_color`. The color must be provided as a six-character hexadecimal number. Default is `000000`. |
| `route_sort_order` | Non-negative integer | Optional | Orders the routes in a way which is ideal for presentation to customers. Routes with smaller `route_sort_order` values should be displayed before those with larger values. |
| `continuous_pickup` | Enum | Optional | Indicates whether a rider can board the transit vehicle at any point along the vehicle's travel path. Valid options are:<br>`0` - Continuous stopping pickup.<br>`1` - No continuous stopping pickup (Default).<br>`2` - Must phone agency to arrange pickup.<br>`3` - Must coordinate with driver to arrange pickup. |
| `continuous_drop_off` | Enum | Optional | Indicates whether a rider can alight from the transit vehicle at any point along the vehicle's travel path. Valid options are:<br>`0` - Continuous stopping drop off.<br>`1` - No continuous stopping drop off (Default).<br>`2` - Must phone agency to arrange drop off.<br>`3` - Must coordinate with driver to arrange drop off. |
| `network_id` | ID | Optional | Identifies the network the route belongs to. |

## Reference

- [Official GTFS Specification - routes.txt](https://gtfs.org/schedule/reference/#routestxt)
