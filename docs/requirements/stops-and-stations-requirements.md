# Stops and Stations Requirements Document

**Section:** Stops and Stations  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Stops and Stations section manages the `stops.txt` file, one of the conditionally required files in the GTFS specification. This file defines all geographic locations where passengers board or alight from transit vehicles, as well as the hierarchical station structures that contain them.

### 1.1 Core Data Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `stop_id` | Unique ID | Required | Unique identifier for the location. Must be unique across all stops, locations.geojson IDs, and location group IDs. |
| `stop_code` | Text | Optional | Customer-facing alphanumeric code, typically shown on signage or used with real-time arrival systems. |
| `stop_name` | Text | Conditionally Required | Rider-facing name matching timetables, signage, and published materials. Required for stops (location_type=0), stations (location_type=1), and entrances/exits (location_type=2). |
| `tts_stop_name` | Text | Optional | Text-to-speech readable version of the stop name. |
| `stop_desc` | Text | Optional | Description providing useful, quality information. Must not duplicate stop_name. |
| `stop_lat` | Latitude | Conditionally Required | WGS84 latitude. For stops/platforms, coordinates must represent where riders board (sidewalk/platform), not the roadway. |
| `stop_lon` | Longitude | Conditionally Required | WGS84 longitude. Same positioning requirements as latitude. |
| `zone_id` | ID | Optional | Identifies the fare zone for a stop. Ignored for stations and station entrances. |
| `stop_url` | URL | Optional | URL of a web page specific to this stop. |
| `location_type` | Enum | Optional | Defines the location hierarchy: 0=Stop/Platform (default), 1=Station, 2=Entrance/Exit, 3=Generic Node, 4=Boarding Area. |
| `parent_station` | Foreign ID | Conditionally Required | References the parent station's stop_id. Required for entrances, generic nodes, and boarding areas. Optional for stops/platforms. Forbidden for stations. |
| `stop_timezone` | Timezone | Optional | Timezone of the location. Inherits from parent station or agency if empty. |
| `wheelchair_boarding` | Enum | Optional | Wheelchair accessibility: 0=No info, 1=Some vehicles accessible, 2=Not accessible. |
| `level_id` | Foreign ID | Optional | References levels.txt for multi-level stations. |
| `platform_code` | Text | Optional | Platform identifier for riders (e.g., "A", "Platform 3"). |

### 1.2 Location Type Hierarchy

The GTFS specification defines a hierarchical structure for complex transit facilities:

```
Station (location_type=1)
├── Entrance/Exit (location_type=2)
├── Generic Node (location_type=3)
└── Stop/Platform (location_type=0)
    └── Boarding Area (location_type=4)
```

**Hierarchy Rules:**
- Stations must not have a parent_station
- Stops/platforms may optionally reference a station as parent
- Entrances, generic nodes, and boarding areas must have a parent
- Boarding areas reference a platform, not directly a station

### 1.3 Operational Implications

#### Trip Planning Impact
Stop coordinates directly affect trip planning accuracy. Coordinates placed in roadways or intersections rather than on sidewalks cause navigation systems to direct riders to incorrect locations, potentially creating safety hazards.

#### Real-Time Integration
The `stop_code` field enables integration with Automatic Vehicle Location (AVL) systems. Agencies using real-time arrival information must maintain consistent stop codes between GTFS and AVL systems. When stop codes are configured to export as stop_id, this field becomes functionally required.

#### Fare Calculation
The `zone_id` field drives zone-based fare calculation. Stops assigned to fare zones enable trip planners to calculate accurate fares for journeys crossing zone boundaries. Incomplete or inconsistent zone assignments break fare estimation.

#### Accessibility Compliance
The `wheelchair_boarding` field powers accessibility filtering in trip planners. Partial data (some stops marked, others empty) creates misleading results. This field should only be populated when accessibility status is known for all stops in the system.

#### Station Wayfinding
Parent-child relationships between stations and platforms enable detailed wayfinding within complex facilities. Transit centers with multiple bays benefit from station hierarchies that help riders understand which platform serves their route.

#### Data Consumers
Stops data flows to Google Maps, Apple Maps, Transit App, and other consumer applications. Data quality directly affects millions of rider interactions. Duplicate stops, inaccurate coordinates, and inconsistent naming conventions degrade rider experience across all consuming platforms.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Stop Creation

