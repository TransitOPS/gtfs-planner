# Schedules and Blocks Requirements Document

**Section:** Schedules and Blocks  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Schedules and Blocks section manages the scheduling of trips and the assignment of vehicle blocks within a GTFS feed. This section primarily interacts with `trips.txt` and `stop_times.txt`, while leveraging data from routes, stop patterns, timed patterns, and calendars to compose complete schedule records.

### 1.1 Core Data Fields (trips.txt)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Unique ID | Required | Unique identifier for the trip. |
| `route_id` | Foreign ID | Required | References the route this trip belongs to. |
| `service_id` | Foreign ID | Required | References the calendar defining when this trip operates. |
| `trip_headsign` | Text | Optional | Rider-facing destination text displayed on vehicle signage. May be overridden by stop_times.stop_headsign for specific stops. |
| `trip_short_name` | Text | Optional | Public-facing identifier such as a train number or run number. Should uniquely identify a trip within a service day. |
| `direction_id` | Enum | Optional | Indicates travel direction: 0 = outbound, 1 = inbound. Used for timetable organization, not routing. |
| `block_id` | ID | Optional | Identifies the block (vehicle assignment) to which this trip belongs. Enables in-seat transfers and real-time tracking. |
| `shape_id` | Foreign ID | Conditionally Required | References the geographic shape of the trip's path. Required if continuous pickup/drop-off behavior is defined. |
| `wheelchair_accessible` | Enum | Optional | Accessibility status: 0 = no info, 1 = accessible, 2 = not accessible. |
| `bikes_allowed` | Enum | Optional | Bicycle accommodation: 0 = no info, 1 = allowed, 2 = not allowed. |

### 1.2 Schedule Composition Model

A scheduled trip in the application is composed of several interconnected elements:

```
Route
└── Stop Pattern (sequence of stops)
    └── Timed Pattern (timing between stops)
        └── Trip (specific departure assigned to a calendar)
            └── Block (optional vehicle assignment)
```

**Composition Rules:**
- A trip must reference exactly one route
- A trip must follow exactly one stop pattern
- A trip must apply exactly one timed pattern
- A trip must be assigned to exactly one calendar (service_id)
- A trip may optionally be assigned to one block
- Multiple trips may share the same block within a service day

### 1.3 Block Structure

Blocks represent vehicle assignments that may span multiple trips, routes, or service periods. A block groups sequential trips operated by the same vehicle.

**Block Characteristics:**
- Blocks are identified by a user-defined label and display color
- A single block may contain trips from multiple routes (interlining)
- A single block may span trips across the same calendar
- Trips within a block must not overlap temporally on the same service day
- The same block_id may operate on different service days with different trip sequences

### 1.4 Operational Implications

#### Real-Time System Integration
The `block_id` field is essential for Automatic Vehicle Location (AVL) and real-time arrival prediction systems. These systems track vehicle positions and use block assignments to predict arrivals for subsequent trips. Agencies using real-time systems must maintain accurate block assignments.

#### In-Seat Transfer Support
Blocks enable trip planners to identify in-seat transfer opportunities. When trips share a block_id, riders can remain on the vehicle as it transitions between trips or routes. Trip planners display "Stay on Board" messaging for interlined routes. For loop routes, blocks allow riders to continue past the loop terminus without alighting.

#### Vehicle Resource Planning
Block definitions correspond to vehicle assignments in operational planning. Each distinct block typically represents one vehicle's work for a service day. Accurate block modeling supports runcut validation and driver scheduling integration.

#### Overlapping Block Validation
A common data quality error is overlapping blocks—where two trips assigned to the same block have overlapping service times on the same service day. Overlapping blocks are physically impossible (one vehicle cannot serve two trips simultaneously) and must be detected and resolved.

#### Schedule Visualization
Schedule data flows into timetables, timeline views, and public-facing schedule documents. The hierarchical organization by calendar, service day, pattern, and block enables users to review and validate complex schedules efficiently.

#### Data Consumers
Trip and schedule data powers Google Maps, Apple Maps, Transit App, and agency-specific applications. Incomplete schedules, missing blocks, or incorrect timing data directly impact millions of rider queries. Schedule accuracy is essential for rider trust and operational efficiency.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Schedule Viewing and Navigation

**JS-SCHED-001: Reviewing a route's complete schedule**
When I need to understand the full service pattern for a route, I want to view all trips organized by calendar and service day, so I can verify that the published schedule matches operational plans.

