# Trips Requirements Document

**Section:** Trips  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Trips section manages the `trips.txt` file and its related `stop_times.txt` records, which together define individual vehicle runs through the transit network. A trip represents a single scheduled journey of a vehicle along a defined path at a specific time. Trips are the fundamental unit of scheduled transit service and connect routes, calendars, patterns, and stop times into the rider-facing schedules that appear in trip planners.

### 1.1 Core Data Fields (trips.txt)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Unique ID | Required | Unique identifier for the trip. |
| `route_id` | Foreign ID | Required | References the route this trip belongs to. |
| `service_id` | Foreign ID | Required | References the calendar or calendar_dates defining when this trip operates. |
| `trip_headsign` | Text | Optional | Destination text displayed on vehicle signage. Recommended for all services with headsign displays. |
| `trip_short_name` | Text | Optional | Public-facing identifier for the trip (e.g., train number "8453"). Should uniquely identify a trip within a service day. Not for destination names or express designations. |
| `direction_id` | Enum | Optional | Indicates travel direction: 0 = outbound, 1 = inbound. Used for organizing timetables, not routing. |
| `block_id` | ID | Optional | Groups sequential trips operated by the same vehicle. Enables vehicle tracking and in-seat transfers. |
| `shape_id` | Foreign ID | Conditionally Required | References the geographic path the vehicle follows. Required if continuous pickup/drop-off is defined. |
| `wheelchair_accessible` | Enum | Optional | Accessibility status: 0 = no info, 1 = accessible, 2 = not accessible. |
| `bikes_allowed` | Enum | Optional | Bicycle accommodation: 0 = no info, 1 = allowed, 2 = not allowed. |

### 1.2 Stop Times Data Fields (stop_times.txt)

Each trip contains an ordered sequence of stop times defining when the vehicle arrives at and departs from each stop.

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Foreign ID | Required | References the parent trip. |
| `stop_id` | Foreign ID | Required | References the stop served at this point in the trip. |
| `stop_sequence` | Non-negative Integer | Required | Order of stops for the trip. Values increase along the trip. |
| `arrival_time` | Time | Conditionally Required | Arrival time at the stop. Required for first/last stop and timepoints. |
| `departure_time` | Time | Conditionally Required | Departure time from the stop. Same requirements as arrival_time. |
| `stop_headsign` | Text | Optional | Overrides trip_headsign for this stop. Useful when destination signage changes mid-trip. |
| `pickup_type` | Enum | Optional | Pickup availability: 0 = regular, 1 = none, 2 = phone agency, 3 = coordinate with driver. |
| `drop_off_type` | Enum | Optional | Drop-off availability: same values as pickup_type. |
| `timepoint` | Enum | Optional | Whether times are exact (1) or approximate/interpolated (0). |
| `shape_dist_traveled` | Non-negative Float | Optional | Distance along the shape from trip start. Important for looping routes. |

### 1.3 Frequency-Based Service (frequencies.txt)

Trips operating at regular headways can be represented using frequency definitions rather than discrete trip records.

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Foreign ID | Required | References the representative trip. |
| `start_time` | Time | Required | Time when frequency-based service begins. |
| `end_time` | Time | Required | Time when frequency-based service ends. |
| `headway_secs` | Positive Integer | Required | Time between departures, in seconds. |
| `exact_times` | Enum | Optional | 0 = frequency-based (approximate), 1 = schedule-based with exact headway. |

### 1.4 Trip Composition Model

In this application, trips are composed of reusable building blocks:

```
Trip
├── Route (what line)
├── Calendar (when it operates)
├── Service Days (which days of week)
├── Stop Pattern (sequence of stops)
└── Timed Pattern (timing between stops)
    └── Start Time (when this specific run begins)
```

**Stop Pattern:** Defines the ordered sequence of stops the trip visits. Multiple trips can share the same stop pattern.

**Timed Pattern:** Defines the timing relationships between stops (travel times, dwell times). Assigned to a stop pattern. Multiple trips can share the same timed pattern.

**Trip:** An instantiation of a timed pattern at a specific start time, assigned to a calendar and service days.

### 1.5 Operational Implications