**JS-STOP-001: Creating stops via map interaction**
When I am reviewing a new service area on the map, I want to place a stop by clicking the exact boarding location, so I can ensure coordinates represent where riders actually wait.

**JS-STOP-002: Creating stops via address search**
When I know the address or landmark name but not the exact coordinates, I want to search for a location and create a stop there, so I can quickly add stops without manually looking up coordinates.

**JS-STOP-003: Creating stops via coordinate entry**
When I have surveyed stop locations in the field with GPS equipment, I want to enter latitude/longitude coordinates directly, so I can preserve the precision of my field measurements.

### 2.2 Stop Editing

**JS-STOP-004: Relocating misplaced stops**
When a stop's coordinates are on the roadway instead of the sidewalk, I want to drag the map pin to the correct location, so I can fix trip planning navigation without re-entering all the stop's metadata.

**JS-STOP-005: Bulk coordinate updates**
When I receive corrected coordinates from a field survey, I want to paste a coordinate pair and have latitude/longitude auto-populate, so I can update locations efficiently without manual field-by-field entry.

**JS-STOP-006: Standardizing stop names**
When stop names use inconsistent abbreviations or formats, I want to edit names while seeing naming conventions used elsewhere in my system, so I can maintain consistency that riders recognize.

### 2.3 Stop Organization

**JS-STOP-007: Filtering large stop inventories**
When my agency has hundreds of stops, I want to filter by city, direction, zone, or route usage, so I can find specific stops without scrolling through the entire list.

**JS-STOP-008: Identifying orphan stops**
When cleaning up my GTFS data, I want to see which stops are not used in any active patterns, so I can decide whether to mark them inactive or delete them.

**JS-STOP-009: Reviewing stops flagged for issues**
When stops are very close together or have other data quality issues, I want to see them flagged as "Needs Review," so I can prioritize corrections that affect data quality.

### 2.4 Station Management

**JS-STOP-010: Creating station hierarchies**
When a transit center has multiple bays serving different routes, I want to group those bays under a parent station, so I can model the facility structure accurately for wayfinding applications.

**JS-STOP-011: Assigning platforms to stations**
When adding a new bay to an existing transit center, I want to select the parent station from a dropdown, so I can maintain the station hierarchy without manual ID entry.

**JS-STOP-012: Differentiating platforms within stations**
When a station has multiple platforms, I want to assign platform codes (e.g., "Bay A", "Platform 2"), so I can provide riders with specific boarding location information.

### 2.5 Zone Management

**JS-STOP-013: Creating fare zones**
When my agency uses zone-based fares, I want to create named zones that I can assign to stops, so I can enable accurate fare calculation in trip planners.

**JS-STOP-014: Assigning stops to zones**
When configuring zone-based fares, I want to assign multiple stops to a zone at once, so I can efficiently configure large service areas without editing each stop individually.

### 2.6 Service State Management

**JS-STOP-015: Marking stops inactive**
When a stop is temporarily out of service due to construction, I want to mark it inactive without deleting it, so I can preserve the stop data for when service resumes.

**JS-STOP-016: Understanding stop usage before deletion**
When considering deleting a stop, I want to see all patterns and routes that use it, so I can assess the impact and remove it from patterns before deletion.

### 2.7 Special Stop Types

**JS-STOP-017: Configuring flag stops**
When service operates as "flag stop" (passengers can request stops anywhere along a segment), I want to mark stops with this designation, so I can convey this service characteristic to riders.

**JS-STOP-018: Configuring on-demand stops**
When certain stops only receive service upon request, I want to indicate this in the stop configuration, so I can ensure riders understand they must request service.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Stop Inventory Management

**US-STOP-001: View stop list**
As a schedule editor, I want to view all stops in a sortable, searchable list, so that I can quickly locate stops by name, code, or other attributes.

**US-STOP-002: View stops on map**
As a schedule editor, I want to view all stops on an interactive map, so that I can understand spatial relationships and identify geographic coverage gaps.

**US-STOP-003: Toggle map visibility**
As a schedule editor, I want to show or hide the map view, so that I can maximize screen space for the data table when spatial context isn't needed.

**US-STOP-004: Filter stop list**
As a schedule editor, I want to filter stops by city, direction, zone, active status, and route, so that I can focus on relevant subsets of a large stop inventory.

**US-STOP-005: Sort stop list**
As a schedule editor, I want to sort stops by any column header, so that I can organize the list according to my current task.

