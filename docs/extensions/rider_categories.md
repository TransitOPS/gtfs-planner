# Rider Categories Specification

## Overview

`rider_categories.txt` is an optional GTFS file that defines categories of riders (e.g., elderly, student) eligible for specific fare rates.

**Primary Key:** `rider_category_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `rider_category_id` | Unique ID | **Required** | Identifies a rider category. |
| `rider_category_name` | Text | **Required** | The name of the rider category (e.g., "Adult", "Child", "Senior"). |
| `min_age` | Integer | Optional | The minimum age for this rider category. |
| `max_age` | Integer | Optional | The maximum age for this rider category. |
| `eligibility_url` | URL | Optional | URL of a document describing the eligibility criteria for this rider category. |

## Reference

- [Official GTFS Specification - rider_categories.txt](https://gtfs.org/schedule/reference/#rider_categoriestxt)