#### Trip Planning Integration
Trips are the atomic unit of transit service in trip planners. Each trip record results in a schedulable option for riders. Incorrect start times, missing trips, or wrong calendar assignments directly cause riders to miss buses or receive incorrect journey plans.

#### Real-Time Vehicle Tracking
The `block_id` field enables vehicle tracking across multiple trips. When vehicles operate sequential trips without returning to the depot, block assignments allow real-time systems to predict arrivals based on current vehicle position on earlier trips in the block.

#### Timetable Generation
The `direction_id` and `trip_headsign` fields organize trips into readable public timetables. Consistent use enables automated timetable generation that matches how agencies traditionally organize printed schedules.

#### In-Seat Transfers
When passengers can remain on a vehicle between trips (common on loop routes), the application must generate appropriate transfer records (transfer_type=4) or use block_id to indicate continuous service. Misconfigured in-seat transfers force trip planners to instruct riders to exit and re-board unnecessarily.

#### Accessibility Filtering
The `wheelchair_accessible` and `bikes_allowed` fields enable trip planners to filter journeys by accessibility requirements. Incomplete data (some trips marked, others empty) creates unreliable results. These fields should be populated consistently across all trips on a route.

#### Headway-Based Service Display
Frequency-based trips (using `frequencies.txt`) display differently in trip planners than scheduled trips. Routes with "every 15 minutes" service during peak hours benefit from frequency representation, which shows riders a service pattern rather than specific departure times.

#### Data Consumer Impact
Trip data flows to Google Maps, Apple Maps, Transit App, and agency websites. Errors propagate to millions of rider interactions. Common issues include trips assigned to wrong calendars (showing service on holidays), incorrect headsigns (confusing destination information), and missing trips (gaps in published schedules).

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Trip Creation

**JS-TRIP-001: Creating a trip from the timeline view**
When I see an empty time slot in the schedule timeline, I want to click at that position to create a new trip, so I can quickly add service at the exact time needed without navigating away from the schedule view.

**JS-TRIP-002: Creating a trip from the timetable view**
When I am reviewing the timetable and notice a gap between existing trips, I want to insert a new trip between them, so I can fill service gaps while seeing the timing context of adjacent trips.

**JS-TRIP-003: Creating a trip from scratch**
When I am setting up service for a new route or calendar, I want to create a trip by specifying all required elements (pattern, timing, calendar, start time), so I can build the schedule systematically from the ground up.

**JS-TRIP-004: Creating repeated trips with regular headways**
When a route operates at consistent intervals (e.g., every 30 minutes from 6 AM to 6 PM), I want to define the headway and time range once, so I can generate all trips automatically without entering each one individually.

**JS-TRIP-005: Copying trips to another calendar**
When I need the same service pattern on a different calendar (e.g., Saturday service similar to weekday), I want to copy existing trips and assign them to the new calendar, so I can reuse schedule work rather than recreating it.

### 2.2 Trip Editing

**JS-TRIP-006: Adjusting a trip start time**
When a trip needs to depart earlier or later, I want to change just the start time while keeping all other trip properties, so I can make timing adjustments without recreating the trip.

**JS-TRIP-007: Moving trips with keyboard shortcuts**
When I am fine-tuning a schedule, I want to use arrow keys to shift trip times by one minute (or five minutes with modifier keys), so I can make rapid incremental adjustments without opening edit dialogs.

**JS-TRIP-008: Reassigning a trip to a different calendar**
When service patterns change seasonally, I want to move a trip from one calendar to another, so I can reorganize schedules without deleting and recreating trips.

**JS-TRIP-009: Changing a trip's stop pattern or timed pattern**
When a trip's routing or timing changes, I want to assign it to a different existing pattern, so I can reflect service modifications while maintaining the trip's other properties.

**JS-TRIP-010: Editing multiple trips simultaneously**
When the same change applies to several trips (e.g., all morning trips need a new headsign), I want to select multiple trips and edit them together, so I can make bulk changes efficiently.

### 2.3 Trip Scheduling

**JS-TRIP-011: Assigning service days to a trip**
When a trip operates only on certain days (e.g., Monday, Wednesday, Friday), I want to select which days of the week the trip runs, so I can model schedules that vary by day.

