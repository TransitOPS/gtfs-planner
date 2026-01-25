# Patterns and Alignments Requirements Document

**Section:** Patterns and Alignments  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Patterns and Alignments section manages data that spans multiple GTFS files: `trips.txt`, `stop_times.txt`, and `shapes.txt`. This section provides the abstraction layer that connects routes to their operational variations, timing sequences, and geographic representations.

### 1.1 Conceptual Model

Patterns represent the bridge between abstract route definitions and concrete trip schedules:

```
Route
├── Stop Pattern (ordered sequence of stops + direction)
│   ├── Timed Pattern (timing between stops)
│   │   └── Trips (scheduled instances)
│   └── Alignments (geographic path between consecutive stops)
```

**Stop Patterns** define unique orderings of stops for a route, capturing service variations such as direction, abbreviated runs, extended service, or route deviations.

**Timed Patterns** define the travel time between stops within a stop pattern, enabling multiple timing variations (peak vs. off-peak, express vs. local) to share a common stop sequence.

**Alignments** define the geographic path a vehicle travels between consecutive stops, exported as shape points in `shapes.txt`.

### 1.2 Core GTFS Fields

#### trips.txt (Generated from Patterns + Trips)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Unique ID | Required | Unique identifier for the trip. |
| `route_id` | Foreign ID | Required | References the route this trip belongs to. |
| `service_id` | Foreign ID | Required | References the calendar defining when this trip runs. |
| `trip_headsign` | Text | Optional | Destination text displayed on vehicle signage. Can be set at stop pattern level or overridden per timed pattern. |
| `direction_id` | Enum | Optional | Indicates travel direction (0 or 1). Derived from stop pattern direction. |
| `shape_id` | Foreign ID | Conditionally Required | References the shape describing the vehicle's geographic path. Generated from alignments. |

#### stop_times.txt (Generated from Timed Patterns + Trips)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Foreign ID | Required | References the trip. |
| `stop_id` | Foreign ID | Required | References the stop. Sequence derived from stop pattern. |
| `stop_sequence` | Non-negative Integer | Required | Order of stops for the trip. Generated from stop pattern stop order. |
| `arrival_time` | Time | Conditionally Required | Arrival time at stop. Calculated from timed pattern timing plus trip start time. |
| `departure_time` | Time | Conditionally Required | Departure time from stop. Defaults to arrival_time unless dwell time specified. |
| `pickup_type` | Enum | Optional | Pickup availability: 0=Regular, 1=None, 2=Phone agency, 3=Coordinate with driver. |
| `drop_off_type` | Enum | Optional | Drop-off availability. Same values as pickup_type. |
| `timepoint` | Enum | Optional | Indicates if times are exact (1) or approximate/interpolated (0). |
| `shape_dist_traveled` | Non-negative Float | Optional | Distance traveled along shape to this stop. Calculated from alignments. |

#### shapes.txt (Generated from Alignments)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `shape_id` | ID | Required | Unique identifier for the shape. Generated per unique alignment sequence. |
| `shape_pt_lat` | Latitude | Required | Latitude of shape point. |
| `shape_pt_lon` | Longitude | Required | Longitude of shape point. |
| `shape_pt_sequence` | Non-negative Integer | Required | Order of points in the shape. |
| `shape_dist_traveled` | Non-negative Float | Optional | Distance from first shape point. Enables accurate rendering of loops. |

### 1.3 Operational Implications

#### Trip Planning Accuracy
Stop patterns determine which stops appear in trip planner results for a given route. Incomplete or incorrect stop patterns cause riders to miss connections or receive invalid directions. Stop sequence must match physical vehicle travel order.

#### Schedule Integrity
Timed patterns define the temporal relationship between stops. Errors cascade to all trips using that timed pattern. A single timing mistake can affect dozens of scheduled trips, creating confusion for riders and operators.

#### Timepoint Handling
Timepoints identify stops where vehicles are scheduled to hold if running early. Agencies use timepoints differently; some mark major stops as timepoints while others mark all scheduled stop times. Timepoints also determine which stop times appear in public timetables and can drive interpolated time calculation for intermediate stops.