**JS-SCHED-002: Switching between schedule visualizations**
When a timeline view shows overlapping trips that are hard to distinguish, I want to switch to a timetable view, so I can see exact departure times in a familiar tabular format.

**JS-SCHED-003: Filtering schedules by calendar**
When I am working on a specific service period (e.g., summer schedule), I want to filter the schedule view to show only trips on that calendar, so I can focus on the relevant subset of trips.

**JS-SCHED-004: Filtering schedules by block**
When I need to review all trips assigned to a specific vehicle, I want to filter the schedule by block, so I can validate the vehicle's complete daily work.

**JS-SCHED-005: Filtering schedules by direction**
When reviewing outbound versus inbound service levels, I want to filter trips by direction, so I can ensure balanced service in each direction.

### 2.2 Trip Creation

**JS-SCHED-006: Creating a trip from the timeline**
When I identify a service gap in the timeline view, I want to click at the desired time to create a new trip, so I can fill the gap without manually entering the start time.

**JS-SCHED-007: Creating a trip from the timetable**
When I need to add a trip similar to an existing one, I want to insert a new trip between existing trips with values pre-populated, so I can create trips efficiently without re-entering pattern and calendar information.

**JS-SCHED-008: Creating a trip from scratch**
When building a new schedule with no existing trips, I want to create a trip by selecting all required components (calendar, pattern, timing), so I can establish the first trips in a schedule.

**JS-SCHED-009: Creating repeated trips at regular headways**
When service operates at consistent intervals, I want to specify a start time, end time, and headway to generate multiple trips automatically, so I can avoid creating each trip individually.

### 2.3 Trip Editing

**JS-SCHED-010: Adjusting a trip's start time**
When a trip's departure needs to change, I want to edit the start time and have all subsequent stop times recalculate, so I can shift the trip without manual timing adjustments.

**JS-SCHED-011: Reassigning a trip to a different calendar**
When service periods change, I want to move a trip from one calendar to another, so I can reorganize schedules without recreating trips.

**JS-SCHED-012: Assigning a block to a trip**
When a trip needs to be associated with a vehicle assignment, I want to select a block from available options, so I can enable real-time tracking and in-seat transfers.

**JS-SCHED-013: Changing a trip's pattern**
When a trip needs to follow a different stop sequence, I want to change its stop pattern and timed pattern, so I can accommodate route variations without deleting and recreating the trip.

### 2.4 Trip Deletion

**JS-SCHED-014: Deleting a single trip**
When a trip should no longer operate, I want to delete it from the schedule, so I can remove obsolete service from the GTFS export.

**JS-SCHED-015: Understanding deletion impact**
When considering trip deletion, I want to see if the trip is part of a block with other trips, so I can assess whether deletion will affect related real-time or transfer functionality.

### 2.5 Block Management

**JS-SCHED-016: Creating a new block**
When I need to define a new vehicle assignment, I want to create a block with a label and color, so I can begin assigning trips to it.

**JS-SCHED-017: Renaming a block**
When a block's label no longer reflects its purpose, I want to rename it, so I can maintain clear block identification.

**JS-SCHED-018: Changing a block's color**
When multiple blocks appear similar in schedule views, I want to change a block's display color, so I can distinguish blocks visually.

**JS-SCHED-019: Viewing block usage across routes**
When managing interlining, I want to see all trips assigned to a block organized by route, so I can understand the complete vehicle assignment.

**JS-SCHED-020: Deleting an unused block**
When a block is no longer needed, I want to delete it, so I can keep the block list manageable.

### 2.6 Block Schedule Visualization

**JS-SCHED-021: Viewing a block's complete schedule**
When validating a vehicle's daily work, I want to see all trips in a block displayed in timeline and timetable format, so I can verify the sequence makes operational sense.

**JS-SCHED-022: Viewing a block across multiple routes**
When a block interlines between routes, I want to see trips color-coded by route in the block schedule, so I can understand how the vehicle transitions between routes.

**JS-SCHED-023: Filtering block schedules by date**
When a block operates differently on different days, I want to filter the block schedule to a specific date, so I can see the exact trips for that day.

**JS-SCHED-024: Combining calendars in block view**
When comparing block usage across service periods, I want to optionally combine calendars in the block schedule view, so I can see comprehensive block utilization.

### 2.7 Overlapping Block Detection