**JS-TRIP-012: Scheduling semi-monthly trips**
When service operates less frequently than weekly (e.g., 1st and 3rd Tuesday shopping shuttle), I want to schedule trips on specific calendar dates, so I can model irregular service patterns.

**JS-TRIP-013: Setting in-seat transfer allowance**
When riders can remain on a vehicle between trips (e.g., on a loop route), I want to enable in-seat transfers for those trips, so I can prevent trip planners from incorrectly instructing riders to exit.

### 2.4 Trip Information

**JS-TRIP-014: Setting trip headsign**
When I need to display destination information to riders, I want to set the trip headsign (which can inherit from the pattern or be overridden per trip), so I can ensure accurate signage information in rider-facing applications.

**JS-TRIP-015: Setting trip short name**
When my agency uses train numbers or run identifiers that riders recognize, I want to assign a trip short name, so I can provide familiar identifiers in trip planning results.

**JS-TRIP-016: Assigning trips to blocks**
When tracking vehicles across multiple trips, I want to assign trips to a block, so I can model vehicle assignments and enable real-time tracking continuity.

**JS-TRIP-017: Setting wheelchair accessibility**
When certain trips use accessible vehicles, I want to indicate wheelchair accessibility status, so I can provide accurate accessibility information to riders who need it.

**JS-TRIP-018: Setting bicycle allowance**
When certain trips permit bicycles, I want to indicate bikes allowed status, so I can help cyclists plan trips on appropriate vehicles.

### 2.5 Trip Organization and Review

**JS-TRIP-019: Viewing trips in timeline format**
When I want to see the overall service pattern across a day, I want to view trips as horizontal bars on a timeline, so I can visualize service frequency, gaps, and overlaps.

**JS-TRIP-020: Viewing trips in timetable format**
When I need to review specific departure times at each stop, I want to view trips in a traditional timetable grid, so I can verify schedules match printed timetables.

**JS-TRIP-021: Filtering trips by calendar**
When working on a specific service period (e.g., summer schedule), I want to filter the trip list to show only trips on that calendar, so I can focus on relevant trips without distraction.

**JS-TRIP-022: Filtering trips by direction**
When organizing timetables, I want to filter trips by direction (inbound/outbound), so I can work on one direction at a time as agencies traditionally do.

### 2.6 Trip Deletion

**JS-TRIP-023: Deleting a single trip**
When a trip is discontinued, I want to delete it from the schedule, so I can remove service that no longer operates.

**JS-TRIP-024: Deleting multiple trips at once**
When removing a block of service (e.g., all evening trips being cut), I want to select and delete multiple trips together, so I can make bulk deletions efficiently.

**JS-TRIP-025: Understanding deletion impact**
When considering deleting a trip that may be part of a repeated trip group or block, I want to see what will be affected by the deletion, so I can avoid unintended consequences.

### 2.7 Frequency-Based Service

**JS-TRIP-026: Converting trips to frequency-based**
When a series of trips operates at regular headways, I want to aggregate them into a frequency-based representation, so I can simplify the data and enable "every X minutes" display in trip planners.

**JS-TRIP-027: Expanding frequency-based trips**
When I need to make individual adjustments to trips within a frequency group, I want to expand them back into discrete trips, so I can edit specific departures.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Schedule View Navigation

**US-TRIP-001: View schedule timeline**
As a schedule editor, I want to view all trips for a route on a horizontal timeline, so that I can visualize the service pattern throughout the day.

**US-TRIP-002: View schedule timetable**
As a schedule editor, I want to view trips in a timetable grid showing stop times, so that I can verify schedules against printed timetables.

**US-TRIP-003: Toggle between schedule views**
As a schedule editor, I want to switch between timeline and timetable views, so that I can use the most appropriate visualization for my current task.

**US-TRIP-004: Filter trips by calendar**
As a schedule editor, I want to filter the schedule view by calendar, so that I can focus on trips for a specific service period.

**US-TRIP-005: Filter trips by direction**
As a schedule editor, I want to filter trips by direction, so that I can work on inbound and outbound schedules separately.

**US-TRIP-006: Expand/collapse calendar groups**
As a schedule editor, I want to expand or collapse trip groups by calendar, so that I can manage screen space when working with complex schedules.

