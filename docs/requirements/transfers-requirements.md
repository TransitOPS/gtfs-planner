# Transfers Requirements Document

**Section:** Transfers  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Transfers section manages the `transfers.txt` file, an optional file in the GTFS specification. This file defines rules and overrides for passenger transfers between routes, trips, or stops. When calculating itineraries, GTFS-consuming applications interpolate transfers based on allowable time and stop proximity; `transfers.txt` enables agencies to specify exceptions to default transfer behavior.

### 1.1 Core Data Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `from_stop_id` | Foreign ID (stops.stop_id) | Conditionally Required | Identifies the stop or station where the transfer begins. If referencing a station, the rule applies to all child stops. Required for transfer_type 1, 2, or 3. |
| `to_stop_id` | Foreign ID (stops.stop_id) | Conditionally Required | Identifies the stop or station where the transfer ends. If referencing a station, the rule applies to all child stops. Required for transfer_type 1, 2, or 3. |
| `from_route_id` | Foreign ID (routes.route_id) | Optional | Identifies the route where the transfer begins. If defined, the rule applies to arriving trips on this route at the specified stop. |
| `to_route_id` | Foreign ID (routes.route_id) | Optional | Identifies the route where the transfer ends. If defined, the rule applies to departing trips on this route at the specified stop. |
| `from_trip_id` | Foreign ID (trips.trip_id) | Conditionally Required | Identifies the specific trip where the transfer begins. Required for transfer_type 4 or 5 (linked trips). Takes precedence over from_route_id. |
| `to_trip_id` | Foreign ID (trips.trip_id) | Conditionally Required | Identifies the specific trip where the transfer ends. Required for transfer_type 4 or 5 (linked trips). Takes precedence over to_route_id. |
| `transfer_type` | Enum | Required | Indicates the type of connection. See Transfer Types below. |
| `min_transfer_time` | Non-negative Integer | Optional | Minimum time in seconds required to make a transfer. Used when transfer_type = 2. |

### 1.2 Transfer Types

The GTFS specification defines six transfer types:

| Type | Name | Description |
|------|------|-------------|
| 0 | Recommended Transfer | Preferred transfer point between routes. Does not override timing assumptions but indicates agency preference when multiple transfer options have equal travel time. |
| 1 | Timed Transfer | Guaranteed connection. The departing vehicle is expected to wait for the arriving vehicle, allowing sufficient time for passengers to transfer. Overrides default transfer timing assumptions. |
| 2 | Minimum Time Required | Transfer requires a specified minimum interval between arrival and departure. The `min_transfer_time` field defines the required buffer. |
| 3 | Transfer Not Possible | Indicates that transfers between routes are not possible at this location, even if stops are nearby. |
| 4 | In-Seat Transfer | Passengers may transfer by remaining on the same vehicle (block transfer). The vehicle continues as a different trip. |
| 5 | In-Seat Transfer Not Allowed | Passengers must alight and reboard even though trips are linked on the same vehicle. |

### 1.3 Specificity Ranking

When multiple transfer rules could apply to a given pair of arriving and departing trips, the GTFS specification defines a ranking by specificity. The most specific matching rule applies:

1. Both `trip_id` fields defined (highest specificity)
2. One `trip_id` and one `route_id` defined
3. One `trip_id` defined
4. Both `route_id` fields defined
5. One `route_id` defined
6. Only `from_stop_id` and `to_stop_id` defined (lowest specificity)

For any pair of trips, there should not be two transfer rules with equally maximal specificity.

### 1.4 Operational Implications

#### Trip Planning Algorithm Behavior

Trip planning applications apply default transfer assumptions when calculating itineraries. Most applications, including Google Maps, assume a minimum transfer time of approximately four minutes plus walking time between stops. This means that even when two routes share a common stop, trip planners will not suggest a transfer unless the scheduled departure is at least four minutes after the arrival. Timed transfers (type 1) override this assumption, enabling agencies to model pulse schedules and guaranteed connections.

#### Pulse Schedule Modeling

Agencies operating pulse or timed-transfer schedules—where multiple routes converge at a transfer point and hold for connections—must define timed transfers to accurately represent their service. Without explicit transfer rules, trip planners will show longer, less optimal itineraries that avoid tight connections the agency has designed to work.

#### Transfer Penalties and Recommendations

When multiple transfer opportunities exist between two routes (routes intersecting at several points), trip planners may select any viable option. Recommended transfers (type 0) enable agencies to indicate preferred transfer points, improving wayfinding for riders and aligning trip planner output with published schedules and signage.