**JS-SCHED-025: Identifying blocks with overlaps**
When validating my GTFS data, I want to see which blocks have overlapping trips flagged prominently, so I can prioritize fixing these validation errors.

**JS-SCHED-026: Understanding overlap details**
When a block has overlapping trips, I want to see the specific trips and dates where overlaps occur, so I can determine how to resolve the conflict.

**JS-SCHED-027: Navigating to fix overlaps**
When I identify an overlapping trip in the block schedule view, I want to navigate directly to that trip in the route editor, so I can fix the overlap efficiently.

### 2.8 Special Trip Configurations

**JS-SCHED-028: Enabling in-seat transfers**
When riders should be allowed to stay on board between trips (e.g., loop routes), I want to mark trips as allowing in-seat transfers, so I can enable appropriate trip planner behavior.

**JS-SCHED-029: Setting trip accessibility**
When a specific trip uses an accessible vehicle, I want to set the wheelchair accessible flag, so I can communicate accessibility to riders.

**JS-SCHED-030: Assigning trip short names**
When trips have operational identifiers like run numbers, I want to assign trip short names, so I can maintain consistency with internal scheduling systems.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Schedule Viewing

**US-SCHED-001: View route schedule**
As a schedule editor, I want to view a route's schedule organized by calendar and pattern, so that I can review the complete service definition.

**US-SCHED-002: View schedule in timeline format**
As a schedule editor, I want to view trips as bars on a time-based timeline, so that I can visualize service coverage and identify gaps.

**US-SCHED-003: View schedule in timetable format**
As a schedule editor, I want to view trips in a traditional timetable grid with stops as rows and trips as columns, so that I can review timing details in a familiar format.

**US-SCHED-004: Filter schedule by calendar**
As a schedule editor, I want to filter the schedule view to specific calendars, so that I can focus on one service period at a time.

**US-SCHED-005: Filter schedule by block**
As a schedule editor, I want to filter the schedule view to specific blocks, so that I can review all trips for a particular vehicle assignment.

**US-SCHED-006: Filter schedule by direction**
As a schedule editor, I want to filter the schedule view by direction, so that I can review outbound and inbound service separately.

**US-SCHED-007: Sort timeline by pattern**
As a schedule editor, I want to sort the timeline view by stop pattern, so that I can see trips grouped by their stop sequences.

**US-SCHED-008: Sort timeline by start time**
As a schedule editor, I want to sort the timeline view by start time only, so that I can see all trips in chronological order regardless of pattern.

**US-SCHED-009: Sort timeline by block**
As a schedule editor, I want to sort the timeline view by block, so that I can see trips grouped by vehicle assignment.

**US-SCHED-010: Toggle timepoints in timetable**
As a schedule editor, I want to show only timepoints or all stops in the timetable view, so that I can control the level of timing detail displayed.

### 3.2 Trip Creation

**US-SCHED-011: Create trip via Add Trip button**
As a schedule editor, I want to click an "Add Trip" button to create a trip from scratch, so that I can build new schedules.

**US-SCHED-012: Create trip via timeline click**
As a schedule editor, I want to click on the timeline at a specific time to create a trip starting at that time, so that I can quickly fill schedule gaps.

**US-SCHED-013: Create trip via timetable insertion**
As a schedule editor, I want to insert a trip between existing trips in the timetable, with values copied from the adjacent trip, so that I can quickly add similar trips.

**US-SCHED-014: Set trip start time**
As a schedule editor, I want to set a trip's start time, so that I can define when the trip departs from the first stop.

**US-SCHED-015: Select trip calendar**
As a schedule editor, I want to select which calendar a trip operates on, so that I can associate trips with specific service periods.

**US-SCHED-016: Select trip service days**
As a schedule editor, I want to select which days of the week a trip operates, so that I can define the trip's weekly schedule.

**US-SCHED-017: Select trip stop pattern**
As a schedule editor, I want to select which stop pattern a trip follows, so that I can define the trip's stop sequence.

**US-SCHED-018: Select trip timed pattern**
As a schedule editor, I want to select which timed pattern a trip uses, so that I can define the timing between stops.

**US-SCHED-019: Create repeated trips**
As a schedule editor, I want to create multiple trips at regular intervals by specifying a start time, end time, and headway, so that I can efficiently build high-frequency schedules.

**US-SCHED-020: Save trip**
As a schedule editor, I want to save a trip after entering its details, so that my work is persisted to the database.

