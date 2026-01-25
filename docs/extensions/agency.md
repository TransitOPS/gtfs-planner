# Agency Specification

## Overview

`agency.txt` is a **required** GTFS file that defines the transit agencies that provide the data in the feed.

**Primary Key:** `agency_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `agency_id` | Unique ID | **Conditionally Required** | Identifies a transit brand which is often synonymous with a transit agency. Note that in some cases, such as when a single agency operates multiple separate services, agencies and brands are distinct. This document uses the term "agency" in place of "brand". A dataset may contain data from multiple agencies.<br><br>**Conditionally Required:**<br>- **Required** when the dataset contains data for multiple transit agencies.<br>- Optional otherwise. |
| `agency_name` | Text | **Required** | Full name of the transit agency. |
| `agency_url` | URL | **Required** | URL of the transit agency. |
| `agency_timezone` | Timezone | **Required** | Timezone where the transit agency is located. If multiple agencies are specified in the dataset, each must have the same `agency_timezone`. |
| `agency_lang` | Language code | Optional | Primary language used by this transit agency. This field helps GTFS consumers choose capitalization rules and other language-specific settings for the dataset. |
| `agency_phone` | Phone number | Optional | A voice telephone number for the specified agency. |
| `agency_fare_url` | URL | Optional | URL of a web page where a rider can purchase tickets or other fare instruments for that agency, or a web page containing information about that agency's fares. |
| `agency_email` | Email | Optional | Email address actively monitored by the agency's customer service department. |
| `cemv_support` | Enum | Optional | Indicates if riders can access a transit service (i.e., trip) associated with this agency by using a contactless EMV (Europay, Mastercard, and Visa) card or mobile device as fare media at a fare validator. Valid options are:<br>`0` or empty - EMV not supported.<br>`1` - EMV supported.<br>`2` - EMV supported with pre-authorization. |

## Reference

- [Official GTFS Specification - agency.txt](https://gtfs.org/schedule/reference/#agencytxt)