#### Interpolated Times
When enabled, the system calculates estimated arrival times for non-timepoint stops based on distance or proportional travel time between timepoints. This reduces data entry burden and improves rider information quality, but requires accurate alignment data for distance-based interpolation.

#### Shape Data Quality
Alignments export as shapes that display in Google Maps, Apple Maps, and other consumer applications. Poorly drawn alignments make routes appear to travel through buildings, cross water incorrectly, or take impossible paths. Shape quality directly affects transit agency credibility.

#### Alignment Reuse
Alignments between two stops in sequence are shared across all stop patterns using that stop pair. This reduces maintenance burden but requires custom override capability for cases where different patterns follow different physical paths between the same stops.

#### Schedule Change Workflow
Modifying patterns affects all associated trips. The system must support schedule change workflows where future patterns can be created and modified without affecting currently active service. Timed pattern copying enables creating variations for new schedules.

#### Pickup/Drop-off Restrictions
Stop-level pickup and drop-off settings enable modeling of express service (no intermediate pickups), last-run-of-day restrictions (drop-off only), flag stops, and call-ahead service. These settings override route-level defaults and appear in `stop_times.txt`.

#### Data Consumer Compatibility
Pattern data flows to multiple downstream systems. Google Maps has specific requirements for direction_id usage. Real-time systems require consistent trip_id patterns. Some agencies export stop codes as stop_ids, requiring coordination between pattern and stop data.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Stop Pattern Management

**JS-PAT-001: Creating stop patterns from existing service**
When I am documenting an existing route with multiple service variations, I want to create stop patterns that match each unique stop sequence, so I can accurately represent how the route actually operates.

**JS-PAT-002: Creating directional stop patterns**
When a route operates in two directions with different stop sequences, I want to create separate stop patterns for each direction, so I can assign appropriate headsigns and distinguish inbound from outbound trips.

**JS-PAT-003: Creating abbreviated service patterns**
When the last run of the day serves fewer stops, I want to create a stop pattern that excludes the final stops, so I can schedule a trip that accurately reflects the shortened service.

**JS-PAT-004: Creating extended service patterns**
When the first morning run picks up at an additional location (such as a train station), I want to create a stop pattern with the extra stop, so I can schedule early trips that serve commuter connections.

**JS-PAT-005: Creating deviated service patterns**
When certain trips deviate to serve a school or employer, I want to create a stop pattern that includes the deviation stops, so I can schedule trips that show the complete routing.

**JS-PAT-006: Copying patterns for schedule changes**
When preparing a schedule change, I want to copy an existing stop pattern, so I can modify it for future service without affecting currently running trips.

**JS-PAT-007: Comparing stop patterns visually**
When I am unsure which stop pattern matches a particular service variation, I want to see a side-by-side comparison of all stop patterns for a route, so I can identify the correct pattern by its stop sequence.

### 2.2 Timed Pattern Management

**JS-PAT-008: Creating initial timed patterns**
When a stop pattern has no timing defined, I want to create a timed pattern with arrival times at each stop, so I can begin scheduling trips on this pattern.

**JS-PAT-009: Creating peak and off-peak timing variations**
When service runs faster during off-peak hours, I want to create separate timed patterns for peak and off-peak periods, so I can accurately represent different running times throughout the day.

**JS-PAT-010: Setting timepoints for timetable display**
When building a public timetable, I want to mark specific stops as timepoints, so I can control which columns appear in printed and web timetables.

**JS-PAT-011: Using timepoints for interpolation**
When I only know timing at major stops, I want to set those stops as timepoints and enable interpolation, so I can automatically generate estimated times for intermediate stops.

**JS-PAT-012: Adding dwell time at transfer points**
When a bus holds at a transit center to allow connections, I want to specify a departure time that differs from arrival time, so I can represent the scheduled dwell.

**JS-PAT-013: Previewing timed pattern with offset**
When creating a timed pattern before associating it with trips, I want to preview stop times using a sample start time, so I can verify the timing looks correct before saving.

