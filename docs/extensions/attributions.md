# Attributions Specification

## Overview

`attributions.txt` is an optional GTFS file that defines attributions for the dataset or for specific parts of the dataset.

**Primary Key:** `attribution_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `attribution_id` | Unique ID | **Conditionally Required** | Identifies an attribution. |
| `agency_id` | Foreign ID referencing `agency.agency_id` | Optional | Agency to which the attribution applies. |
| `route_id` | Foreign ID referencing `routes.route_id` | Optional | Route to which the attribution applies. |
| `trip_id` | Foreign ID referencing `trips.trip_id` | Optional | Trip to which the attribution applies. |
| `organization_name` | Text | **Required** | Name of the organization that the attribution applies to. |
| `is_producer` | Enum | Optional | Indicates if the organization is a producer of the data. Valid options are:<br>`0` or empty - Organization is not a producer.<br>`1` - Organization is a producer. |
| `is_operator` | Enum | Optional | Indicates if the organization is an operator of the service. Valid options are:<br>`0` or empty - Organization is not an operator.<br>`1` - Organization is an operator. |
| `is_authority` | Enum | Optional | Indicates if the organization is an authority of the service. Valid options are:<br>`0` or empty - Organization is not an authority.<br>`1` - Organization is an authority. |
| `attribution_url` | URL | Optional | URL of the attribution. |
| `attribution_email` | Email | Optional | Email address for the attribution. |
| `attribution_phone` | Phone number | Optional | Phone number for the attribution. |

## Reference

- [Official GTFS Specification - attributions.txt](https://gtfs.org/schedule/reference/#attributionstxt)