### 3.2 Trip Creation

**US-TRIP-007: Create trip via Add Trip button**
As a schedule editor, I want to create a trip using an Add Trip button, so that I can build schedules from scratch with full control over all trip properties.

**US-TRIP-008: Create trip from timeline click**
As a schedule editor, I want to create a trip by clicking on the timeline at a specific time, so that I can quickly add trips with the start time pre-populated.

**US-TRIP-009: Create trip from timetable insertion**
As a schedule editor, I want to insert a new trip between existing trips in timetable view, so that I can add trips with context from adjacent departures.

**US-TRIP-010: Set trip start time**
As a schedule editor, I want to specify the trip start time, so that the first stop departure is scheduled correctly.

**US-TRIP-011: Assign trip to calendar**
As a schedule editor, I want to assign a trip to a calendar, so that the trip operates during the correct service period.

**US-TRIP-012: Assign trip service days**
As a schedule editor, I want to select which days of the week a trip operates, so that I can model day-specific schedules.

**US-TRIP-013: Assign stop pattern to trip**
As a schedule editor, I want to assign a stop pattern to a trip, so that the trip follows the correct sequence of stops.

**US-TRIP-014: Assign timed pattern to trip**
As a schedule editor, I want to assign a timed pattern to a trip, so that the trip uses the correct timing between stops.

**US-TRIP-015: Create repeated trips**
As a schedule editor, I want to create multiple trips with regular headways from a single definition, so that I can build consistent schedules efficiently.

### 3.3 Trip Details

**US-TRIP-016: Set trip headsign**
As a schedule editor, I want to set the trip headsign, so that riders see correct destination information.

**US-TRIP-017: Set trip short name**
As a schedule editor, I want to set a trip short name (e.g., train number), so that riders can identify specific runs.

**US-TRIP-018: Set trip direction**
As a schedule editor, I want to set the direction ID, so that trips are organized correctly in timetables.

**US-TRIP-019: Assign trip to block**
As a schedule editor, I want to assign a trip to a block, so that vehicle tracking works across sequential trips.

**US-TRIP-020: Set wheelchair accessibility**
As a schedule editor, I want to set wheelchair accessibility status, so that accessibility filters work correctly.

**US-TRIP-021: Set bikes allowed**
As a schedule editor, I want to set bicycle allowance status, so that cyclists can plan appropriate trips.

**US-TRIP-022: Enable in-seat transfers**
As a schedule editor, I want to enable in-seat transfers between trips, so that riders on loop routes aren't told to exit unnecessarily.

**US-TRIP-023: Save trip changes**
As a schedule editor, I want to save my trip edits, so that changes are persisted to the database.

### 3.4 Trip Editing

**US-TRIP-024: Edit trip via selection**
As a schedule editor, I want to click on a trip in timeline or timetable view to edit it, so that I can make changes without navigating away.

**US-TRIP-025: Edit trip start time**
As a schedule editor, I want to change a trip's start time, so that I can adjust scheduling without recreating the trip.

**US-TRIP-026: Move trip with keyboard shortcuts**
As a schedule editor, I want to use arrow keys to shift trip times (1 minute, 5 minutes with Shift, 1 hour with Ctrl), so that I can make rapid adjustments.

**US-TRIP-027: Change trip calendar**
As a schedule editor, I want to reassign a trip to a different calendar, so that I can reorganize schedules.

**US-TRIP-028: Change trip patterns**
As a schedule editor, I want to change a trip's stop pattern or timed pattern, so that I can update routing or timing.

**US-TRIP-029: Edit multiple trips**
As a schedule editor, I want to select multiple trips and edit them together, so that I can make bulk changes.

### 3.5 Trip Copying

**US-TRIP-030: Copy trip**
As a schedule editor, I want to copy a trip with Ctrl+C, so that I can duplicate it elsewhere.

**US-TRIP-031: Paste trip at specific time**
As a schedule editor, I want to paste a copied trip at a specific time on the timeline, so that I can create a new trip with the same properties at a different time.

**US-TRIP-032: Paste trip at original time**
As a schedule editor, I want to paste a copied trip at its original time on a different calendar row, so that I can duplicate service patterns across calendars.