#### Blocked Transfers

Some stop pairs may be geographically proximate but operationally unsuitable for transfers. Physical barriers, fare zone boundaries, or safety concerns may make transfers impractical. Transfer type 3 (not possible) prevents trip planners from suggesting these connections.

#### Block Transfers and Through-Routed Service

For interlined service where vehicles continue as different trips (through-routing), in-seat transfer rules (types 4 and 5) communicate whether passengers may remain on board. This affects journey time calculations and rider experience. These rules require both `from_trip_id` and `to_trip_id`, linking specific trip pairs.

#### Minimum Transfer Time at Complex Facilities

Large transit hubs, multimodal stations, or facilities requiring security screening may need longer transfer times than the default. Transfer type 2 with an explicit `min_transfer_time` ensures trip planners account for the actual walking distance or processing time between platforms.

#### Data Consumer Impact

Transfer rules flow to Google Maps, Apple Maps, Transit App, and other consumer applications. Incorrect or missing transfer rules degrade itinerary quality for all riders using these platforms. Overly restrictive rules hide viable connections; missing timed transfer rules cause trip planners to suggest longer journeys that ignore guaranteed connections.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Transfer Creation

**JS-XFER-001: Defining timed transfers at a pulse point**
When routes are scheduled to meet at a transit center with guaranteed connections, I want to define timed transfers between those routes at that stop, so I can ensure trip planners suggest the connections our schedule is designed to provide.

**JS-XFER-002: Defining recommended transfers at multi-point intersections**
When two routes intersect at multiple stops throughout their alignments, I want to mark one intersection as the recommended transfer point, so I can guide riders to the location with the best amenities or schedule coordination.

**JS-XFER-003: Blocking transfers at unsuitable locations**
When two routes share a stop that is not suitable for transfers due to physical barriers or operational constraints, I want to mark transfers as not possible at that location, so I can prevent trip planners from suggesting impractical connections.

**JS-XFER-004: Specifying minimum transfer time at large facilities**
When transfers at a major hub require extra walking time or security processing, I want to specify a minimum transfer time, so I can ensure trip planners only suggest connections with adequate time between arrival and departure.

**JS-XFER-005: Creating route-level transfer rules**
When a transfer rule should apply to all trips on a route pair, I want to define the rule at the route level without specifying individual trips, so I can efficiently manage transfers for the entire service pattern.

**JS-XFER-006: Creating trip-level transfer rules**
When a guaranteed connection only exists between specific trips (not all trips on the routes), I want to define transfers at the trip level, so I can model exceptions to the general route-level transfer behavior.

### 2.2 Transfer Editing

**JS-XFER-007: Modifying transfer type**
When operational circumstances change and a previously timed transfer is no longer guaranteed, I want to change the transfer type from timed to recommended or remove the rule, so I can keep transfer data aligned with actual service.

**JS-XFER-008: Adjusting minimum transfer time**
When facility improvements reduce the required transfer time at a hub, I want to update the minimum transfer time value, so I can reflect the improved connection without recreating the transfer rule.

**JS-XFER-009: Upgrading stop-level rules to route-level**
When I have multiple stop-level transfers between the same routes, I want to consolidate them into route-level rules, so I can simplify transfer management and reduce redundant data.

### 2.3 Transfer Review

**JS-XFER-010: Finding transfers at a specific stop**
When reviewing transfer configuration for a transit center, I want to see all transfer rules that involve that stop, so I can verify that connections are modeled correctly for the facility.

**JS-XFER-011: Finding transfers for a specific route**
When a route's schedule changes, I want to see all transfer rules involving that route, so I can assess whether existing transfer rules remain valid.

**JS-XFER-012: Identifying stops without defined transfers**
When auditing my GTFS data, I want to see stops where multiple routes intersect but no transfer rules are defined, so I can evaluate whether transfer rules should be added.

### 2.4 Transfer Validation

**JS-XFER-013: Detecting conflicting transfer rules**
When two transfer rules with equal specificity could apply to the same trip pair, I want the system to flag this conflict, so I can resolve ambiguity before export.

**JS-XFER-014: Validating stop references**
When I define a transfer, I want to confirm that the from_stop_id and to_stop_id reference valid stops where the specified routes actually serve, so I can avoid creating orphan transfer rules.