### 3.3 Trip Editing

**US-SCHED-021: Select trip from timeline**
As a schedule editor, I want to click on a trip in the timeline to open its details, so that I can edit it.

**US-SCHED-022: Select trip from timetable**
As a schedule editor, I want to click on a trip column in the timetable to open its details, so that I can edit it.

**US-SCHED-023: Edit trip start time**
As a schedule editor, I want to change a trip's start time, so that I can adjust departure times.

**US-SCHED-024: Edit trip calendar assignment**
As a schedule editor, I want to change which calendar a trip is assigned to, so that I can reorganize trips between service periods.

**US-SCHED-025: Edit trip service days**
As a schedule editor, I want to change which days a trip operates, so that I can adjust weekly schedules.

**US-SCHED-026: Edit trip stop pattern**
As a schedule editor, I want to change a trip's stop pattern, so that I can assign it to a different stop sequence.

**US-SCHED-027: Edit trip timed pattern**
As a schedule editor, I want to change a trip's timed pattern, so that I can assign it different timing.

**US-SCHED-028: Assign block to trip**
As a schedule editor, I want to assign a block to a trip, so that I can associate it with a vehicle assignment.

**US-SCHED-029: Remove block from trip**
As a schedule editor, I want to remove a block assignment from a trip, so that I can disassociate it from a vehicle.

**US-SCHED-030: Set trip headsign**
As a schedule editor, I want to set a trip's headsign, so that I can define the destination text displayed to riders.

**US-SCHED-031: Set trip short name**
As a schedule editor, I want to set a trip's short name (e.g., run number), so that I can maintain operational identifiers.

**US-SCHED-032: Set trip direction**
As a schedule editor, I want to set a trip's direction_id, so that I can organize timetables by direction.

**US-SCHED-033: Set wheelchair accessibility**
As a schedule editor, I want to set a trip's wheelchair accessibility status, so that I can communicate accessibility to riders.

**US-SCHED-034: Set bikes allowed**
As a schedule editor, I want to set whether bikes are allowed on a trip, so that I can communicate bicycle policy to riders.

**US-SCHED-035: Enable in-seat transfers**
As a schedule editor, I want to mark a trip as allowing in-seat transfers, so that riders can stay on board for loop routes.

### 3.4 Trip Deletion

**US-SCHED-036: Delete trip from details view**
As a schedule editor, I want to delete a trip from its details view, so that I can remove obsolete trips.

**US-SCHED-037: Delete trip from timeline**
As a schedule editor, I want to delete a trip directly from the timeline view, so that I can quickly remove trips without opening details.

**US-SCHED-038: Confirm trip deletion**
As a schedule editor, I want to confirm before a trip is deleted, so that I don't accidentally remove trips.

### 3.5 Block Management

**US-SCHED-039: View block list**
As a schedule editor, I want to view all blocks defined for the agency, so that I can manage vehicle assignments.

**US-SCHED-040: Create block**
As a schedule editor, I want to create a new block with a label and color, so that I can define a new vehicle assignment.

**US-SCHED-041: Edit block label**
As a schedule editor, I want to edit a block's label, so that I can rename blocks for clarity.

**US-SCHED-042: Edit block color**
As a schedule editor, I want to change a block's color, so that I can improve visual distinction in schedule views.

**US-SCHED-043: View block usage**
As a schedule editor, I want to view all trips assigned to a block organized by route, so that I can understand block utilization.

**US-SCHED-044: Delete unused block**
As a schedule editor, I want to delete a block that has no trips assigned, so that I can remove obsolete blocks.

**US-SCHED-045: Prevent deletion of used block**
As a schedule editor, I want the system to prevent deletion of blocks with assigned trips, so that I don't accidentally orphan trip-block relationships.

### 3.6 Block Schedule View

**US-SCHED-046: Access block schedules**
As a schedule editor, I want to navigate to a block schedules view, so that I can visualize blocks across routes.

**US-SCHED-047: Select block for schedule view**
As a schedule editor, I want to select a block to view its complete schedule, so that I can validate vehicle assignments.

**US-SCHED-048: View block timeline**
As a schedule editor, I want to see a block's trips displayed in timeline format, so that I can visualize the vehicle's daily work.

**US-SCHED-049: View block timetable**
As a schedule editor, I want to see a block's trips displayed in timetable format, so that I can review exact timing details.