**JS-PAT-014: Configuring pickup and drop-off restrictions**
When express service skips intermediate stops for boarding, I want to set those stops to "no pickup" within the timed pattern, so I can trip planners exclude them as boarding options.

### 2.3 Alignment Management

**JS-PAT-015: Auto-generating alignments**
When I add a stop to a pattern, I want to automatically generate the alignment using street routing, so I can quickly create accurate shapes without manual drawing.

**JS-PAT-016: Editing auto-generated alignments**
When the auto-generated path follows an incorrect street, I want to manually adjust segment points, so I can correct the alignment to match actual vehicle travel.

**JS-PAT-017: Creating all missing alignments**
When importing a pattern with many new segments, I want to auto-generate all missing alignments at once, so I can quickly complete the shape without editing each segment individually.

**JS-PAT-018: Creating custom alignments for specific patterns**
When an express route follows a different path than local service between the same stops, I want to create a custom alignment that applies only to the express pattern, so I can have accurate shapes for both services.

**JS-PAT-019: Simplifying complex alignments**
When an alignment has excessive shape points (causing file size or rendering issues), I want to simplify the alignment while preserving the general path, so I can optimize the exported shape data.

**JS-PAT-020: Viewing alignment status**
When reviewing a stop pattern, I want to immediately see which segments have alignments (green), need alignments (red), or have unsaved changes (yellow), so I can prioritize my editing work.

### 2.4 Headsign Management

**JS-PAT-021: Setting pattern-level headsigns**
When all trips on a stop pattern display the same destination, I want to set the headsign at the pattern level, so I can avoid repetitive entry on each timed pattern.

**JS-PAT-022: Setting headsign changes mid-trip**
When a loop route changes its displayed destination partway through, I want to specify headsign changes at specific stops within the timed pattern, so I can model mid-trip sign changes.

**JS-PAT-023: Overriding headsigns for specific timed patterns**
When the last run displays "Drop Off Only," I want to set a different headsign on that timed pattern, so I can communicate the service restriction to riders.

### 2.5 Loop Route Handling

**JS-PAT-024: Creating loop patterns**
When a route follows a circular path returning to its origin, I want to create a stop pattern that starts and ends at the same stop, so I can accurately model loop service.

**JS-PAT-025: Including stops served multiple times**
When a loop route passes a stop twice, I want to add the same stop at multiple positions in the sequence, so I can represent both service opportunities.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Stop Pattern Inventory

**US-PAT-001: View stop pattern list**
As a schedule editor, I want to view all stop patterns for a route in a sortable list, so that I can quickly find patterns by direction, name, or stop count.

**US-PAT-002: Filter stop patterns**
As a schedule editor, I want to filter stop patterns by direction, so that I can focus on patterns traveling in a specific direction.

**US-PAT-003: Compare stop patterns**
As a schedule editor, I want to see a visual comparison of all stop patterns showing which stops each pattern serves, so that I can understand the differences between service variations.

**US-PAT-004: Search for patterns by stop**
As a schedule editor, I want to search for patterns that include a specific stop, so that I can find all patterns affected when a stop changes.

### 3.2 Stop Pattern Creation

**US-PAT-005: Create new stop pattern**
As a schedule editor, I want to create a new stop pattern by naming it and assigning a direction, so that I can define a new service variation.

**US-PAT-006: Copy existing stop pattern**
As a schedule editor, I want to copy an existing stop pattern including its timed patterns, so that I can create variations without re-entering all timing data.

**US-PAT-007: Add stops via map**
As a schedule editor, I want to add stops to a pattern by clicking on the map, so that I can build patterns visually using geographic context.

**US-PAT-008: Add stops via list**
As a schedule editor, I want to add stops to a pattern by searching and selecting from a list, so that I can quickly add stops when I know their names.

**US-PAT-009: Insert stop between existing stops**
As a schedule editor, I want to insert a stop between two existing stops in a pattern, so that I can add a new stop mid-route without rebuilding the sequence.

**US-PAT-010: Reorder stops via drag-and-drop**
As a schedule editor, I want to reorder stops in a pattern by dragging them, so that I can correct sequence errors efficiently.