**JS-XFER-015: Reviewing transfer rules for deleted routes**
When a route is discontinued, I want to see transfer rules that reference that route, so I can clean up obsolete transfer data.

### 2.5 In-Seat Transfers

**JS-XFER-016: Defining in-seat transfers for through-routed service**
When a vehicle continues as a different trip and passengers may remain on board, I want to define an in-seat transfer between the trip pair, so I can communicate this convenience to riders through trip planners.

**JS-XFER-017: Requiring deboarding between linked trips**
When a vehicle continues as a different trip but passengers must alight (for cleaning, fare collection, or operational reasons), I want to define a type-5 transfer, so I can prevent trip planners from incorrectly showing in-seat continuity.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Transfer List Management

**US-XFER-001: View transfer list**
As a schedule editor, I want to view all transfers in a sortable, searchable list, so that I can quickly locate transfer rules by stop, route, or type.

**US-XFER-002: Filter transfer list**
As a schedule editor, I want to filter transfers by transfer type, route, stop, or specificity level, so that I can focus on relevant subsets of transfer rules.

**US-XFER-003: Sort transfer list**
As a schedule editor, I want to sort transfers by any column header, so that I can organize the list according to my current task.

**US-XFER-004: Search transfer list**
As a schedule editor, I want to search transfers by stop name, route name, or stop code, so that I can find specific transfer rules without scrolling.

### 3.2 Transfer Creation

**US-XFER-005: Create transfer via form**
As a schedule editor, I want to create a new transfer by completing a form, so that I can add transfer rules with all required fields.

**US-XFER-006: Select from stop via dropdown**
As a schedule editor, I want to select the "from" stop from a searchable dropdown of existing stops, so that I can associate transfers with valid stop IDs without manual entry.

**US-XFER-007: Select to stop via dropdown**
As a schedule editor, I want to select the "to" stop from a searchable dropdown of existing stops, so that I can ensure valid stop references.

**US-XFER-008: Select from route via dropdown**
As a schedule editor, I want to optionally select a "from" route to increase transfer specificity, so that I can target transfers to specific route pairs.

**US-XFER-009: Select to route via dropdown**
As a schedule editor, I want to optionally select a "to" route to increase transfer specificity, so that I can complete route-level transfer rules.

**US-XFER-010: Select transfer type**
As a schedule editor, I want to select a transfer type from a dropdown with clear descriptions, so that I can understand the operational implications of each type.

**US-XFER-011: Enter minimum transfer time**
As a schedule editor, I want to enter a minimum transfer time in seconds when creating a type-2 transfer, so that I can specify the required buffer.

**US-XFER-012: Create transfer from stop context**
As a schedule editor, I want to create a transfer directly from a stop's detail page, so that I can add transfer rules without navigating away from the stop I'm working on.

### 3.3 Transfer Editing

**US-XFER-013: Edit transfer details**
As a schedule editor, I want to edit an existing transfer's type, stops, routes, or minimum time, so that I can update rules as service evolves.

**US-XFER-014: Save transfer changes**
As a schedule editor, I want to save my transfer edits, so that my changes are persisted to the database.

**US-XFER-015: Cancel transfer edit**
As a schedule editor, I want to cancel edits and revert to the saved state, so that I can abandon unwanted changes.

### 3.4 Transfer Deletion

**US-XFER-016: Delete transfer**
As a schedule editor, I want to delete a transfer rule that is no longer valid, so that I can remove obsolete data from my feed.

**US-XFER-017: Bulk delete transfers**
As a schedule editor, I want to select multiple transfers and delete them in one action, so that I can efficiently clean up transfer rules when routes change.

### 3.5 Transfer Validation

**US-XFER-018: View validation errors**
As a schedule editor, I want to see validation errors for transfer rules (conflicting specificity, invalid references), so that I can correct problems before export.

**US-XFER-019: View validation warnings**
As a schedule editor, I want to see warnings for potentially problematic transfers (e.g., timed transfers with very short scheduled intervals), so that I can review and confirm intentional configurations.

### 3.6 Transfer Context

**US-XFER-020: View transfers from stop detail**
As a schedule editor, I want to see all transfers involving a stop when viewing that stop's details, so that I can understand transfer configuration in context.

**US-XFER-021: View transfers from route detail**
As a schedule editor, I want to see all transfers involving a route when viewing that route's details, so that I can assess transfer coverage for a route.

**US-XFER-022: Navigate from transfer to stop**
As a schedule editor, I want to click on a stop in the transfer list to navigate to that stop's detail page, so that I can make related edits efficiently.