### 3.2 Stop Creation

**US-STOP-006: Create stop via map right-click**
As a schedule editor, I want to right-click on the map to create a stop at that location, so that I can visually place stops with accurate coordinates.

**US-STOP-007: Create stop via address search**
As a schedule editor, I want to create a stop by searching for an address or landmark, so that I can add stops without knowing exact coordinates.

**US-STOP-008: Create stop via coordinate entry**
As a schedule editor, I want to create a stop by entering latitude and longitude coordinates, so that I can import field-surveyed locations precisely.

**US-STOP-009: Auto-populate coordinates from map**
As a schedule editor, I want latitude and longitude to auto-populate when I create a stop from the map, so that I don't have to manually transcribe coordinates.

**US-STOP-010: Auto-split coordinate pairs**
As a schedule editor, I want pasted coordinate pairs (comma-separated) to automatically split into latitude and longitude fields, so that I can quickly update locations from external sources.

### 3.3 Stop Details

**US-STOP-011: Edit stop name**
As a schedule editor, I want to edit a stop's name, so that I can correct errors or align with updated signage.

**US-STOP-012: Edit stop code**
As a schedule editor, I want to edit a stop's customer-facing code, so that I can maintain consistency with posted signs and real-time systems.

**US-STOP-013: Edit stop coordinates**
As a schedule editor, I want to edit a stop's latitude and longitude, so that I can correct misplaced stops.

**US-STOP-014: Edit stop via map drag**
As a schedule editor, I want to drag a stop's map pin to a new location, so that I can relocate stops visually without manual coordinate entry.

**US-STOP-015: Set location type**
As a schedule editor, I want to set a stop's location type (stop, station, entrance, generic node, boarding area), so that I can model complex station hierarchies.

**US-STOP-016: Assign parent station**
As a schedule editor, I want to assign a stop to a parent station, so that I can create station hierarchies for transit centers.

**US-STOP-017: Assign platform code**
As a schedule editor, I want to assign a platform code to a stop within a station, so that I can differentiate boarding locations for riders.

**US-STOP-018: Assign fare zone**
As a schedule editor, I want to assign a stop to a fare zone, so that I can enable zone-based fare calculation.

**US-STOP-019: Set wheelchair boarding status**
As a schedule editor, I want to set wheelchair boarding availability for a stop, so that I can provide accessibility information to riders.

**US-STOP-020: Set stop URL**
As a schedule editor, I want to set a URL for stop-specific information pages, so that I can link riders to detailed stop information.

**US-STOP-021: Assign city**
As a schedule editor, I want to assign a city to a stop, so that I can organize and filter stops by municipality.

**US-STOP-022: Assign direction**
As a schedule editor, I want to assign a direction indicator to a stop, so that I can organize stops by service direction.

**US-STOP-023: Add internal comments**
As a schedule editor, I want to add internal comments to a stop, so that I can document notes that don't appear in the published GTFS.

**US-STOP-024: Save stop changes**
As a schedule editor, I want to save my stop edits, so that my changes are persisted to the database.

### 3.4 Stop Usage

**US-STOP-025: View stop usage details**
As a schedule editor, I want to view which routes and patterns use a stop, so that I can understand the impact of changes.

**US-STOP-026: Navigate to pattern from stop usage**
As a schedule editor, I want to click on a pattern in the stop usage list to navigate to that pattern, so that I can make related edits efficiently.

### 3.5 Stop Deletion and Deactivation

**US-STOP-027: Mark stop inactive**
As a schedule editor, I want to mark a stop as inactive, so that it remains in my inventory but is excluded from GTFS exports.

**US-STOP-028: Reactivate inactive stop**
As a schedule editor, I want to reactivate an inactive stop, so that I can restore service to a previously suspended stop.

**US-STOP-029: Delete unused stop**
As a schedule editor, I want to delete a stop that is not used in any patterns, so that I can remove obsolete data from my inventory.

**US-STOP-030: Prevent deletion of used stops**
As a schedule editor, I want the system to prevent deletion of stops used in active patterns, so that I don't accidentally break existing service definitions.

### 3.6 Station Management

**US-STOP-031: Create station**
As a schedule editor, I want to create a station record, so that I can model transit centers with multiple boarding locations.

**US-STOP-032: View station children**
As a schedule editor, I want to view all stops/platforms assigned to a station, so that I can manage the station hierarchy.