**US-PAT-011: Remove stop from pattern**
As a schedule editor, I want to remove a stop from a pattern, so that I can model service that skips certain stops.

### 3.3 Stop Pattern Editing

**US-PAT-012: Rename stop pattern**
As a schedule editor, I want to rename a stop pattern, so that I can use meaningful labels that match internal documentation.

**US-PAT-013: Change stop pattern direction**
As a schedule editor, I want to change a stop pattern's direction assignment, so that I can correct direction errors.

**US-PAT-014: Set pattern-level headsign**
As a schedule editor, I want to set a headsign that applies to all trips on a stop pattern, so that I can define the displayed destination once.

**US-PAT-015: View stops in pattern**
As a schedule editor, I want to view the ordered list of stops in a pattern with sequence numbers, so that I can verify the stop order is correct.

### 3.4 Stop Pattern Deletion

**US-PAT-016: Delete stop pattern**
As a schedule editor, I want to delete a stop pattern that is no longer needed, so that I can keep the pattern list clean and relevant.

**US-PAT-017: View pattern usage before deletion**
As a schedule editor, I want to see which timed patterns and trips use a stop pattern before deleting it, so that I can understand the impact of deletion.

### 3.5 Timed Pattern Creation

**US-PAT-018: Create new timed pattern**
As a schedule editor, I want to create a new timed pattern for a stop pattern, so that I can define timing for trips using this stop sequence.

**US-PAT-019: Name timed pattern descriptively**
As a schedule editor, I want to name a timed pattern by duration, time of day, or trip reference, so that I can identify it when scheduling trips.

**US-PAT-020: Enter arrival times**
As a schedule editor, I want to enter arrival times at each stop relative to trip start, so that I can define the travel time between stops.

**US-PAT-021: Enter departure times**
As a schedule editor, I want to optionally enter departure times that differ from arrival times, so that I can model scheduled dwell time.

### 3.6 Timed Pattern Editing

**US-PAT-022: Edit timed pattern timing**
As a schedule editor, I want to modify arrival and departure times in a timed pattern, so that I can adjust timing without creating a new pattern.

**US-PAT-023: Set timepoints**
As a schedule editor, I want to toggle timepoint status on individual stops within a timed pattern, so that I can control timetable display and interpolation behavior.

**US-PAT-024: Set pickup/drop-off restrictions**
As a schedule editor, I want to set pickup and drop-off restrictions on individual stops within a timed pattern, so that I can model express or limited service.

**US-PAT-025: Set timed pattern headsign**
As a schedule editor, I want to set a headsign on a specific timed pattern that overrides the pattern-level headsign, so that I can model headsign variations.

**US-PAT-026: Set mid-trip headsign changes**
As a schedule editor, I want to specify that the headsign changes at a particular stop, so that I can model routes where the displayed destination changes en route.

**US-PAT-027: Preview timed pattern with offset**
As a schedule editor, I want to preview stop times using a sample start time offset, so that I can see realistic times before associating trips.

### 3.7 Timed Pattern Deletion

**US-PAT-028: Delete timed pattern**
As a schedule editor, I want to delete a timed pattern that is no longer needed, so that I can keep the timed pattern list manageable.

**US-PAT-029: View timed pattern usage before deletion**
As a schedule editor, I want to see which trips use a timed pattern before deleting it, so that I understand the deletion impact.

### 3.8 Alignment Creation

**US-PAT-030: Auto-generate single alignment**
As a schedule editor, I want to auto-generate an alignment between two consecutive stops, so that I can quickly create accurate shape data.

**US-PAT-031: Auto-generate all missing alignments**
As a schedule editor, I want to auto-generate all missing alignments for a stop pattern at once, so that I can complete shapes efficiently.

**US-PAT-032: Manually draw alignment**
As a schedule editor, I want to manually place points along the path between stops, so that I can create alignments where auto-generation fails.

### 3.9 Alignment Editing

**US-PAT-033: View alignment on map**
As a schedule editor, I want to view alignments overlaid on a map with the route color, so that I can verify the path matches actual vehicle travel.

**US-PAT-034: Add segment points**
As a schedule editor, I want to add intermediate points to an alignment, so that I can refine the path to follow the actual roadway.