**US-SCHED-050: Filter block schedule by date**
As a schedule editor, I want to filter the block schedule to a specific date, so that I can see exactly which trips operate that day.

**US-SCHED-051: Filter block schedule by calendar**
As a schedule editor, I want to filter the block schedule by calendar, so that I can focus on specific service periods.

**US-SCHED-052: Combine calendars in block view**
As a schedule editor, I want to optionally combine multiple calendars in the block view, so that I can see comprehensive utilization.

**US-SCHED-053: Combine day groups in block view**
As a schedule editor, I want to optionally combine service days in the block view, so that I can see all trips regardless of day.

**US-SCHED-054: Filter block schedule by direction**
As a schedule editor, I want to filter the block schedule by direction, so that I can focus on specific travel directions.

**US-SCHED-055: Select routes in block view**
As a schedule editor, I want to select which routes to include in the block schedule view, so that I can focus on specific interline combinations.

**US-SCHED-056: View trip details from block schedule**
As a schedule editor, I want to click on a trip in the block schedule to view its details, so that I can review individual trip information.

### 3.7 Overlapping Block Detection

**US-SCHED-057: View blocks with overlaps**
As a schedule editor, I want to see blocks with overlapping trips highlighted in the block list, so that I can identify validation errors.

**US-SCHED-058: View overlap dates**
As a schedule editor, I want to see which dates have overlapping trips for a block, so that I can understand when the conflict occurs.

**US-SCHED-059: View overlapping trips**
As a schedule editor, I want to see overlapping trips highlighted in the block schedule, so that I can identify the specific conflict.

**US-SCHED-060: Navigate to overlapping trip**
As a schedule editor, I want to navigate from an overlapping trip to the route editor, so that I can fix the overlap in context.

---

## 4. Acceptance Criteria

### 4.1 Schedule View Navigation

**AC-SCHED-001: Schedule view displays trip data**
- Given I navigate to a route's Schedules section
- When the schedule loads
- Then I see trips organized by calendar, service day, and pattern
- And each trip displays its start time, end time, and block assignment (if any)

**AC-SCHED-002: Timeline view displays trips as bars**
- Given I am viewing the schedule in timeline mode
- Then trips display as horizontal bars positioned at their start times
- And bar length corresponds to trip duration
- And bar color corresponds to block assignment

**AC-SCHED-003: Timetable view displays trips in grid**
- Given I am viewing the schedule in timetable mode
- Then stops display as rows and trips display as columns
- And each cell shows the departure time for that stop
- And trips are sorted by start time

**AC-SCHED-004: Calendar filter works**
- Given I am viewing a route's schedule
- When I select a specific calendar from the filter
- Then only trips on that calendar are displayed
- And selecting "Show All Calendars" displays all trips

**AC-SCHED-005: Block filter works**
- Given I am viewing a route's schedule
- When I select a specific block from the filter
- Then only trips assigned to that block are displayed

**AC-SCHED-006: Direction filter works**
- Given I am viewing a route's schedule
- When I select a specific direction from the filter
- Then only trips with that direction_id are displayed

**AC-SCHED-007: Timeline sort by pattern**
- Given I am viewing the timeline
- When I select "Sort by Pattern"
- Then trips group by stop pattern, then timed pattern, then start time

**AC-SCHED-008: Timeline sort by start time**
- Given I am viewing the timeline
- When I select "Sort by Start Time Only"
- Then trips display in chronological order regardless of pattern

**AC-SCHED-009: Timeline sort by block**
- Given I am viewing the timeline
- When I select "Sort by Block"
- Then trips group by block, then by start time within each block

**AC-SCHED-010: Timetable timepoint toggle**
- Given I am viewing the timetable
- When I toggle "Timepoints Only"
- Then only rows for timepoint stops are displayed
- And toggling off shows all stops

### 4.2 Trip Creation

**AC-SCHED-011: Create trip via Add Trip button**
- Given I am viewing a route's schedule
- When I click the "Add a Trip" button
- Then a trip creation form opens with no pre-populated values
- And all required fields are empty

**AC-SCHED-012: Create trip via timeline click**
- Given I am viewing the timeline
- When I hover over a time position and click the "Add Trip" button
- Then a trip creation form opens
- And the start time is pre-populated with the clicked time
- And the calendar and service days are pre-populated from the context