**US-TRIP-033: Copy multiple trips**
As a schedule editor, I want to copy multiple selected trips at once, so that I can duplicate groups of trips.

### 3.6 Trip Deletion

**US-TRIP-034: Delete single trip**
As a schedule editor, I want to delete a trip, so that I can remove discontinued service.

**US-TRIP-035: Delete multiple trips**
As a schedule editor, I want to delete multiple selected trips at once, so that I can remove service in bulk.

**US-TRIP-036: Confirm trip deletion**
As a schedule editor, I want to confirm before trips are deleted, so that I don't accidentally remove service.

### 3.7 Repeated Trips (Frequency)

**US-TRIP-037: Set regular headway**
As a schedule editor, I want to define a regular headway for repeated trips, so that consistent service is scheduled automatically.

**US-TRIP-038: Set number of trips**
As a schedule editor, I want to specify how many trips repeat, so that I control the extent of the service.

**US-TRIP-039: Set last trip departure**
As a schedule editor, I want to set when the last trip departs, so that service ends at the right time.

**US-TRIP-040: Aggregate trips to repeated**
As a schedule editor, I want to combine individual trips with matching patterns and regular headways into a repeated trip group, so that I can simplify the schedule representation.

**US-TRIP-041: Expand repeated trips**
As a schedule editor, I want to expand a repeated trip group into individual trips, so that I can edit specific departures.

**US-TRIP-042: Set frequency-based display**
As a schedule editor, I want to mark repeated trips for frequency-based display (frequencies.txt), so that trip planners show "every X minutes" rather than specific times.

### 3.8 Data Validation

**US-TRIP-043: Validate required fields**
As a schedule editor, I want the system to validate that required fields are populated, so that I don't create incomplete trip records.

**US-TRIP-044: Validate pattern compatibility**
As a schedule editor, I want the system to ensure the timed pattern is compatible with the stop pattern, so that I don't create invalid combinations.

**US-TRIP-045: Warn about schedule conflicts**
As a schedule editor, I want to be warned about overlapping trips on the same block, so that I can identify scheduling conflicts.

---

## 4. Acceptance Criteria

### 4.1 Schedule View - Timeline

**AC-TRIP-001: Timeline displays trips as horizontal bars**
- Given I navigate to the Schedule tab for a route
- When the timeline view loads
- Then trips are displayed as horizontal bars positioned by start time
- And the bar length represents trip duration
- And trips are organized by calendar rows

**AC-TRIP-002: Timeline shows time scale**
- Given I am viewing the schedule timeline
- Then a time scale is displayed along the top
- And the scale shows hours from service start to service end
- And I can scroll horizontally to view the full day

**AC-TRIP-003: Timeline calendars are expandable**
- Given I am viewing the schedule timeline with multiple calendars
- When I click on a calendar header
- Then the calendar row expands to show its trips
- And clicking again collapses the row

**AC-TRIP-004: Timeline supports zoom**
- Given I am viewing the schedule timeline
- When I zoom in or out
- Then the time scale adjusts
- And trips resize proportionally

### 4.2 Schedule View - Timetable

**AC-TRIP-005: Timetable displays stop times in grid**
- Given I switch to timetable view
- When the view loads
- Then stops are listed as rows
- And trips are listed as columns
- And each cell shows the arrival time at that stop

**AC-TRIP-006: Timetable columns are sortable**
- Given I am viewing the timetable
- Then trips are sorted by departure time from the first stop
- And earliest trips appear in leftmost columns

**AC-TRIP-007: Timetable insertion points**
- Given I am viewing the timetable
- When I hover between two trip columns
- Then a "+" icon appears
- And clicking it creates a new trip

### 4.3 Trip Creation

**AC-TRIP-008: Create trip via Add Trip button**
- Given I am on the Schedule tab
- When I click the "Add a Trip" button
- Then a trip creation form opens
- And all fields are empty or set to defaults

**AC-TRIP-009: Create trip from timeline**
- Given I am viewing the timeline
- When I move the cursor to an empty area on a calendar row
- Then an "Add Trip" button appears at that time position
- And clicking it opens the trip form with start time, calendar, and service days pre-populated