**US-XFER-023: Navigate from transfer to route**
As a schedule editor, I want to click on a route in the transfer list to navigate to that route's detail page, so that I can review the route's full configuration.

### 3.7 In-Seat Transfers

**US-XFER-024: Create in-seat transfer**
As a schedule editor, I want to create a type-4 transfer linking two trips, so that I can model through-routed service where passengers remain on board.

**US-XFER-025: Select from trip via dropdown**
As a schedule editor, I want to select a "from" trip from trips on the specified route, so that I can define trip-specific transfer rules.

**US-XFER-026: Select to trip via dropdown**
As a schedule editor, I want to select a "to" trip from trips on the specified route, so that I can complete the in-seat transfer definition.

**US-XFER-027: View linked trip details**
As a schedule editor, I want to see trip headsign and departure time when selecting trips for in-seat transfers, so that I can identify the correct trip pair.

---

## 4. Acceptance Criteria

### 4.1 Transfer List View

**AC-XFER-001: Transfer list displays required columns**
- Given I navigate to the Transfers section
- When the transfer list loads
- Then I see columns for: From Stop, To Stop, From Route, To Route, Transfer Type, and Min Transfer Time
- And the list displays all transfers in the current dataset

**AC-XFER-002: Transfer list is sortable**
- Given I am viewing the transfer list
- When I click on any column header
- Then the list sorts by that column in ascending order
- And clicking the same header again sorts in descending order

**AC-XFER-003: Transfer list is filterable**
- Given I am viewing the transfer list
- When I apply filters for transfer type, route, or stop
- Then only transfers matching the filter criteria are displayed
- And I can combine multiple filters

**AC-XFER-004: Transfer list supports search**
- Given I am viewing the transfer list
- When I enter text in the search field
- Then the list filters to show transfers whose stop names, stop codes, or route names contain the search text

**AC-XFER-005: Transfer type displays human-readable label**
- Given I am viewing the transfer list
- When transfer type values are displayed
- Then numeric codes are replaced with readable labels (e.g., "1" displays as "Timed Transfer")

### 4.2 Transfer Creation

**AC-XFER-006: Create transfer via Add Transfer button**
- Given I am viewing the Transfers section
- When I click the "Add Transfer" button
- Then a form appears with fields for from stop, to stop, transfer type, and optional fields

**AC-XFER-007: From stop is required for types 1, 2, 3**
- Given I am creating a transfer with type 1, 2, or 3
- When I attempt to save without selecting a from stop
- Then the system displays a validation error
- And the transfer is not saved

**AC-XFER-008: To stop is required for types 1, 2, 3**
- Given I am creating a transfer with type 1, 2, or 3
- When I attempt to save without selecting a to stop
- Then the system displays a validation error
- And the transfer is not saved

**AC-XFER-009: Transfer type is required**
- Given I am creating a transfer
- When I attempt to save without selecting a transfer type
- Then the system displays a validation error
- And the transfer is not saved

**AC-XFER-010: Min transfer time conditional on type 2**
- Given I am creating a transfer with type 2 (Minimum Time Required)
- When I view the form
- Then the minimum transfer time field is visible and editable
- And the field is required for this transfer type

**AC-XFER-011: Min transfer time hidden for other types**
- Given I am creating a transfer with type 0, 1, or 3
- When I view the form
- Then the minimum transfer time field is hidden or disabled

**AC-XFER-012: Route dropdowns filter by stop**
- Given I have selected from_stop_id and to_stop_id
- When I view the route dropdowns
- Then from_route_id shows only routes serving the from stop
- And to_route_id shows only routes serving the to stop

**AC-XFER-013: Save new transfer**
- Given I have completed all required fields for a transfer
- When I click the Save button
- Then the transfer is persisted to the database
- And a success confirmation is displayed
- And the new transfer appears in the transfer list

### 4.3 Transfer Editing

**AC-XFER-014: Edit transfer via list selection**
- Given I am viewing the transfer list
- When I click on a transfer row
- Then the transfer detail form opens for editing

**AC-XFER-015: Edit from stop**
- Given I am editing a transfer
- When I change the from stop selection
- Then the from_stop_id updates
- And route dropdowns refresh to show routes serving the new stop

**AC-XFER-016: Edit to stop**
- Given I am editing a transfer
- When I change the to stop selection
- Then the to_stop_id updates
- And route dropdowns refresh to show routes serving the new stop