**AC-SCHED-013: Create trip via timetable insertion**
- Given I am viewing the timetable
- When I click the "+" icon between two trips
- Then a trip creation form opens
- And all values are copied from the preceding trip
- And start time is copied (requiring manual adjustment)

**AC-SCHED-014: Trip requires start time**
- Given I am creating or editing a trip
- When I attempt to save without a start time
- Then a validation error is displayed
- And the trip is not saved

**AC-SCHED-015: Trip requires calendar**
- Given I am creating or editing a trip
- When I attempt to save without selecting a calendar
- Then a validation error is displayed
- And the trip is not saved

**AC-SCHED-016: Trip requires service days**
- Given I am creating or editing a trip on a standard calendar
- When I attempt to save without selecting at least one service day
- Then a validation error is displayed
- And the trip is not saved

**AC-SCHED-017: Trip requires stop pattern**
- Given I am creating or editing a trip
- When I attempt to save without selecting a stop pattern
- Then a validation error is displayed
- And the trip is not saved

**AC-SCHED-018: Trip requires timed pattern**
- Given I am creating or editing a trip
- When I attempt to save without selecting a timed pattern
- Then a validation error is displayed
- And the trip is not saved

**AC-SCHED-019: Repeated trips creation**
- Given I am creating a trip
- When I enable "Repeats with regular headways"
- And I specify an end time and headway interval
- And I save
- Then multiple trips are created from start time to end time at the specified headway
- And all trips share the same calendar, pattern, and service days

**AC-SCHED-020: Trip save success**
- Given I have completed all required trip fields
- When I click Save
- Then the trip is persisted
- And a success confirmation is displayed
- And the trip appears in the schedule view

### 4.3 Trip Editing

**AC-SCHED-021: Select trip from timeline**
- Given I am viewing the timeline
- When I click on a trip bar
- Then the trip details panel opens for that trip

**AC-SCHED-022: Select trip from timetable**
- Given I am viewing the timetable
- When I click on a trip's column header or times
- Then the trip details panel opens for that trip

**AC-SCHED-023: Edit trip start time**
- Given I am editing a trip
- When I change the start time
- And I save
- Then the start time is updated
- And all stop times shift accordingly based on the timed pattern

**AC-SCHED-024: Edit trip calendar**
- Given I am editing a trip
- When I select a different calendar
- And I save
- Then the trip is associated with the new calendar

**AC-SCHED-025: Block dropdown shows available blocks**
- Given I am editing a trip
- When I view the Block dropdown
- Then all defined blocks are available for selection
- And an option for no block is available

**AC-SCHED-026: Assign block to trip**
- Given I am editing a trip
- When I select a block from the dropdown
- And I save
- Then the trip is assigned to that block
- And the trip displays with the block's color in schedule views

**AC-SCHED-027: Remove block from trip**
- Given I am editing a trip that has a block assigned
- When I select the no-block option
- And I save
- Then the block assignment is removed from the trip

**AC-SCHED-028: Unsaved changes warning**
- Given I have unsaved changes to a trip
- When I attempt to navigate away
- Then a warning is displayed about unsaved changes
- And I can choose to save, discard, or cancel navigation

### 4.4 Trip Deletion

**AC-SCHED-029: Delete trip from details**
- Given I am viewing a trip's details
- When I click "Delete Trip"
- Then a confirmation dialog appears

**AC-SCHED-030: Confirm trip deletion**
- Given I am viewing the deletion confirmation dialog
- When I confirm the deletion
- Then the trip is permanently removed
- And it no longer appears in schedule views

**AC-SCHED-031: Cancel trip deletion**
- Given I am viewing the deletion confirmation dialog
- When I cancel the deletion
- Then the trip is not deleted
- And I return to the trip details

### 4.5 Block Management

**AC-SCHED-032: View block list**
- Given I navigate to the Blocks section
- Then I see a list of all defined blocks
- And each block displays its label and color

**AC-SCHED-033: Create new block**
- Given I am in the Blocks section
- When I click "Add a Block"
- And I enter a label and select a color
- And I save
- Then a new block is created
- And it appears in the block list and block dropdowns

**AC-SCHED-034: Edit block label**
- Given I am viewing a block's details
- When I change the block label
- And I save
- Then the label is updated throughout the system

**AC-SCHED-035: Edit block color**
- Given I am viewing a block's details
- When I change the block color
- And I save
- Then the color is updated in all schedule views

