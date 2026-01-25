# Calendars and Service Periods Requirements Document

**Section:** Calendars and Service Periods  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Calendars and Service Periods section manages two conditionally required files in the GTFS specification: `calendar.txt` and `calendar_dates.txt`. Together, these files define when transit service operates, enabling trip planners to determine which trips are available on any given date.

GTFS supports two approaches for defining service availability:

1. **Recommended approach:** Use `calendar.txt` to define recurring weekly service patterns with start and end dates, and use `calendar_dates.txt` to specify exceptions (holidays, special events, service disruptions).

2. **Alternate approach:** Omit `calendar.txt` entirely and enumerate every date of service in `calendar_dates.txt`. This accommodates highly variable service without normal weekly patterns.

### 1.1 Core Data Fields — calendar.txt

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `service_id` | Unique ID | Required | Identifies a set of dates when service is available for one or more routes. Referenced by trips.txt to associate trips with service patterns. |
| `monday` | Enum (0/1) | Required | Indicates whether service operates on all Mondays in the date range. 1 = available, 0 = not available. |
| `tuesday` | Enum (0/1) | Required | Functions the same as monday, for Tuesdays. |
| `wednesday` | Enum (0/1) | Required | Functions the same as monday, for Wednesdays. |
| `thursday` | Enum (0/1) | Required | Functions the same as monday, for Thursdays. |
| `friday` | Enum (0/1) | Required | Functions the same as monday, for Fridays. |
| `saturday` | Enum (0/1) | Required | Functions the same as monday, for Saturdays. |
| `sunday` | Enum (0/1) | Required | Functions the same as monday, for Sundays. |
| `start_date` | Date | Required | Start service day for the service interval. |
| `end_date` | Date | Required | End service day for the service interval. This day is included in the interval. |

### 1.2 Core Data Fields — calendar_dates.txt

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `service_id` | Foreign ID or ID | Required | Identifies a set of dates when a service exception occurs. When used with calendar.txt, references calendar.service_id. When calendar.txt is omitted, acts as a standalone ID. |
| `date` | Date | Required | Date when the service exception occurs. |
| `exception_type` | Enum (1/2) | Required | Indicates whether service is available: 1 = service added for this date, 2 = service removed for this date. |

### 1.3 Conceptual Model

The application introduces user-facing concepts that map to the underlying GTFS structure:

| Application Concept | GTFS Mapping | Description |
|---------------------|--------------|-------------|
| **Calendar** | `service_id` in calendar.txt | A named container representing a distinct service pattern (e.g., "Year Round", "School Year", "Summer Trolley"). |
| **Service Period** | `start_date` / `end_date` range | A date range during which a calendar is active. A calendar may have multiple non-overlapping service periods. |
| **Service Days** | `monday` through `sunday` fields | The days of the week when trips on this calendar operate. |
| **Calendar Exception** | Records in calendar_dates.txt | Date-specific overrides that add or remove service from a calendar. |
| **Exception Only Calendar** | calendar.txt entry with all days set to 0, combined with calendar_dates.txt | A calendar with no recurring weekly pattern, activated only through explicit date exceptions. |

### 1.4 Operational Implications

#### Trip Availability
Calendars and service periods directly determine which trips appear in trip planning results. A trip assigned to a calendar only appears for dates that fall within an active service period and match the calendar's service days, unless modified by exceptions. Incorrect calendar configuration causes trips to appear on wrong dates or disappear entirely.

#### Holiday and Special Event Management
Calendar exceptions enable agencies to suspend regular service for holidays (e.g., no service on Thanksgiving) or substitute alternative schedules (e.g., running Sunday service on Memorial Day). Exceptions work at the calendar level—individual routes or trips cannot be exempted unless moved to a separate calendar.

#### Seasonal and Academic Service
Agencies operating seasonal routes (summer trolleys, ski shuttles) or academic-aligned service (university routes) require separate calendars with service periods matching their operational windows. School calendars require frequent updates to reflect academic year breaks.