**AC-XFER-017: Edit transfer type**
- Given I am editing a transfer
- When I change the transfer type
- Then conditional fields (min_transfer_time) show/hide appropriately
- And the transfer can be saved with the new type

**AC-XFER-018: Save transfer changes**
- Given I have made changes to a transfer
- When I click the Save button
- Then my changes are persisted
- And a success confirmation is displayed

**AC-XFER-019: Unsaved changes warning**
- Given I have unsaved changes to a transfer
- When I navigate away without saving
- Then the system warns me about unsaved changes
- And gives me the option to save or discard

### 4.4 Transfer Deletion

**AC-XFER-020: Delete transfer from detail view**
- Given I am viewing a transfer's details
- When I click "Delete Transfer" and confirm
- Then the transfer is permanently removed
- And it no longer appears in the transfer list

**AC-XFER-021: Delete transfer from list**
- Given I am viewing the transfer list
- When I click the delete icon for a transfer
- And I confirm the deletion
- Then the transfer is removed from the list

**AC-XFER-022: Bulk delete transfers**
- Given I am viewing the transfer list
- When I select multiple transfers via checkboxes
- And I click "Delete Selected" and confirm
- Then all selected transfers are permanently removed

### 4.5 Transfer Type Behavior

**AC-XFER-023: Recommended transfer (type 0)**
- Given I create a transfer with type 0
- When I save the transfer
- Then transfer_type = 0 is stored
- And no min_transfer_time is required

**AC-XFER-024: Timed transfer (type 1)**
- Given I create a transfer with type 1
- When I save the transfer
- Then transfer_type = 1 is stored
- And the transfer indicates a guaranteed connection

**AC-XFER-025: Minimum time transfer (type 2)**
- Given I create a transfer with type 2
- When I enter a minimum transfer time of 300 seconds
- And I save the transfer
- Then transfer_type = 2 is stored
- And min_transfer_time = 300 is stored

**AC-XFER-026: Min transfer time validation**
- Given I am creating a transfer with type 2
- When I enter a negative value for min_transfer_time
- Then the system displays a validation error
- And the transfer cannot be saved

**AC-XFER-027: Transfer not possible (type 3)**
- Given I create a transfer with type 3
- When I save the transfer
- Then transfer_type = 3 is stored
- And the transfer indicates connections should not be suggested

### 4.6 In-Seat Transfers (Types 4 and 5)

**AC-XFER-028: In-seat transfer requires trip IDs**
- Given I am creating a transfer with type 4 or 5
- When I attempt to save without from_trip_id
- Then the system displays a validation error indicating trip IDs are required

**AC-XFER-029: Trip dropdown shows trip details**
- Given I am selecting a trip for an in-seat transfer
- When I view the trip dropdown
- Then I see trip headsign and departure time to help identify the correct trip

**AC-XFER-030: In-seat transfer (type 4)**
- Given I create a transfer with type 4 and valid trip IDs
- When I save the transfer
- Then transfer_type = 4 is stored
- And from_trip_id and to_trip_id are stored

**AC-XFER-031: Forced deboarding (type 5)**
- Given I create a transfer with type 5 and valid trip IDs
- When I save the transfer
- Then transfer_type = 5 is stored
- And the transfer indicates passengers must alight

### 4.7 Specificity and Validation

**AC-XFER-032: Detect conflicting specificity**
- Given two transfers exist with identical from_stop_id, to_stop_id, and route/trip combinations
- When I view the transfer list or validation report
- Then the conflicting transfers are flagged with a warning
- And a message indicates the ambiguity should be resolved

**AC-XFER-033: Validate stop references**
- Given I am creating a transfer
- When I select from_stop_id and to_stop_id
- Then only valid, active stops are available in the dropdown

**AC-XFER-034: Validate route references**
- Given I have selected routes for a transfer
- When I save the transfer
- Then the system verifies the routes exist and are active
- And the transfer is not saved if routes are invalid

**AC-XFER-035: Duplicate transfer prevention**
- Given a transfer exists with specific from_stop_id, to_stop_id, from_route_id, and to_route_id
- When I attempt to create an identical transfer
- Then the system displays a validation error indicating a duplicate exists
- And the duplicate transfer is not saved

### 4.8 Integration Points

**AC-XFER-036: Transfers reference stops from stop inventory**
- Given I am creating a transfer
- When I view the stop dropdowns
- Then I can select from all active stops in the stop inventory