**AC-TRIP-010: Create trip from timetable**
- Given I am viewing the timetable
- When I click the "+" between two trips
- Then a trip form opens with values copied from the preceding trip
- And the start time defaults to the same as the preceding trip (requiring adjustment)

**AC-TRIP-011: Trip requires start time**
- Given I am creating or editing a trip
- When I attempt to save without a start time
- Then the system displays a validation error
- And the trip is not saved

**AC-TRIP-012: Trip requires calendar**
- Given I am creating a trip
- When I attempt to save without selecting a calendar
- Then the system displays a validation error
- And the trip is not saved

**AC-TRIP-013: Trip requires stop pattern**
- Given I am creating a trip
- When I attempt to save without selecting a stop pattern
- Then the system displays a validation error
- And the trip is not saved

**AC-TRIP-014: Trip requires timed pattern**
- Given I am creating a trip
- When I attempt to save without selecting a timed pattern
- Then the system displays a validation error
- And the trip is not saved

**AC-TRIP-015: Trip requires at least one service day**
- Given I am creating a trip on a standard calendar (not exception-only)
- When I attempt to save without selecting any service days
- Then the system displays a validation error
- And the trip is not saved

### 4.4 Trip Editing

**AC-TRIP-016: Select trip from timeline**
- Given I am viewing the timeline
- When I click on a trip bar
- Then the trip details panel opens
- And the trip is visually highlighted

**AC-TRIP-017: Select trip from timetable**
- Given I am viewing the timetable
- When I click on a trip column header
- Then the trip details panel opens

**AC-TRIP-018: Edit trip start time**
- Given I am editing a trip
- When I change the start time field
- Then all stop times shift accordingly
- And the trip bar moves on the timeline

**AC-TRIP-019: Save trip changes**
- Given I have edited a trip
- When I click the Save button
- Then my changes are persisted
- And the timeline/timetable updates to reflect changes
- And a success confirmation is displayed

**AC-TRIP-020: Unsaved changes warning**
- Given I have unsaved changes to a trip
- When I navigate away or select another trip
- Then the system warns me about unsaved changes
- And offers to save or discard

### 4.5 Keyboard Navigation

**AC-TRIP-021: Move trip one minute with arrow keys**
- Given I have selected a trip in timeline view
- When I press left or right arrow
- Then the trip start time shifts by one minute in that direction

**AC-TRIP-022: Move trip five minutes with Shift+arrow**
- Given I have selected a trip in timeline view
- When I press Shift + left or right arrow
- Then the trip start time shifts by five minutes

**AC-TRIP-023: Move trip one hour with Ctrl+arrow**
- Given I have selected a trip in timeline view
- When I press Ctrl + left or right arrow
- Then the trip start time shifts by one hour

### 4.6 Multi-Select Operations

**AC-TRIP-024: Select multiple trips with Shift+click**
- Given I am viewing the timeline
- When I hold Shift and click on multiple trips
- Then all clicked trips are selected
- And the edit panel shows multi-edit mode

**AC-TRIP-025: Select trips with drag selection**
- Given I am viewing the timeline
- When I hold Shift and drag to create a selection box
- Then all trips within the box are selected

**AC-TRIP-026: Edit multiple trips**
- Given I have multiple trips selected
- When I change a field in the edit panel
- Then the change applies to all selected trips
- And the system indicates how many trips will be affected

### 4.7 Copy and Paste

**AC-TRIP-027: Copy trip with Ctrl+C**
- Given I have selected one or more trips
- When I press Ctrl+C
- Then the trips are copied to clipboard
- And a visual indication confirms the copy

**AC-TRIP-028: Paste trip at specific time**
- Given I have copied a trip
- When I click on the timeline at a specific time (with no trip selected)
- And I press Ctrl+V
- Then a new trip is created at that time
- And the trip inherits all properties from the copied trip

**AC-TRIP-029: Paste trip at original time**
- Given I have copied a trip
- When I click in the header area above the timeline (not on a specific time)
- And I press Ctrl+V
- Then a new trip is created at the original start time
- And this allows duplicating trips to different calendars at the same time

### 4.8 Trip Deletion