**US-PAT-035: Move segment points**
As a schedule editor, I want to drag segment points to new positions, so that I can adjust the alignment path.

**US-PAT-036: Delete segment points**
As a schedule editor, I want to delete individual segment points, so that I can simplify an alignment or remove incorrect points.

**US-PAT-037: Multi-select segment points**
As a schedule editor, I want to select multiple segment points at once, so that I can delete or regenerate a portion of an alignment.

**US-PAT-038: Simplify alignment**
As a schedule editor, I want to reduce the number of points in an alignment while preserving its shape, so that I can optimize shape file size.

**US-PAT-039: Clear segment points**
As a schedule editor, I want to remove all points from an alignment segment without deleting the alignment, so that I can start fresh.

**US-PAT-040: Delete alignment**
As a schedule editor, I want to delete an alignment entirely, so that I can remove an incorrect alignment and create a new one.

### 3.10 Custom Alignments

**US-PAT-041: Create pattern-specific alignment**
As a schedule editor, I want to create a custom alignment that applies only to a specific stop pattern, so that I can have different paths for different services between the same stops.

**US-PAT-042: Designate system-wide alignment**
As a schedule editor, I want to designate an alignment as system-wide, so that it becomes the default for all patterns using those stops in sequence.

### 3.11 Interpolated Times

**US-PAT-043: Enable interpolated times**
As an agency administrator, I want to enable interpolated times for my agency, so that estimated arrival times are automatically calculated for non-timepoint stops.

**US-PAT-044: View interpolated times on export**
As a schedule editor, I want to understand that interpolated times appear only in the GTFS export (not in the editing interface), so that I have accurate expectations about the data.

---

## 4. Acceptance Criteria

### 4.1 Stop Pattern List

**AC-PAT-001: Display stop pattern list**
- Given I navigate to a route's patterns tab
- Then I see a list of all stop patterns for that route
- And each row displays the pattern label, direction, and stop count

**AC-PAT-002: Sort stop patterns**
- Given I am viewing the stop pattern list
- When I click a column header (Label, Direction, Stop Count)
- Then the list sorts by that column
- And clicking again reverses the sort order

**AC-PAT-003: Filter by direction**
- Given I am viewing the stop pattern list
- When I select a direction filter
- Then only patterns with that direction are displayed

**AC-PAT-004: Compare patterns view**
- Given I click "Compare Patterns"
- Then I see a matrix showing all patterns grouped by direction
- And each pattern's stops are displayed in sequence
- And I can visually identify which stops differ between patterns

### 4.2 Stop Pattern Creation

**AC-PAT-005: Create new stop pattern**
- Given I am on the patterns list
- When I click "New Pattern"
- And I enter a label and select a direction
- And I click Save
- Then a new empty stop pattern is created
- And I am navigated to the pattern editor

**AC-PAT-006: Copy stop pattern**
- Given I am viewing a stop pattern
- When I click "Copy Pattern"
- Then a new pattern is created with the same stops, alignments, and timed patterns
- And the new pattern label includes "Copy"
- And a duplicate pattern warning is displayed until modifications are made

**AC-PAT-007: Add stop from map**
- Given I am editing a stop pattern in map view
- And I am in stop order edit mode
- When I drag the dashed line between stops onto a stop marker
- Then that stop is inserted into the sequence at that position
- And the row is highlighted to indicate unsaved changes

**AC-PAT-008: Add stop from list**
- Given I am editing a stop pattern in list view
- When I click the insert button between two stops
- And I search for a stop by name
- And I select the stop
- Then the stop is inserted at that position
- And the row is highlighted to indicate unsaved changes

**AC-PAT-009: Remove stop from pattern**
- Given I am editing a stop pattern
- When I click the remove button next to a stop
- Then the stop is removed from the sequence
- And the change is highlighted as unsaved

**AC-PAT-010: Reorder stops**
- Given I am editing a stop pattern in list view
- When I drag a stop row to a new position
- Then the stop sequence updates to reflect the new order

**AC-PAT-011: Save stop pattern changes**
- Given I have made changes to a stop pattern
- When I click Save
- Then all changes are persisted
- And unsaved indicators are cleared