**AC-XFER-037: Transfers reference routes from route inventory**
- Given I am creating a transfer
- When I view the route dropdowns
- Then I can select from all active routes in the route inventory

**AC-XFER-038: Stop detail shows related transfers**
- Given I am viewing a stop's detail page
- When transfers exist involving that stop
- Then I see a Transfers section listing all transfers at that stop

**AC-XFER-039: Route detail shows related transfers**
- Given I am viewing a route's detail page
- When transfers exist involving that route
- Then I see a Transfers section listing all transfers for that route

**AC-XFER-040: GTFS export includes all transfers**
- Given I have transfers defined
- When I export GTFS
- Then transfers.txt contains all transfers with required fields populated
- And the file conforms to GTFS specification

**AC-XFER-041: Station-level transfers apply to child stops**
- Given I create a transfer where from_stop_id references a station (location_type=1)
- When the transfer is consumed by trip planners
- Then the rule applies to all child stops of that station
- And this behavior is documented in the interface

---

## 5. Non-Functional Requirements

### 5.1 Performance

- Transfer list must load within 2 seconds for datasets with up to 1,000 transfer rules
- Dropdown searches (stops, routes, trips) must return results within 500ms
- Save operations must complete within 1 second

### 5.2 Usability

- Transfer type selection must include clear descriptions of each type's operational meaning
- Min transfer time field must accept input in seconds and optionally display in minutes:seconds format
- Stop and route dropdowns must support type-ahead search
- Delete operations must require confirmation to prevent accidental data loss
- Form validation must provide inline feedback before form submission

### 5.3 Data Integrity

- Transfer deletion must be permitted regardless of other data (transfers have no dependents)
- System must prevent duplicate transfers (same from_stop, to_stop, from_route, to_route, from_trip, to_trip combination)
- System must enforce GTFS conditional requirements (trip IDs required for types 4 and 5)
- Foreign key references (stop_id, route_id, trip_id) must reference existing records

### 5.4 Accessibility

- All form fields must have associated labels
- Transfer type radio buttons or dropdowns must be keyboard navigable
- Error messages must be announced to screen readers
- Color-coding for validation status must not be the sole indicator (use icons or text)

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The transfer list prioritizes data visibility. Display transfer relationships clearly without decorative elements. Use concise column headers and avoid visual noise.

**Grid System:** List views and forms follow a consistent grid. The transfer form uses a logical field arrangement: source fields (from_stop, from_route), destination fields (to_stop, to_route), then configuration (transfer_type, min_transfer_time).

**Typography:** Use system sans-serif fonts. Stop and route names display in standard weight; field labels in lighter weight for hierarchy. Transfer type labels should be immediately scannable.

**Color for Information:** Use color sparingly to encode transfer type categories if needed for quick scanning. Do not use color as decoration. Maintain high contrast for readability. Use yellow or orange indicators for validation warnings.

**Plain Language:** Field labels use standard terms ("From Stop" not "Origin Stop ID"). Transfer type descriptions explain operational meaning, not just GTFS field values. Help text clarifies when each transfer type is appropriate.

**Input Efficiency:** Minimize clicks. Support keyboard navigation. Filter route dropdowns based on selected stops. Provide smart defaults where possible (e.g., default to type 0).

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Transfer management belongs to a `Transfers` context that encapsulates all transfer-related business logic. The context owns the `Transfer` schema and coordinates with `Stops` and `Routes` contexts for reference validation.

**Data Validation:** Use Ecto changesets with explicit validations. Enforce conditional requirements (min_transfer_time required when transfer_type = 2). Return tagged tuples (`{:ok, transfer}` or `{:error, changeset}`) from context functions.

**Composite Primary Key:** The GTFS specification defines the primary key as (from_stop_id, to_stop_id, from_trip_id, to_trip_id, from_route_id, to_route_id). Implement uniqueness constraints accordingly.

**LiveView Architecture:** Transfer list and form views implement as LiveView. Use streams for the transfer list to handle moderate-sized inventories. Delegate to function components for reusable UI elements (stop selector, route selector).

**Real-Time Updates:** Use Phoenix PubSub to broadcast transfer changes. Multiple users editing the same dataset see updates without manual refresh.

**Testing Strategy:**
- Context tests validate business rules (conditional requirements, specificity conflicts, duplicate detection)
- LiveView tests verify user flows (create, edit, delete, bulk delete)
- Integration tests verify GTFS export correctness
- Focus on behavior over implementation
