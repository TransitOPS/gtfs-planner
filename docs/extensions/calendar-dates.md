# Calendar Dates Specification

## Overview

`calendar_dates.txt` is a **conditionally required** GTFS file that explicitly activates or disables service by date. It may be used in two ways:

**Primary Key:** `service_id`, `date`

**Conditionally Required:**
- **Required** if `calendar.txt` is omitted. In which case `calendar_dates.txt` must contain all dates of service.
- Optional otherwise.

## Usage Approaches

### Recommended Approach
Use `calendar_dates.txt` in conjunction with `calendar.txt` to define exceptions to the default service patterns defined in `calendar.txt`. If service is generally regular, with a few changes on explicit dates (for instance, to accommodate special event services, or a school schedule), this is a good approach. In this case `calendar_dates.service_id` is a foreign ID referencing `calendar.service_id`.

### Alternate Approach
Omit `calendar.txt`, and specify each date of service in `calendar_dates.txt`. This allows for considerable service variation and accommodates service without normal weekly schedules. In this case `service_id` is an ID.

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `service_id` | Foreign ID referencing `calendar.service_id` or ID | **Required** | Identifies a set of dates when a service exception occurs for one or more routes. Each (`service_id`, `date`) pair may only appear once in calendar_dates.txt if using calendar.txt and calendar_dates.txt in conjunction. If a `service_id` value appears in both calendar.txt and calendar_dates.txt, the information in calendar_dates.txt modifies the service information specified in calendar.txt. |
| `date` | Date | **Required** | Date when service exception occurs. |
| `exception_type` | Enum | **Required** | Indicates whether service is available on the date specified in the date field. Valid options are:<br>`1` - Service has been added for the specified date.<br>`2` - Service has been removed for the specified date. |

## Example

Suppose a route has one set of trips available on holidays and another set of trips available on all other days. One `service_id` could correspond to the regular service schedule and another `service_id` could correspond to the holiday schedule. For a particular holiday, the `calendar_dates.txt` file could be used to add the holiday to the holiday `service_id` and to remove the holiday from the regular `service_id` schedule.

```csv
service_id,date,exception_type
weekday,20260704,2
holiday,20260704,1
weekday,20261225,2
holiday,20261225,1
```

In this example:
- Regular weekday service is **removed** (`exception_type=2`) on July 4th and December 25th
- Holiday service is **added** (`exception_type=1`) on those same dates

## Reference

- [Official GTFS Specification - calendar_dates.txt](https://gtfs.org/schedule/reference/#calendar_datestxt)