**AC-SCHED-036: View block usage**
- Given I am viewing a block's details
- Then I see a list of all trips assigned to this block
- And trips are organized by route

**AC-SCHED-037: Delete unused block**
- Given I am viewing a block with no trips assigned
- When I click delete (the red "X")
- And I confirm
- Then the block is removed from the system

**AC-SCHED-038: Cannot delete block in use**
- Given I am viewing a block with trips assigned
- When I attempt to delete the block
- Then an error message indicates the block is in use
- And the block is not deleted

**AC-SCHED-039: Block deletion removes from trips**
- Given I delete a block that was previously assigned to trips
- Then the block_id is cleared from those trips
- And the trips themselves are not deleted

### 4.6 Block Schedule View

**AC-SCHED-040: Navigate to block schedules**
- Given I am in the Blocks section
- When I click "Block Schedules"
- Then I see a list of all blocks
- And blocks with overlaps are highlighted

**AC-SCHED-041: Select block for schedule view**
- Given I am in block schedules
- When I select a block
- Then I see filter options and the block's schedule

**AC-SCHED-042: Block schedule timeline view**
- Given I am viewing a block's schedule
- Then trips display in timeline format
- And trips are color-coded by route (overriding block color)

**AC-SCHED-043: Block schedule timetable view**
- Given I am viewing a block's schedule
- When I switch to timetable view
- Then trips display in timetable format with stops as rows

**AC-SCHED-044: Filter block schedule by date**
- Given I am viewing a block's schedule
- When I select a specific date
- Then only trips operating on that date are displayed

**AC-SCHED-045: Filter block schedule by calendar**
- Given I am viewing a block's schedule
- When I select specific calendars
- Then only trips on those calendars are displayed

**AC-SCHED-046: Combine calendars in block view**
- Given I am viewing a block's schedule
- When I enable "Combine Calendars"
- Then trips from all selected calendars appear in a single view
- And a warning indicates this may not reflect a single run

**AC-SCHED-047: Combine day groups in block view**
- Given I am viewing a block's schedule
- When I enable "Combine Day Groups"
- Then trips from all service days appear in a single view

**AC-SCHED-048: Filter block schedule by direction**
- Given I am viewing a block's schedule
- When I select a direction filter
- Then only trips with that direction are displayed

**AC-SCHED-049: Select routes in block view**
- Given I am viewing a block's schedule with interlining
- When I select specific routes
- Then only trips on those routes are displayed

**AC-SCHED-050: Trip selection in block schedule**
- Given I am viewing a block's schedule
- When I click on a trip
- Then the trip's details are displayed
- And a link to "Edit Trip in Route Editor" is available

### 4.7 Overlapping Block Detection

**AC-SCHED-051: Overlapping blocks highlighted**
- Given there are blocks with overlapping trips
- When I view the block schedules list
- Then blocks with overlaps are visually highlighted

**AC-SCHED-052: Overlap dates displayed**
- Given I select a block with overlaps
- Then I see a list of upcoming dates where overlaps occur

**AC-SCHED-053: Overlapping trips highlighted in timeline**
- Given I am viewing a block schedule with overlaps
- Then overlapping trip segments are highlighted in red

**AC-SCHED-054: Navigate to edit overlapping trip**
- Given I am viewing an overlapping trip in block schedule
- When I click "Edit Trip in Route Editor"
- Then I navigate to that trip's edit view in the route context

### 4.8 Trip Optional Fields

**AC-SCHED-055: Set trip headsign**
- Given I am editing a trip
- When I enter a headsign value
- And I save
- Then the trip_headsign is stored and exported

**AC-SCHED-056: Set trip short name**
- Given I am editing a trip
- When I enter a trip short name
- And I save
- Then the trip_short_name is stored and exported

**AC-SCHED-057: Set trip direction**
- Given I am editing a trip
- When I select a direction (0 or 1)
- And I save
- Then the direction_id is stored and exported

**AC-SCHED-058: Set wheelchair accessibility**
- Given I am editing a trip
- When I set wheelchair accessibility to Accessible, Not Accessible, or No Info
- And I save
- Then the wheelchair_accessible value is stored and exported

**AC-SCHED-059: Set bikes allowed**
- Given I am editing a trip
- When I set bikes allowed to Yes, No, or No Info
- And I save
- Then the bikes_allowed value is stored and exported