**US-STOP-033: Convert stop to station**
As a schedule editor, I want to change a stop's location type from "stop" to "station," so that I can create hierarchies for existing locations.

### 3.7 Zone Management

**US-STOP-034: View zone list**
As a schedule editor, I want to view all defined fare zones, so that I can manage zone-based fare structures.

**US-STOP-035: Create zone**
As a schedule editor, I want to create a new fare zone, so that I can define geographic areas for fare calculation.

**US-STOP-036: Delete zone**
As a schedule editor, I want to delete an unused fare zone, so that I can remove obsolete zone definitions.

**US-STOP-037: Unassign stop from zone**
As a schedule editor, I want to remove a stop's zone assignment, so that I can correct misconfigured fare zones.

### 3.8 Transfers

**US-STOP-038: Define transfer point**
As a schedule editor, I want to define transfer relationships at a stop, so that I can specify timed transfers or other transfer rules.

### 3.9 Data Quality

**US-STOP-039: View stops needing review**
As a schedule editor, I want to see stops flagged as "Needs Review" (e.g., duplicates, close proximity), so that I can prioritize data quality improvements.

**US-STOP-040: Request stop merge**
As a schedule editor, I want to request that two nearby stops be merged, so that I can consolidate duplicate stop records.

---

## 4. Acceptance Criteria

### 4.1 Stop List View

**AC-STOP-001: Stop list displays required columns**
- Given I navigate to the Stops section
- When the stop list loads
- Then I see columns for: Stop Name, Stop Code, Location Type, Zone, City, and active status indicator
- And the list displays all stops in the current dataset

**AC-STOP-002: Stop list is sortable**
- Given I am viewing the stop list
- When I click on any column header
- Then the list sorts by that column in ascending order
- And clicking the same header again sorts in descending order

**AC-STOP-003: Stop list is filterable**
- Given I am viewing the stop list
- When I apply filters for city, direction, zone, or active status
- Then only stops matching the filter criteria are displayed
- And I can combine multiple filters

**AC-STOP-004: Stop list supports search**
- Given I am viewing the stop list
- When I enter text in the search field
- Then the list filters to show stops whose name or code contains the search text

### 4.2 Map View

**AC-STOP-005: Map displays all stops**
- Given I enable the map view in the Stops section
- When the map loads
- Then all stops are displayed as pins at their geographic coordinates
- And I can pan and zoom the map

**AC-STOP-006: Map supports satellite view**
- Given I am viewing the stops map
- When I toggle to satellite view
- Then the base map changes to satellite imagery
- And stop pins remain visible with adequate contrast

**AC-STOP-007: Map stop selection**
- Given I am viewing the stops map
- When I click on a stop pin
- Then that stop is selected in the list
- And the stop details panel opens

**AC-STOP-008: Map shows filtered stops only**
- Given I have filters applied to the stop list
- When I view the map
- Then only stops matching the current filter are displayed on the map

### 4.3 Stop Creation

**AC-STOP-009: Create stop via map right-click**
- Given I am viewing the stops map
- When I right-click on a location
- Then a context menu appears with "Add a new stop here" option
- And selecting this option opens the stop details form with coordinates pre-populated

**AC-STOP-010: Create stop via Add Stop button**
- Given I am viewing the Stops section
- When I click the "Add Stop" button
- Then a dialog appears allowing me to search by address/landmark or enter coordinates
- And clicking "Go to Stop Details" opens the stop form

**AC-STOP-011: Stop name is required**
- Given I am creating or editing a stop
- When I attempt to save without a stop name
- Then the system displays a validation error
- And the stop is not saved

**AC-STOP-012: Coordinates are required for stops**
- Given I am creating a stop with location_type = 0 (Stop/Platform)
- When I attempt to save without latitude and longitude
- Then the system displays a validation error
- And the stop is not saved

**AC-STOP-013: Coordinate auto-split**
- Given I am editing stop coordinates
- When I paste a comma-separated coordinate pair (e.g., "41.890169, 12.492269") into the latitude field
- Then the latitude field contains "41.890169"
- And the longitude field auto-populates with "12.492269"

### 4.4 Stop Editing

**AC-STOP-014: Edit stop via list selection**
- Given I am viewing the stop list
- When I click on a stop name
- Then the stop details panel opens for editing