**AC-TRIP-030: Delete single trip**
- Given I am editing a trip
- When I click the Delete button
- Then a confirmation dialog appears
- And confirming deletes the trip
- And the trip is removed from timeline/timetable

**AC-TRIP-031: Delete multiple trips**
- Given I have multiple trips selected
- When I delete them
- Then a confirmation indicates how many trips will be deleted
- And confirming deletes all selected trips

**AC-TRIP-032: Trip deletion confirmation**
- Given I initiate a trip deletion
- Then the system shows a confirmation dialog
- And the dialog indicates what will be deleted
- And I must explicitly confirm to proceed

### 4.9 Repeated Trips

**AC-TRIP-033: Enable repeated trips**
- Given I am creating or editing a trip
- When I check "Repeats with regular headways"
- Then headway configuration fields appear
- And I can set headway interval, number of trips, or last departure time

**AC-TRIP-034: Headway field updates other fields**
- Given I am configuring repeated trips
- When I change the regular headway interval
- Then the number of trips updates based on start time and last departure
- Or the last departure updates if number is fixed

**AC-TRIP-035: Repeated trips display on timeline**
- Given a trip is configured with repetitions
- Then all instances appear as separate bars on the timeline
- And they are visually grouped (e.g., with a connecting line or shared highlight)

**AC-TRIP-036: Expand repeated trip**
- Given I am viewing a repeated trip
- When I select "Expand into individual trips" from the menu
- Then the repeated trip is converted to individual trip records
- And each can be edited separately

**AC-TRIP-037: Aggregate trips to repeated**
- Given I have multiple trips with the same pattern and regular headways selected
- When I select "Combine into repeating trip"
- Then the trips are aggregated into a single repeated trip definition

### 4.10 Service Days

**AC-TRIP-038: Service days checkboxes**
- Given I am editing a trip
- Then I see checkboxes for each day of the week (Mon-Sun)
- And I can check/uncheck to set which days the trip operates

**AC-TRIP-039: Service days required for standard calendars**
- Given I am editing a trip on a calendar with Service Periods
- When no service days are checked
- Then a validation warning indicates at least one day must be selected

**AC-TRIP-040: Exception-only calendar allows no service days**
- Given I am editing a trip on an exception-only calendar
- Then service days checkboxes may be disabled or hidden
- And the trip operates only on dates explicitly added as exceptions

### 4.11 In-Seat Transfers

**AC-TRIP-041: In-seat transfer checkbox**
- Given I am editing a trip
- Then I see an "In-seat transfers allowed" checkbox
- And checking it indicates passengers may remain on the vehicle to the next trip

**AC-TRIP-042: In-seat transfer generates transfer record**
- Given in-seat transfers are enabled for a trip
- When GTFS is exported
- Then appropriate transfer records (transfer_type=4) are generated
- And trip planners allow passengers to remain on board

### 4.12 Trip Information Fields

**AC-TRIP-043: Headsign field**
- Given I am editing a trip
- Then I can view and edit the trip headsign
- And the headsign may inherit from the timed pattern
- And I can override it for this specific trip

**AC-TRIP-044: Trip short name field**
- Given I am editing a trip
- Then I can enter a trip short name
- And help text indicates this is for train numbers or run identifiers
- And warns it should not be used for destinations

**AC-TRIP-045: Direction field**
- Given I am editing a trip
- Then I can set direction_id (0 = outbound, 1 = inbound)
- And direction is used for organizing timetables

**AC-TRIP-046: Block assignment**
- Given I am editing a trip
- Then I can assign or change the block ID
- And the block dropdown shows existing blocks
- And I can enter a new block name

**AC-TRIP-047: Wheelchair accessibility field**
- Given I am editing a trip
- Then I can set wheelchair accessibility status
- And options are: No information, Accessible, Not accessible

**AC-TRIP-048: Bikes allowed field**
- Given I am editing a trip
- Then I can set bicycle allowance status
- And options are: No information, Allowed, Not allowed

### 4.13 Filtering

**AC-TRIP-049: Filter by calendar**
- Given I am viewing the schedule
- When I select a calendar from the filter dropdown
- Then only trips on that calendar are displayed

**AC-TRIP-050: Filter by direction**
- Given I am viewing the schedule
- When I select a direction filter
- Then only trips with that direction_id are displayed