**AC-SCHED-060: Enable in-seat transfers**
- Given I am editing a trip with a block assigned
- When I check "In-seat transfers allowed"
- And I save
- Then the trip is configured to allow in-seat transfers

### 4.9 Integration Points

**AC-SCHED-061: Trips reference valid calendars**
- Given I am creating or editing a trip
- When I select a calendar
- Then only valid calendars from the Calendar Dashboard are available

**AC-SCHED-062: Trips reference valid patterns**
- Given I am creating or editing a trip
- When I select a stop pattern
- Then only patterns defined for this route are available
- And selecting a pattern updates available timed patterns

**AC-SCHED-063: GTFS export includes trips**
- Given I have saved trips in the schedule
- When I export GTFS
- Then trips.txt contains all trips with required fields populated
- And stop_times.txt contains timing records for each trip

**AC-SCHED-064: Block export includes block_id**
- Given trips have block assignments
- When I export GTFS
- Then trips.txt includes block_id for assigned trips

---

## 5. Non-Functional Requirements

### 5.1 Performance

- Schedule view must load within 2 seconds for routes with up to 500 trips
- Timeline rendering must update within 500ms when filters change
- Timetable rendering must handle routes with up to 100 stops and 200 trips
- Block schedule view must load within 3 seconds for blocks with up to 100 trips across 10 routes

### 5.2 Usability

- Timeline view must support zoom and pan for navigating large schedules
- Trip bars must display start and end times on hover
- Block colors must maintain adequate contrast for visibility
- Keyboard shortcuts should support common operations (save, navigate between trips)
- Delete operations must require confirmation to prevent accidental data loss

### 5.3 Data Integrity

- Trip deletion must be confirmed before execution
- Block deletion must validate no trips are assigned
- Overlapping blocks must be detected and flagged, not prevented
- Service day selection must enforce at least one day for standard calendars
- Pattern changes must validate timed pattern compatibility with stop pattern

### 5.4 Accessibility

- All form fields must have associated labels
- Color-coding must not be the sole indicator of block assignment (use labels/icons)
- Timeline must support keyboard navigation between trips
- Screen readers must announce trip details when selected

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** Schedule views prioritize data visibility. Trip bars display essential timing information without decorative elements. Timetables use minimal grid lines. Block colors serve functional purposes (identification), not decoration.

**Grid System:** Timeline view uses a strict time-based grid. Timetable view uses consistent column widths and row heights. Filter panels align to the overall page grid.

**Typography:** Use system sans-serif fonts. Times display in consistent format (HH:MM). Trip labels use standard weight; headers use bold for hierarchy.

**Color for Information:** Block colors encode vehicle assignments. Route colors differentiate interlined trips. Overlap highlighting uses red to indicate errors. Avoid color-only encoding; pair with icons or text.

**Plain Language:** Use "Trip" not "Run" in UI (unless agency-specific terminology is configured). Label filters clearly: "Calendar," "Block," "Direction." Error messages state the problem and suggest resolution.

**Input Efficiency:** Pre-populate fields when context is available. Support click-to-create in timeline view. Auto-advance to next field after time entry. Provide keyboard shortcuts for power users.

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Schedule management belongs to a `Schedules` context that encapsulates trip and block business logic. The context owns `Trip`, `Block`, and related schemas. Route and pattern references come from the `Routes` and `Patterns` contexts.

**Data Validation:** Use Ecto changesets with explicit validations. Return tagged tuples (`{:ok, trip}` or `{:error, changeset}`) from context functions. Validate block overlap at the context level, returning warnings rather than blocking saves.

**LiveView Architecture:** Schedule views implement as LiveView. Use streams for trip lists to handle large schedules efficiently. Timeline and timetable views are function components receiving trip data as props. Block schedule view is a separate LiveView with its own state.

**Real-Time Updates:** Use Phoenix PubSub to broadcast trip and block changes. Multiple users editing the same route's schedule see updates without manual refresh. Broadcast overlap status changes when trips are modified.

**Testing Strategy:**
- Context tests validate business rules (required fields, block overlap detection, service day requirements)
- LiveView tests verify user flows (create trip from timeline, assign block, delete trip)
- Integration tests confirm GTFS export produces valid trips.txt and stop_times.txt
- Focus on behavior over implementation

**Overlap Detection Algorithm:** Implement overlap detection as a pure function that takes a list of trips with the same block_id and returns pairs of overlapping trips with conflict dates. Run on save and on block schedule view load. Cache results per block for performance.