**AC-PAT-012: Undo stop pattern changes**
- Given I have made unsaved changes to a stop pattern
- When I click Undo
- Then the most recent change is reverted

### 4.3 Stop Pattern Editing

**AC-PAT-013: Rename stop pattern**
- Given I am viewing a stop pattern
- When I edit the label field
- And I save
- Then the pattern label is updated
- And the change is reflected in the patterns list

**AC-PAT-014: Set pattern headsign**
- Given I am viewing a stop pattern
- When I enter a headsign value at the pattern level
- And I save
- Then all trips using this pattern inherit this headsign
- Unless overridden at the timed pattern level

**AC-PAT-015: Change direction**
- Given I am viewing a stop pattern
- When I select a different direction from the dropdown
- And I save
- Then the pattern's direction is updated

### 4.4 Stop Pattern Deletion

**AC-PAT-016: Delete stop pattern with no trips**
- Given I am viewing a stop pattern with no associated trips
- When I click Delete
- And I confirm the deletion
- Then the stop pattern and all its timed patterns are deleted

**AC-PAT-017: Prevent deletion with active trips**
- Given I am viewing a stop pattern that has trips scheduled
- When I attempt to delete
- Then the system displays a message indicating trips must be removed first
- And the pattern is not deleted

**AC-PAT-018: View deletion impact**
- Given I click Delete on a stop pattern
- Then I see a summary of affected timed patterns and trips before confirming

### 4.5 Timed Pattern Creation

**AC-PAT-019: Create first timed pattern**
- Given I am viewing a stop pattern with no timed patterns
- When I click "Add Timed Pattern"
- And I enter a name
- Then a new timed pattern is created
- And all stops display with 00:00:00 default times

**AC-PAT-020: Create additional timed pattern**
- Given a stop pattern already has one or more timed patterns
- When I click the add button next to the timed patterns dropdown
- And I enter a name
- Then a new timed pattern is created for this stop pattern

**AC-PAT-021: Enter arrival times**
- Given I am editing a timed pattern
- When I enter an arrival time for a stop in HH:MM:SS or MM:SS format
- Then the time is saved relative to trip start (00:00:00)

**AC-PAT-022: Enter departure times**
- Given I am editing a timed pattern
- When I enter a departure time that differs from arrival time
- Then both arrival and departure times are stored
- And the departure time is included in GTFS export

### 4.6 Timed Pattern Editing

**AC-PAT-023: Edit timing values**
- Given I am viewing a timed pattern
- When I modify an arrival or departure time
- And I save
- Then the new timing is applied to all trips using this timed pattern

**AC-PAT-024: Set timepoint flag**
- Given I am editing a timed pattern
- When I toggle the timepoint checkbox on a stop
- Then the timepoint value is stored
- And it is included in the stop_times export

**AC-PAT-025: Set pickup restriction**
- Given I am editing a timed pattern
- When I set a stop's pickup type to "No Pickup"
- Then the pickup_type is stored
- And trip planners will not offer this stop for boarding on trips using this pattern

**AC-PAT-026: Set drop-off restriction**
- Given I am editing a timed pattern
- When I set a stop's drop-off type to "Coordinate with Driver"
- Then the drop_off_type is stored
- And the value appears in the GTFS export

**AC-PAT-027: Set timed pattern headsign**
- Given I am editing a timed pattern
- When I enter a headsign that differs from the stop pattern headsign
- Then trips using this timed pattern use this headsign

**AC-PAT-028: Set mid-trip headsign change**
- Given I am editing a timed pattern
- When I specify a headsign change at a particular stop
- Then the stop_headsign field is populated for that stop
- And the headsign change is reflected in trip planning results

**AC-PAT-029: Preview with offset**
- Given I am viewing a timed pattern
- When I enter an offset time (e.g., 14:00:00)
- Then all stop times display with the offset applied
- And I can verify realistic departure times

### 4.7 Timed Pattern Deletion

**AC-PAT-030: Delete timed pattern with no trips**
- Given I am viewing a timed pattern with no associated trips
- When I click Delete
- And I confirm
- Then the timed pattern is deleted