**AC-STOP-015: Edit stop via map selection**
- Given I am viewing the stops map
- When I click on a stop pin
- Then the stop details panel opens for editing

**AC-STOP-016: Drag stop to new location**
- Given I am viewing the stop details with map
- When I drag the stop pin to a new location
- Then the latitude and longitude fields update to reflect the new position

**AC-STOP-017: Save stop changes**
- Given I have made changes to a stop
- When I click the Save button
- Then my changes are persisted
- And a success confirmation is displayed

**AC-STOP-018: Unsaved changes warning**
- Given I have unsaved changes to a stop
- When I navigate away without saving
- Then the system warns me about unsaved changes
- And gives me the option to save or discard

### 4.5 Location Type and Hierarchy

**AC-STOP-019: Set location type**
- Given I am editing a stop
- When I change the Location Type field
- Then the available fields update based on the selected type
- And parent_station field appears/disappears appropriately

**AC-STOP-020: Station cannot have parent**
- Given I am creating or editing a station (location_type = 1)
- Then the Parent Station field is disabled/hidden
- And any existing parent_station value is cleared

**AC-STOP-021: Entrance requires parent station**
- Given I am creating or editing an entrance (location_type = 2)
- When I attempt to save without a parent station
- Then the system displays a validation error
- And the record is not saved

**AC-STOP-022: Parent station dropdown shows stations only**
- Given I am editing a stop's Parent Station field
- When I view the dropdown options
- Then only records with location_type = 1 (Station) are available for selection

### 4.6 Fare Zones

**AC-STOP-023: View zone list**
- Given I navigate to the Stop Zones sub-section
- When the page loads
- Then I see a list of all defined fare zones with their names

**AC-STOP-024: Create fare zone**
- Given I am in the Stop Zones sub-section
- When I click "Add Zone" and enter a zone name
- Then a new zone record is created
- And it appears in the zone list and zone dropdown

**AC-STOP-025: Assign stop to zone**
- Given I am editing a stop
- When I select a zone from the Zone dropdown
- And I save the stop
- Then the stop is associated with that zone
- And the zone_id is included in GTFS export

**AC-STOP-026: Unassign stop from zone**
- Given I am editing a stop assigned to a zone
- When I select "No zone selected" from the Zone dropdown
- And I save the stop
- Then the stop's zone assignment is removed

### 4.7 Stop Usage and Deletion

**AC-STOP-027: View stop usage details**
- Given I am viewing a stop's details
- When I click "Stop Usage Details"
- Then I see a list of all routes and patterns that use this stop
- And patterns are grouped by route

**AC-STOP-028: Navigate from usage to pattern**
- Given I am viewing stop usage details
- When I click on a pattern name
- Then I navigate to that pattern's detail page

**AC-STOP-029: Delete unused stop**
- Given I am viewing a stop that is not used in any patterns
- When I click "Delete Stop" and confirm
- Then the stop is permanently removed
- And it no longer appears in the stop list

**AC-STOP-030: Cannot delete stop in use**
- Given I am viewing a stop that is used in one or more patterns
- When I attempt to delete the stop
- Then the system displays an error indicating the stop is in use
- And the stop is not deleted

**AC-STOP-031: Delete stop from list**
- Given I am viewing the stop list
- When I click the delete icon (red "x") for an unused stop
- And I confirm the deletion
- Then the stop is removed from the list

### 4.8 Stop Activation Status

**AC-STOP-032: Mark stop inactive**
- Given I am viewing a stop that is not used in any active patterns
- When I click the inactive checkbox
- Then the stop is marked as inactive
- And it is excluded from future GTFS exports
- And it remains visible in the stop inventory

**AC-STOP-033: Cannot inactivate stop in active pattern**
- Given I am viewing a stop that is used in active patterns
- When I attempt to mark it inactive
- Then the system displays a message indicating the stop must first be removed from active patterns

**AC-STOP-034: Reactivate inactive stop**
- Given I am viewing an inactive stop
- When I uncheck the inactive checkbox
- Then the stop is marked as active
- And it will be included in future GTFS exports

### 4.9 Wheelchair Accessibility

**AC-STOP-035: Set wheelchair boarding status**
- Given I am editing a stop
- When I set the Wheelchair Boarding field to "Accessible", "Not Accessible", or "No Information"
- And I save the stop
- Then the wheelchair_boarding value is stored
- And it is included in the GTFS export