#### Semi-Monthly Service
Services operating less frequently than weekly (e.g., 2nd and 4th Tuesday shopping shuttle) require calendars with single-day service periods for each operating date, or exception-only calendars activated via calendar_dates.txt.

#### Schedule Transitions
Service changes (permanent or seasonal) require careful calendar management. Agencies typically maintain separate calendars for current and upcoming schedules, with service periods configured to activate the new schedule at the changeover date.

#### Feed Validity
The `start_date` and `end_date` fields affect feed validity. GTFS best practice recommends maintaining calendar data that extends at least two weeks into the future. Short-term service changes lasting less than two weeks should be handled via calendar exceptions rather than new calendars.

#### Data Consumers
Calendar data flows to Google Maps, Apple Maps, Transit App, and other consumer applications. Errors in calendar configuration—such as overlapping service periods, gaps in coverage, or misconfigured exceptions—cause trip planners to display incorrect service information to millions of riders.

#### GTFS-Realtime Integration
Calendar service_ids connect static GTFS schedules to GTFS-Realtime service alerts and trip updates. Consistent service_id values between static and realtime feeds are essential for accurate real-time arrival predictions.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Calendar Creation

**JS-CAL-001: Creating a new calendar for year-round service**
When I am setting up GTFS for an agency with consistent weekly service patterns, I want to create a single calendar with service days and date ranges, so I can associate all trips with this recurring schedule.

**JS-CAL-002: Creating a calendar for seasonal service**
When my agency operates a summer trolley that runs only from Memorial Day through Labor Day, I want to create a dedicated seasonal calendar, so I can isolate this service and update its dates annually without affecting other routes.

**JS-CAL-003: Creating a calendar for academic service**
When my agency provides routes that operate only when the university is in session, I want to create a school-year calendar with service periods matching academic terms, so I can suspend service during breaks without affecting year-round routes.

**JS-CAL-004: Creating an exception-only calendar**
When I need to schedule special event service (e.g., football game shuttle) that operates on irregular dates, I want to create a calendar without recurring service days that is activated only through specific date exceptions, so I can manage event-driven service without creating complex service period configurations.

### 2.2 Service Period Management

**JS-CAL-005: Adding a service period to an existing calendar**
When the new fiscal year begins and I need to extend service coverage, I want to add a new service period to my calendar without modifying existing periods, so I can maintain continuous service into the future.

**JS-CAL-006: Adjusting service period dates**
When the school district changes its academic calendar, I want to modify the start and end dates of existing service periods, so I can align transit service with the updated school schedule.

**JS-CAL-007: Managing multiple non-overlapping service periods**
When my academic calendar has fall semester, spring semester, and summer session, I want to configure multiple service periods on a single calendar with gaps between them, so I can represent the natural breaks in service.

**JS-CAL-008: Preventing service period overlaps**
When I am editing service period dates, I want the system to prevent me from creating overlapping periods on the same calendar, so I can avoid duplicate trips appearing in the GTFS feed.

### 2.3 Calendar Exceptions

**JS-CAL-009: Scheduling a holiday service suspension**
When I need to suspend all service on Thanksgiving Day, I want to create a calendar exception that removes service for that date across affected calendars, so I can ensure no trips appear for riders on that holiday.

**JS-CAL-010: Scheduling a service swap**
When my agency runs Sunday service on Memorial Day (a Monday), I want to suspend regular Monday service and add Sunday service for that date, so I can provide holiday schedules without creating separate calendars.

**JS-CAL-011: Scheduling additional service for a special event**
When a major concert requires extended evening service, I want to add trips from an exception-only calendar for that specific date, so I can provide extra capacity without modifying the regular schedule.

