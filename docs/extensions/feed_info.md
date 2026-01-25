# Feed Info Specification

## Overview

`feed_info.txt` is an optional GTFS file that contains additional information about the feed itself, rather than the services it describes.

**Primary Key:** `feed_publisher_name`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `feed_publisher_name` | Text | **Required** | Full name of the organization that publishes the feed. |
| `feed_publisher_url` | URL | **Required** | URL of the feed publisher's website. |
| `feed_lang` | Language code | **Required** | Default language of the feed. |
| `feed_start_date` | Date | Optional | The start date of the feed's validity. |
| `feed_end_date` | Date | Optional | The end date of the feed's validity. |
| `feed_version` | Text | Optional | The version of the feed. |
| `feed_contact_email` | Email | Optional | Email address for feed publishers. |
| `feed_contact_url` | URL | Optional | URL for feed publishers. |

## Reference

- [Official GTFS Specification - feed_info.txt](https://gtfs.org/schedule/reference/#feed_infotxt)