**AC-PAT-031: Prevent deletion with active trips**
- Given a timed pattern has scheduled trips
- When I attempt to delete it
- Then the system displays a message indicating trips must be removed first
- And the timed pattern is not deleted

### 4.8 Alignment Display

**AC-PAT-032: Display alignment status indicators**
- Given I am viewing a stop pattern in map view with alignments mode selected
- Then segments with saved alignments display in green
- And segments without alignments display in red
- And segments with unsaved changes display in yellow

**AC-PAT-033: Display alignment on map**
- Given I am viewing a stop pattern with alignments
- Then the alignment is drawn on the map following the path between stops
- And the alignment uses the route color

### 4.9 Alignment Creation

**AC-PAT-034: Auto-generate single alignment**
- Given I select a red (missing) segment between two stops
- When I click "Autogenerate"
- Then the system generates an alignment following the optimal street path
- And the segment turns yellow (unsaved)

**AC-PAT-035: Auto-generate all missing alignments**
- Given I click "Create Missing Alignments" from the menu
- Then all red segments are auto-generated
- And all newly generated segments turn yellow
- And I can save all changes at once

**AC-PAT-036: Manual alignment creation**
- Given I select a segment
- When I click along the map to add points
- Then segment points are added along the path
- And the alignment follows my placed points

**AC-PAT-037: Save alignment**
- Given I have created or edited an alignment
- When I click Save
- Then the alignment is persisted
- And the segment turns green

### 4.10 Alignment Editing

**AC-PAT-038: Add segment point**
- Given I am editing an alignment
- When I click on the alignment line
- Then a new segment point is added at that location
- And I can drag it to adjust the path

**AC-PAT-039: Move segment point**
- Given I am editing an alignment
- When I drag an existing segment point
- Then the point moves to the new location
- And the alignment path updates

**AC-PAT-040: Delete segment point**
- Given I have a segment point selected
- When I press Delete or Backspace
- Then the point is removed
- And the alignment path adjusts

**AC-PAT-041: Multi-select segment points**
- Given I hold Shift and drag a selection rectangle
- Then all segment points within the rectangle are selected
- And I can delete or regenerate them together

**AC-PAT-042: Simplify alignment**
- Given I have segment points selected
- When I click "Simplify"
- Then excess points are removed while preserving the general path shape

**AC-PAT-043: Clear segment points**
- Given I select a segment
- When I click "Clear Segment Points"
- Then all points between the two stops are removed
- And the segment shows as a direct line

**AC-PAT-044: Delete alignment**
- Given I select a segment
- When I click "Delete Segment"
- Then the alignment is removed
- And the segment displays red (missing)

### 4.11 Custom Alignments

**AC-PAT-045: Create custom override alignment**
- Given a system-wide alignment exists between two stops
- When I edit the alignment from a specific stop pattern
- And I save it as "Custom Override"
- Then this pattern uses the custom alignment
- And other patterns continue using the system-wide alignment

**AC-PAT-046: Set system-wide alignment**
- Given I have created an alignment
- When I designate it as "System-Wide"
- Then this alignment is used by all stop patterns using these stops in sequence
- Unless overridden by a custom alignment

### 4.12 Validation

**AC-PAT-047: Validate stop sequence**
- Given I have created a stop pattern
- When I save
- Then the system validates that at least two stops exist
- And displays an error if validation fails

**AC-PAT-048: Validate timing sequence**
- Given I am editing timed pattern times
- When I enter times that decrease along the sequence
- Then the system displays a warning about non-sequential times

**AC-PAT-049: Flag duplicate patterns**
- Given two stop patterns have identical stop sequences
- Then the system displays a "Duplicate Patterns" warning
- And the warning persists until one pattern is modified

**AC-PAT-050: Validate loop patterns**
- Given I am creating a loop route pattern
- Then the system allows the first and last stop to be the same
- And the system allows the same stop to appear multiple times in the sequence

### 4.13 Integration Points

**AC-PAT-051: Stops available in pattern editor**
- Given stops exist in the stops inventory
- Then those stops are available for selection when editing patterns

