# Calendar Specification

## Overview

`calendar.txt` is a **conditionally required** GTFS file that defines service dates using a weekly schedule with start and end dates.

**Primary Key:** `service_id`

**Conditionally Required:**
- **Required** unless all dates of service are defined in `calendar_dates.txt`.
- Optional otherwise.

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `service_id` | Unique ID | **Required** | Identifies a set of dates when service is available for one or more routes. |
| `monday` | Enum | **Required** | Indicates whether the service operates on all Mondays in the date range specified by the `start_date` and `end_date` fields. Note that exceptions for particular dates may be listed in calendar_dates.txt. Valid options are:<br>`1` - Service is available for all Mondays in the date range.<br>`0` - Service is not available for Mondays in the date range. |
| `tuesday` | Enum | **Required** | Functions in the same way as `monday` except applies to Tuesdays. |
| `wednesday` | Enum | **Required** | Functions in the same way as `monday` except applies to Wednesdays. |
| `thursday` | Enum | **Required** | Functions in the same way as `monday` except applies to Thursdays. |
| `friday` | Enum | **Required** | Functions in the same way as `monday` except applies to Fridays. |
| `saturday` | Enum | **Required** | Functions in the same way as `monday` except applies to Saturdays. |
| `sunday` | Enum | **Required** | Functions in the same way as `monday` except applies to Sundays. |
| `start_date` | Date | **Required** | Start service day for the service interval. |
| `end_date` | Date | **Required** | End service day for the service interval. This service day is included in the interval. |

## Usage Notes

The `calendar.txt` file defines when service is regularly scheduled to run. It works in conjunction with `calendar_dates.txt` to provide a complete picture of service availability:

1. **Regular Service Pattern**: Use `calendar.txt` to define the regular weekly service pattern (e.g., weekday service, weekend service).

2. **Exceptions**: Use `calendar_dates.txt` to add or remove service on specific dates (e.g., holidays, special events).

3. **Date Format**: Dates must be in YYYYMMDD format (e.g., `20260115` for January 15, 2026).

## Example

```csv
service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
weekday,1,1,1,1,1,0,0,20260101,20261231
weekend,0,0,0,0,0,1,1,20260101,20261231
daily,1,1,1,1,1,1,1,20260101,20261231
```

In this example:
- `weekday` service runs Monday through Friday
- `weekend` service runs Saturday and Sunday
- `daily` service runs every day of the week

## Reference

- [Official GTFS Specification - calendar.txt](https://gtfs.org/schedule/reference/#calendartxt)