**AC-TRIP-051: Clear filters**
- Given I have filters applied
- When I clear filters
- Then all trips are displayed again

### 4.14 GTFS Export

**AC-TRIP-052: Trips included in GTFS export**
- Given I have trips configured
- When I export GTFS
- Then trips.txt contains records for all active trips
- And stop_times.txt contains ordered stop records for each trip

**AC-TRIP-053: Frequency-based trips export**
- Given I have trips marked for frequency-based display
- When I export GTFS
- Then frequencies.txt contains the frequency definitions
- And the corresponding trip is included in trips.txt as a template

---

## 5. Non-Functional Requirements

### 5.1 Performance

- Timeline view must render within 2 seconds for routes with up to 200 trips per calendar
- Timetable view must render within 3 seconds for routes with up to 200 trips
- Trip creation and save operations must complete within 1 second
- Keyboard-based time adjustments must update the display within 100ms for responsive feel
- Bulk operations (multi-select edit, delete) must process up to 50 trips within 3 seconds

### 5.2 Usability

- Timeline interactions follow established patterns (drag to move, click to select)
- Keyboard shortcuts match common conventions (Ctrl+C/V for copy/paste, arrow keys for movement)
- Save buttons use high-visibility styling (bright green) per existing UI conventions
- Delete operations require explicit confirmation
- Multi-select mode provides clear visual feedback indicating which trips are selected
- Time entry supports common formats (HH:MM, HH:MM:SS) with auto-formatting

### 5.3 Data Integrity

- Trip deletion must cascade appropriately to remove orphaned stop_times
- Pattern changes must validate that new timed patterns are compatible with assigned stop patterns
- Block assignments must validate that trips in the same block have compatible service days and sequential timing
- Service day requirements must be enforced based on calendar type

### 5.4 Accessibility

- All form fields must have associated labels
- Timeline view must provide keyboard navigation alternatives
- Color-coding for calendars must not be the sole differentiator (use labels or patterns)
- Focus states must be clearly visible for keyboard users

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The timeline and timetable views prioritize data visibility. Trip bars use minimal decoration—color encodes calendar or direction, not aesthetic preference. Avoid shadows, gradients, or ornamental elements on trip representations.

**Grid System:** The timeline aligns to a strict time grid. The timetable follows a consistent column/row structure. Maintain mathematical alignment of elements.

**Typography:** Use system sans-serif fonts. Stop names and times display in standard weight; headers and labels in lighter weight for hierarchy. Times use monospace or tabular figures for alignment.

**Color for Information:** Use color to encode calendar or direction consistently throughout the application. Do not use color decoratively. Maintain high contrast for all text.

**Plain Language:** Field labels use plain terms. "Start Time" not "Trip Origin Temporal Designation." Help text is direct and actionable.

**Input Efficiency:** Minimize clicks for common operations. Keyboard shortcuts for time adjustments. Auto-population of fields when context is known. Support for repeated trip creation to avoid manual entry.

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Trip management belongs to a `Schedules` or `Trips` context that encapsulates trip-related business logic. The context owns `Trip`, `StopTime`, and `Frequency` schemas. Stop patterns and timed patterns may belong to a `Patterns` context that the Trips context calls.

**Data Validation:** Use Ecto changesets with explicit validations for required fields, time formats, and referential integrity. Return tagged tuples (`{:ok, trip}` or `{:error, changeset}`) from context functions.

**LiveView Architecture:** The schedule view (timeline and timetable) implements as LiveView for real-time interaction. Use streams for trip lists to handle large schedules efficiently. Keyboard events handled through phx-keydown hooks. Trip editing uses modal or panel components with isolated state.

**Real-Time Updates:** Use Phoenix PubSub to broadcast trip changes. Multiple users editing the same route's schedule see updates without manual refresh.

**Pattern Matching:** Use pattern matching for trip state transitions (e.g., handling different calendar types, validating pattern compatibility).

**Testing Strategy:**
- Context tests validate business rules (required fields, pattern compatibility, block validation)
- LiveView tests verify user flows (create, edit, copy, delete)
- Integration tests verify GTFS export produces valid output
- Focus on behavior over implementation