### 4.10 Data Validation

**AC-STOP-036: Latitude range validation**
- Given I am editing stop coordinates
- When I enter a latitude outside the range -90.0 to 90.0
- Then the system displays a validation error
- And the stop cannot be saved

**AC-STOP-037: Longitude range validation**
- Given I am editing stop coordinates
- When I enter a longitude outside the range -180.0 to 180.0
- Then the system displays a validation error
- And the stop cannot be saved

**AC-STOP-038: Flag nearby stops for review**
- Given two stops are located within close proximity (e.g., 10 meters)
- When viewing these stops
- Then they are flagged with a "Needs Review" indicator
- And a message suggests they may need to be merged

**AC-STOP-039: URL format validation**
- Given I am editing a stop's URL field
- When I enter an invalid URL format
- Then the system displays a validation error
- And the stop cannot be saved until corrected

### 4.11 Station Features

**AC-STOP-040: Create station**
- Given I am creating a new stop
- When I set Location Type to "Station"
- Then the Parent Station field is disabled
- And the stop is created as a station with no parent

**AC-STOP-041: View station child stops**
- Given I am viewing a station's details
- Then I see a list of all stops/platforms assigned to this station as their parent

**AC-STOP-042: Station coordinates represent center**
- Given I am creating or editing a station
- Then the help text indicates coordinates should represent the central location of the station complex

### 4.12 Integration Points

**AC-STOP-043: Stops available in pattern editor**
- Given I have created and saved a stop
- When I edit a route pattern
- Then the new stop is available for insertion into the pattern

**AC-STOP-044: Transfer definition references stops**
- Given I am defining a transfer at a stop
- When I specify the transfer stop
- Then I can select from the existing stop inventory

**AC-STOP-045: GTFS export includes all active stops**
- Given I have active stops in my inventory
- When I export GTFS
- Then stops.txt contains all active stops with required fields populated
- And inactive stops are excluded from the export

---

## 5. Non-Functional Requirements

### 5.1 Performance
- Stop list must load within 2 seconds for inventories up to 5,000 stops
- Map must render stop pins within 3 seconds for inventories up to 5,000 stops
- Search and filter operations must return results within 500ms

### 5.2 Usability
- Map interactions must follow standard web mapping conventions (scroll to zoom, drag to pan)
- Save buttons must use high-visibility styling (bright green) per existing UI conventions
- Delete operations must require confirmation to prevent accidental data loss
- Coordinate entry must accept common formats (decimal degrees, degree-minute-second with auto-conversion)

### 5.3 Data Integrity
- Stop deletion must be prevented while stop is referenced by any pattern
- Location type changes must enforce GTFS hierarchy rules
- System must maintain referential integrity between stations and child stops

### 5.4 Accessibility
- All form fields must have associated labels
- Map must provide alternative text-based stop browsing for screen reader users
- Color-coding must not be the sole indicator of status (use icons or text labels)

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The stop list prioritizes data visibility. Avoid decorative elements, chartjunk, or visual noise that doesn't convey information.

**Grid System:** List views and forms follow a consistent grid. Map and data panel layouts use a predictable split.

**Typography:** Use system sans-serif fonts. Stop names display in standard weight; field labels in lighter weight for hierarchy.

**Color for Information:** Use color to encode status (active/inactive, accessibility status) rather than decoration. Maintain high contrast for readability.

**Plain Language:** Field labels and help text use plain, direct language. Avoid transit jargon where standard terms suffice.

**Input Efficiency:** Minimize clicks. Auto-populate where possible. Support keyboard navigation through forms.

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Stop management belongs to a `Stops` context that encapsulates all stop-related business logic. The context owns `Stop`, `Zone`, and related schemas.

**Data Validation:** Use Ecto changesets with explicit validations. Return tagged tuples (`{:ok, stop}` or `{:error, changeset}`) from context functions.

**LiveView Architecture:** Stop list and map views implement as LiveView. Use streams for the stop list to handle large inventories efficiently. Delegate to function components for reusable UI elements.

**Real-Time Updates:** Use Phoenix PubSub to broadcast stop changes. Multiple users editing the same dataset see updates without manual refresh.

**Testing Strategy:** 
- Context tests validate business rules (hierarchy enforcement, required fields)
- LiveView tests verify user flows (create, edit, delete)
- Focus on behavior over implementation