**JS-CAL-012: Managing recurring annual exceptions**
When I schedule the same holidays each year (New Year's Day, July 4th, etc.), I want to easily replicate last year's exceptions for the new year, so I can efficiently maintain holiday schedules.

**JS-CAL-013: Handling multi-day service disruptions**
When construction will disrupt service for several non-consecutive days, I want to apply calendar exceptions to multiple dates at once, so I can efficiently configure sporadic service changes.

### 2.4 Calendar Organization

**JS-CAL-014: Viewing calendar inventory**
When my agency has many calendars, I want to see them in a sortable, filterable list showing names, service periods, and trip counts, so I can quickly locate the calendar I need to edit.

**JS-CAL-015: Understanding calendar usage**
When deciding whether to delete or archive a calendar, I want to see which routes and trips are assigned to it, so I can assess the impact before making changes.

**JS-CAL-016: Identifying calendars with expiring service periods**
When reviewing my GTFS data for maintenance, I want to see which calendars have service periods ending soon, so I can proactively extend them before the feed becomes stale.

**JS-CAL-017: Duplicating a calendar**
When preparing for a schedule change, I want to duplicate an existing calendar with all its trips, so I can make modifications to the copy while preserving the current schedule until the changeover date.

### 2.5 Calendar Consolidation

**JS-CAL-018: Combining redundant calendars**
When I discover that separate calendars exist for weekday and weekend service that could be unified, I want to merge them into a single calendar, so I can simplify my data structure.

**JS-CAL-019: Moving trips between calendars**
When I need to isolate specific trips for a calendar exception that shouldn't affect all trips on a calendar, I want to move those trips to a dedicated calendar, so I can apply exceptions selectively.

### 2.6 Validation and Quality

**JS-CAL-020: Identifying service gaps**
When reviewing my calendars before export, I want to see warnings about date ranges with no active service periods, so I can ensure continuous coverage in trip planning applications.

**JS-CAL-021: Reviewing upcoming exceptions**
When verifying my GTFS data, I want to see a chronological view of all upcoming calendar exceptions, so I can confirm that holidays and special events are configured correctly.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Calendar Dashboard

**US-CAL-001: View calendar list**
As a schedule editor, I want to view all calendars in a sortable, searchable list, so that I can quickly locate calendars by name or service period.

**US-CAL-002: Sort calendars**
As a schedule editor, I want to sort calendars by ID, name, or service period dates, so that I can organize my view according to my current task.

**US-CAL-003: Filter calendars by status**
As a schedule editor, I want to filter calendars by active, expired, or upcoming status, so that I can focus on calendars relevant to my current maintenance needs.

**US-CAL-004: View calendar summary**
As a schedule editor, I want to see a summary of each calendar including its name, service days, active service period, and trip count, so that I can quickly understand each calendar's purpose.

### 3.2 Calendar Management

**US-CAL-005: Create a new calendar**
As a schedule editor, I want to create a new calendar with a descriptive name, so that I can organize trips into logical service groupings.

**US-CAL-006: Set calendar as exception-only**
As a schedule editor, I want to designate a calendar as exception-only at creation time, so that I can create calendars for special event service without defining weekly patterns.

**US-CAL-007: Edit calendar name**
As a schedule editor, I want to rename an existing calendar, so that I can maintain clear, descriptive names as service patterns evolve.

**US-CAL-008: Delete unused calendar**
As a schedule editor, I want to delete a calendar that has no assigned trips, so that I can remove obsolete configurations from my data.

**US-CAL-009: Duplicate calendar with trips**
As a schedule editor, I want to duplicate a calendar including all its trips and service periods, so that I can prepare a modified version for an upcoming schedule change.

**US-CAL-010: Duplicate calendar without trips**
As a schedule editor, I want to duplicate only a calendar's service periods without copying trips, so that I can create a calendar shell for manual trip assignment.

**US-CAL-011: Combine calendars**
As a schedule editor, I want to merge two calendars by moving all trips from one to the other, so that I can consolidate redundant calendar structures.

### 3.3 Service Period Management

**US-CAL-012: Add service period**
As a schedule editor, I want to add a service period with start and end dates to a calendar, so that I can define when the calendar's trips are active.

**US-CAL-013: Edit service period dates**
As a schedule editor, I want to modify the start or end date of an existing service period, so that I can adjust service coverage as schedules change.

**US-CAL-014: Delete service period**
As a schedule editor, I want to delete a service period from a calendar, so that I can remove obsolete date ranges.

**US-CAL-015: Configure service days**
As a schedule editor, I want to specify which days of the week (Monday through Sunday) a calendar operates, so that I can define the recurring weekly pattern.

**US-CAL-016: View service period timeline**
As a schedule editor, I want to see a visual timeline of a calendar's service periods, so that I can identify gaps or overlaps at a glance.

### 3.4 Calendar Exception Management

**US-CAL-017: View exception list**
As a schedule editor, I want to view all calendar exceptions in a chronological list, so that I can review upcoming service modifications.

**US-CAL-018: Create service removal exception**
As a schedule editor, I want to create an exception that removes service for a specific date on a calendar, so that I can suspend service for holidays or disruptions.

**US-CAL-019: Create service addition exception**
As a schedule editor, I want to create an exception that adds service from one calendar to a specific date, so that I can provide substitute or supplemental service.

**US-CAL-020: Create service swap exception**
As a schedule editor, I want to remove service from one calendar and add service from another for the same date, so that I can implement holiday schedules (e.g., run Sunday service on a Monday holiday).

**US-CAL-021: Apply exception to multiple dates**
As a schedule editor, I want to apply the same exception to multiple dates at once, so that I can efficiently configure multi-day disruptions or recurring annual holidays.

**US-CAL-022: Delete exception**
As a schedule editor, I want to delete a calendar exception, so that I can remove erroneous or obsolete service modifications.

**US-CAL-023: Filter exceptions by calendar**
As a schedule editor, I want to filter the exception list to show only exceptions affecting a specific calendar, so that I can review modifications for a particular service pattern.

**US-CAL-024: Filter exceptions by date range**
As a schedule editor, I want to filter the exception list by date range, so that I can review exceptions for a specific period (e.g., upcoming month, holiday season).

### 3.5 Integration Points

**US-CAL-025: Assign trip to calendar**
As a schedule editor, I want to assign a trip to a calendar when creating or editing the trip, so that I can associate the trip with the appropriate service pattern.

**US-CAL-026: View trips on calendar**
As a schedule editor, I want to see all trips assigned to a calendar, so that I can understand what service the calendar governs.

**US-CAL-027: Reassign trips to different calendar**
As a schedule editor, I want to move trips from one calendar to another, so that I can reorganize service patterns without recreating trips.

**US-CAL-028: Preview service dates**
As a schedule editor, I want to see a list of all dates when a calendar is active (accounting for service periods and exceptions), so that I can verify the configuration is correct.

---

## 4. Acceptance Criteria

### 4.1 Calendar Dashboard

**AC-CAL-001: View calendar list**
- Given I navigate to the Calendars section
- Then I see a list of all calendars showing name, service days summary, current/next service period, and trip count
- And the list loads within 2 seconds

**AC-CAL-002: Sort calendars by name**
- Given I am viewing the calendar list
- When I click the Name column header
- Then calendars are sorted alphabetically by name
- And clicking again reverses the sort order

**AC-CAL-003: Sort calendars by service period**
- Given I am viewing the calendar list
- When I click the Service Period column header
- Then calendars are sorted by their earliest active service period start date
- And calendars with no service periods appear last

**AC-CAL-004: Search calendars by name**
- Given I am viewing the calendar list
- When I enter text in the search field
- Then the list filters to show only calendars whose names contain the search text
- And the filter is applied as I type

**AC-CAL-005: Filter calendars by status**
- Given I am viewing the calendar list
- When I select "Active" from the status filter
- Then only calendars with a service period containing the current date are displayed
- And expired and future-only calendars are hidden

### 4.2 Calendar Creation

**AC-CAL-006: Create standard calendar**
- Given I am on the calendar dashboard
- When I click "Add Calendar"
- And I enter a name
- And I select service days (e.g., Monday through Friday)
- And I save the calendar
- Then a new calendar is created
- And it appears in the calendar list

**AC-CAL-007: Create exception-only calendar**
- Given I am creating a new calendar
- When I check "Exception Only"
- Then the service days selection is disabled
- And all service days default to 0
- And the service period section is hidden
- And the calendar can only be activated via calendar exceptions

**AC-CAL-008: Calendar name required**
- Given I am creating a new calendar
- When I leave the name field empty
- And I attempt to save
- Then a validation error indicates the name is required
- And the calendar is not created

**AC-CAL-009: Calendar name uniqueness**
- Given a calendar named "Year Round" exists
- When I create a new calendar with the name "Year Round"
- Then a validation error indicates the name must be unique
- And the calendar is not created

### 4.3 Calendar Editing

**AC-CAL-010: Edit calendar name**
- Given I am viewing a calendar's details
- When I modify the calendar name
- And I save the changes
- Then the calendar name is updated
- And the change is reflected in the calendar list

**AC-CAL-011: Modify service days**
- Given I am editing a calendar
- When I change the service days configuration (e.g., add Saturday)
- And I save the changes
- Then the service days are updated
- And trips on this calendar now appear on the newly selected days

**AC-CAL-012: Cannot modify exception-only to standard**
- Given I am editing an exception-only calendar with assigned trips
- Then the "Exception Only" checkbox is disabled
- And a message explains that calendars with trips cannot change type

### 4.4 Service Period Management

**AC-CAL-013: Add service period**
- Given I am editing a calendar
- When I click "Add Service Period"
- And I select a start date and end date
- And I save
- Then the service period is added to the calendar
- And it appears in the service periods list

**AC-CAL-014: Service period date validation**
- Given I am adding a service period
- When I select an end date that precedes the start date
- Then a validation error indicates the end date must be on or after the start date
- And the service period is not saved

**AC-CAL-015: Prevent overlapping service periods**
- Given a calendar has a service period from Jan 1 to Mar 31
- When I attempt to add a service period from Feb 15 to Apr 30
- Then a validation error indicates service periods cannot overlap
- And the new service period is not saved

**AC-CAL-016: Allow adjacent service periods**
- Given a calendar has a service period from Jan 1 to Mar 31
- When I add a service period from Apr 1 to Jun 30
- Then the service period is saved successfully
- And both periods appear in the list

**AC-CAL-017: Edit service period dates**
- Given I am viewing a calendar with service periods
- When I click on a service period's date
- And I select a new date from the date picker
- And I save
- Then the service period dates are updated

**AC-CAL-018: Delete service period**
- Given I am viewing a calendar with multiple service periods
- When I click the delete icon on a service period
- And I confirm the deletion
- Then the service period is removed
- And remaining service periods are preserved

**AC-CAL-019: Delete last service period warning**
- Given I am viewing a calendar with one service period and assigned trips
- When I attempt to delete the service period
- Then a warning indicates that deleting this period will cause trips to have no active dates
- And I must confirm to proceed

### 4.5 Calendar Exceptions

**AC-CAL-020: View exception list**
- Given I navigate to the Calendar Exceptions section
- Then I see a list of all exceptions showing date, affected calendar, and exception type (added/removed)
- And exceptions are sorted by date in ascending order

**AC-CAL-021: Create service removal exception**
- Given I am creating a new calendar exception
- When I select a date
- And I select a calendar
- And I set exception type to "Remove Service"
- And I save
- Then an exception is created
- And the calendar's service is suspended for that date

**AC-CAL-022: Create service addition exception**
- Given I am creating a new calendar exception
- When I select a date
- And I select a calendar (typically exception-only)
- And I set exception type to "Add Service"
- And I select which service day pattern to add (e.g., "Saturday" trips)
- And I save
- Then an exception is created
- And the specified trips operate on that date

**AC-CAL-023: Create service swap**
- Given I am creating exceptions for a holiday
- When I create a removal exception for "Year Round" calendar on July 4th
- And I create an addition exception for "Year Round" Sunday service on July 4th
- Then regular service is suspended
- And Sunday service operates instead

**AC-CAL-024: Bulk exception creation**
- Given I am creating calendar exceptions
- When I select multiple dates (e.g., via multi-select date picker)
- And I configure the exception settings
- And I save
- Then an exception is created for each selected date
- And all exceptions have the same configuration

**AC-CAL-025: Prevent duplicate exceptions**
- Given an exception exists for "Year Round" calendar removing service on July 4th
- When I attempt to create another removal exception for the same calendar and date
- Then a validation error indicates an exception already exists
- And the duplicate is not created

**AC-CAL-026: Delete exception**
- Given I am viewing the exception list
- When I click delete on an exception
- And I confirm the deletion
- Then the exception is removed
- And normal service resumes for that date

**AC-CAL-027: Filter exceptions by date range**
- Given I am viewing the exception list
- When I set a date range filter
- Then only exceptions within that range are displayed

**AC-CAL-028: Filter exceptions by calendar**
- Given I am viewing the exception list
- When I select a calendar from the filter dropdown
- Then only exceptions affecting that calendar are displayed

### 4.6 Calendar Duplication

**AC-CAL-029: Duplicate calendar with trips**
- Given I am viewing a calendar
- When I select "Duplicate with Trips" from the actions menu
- Then a new calendar is created with the same name plus " (Copy)"
- And all service periods are copied
- And all trips are duplicated to the new calendar

**AC-CAL-030: Duplicate calendar without trips**
- Given I am viewing a calendar
- When I select "Duplicate without Trips" from the actions menu
- Then a new calendar is created with the same name plus " (Copy)"
- And all service periods are copied
- And no trips are assigned to the new calendar

### 4.7 Calendar Combination

**AC-CAL-031: Combine calendars**
- Given I have two calendars with trips
- When I select "Combine Calendars"
- And I choose the source and destination calendars
- And I confirm
- Then all trips from the source are moved to the destination
- And service periods are merged
- And the source calendar remains (with zero trips) for manual deletion

### 4.8 Calendar Deletion

**AC-CAL-032: Delete calendar without trips**
- Given I am viewing a calendar with no assigned trips
- When I select "Delete Calendar"
- And I confirm the deletion
- Then the calendar is removed from the system
- And it no longer appears in the calendar list

**AC-CAL-033: Cannot delete calendar with trips**
- Given I am viewing a calendar with assigned trips
- When I attempt to delete the calendar
- Then a message indicates the calendar cannot be deleted because it has assigned trips
- And suggests reassigning or deleting the trips first

**AC-CAL-034: Delete calendar removes exceptions**
- Given I delete a calendar
- Then all calendar exceptions referencing that calendar are also deleted

### 4.9 Service Preview

**AC-CAL-035: Preview active service dates**
- Given I am viewing a calendar
- When I click "Preview Service Dates"
- Then I see a calendar view showing all dates when service operates
- And dates within service periods are highlighted
- And dates affected by exceptions are marked differently (added in green, removed in red)

**AC-CAL-036: Preview service for date range**
- Given I am viewing the service preview
- When I adjust the date range
- Then the preview updates to show only dates within that range
- And I can navigate month by month

### 4.10 Validation and Warnings

**AC-CAL-037: Warn on expiring service period**
- Given a calendar's service period ends within 14 days
- When viewing the calendar list
- Then that calendar is flagged with a warning indicator
- And the warning message indicates the service period is expiring

**AC-CAL-038: Warn on service gap**
- Given a calendar has non-contiguous service periods with a gap
- When viewing the calendar
- Then a warning indicates dates with no service coverage
- And the specific gap dates are identified

**AC-CAL-039: Validate exception date within service scope**
- Given I am creating an exception for a date outside any service period
- When I save the exception
- Then a warning indicates the exception date is outside active service periods
- And I can proceed if intentional

### 4.11 Integration Points

**AC-CAL-040: Calendars available in trip editor**
- Given I have created calendars
- When I create or edit a trip
- Then all active calendars appear in the calendar dropdown
- And I can assign the trip to any calendar

**AC-CAL-041: Trip count updates on calendar**
- Given a calendar shows "5 trips"
- When I create a new trip assigned to that calendar
- Then the calendar's trip count updates to "6 trips"

**AC-CAL-042: GTFS export includes calendar data**
- Given I have calendars with service periods and exceptions configured
- When I export GTFS
- Then calendar.txt contains records for each non-exception-only calendar with their service days and date ranges
- And calendar_dates.txt contains records for all exceptions with correct exception_type values

**AC-CAL-043: Exception-only calendars in export**
- Given I have exception-only calendars with trips and date exceptions
- When I export GTFS
- Then calendar.txt contains entries with all service days set to 0
- And calendar_dates.txt contains addition exceptions (exception_type=1) for active dates

---

## 5. Non-Functional Requirements

### 5.1 Performance
- Calendar list must load within 2 seconds for feeds with up to 100 calendars
- Service preview must render within 1 second for a 12-month date range
- Exception list must load within 2 seconds for feeds with up to 500 exceptions
- Search and filter operations must return results within 500ms

### 5.2 Usability
- Date pickers must support keyboard entry and calendar selection
- Service days must be selectable via checkboxes with clear visual state
- Save buttons must use high-visibility styling (bright green) per existing UI conventions
- Delete operations must require confirmation to prevent accidental data loss
- Exception creation must allow selecting multiple dates in a single flow

### 5.3 Data Integrity
- Service periods on the same calendar must not overlap
- Calendar deletion must be prevented while trips are assigned
- Exception date/calendar combinations must be unique
- Orphaned exceptions must be automatically removed when calendars are deleted
- System must maintain referential integrity between calendars and trips

### 5.4 Accessibility
- All form fields must have associated labels
- Calendar/date picker must be navigable via keyboard
- Color-coding (exception added/removed) must not be the sole indicator—use icons or text labels
- Status indicators must include descriptive text for screen readers

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The calendar list and exception list prioritize data visibility. Display service period dates and exception counts prominently. Avoid decorative elements or visual noise that doesn't convey scheduling information.

**Grid System:** Calendar dashboard follows a consistent grid. Service period timelines use proportional date representation. Exception lists align with other data tables in the application.

**Typography:** Use system sans-serif fonts. Calendar names display in standard weight; status labels and dates in lighter weight for hierarchy. Date formats must be consistent and unambiguous (ISO or locale-appropriate).

**Color for Information:** Use color to encode status: active calendars vs. expired, service added (green) vs. removed (red) in exceptions. Maintain high contrast for readability. Warning states use yellow/amber.

**Plain Language:** Field labels use "Start Date" not "service_interval_begin". Exception types display as "Service Added" and "Service Removed" rather than numeric codes. Avoid GTFS jargon in the user interface.

**Input Efficiency:** Provide shortcuts for common patterns: "Copy from previous year" for exception configuration, bulk date selection for recurring holidays, service day presets (Weekdays, Weekend, Daily).

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Calendar management belongs to a `Calendars` context that encapsulates all service period and exception logic. The context owns `Calendar`, `ServicePeriod`, `CalendarException`, and related schemas. Cross-context communication with `Trips` context occurs through public functions.

**Data Validation:** Use Ecto changesets with explicit validations for date ranges, service period overlap detection, and exception uniqueness. Return tagged tuples (`{:ok, calendar}` or `{:error, changeset}`) from context functions. Implement database-level constraints for critical integrity rules.

**LiveView Architecture:** Calendar dashboard and exception manager implement as LiveView. Use streams for calendar and exception lists to handle moderate inventories efficiently. Delegate to function components for service period timeline rendering and date picker interactions.

**Real-Time Updates:** Use Phoenix PubSub to broadcast calendar and exception changes. Multiple users editing the same dataset see updates without manual refresh. Particularly important for exception management during collaborative holiday scheduling.

**Date Handling:** Store all dates as Date type (not DateTime). Service period start/end dates are inclusive. Use Elixir's Date module for overlap detection and gap identification. Ensure timezone-agnostic storage with timezone-aware display.

**Testing Strategy:**
- Context tests validate business rules: service period overlap prevention, exception uniqueness, calendar deletion constraints
- LiveView tests verify user flows: create calendar, add service period, create exception, duplicate calendar
- Focus on behavior over implementation
- Test edge cases: single-day service periods, adjacent periods, exception-only calendar workflows