**AC-PAT-052: Pattern available for trip scheduling**
- Given I have created a stop pattern with at least one timed pattern
- When I navigate to trip scheduling
- Then this pattern is available for creating trips

**AC-PAT-053: Alignment export to shapes.txt**
- Given stop patterns have saved alignments
- When I export GTFS
- Then shapes.txt contains the alignment geometry
- And trips.txt references the appropriate shape_id

**AC-PAT-054: Stop times export**
- Given timed patterns have timing defined
- And trips are scheduled using those timed patterns
- When I export GTFS
- Then stop_times.txt contains calculated arrival/departure times
- And timepoint and pickup/drop-off values are included

---

## 5. Non-Functional Requirements

### 5.1 Performance
- Stop pattern list must load within 2 seconds for routes with up to 50 patterns
- Map view must render alignments within 3 seconds for patterns with up to 200 stops
- Auto-generate alignment must complete within 5 seconds per segment
- Bulk auto-generate must process 50 segments within 30 seconds
- Timed pattern timing entry must respond within 200ms per field

### 5.2 Usability
- Map interactions must follow standard web mapping conventions (scroll to zoom, drag to pan)
- Alignment editing must support touch devices for field use
- Alignment status colors (red/yellow/green) must be accompanied by icons or labels for color-blind users
- Save buttons must use high-visibility styling (bright green) per existing UI conventions
- Unsaved changes must be clearly indicated with visual highlighting
- Undo must be available for stop pattern edits within the current session

### 5.3 Data Integrity
- Stop pattern deletion must be prevented while trips reference the pattern
- Timed pattern deletion must be prevented while trips reference the pattern
- Alignment edits must not affect other stop patterns unless explicitly set as system-wide
- Stop sequence changes must cascade to all timed patterns on that stop pattern

### 5.4 Accessibility
- All form fields must have associated labels
- Map must provide alternative list-based pattern editing for screen reader users
- Color-coding must not be the sole indicator of alignment status

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The pattern list and timing editor prioritize data visibility. Avoid decorative elements that do not convey schedule information.

**Grid System:** Use consistent column widths for timing entry. Align map and list views using predictable split layouts.

**Typography:** Use system sans-serif fonts. Stop names display in standard weight; timing values in monospace for alignment.

**Color for Information:** Use color to encode alignment status (red=missing, yellow=unsaved, green=saved) and direction (consistent colors per direction). Maintain high contrast for readability.

**Plain Language:** Use "Stop Pattern" and "Timed Pattern" consistently. Avoid internal jargon; prefer "arrival time" over "timepoint" in user-facing labels (while retaining "Timepoint" for the specific GTFS field toggle).

**Input Efficiency:** Support keyboard navigation through timing fields. Enable tab-through for rapid time entry. Auto-format time inputs (accept "5" as "00:05:00").

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Pattern management belongs to a `Patterns` context that encapsulates stop patterns, timed patterns, and alignments. The context owns `StopPattern`, `TimedPattern`, `Alignment`, and related schemas.

**Data Validation:** Use Ecto changesets with explicit validations. Return tagged tuples (`{:ok, pattern}` or `{:error, changeset}`) from context functions. Validate stop sequence uniqueness, timing progression, and alignment geometry.

**LiveView Architecture:** Pattern list and editor implement as LiveView. Use streams for stop lists within patterns to handle large sequences efficiently. Delegate to function components for reusable UI elements (timing input, alignment status indicator).

**Real-Time Updates:** Use Phoenix PubSub to broadcast pattern changes. Multiple users editing patterns on the same route see updates without manual refresh.

**Alignment Storage:** Store alignment geometry as a list of coordinate pairs. Generate `shapes.txt` output on GTFS export by concatenating alignments in stop sequence order and calculating shape_dist_traveled.

**Testing Strategy:**
- Context tests validate business rules (sequence integrity, timing validation, cascade behavior)
- LiveView tests verify user flows (create pattern, add stops, edit timing, save alignment)
- Focus on behavior over implementation
- Test edge cases: loop routes, duplicate stops, custom alignments
