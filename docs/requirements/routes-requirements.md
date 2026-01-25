# Routes Requirements Document

**Section:** Routes  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The Routes section manages the `routes.txt` file, one of the required files in the GTFS specification. This file defines transit routes—the public-facing service lines that riders recognize, such as "Route 44," "Red Line," or "Airport Express." Routes serve as the organizational container for patterns, trips, and schedules.

### 1.1 Core Data Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `route_id` | Unique ID | Required | Unique identifier for the route. |
| `agency_id` | Foreign ID | Conditionally Required | References the operating agency. Required if multiple agencies exist in the dataset. |
| `route_short_name` | Text | Conditionally Required | Short abstract identifier (e.g., "32", "100X", "Green"). Should be no longer than 12 characters. Required if `route_long_name` is empty. |
| `route_long_name` | Text | Conditionally Required | Full descriptive name, often including destination or corridor (e.g., "Downtown - Airport Express"). Required if `route_short_name` is empty. |
| `route_desc` | Text | Optional | Description providing useful, quality information. Must not duplicate `route_short_name` or `route_long_name`. |
| `route_type` | Enum | Required | Indicates transportation mode: 0=Tram/Light Rail, 1=Subway/Metro, 2=Rail, 3=Bus, 4=Ferry, 5=Cable Tram, 6=Aerial Lift, 7=Funicular, 11=Trolleybus, 12=Monorail. |
| `route_url` | URL | Optional | URL of a route-specific web page. Must differ from `agency.agency_url`. |
| `route_color` | Color | Optional | Hexadecimal color matching public-facing materials. Defaults to white (FFFFFF) when empty. |
| `route_text_color` | Color | Optional | Legible text color for display against `route_color`. Defaults to black (000000) when empty. Must provide sufficient contrast. |
| `route_sort_order` | Non-negative Integer | Optional | Orders routes for customer-facing presentation. Lower values display first. |
| `continuous_pickup` | Enum | Conditionally Forbidden | Indicates continuous stopping pickup behavior: 0=Continuous stopping, 1/empty=No continuous stopping, 2=Phone agency, 3=Coordinate with driver. |
| `continuous_drop_off` | Enum | Conditionally Forbidden | Indicates continuous stopping drop-off behavior. Same values as `continuous_pickup`. |
| `network_id` | ID | Conditionally Forbidden | Groups routes into fare networks. Forbidden if `route_networks.txt` or `networks.txt` exists. |

### 1.2 Route Naming Convention

GTFS requires at least one of `route_short_name` or `route_long_name` to be populated. The specification recommends the following approach:

- **`route_short_name`**: The commonly-known passenger identifier, typically displayed on vehicles and signage. Keep under 12 characters.
- **`route_long_name`**: The descriptive name that helps riders understand the route's purpose or corridor.

Both fields may be populated simultaneously when agencies use both a numeric identifier and a descriptive name.

### 1.3 Route Types

The `route_type` field categorizes service by transportation mode, which affects how trip planners display and filter routes:

| Value | Mode | Description |
|-------|------|-------------|
| 0 | Tram/Streetcar/Light Rail | Street-level rail within metropolitan areas |
| 1 | Subway/Metro | Underground rail systems |
| 2 | Rail | Intercity or long-distance rail |
| 3 | Bus | Short and long-distance bus service |
| 4 | Ferry | Water transport |
| 5 | Cable Tram | Street-level cable cars |
| 6 | Aerial Lift | Gondolas, aerial tramways |
| 7 | Funicular | Rail systems for steep inclines |
| 11 | Trolleybus | Electric buses with overhead wires |
| 12 | Monorail | Single-rail or beam railways |

### 1.4 Operational Implications

#### Trip Planner Display
Route color and text color directly affect how routes appear in consumer applications. Colors that match public-facing materials create consistency between physical signage and digital trip planners. Insufficient color contrast makes route badges unreadable, particularly for riders with visual impairments.

#### Route Organization
The `route_sort_order` field controls how routes appear in customer-facing lists. Agencies typically order routes by importance, numeric sequence, or geographic coverage. Inconsistent sort orders create confusion when riders compare printed materials to app displays.

#### Multi-Agency Feeds
When a GTFS dataset contains multiple agencies, each route must reference its operating `agency_id`. Missing agency references cause data consumers to reject routes or display them without agency context.

#### Service Types
Special route classifications (loop routes, school tripper routes, academic routes) require consistent configuration to display correctly in trip planners:

- **Loop Routes**: Begin and end at the same stop with no obvious directionality. Require "No Direction" or custom direction labels like "Clockwise."
- **School Tripper Routes**: Supplemental service for school dismissal times. May operate only on school days.
- **Academic Routes**: Seasonal service aligned with academic calendars. Should remain active even when not currently operating to show future service.

#### Continuous Stopping
Routes with flag stops or deviated service use `continuous_pickup` and `continuous_drop_off` to indicate riders can board or alight anywhere along the route alignment. This configuration requires a corresponding shape (`shapes.txt`) to define the travel path.

#### Data Consumers
Route data flows to Google Maps, Apple Maps, Transit App, and other platforms. Route naming, colors, and mode classifications affect millions of rider searches. Inconsistencies between GTFS data and public materials erode rider trust.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Route Creation

**JS-ROUTE-001: Creating a new fixed-route service**
When my agency launches a new bus line, I want to create a route with its public identifier and colors, so I can begin building patterns and schedules for the service.

**JS-ROUTE-002: Creating a route from existing service**
When I'm restructuring service and renaming an existing line, I want to create a new route and migrate patterns from the old route, so I can preserve schedule data while updating public-facing information.

**JS-ROUTE-003: Setting up routes for a new mode**
When my agency launches ferry service alongside existing bus routes, I want to create routes with the appropriate mode classification, so I can ensure trip planners filter and display the new service correctly.

### 2.2 Route Configuration

**JS-ROUTE-004: Matching brand colors**
When my agency uses specific colors in public materials, I want to set route colors using the exact hexadecimal values from our branding, so I can maintain visual consistency between our website and trip planning apps.

**JS-ROUTE-005: Ensuring color accessibility**
When selecting route text color, I want to see whether my color combination meets contrast requirements, so I can ensure readability for all riders.

**JS-ROUTE-006: Organizing routes for display**
When my agency has many routes, I want to set display order values, so I can control how routes appear in customer-facing applications like our website and Google Maps.

**JS-ROUTE-007: Linking to route information**
When my agency maintains route-specific web pages, I want to associate URLs with routes, so I can direct riders from trip planners to detailed schedule and fare information.

### 2.3 Route Editing

**JS-ROUTE-008: Updating route names**
When my agency rebrands a service line, I want to update the route's short name and long name, so I can reflect the new public identity without recreating patterns and schedules.

**JS-ROUTE-009: Correcting route colors**
When I discover route colors don't match our printed materials, I want to update the color values, so I can fix the inconsistency before the next GTFS publish.

**JS-ROUTE-010: Changing route mode**
When service characteristics change (e.g., bus route converted to BRT), I want to update the route type, so I can ensure trip planners categorize the service correctly.

### 2.4 Route Organization

**JS-ROUTE-011: Filtering large route inventories**
When my agency operates dozens of routes, I want to filter the route list by mode, agency, or active status, so I can find specific routes without scrolling through the entire list.

**JS-ROUTE-012: Sorting routes by different criteria**
When reviewing routes, I want to sort by name, ID, agency, or display order, so I can organize the list according to my current task.

**JS-ROUTE-013: Identifying routes needing attention**
When preparing a GTFS publish, I want to see routes flagged for missing required fields or data quality issues, so I can prioritize corrections before export.

### 2.5 Route State Management

**JS-ROUTE-014: Suspending seasonal service**
When a seasonal route ends for the year, I want to mark it inactive without deleting it, so I can preserve the route configuration for reactivation next season.

**JS-ROUTE-015: Understanding route usage before deletion**
When considering deleting a route, I want to see all patterns and scheduled trips that use it, so I can assess the impact and ensure I'm not breaking active service definitions.

**JS-ROUTE-016: Managing academic routes**
When maintaining routes that only operate during school terms, I want to keep routes active year-round while controlling which calendars have scheduled service, so I can show future service availability to riders.

### 2.6 Special Route Types

**JS-ROUTE-017: Configuring loop routes**
When a route operates as a circulator with no obvious directionality, I want to designate it as a loop route, so I can apply appropriate direction labels and ensure patterns start and end at the same stop.

**JS-ROUTE-018: Configuring continuous stopping**
When a route allows flag stops or deviated service along its alignment, I want to enable continuous pickup/drop-off at the route level, so I can indicate this service characteristic to riders.

**JS-ROUTE-019: Configuring school tripper service**
When I operate supplemental school service, I want to configure routes appropriately, so I can communicate to riders that this service targets school dismissal times.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Route Inventory Management

**US-ROUTE-001: View route list**
As a schedule editor, I want to view all routes in a sortable, searchable list, so that I can quickly locate routes by name, ID, or other attributes.

**US-ROUTE-002: Filter route list**
As a schedule editor, I want to filter routes by mode, agency, and active status, so that I can focus on relevant subsets of a large route inventory.

**US-ROUTE-003: Sort route list**
As a schedule editor, I want to sort routes by any column header, so that I can organize the list according to my current task.

**US-ROUTE-004: Search routes**
As a schedule editor, I want to search routes by name or short identifier, so that I can find specific routes quickly.

**US-ROUTE-005: View route display preview**
As a schedule editor, I want to see a preview of how route badges will appear (color, text color, short name), so that I can verify visual appearance before publishing.

### 3.2 Route Creation

**US-ROUTE-006: Create new route**
As a schedule editor, I want to create a new route by entering required fields, so that I can begin defining patterns and schedules for a new service.

**US-ROUTE-007: Validate route names**
As a schedule editor, I want the system to validate that at least one of short name or long name is provided, so that I can ensure GTFS compliance.

**US-ROUTE-008: Select route mode**
As a schedule editor, I want to select a route type from a picklist of transportation modes, so that I can correctly categorize the service.

**US-ROUTE-009: Set route colors via picker**
As a schedule editor, I want to select route colors using a color picker, so that I can set colors without knowing hexadecimal values.

**US-ROUTE-010: Enter route colors via hex code**
As a schedule editor, I want to enter route colors as hexadecimal codes, so that I can precisely match brand specifications.

### 3.3 Route Details

**US-ROUTE-011: Edit route short name**
As a schedule editor, I want to edit a route's short identifier, so that I can update public-facing display names.

**US-ROUTE-012: Edit route long name**
As a schedule editor, I want to edit a route's descriptive name, so that I can update corridor or destination information.

**US-ROUTE-013: Edit route description**
As a schedule editor, I want to edit a route's description, so that I can provide additional context that doesn't fit in the name fields.

**US-ROUTE-014: Edit route URL**
As a schedule editor, I want to set or update a route's web page URL, so that I can link riders to detailed route information.

**US-ROUTE-015: Edit route colors**
As a schedule editor, I want to edit route color and text color, so that I can update visual branding.

**US-ROUTE-016: Edit route sort order**
As a schedule editor, I want to set a route's display sort order, so that I can control presentation sequence in customer-facing applications.

**US-ROUTE-017: Change route mode**
As a schedule editor, I want to change a route's transportation type, so that I can correct miscategorizations or reflect service changes.

**US-ROUTE-018: Assign route to agency**
As a schedule editor, I want to assign a route to an operating agency, so that I can correctly attribute service in multi-agency feeds.

**US-ROUTE-019: Save route changes**
As a schedule editor, I want to save my route edits, so that my changes are persisted to the database.

### 3.4 Route Usage

**US-ROUTE-020: View route patterns**
As a schedule editor, I want to view all patterns defined for a route, so that I can understand the route's stop sequence variations.

**US-ROUTE-021: View route schedules**
As a schedule editor, I want to view all scheduled trips for a route, so that I can understand the route's service span and frequency.

**US-ROUTE-022: Navigate to patterns from route**
As a schedule editor, I want to click through to the Patterns tab from the route list, so that I can efficiently navigate to stop pattern configuration.

**US-ROUTE-023: Navigate to schedules from route**
As a schedule editor, I want to click through to the Schedules tab from the route list, so that I can efficiently navigate to trip scheduling.

### 3.5 Route Deletion and Deactivation

**US-ROUTE-024: Mark route inactive**
As a schedule editor, I want to mark a route as inactive, so that it remains in my inventory but is excluded from GTFS exports.

**US-ROUTE-025: Reactivate inactive route**
As a schedule editor, I want to reactivate an inactive route, so that I can restore service for seasonal or resumed routes.

**US-ROUTE-026: Delete unused route**
As a schedule editor, I want to delete a route that has no patterns or scheduled trips, so that I can remove obsolete data from my inventory.

**US-ROUTE-027: Prevent deletion of routes with data**
As a schedule editor, I want the system to prevent deletion of routes with active patterns or trips, so that I don't accidentally break existing service definitions.

### 3.6 Continuous Stopping Configuration

**US-ROUTE-028: Enable continuous pickup**
As a schedule editor, I want to enable continuous stopping pickup for a route, so that I can indicate riders may board anywhere along the route alignment.

**US-ROUTE-029: Enable continuous drop-off**
As a schedule editor, I want to enable continuous stopping drop-off for a route, so that I can indicate riders may alight anywhere along the route alignment.

**US-ROUTE-030: Specify continuous stopping behavior**
As a schedule editor, I want to specify whether continuous stopping requires driver coordination or agency phone call, so that I can communicate the boarding process to riders.

### 3.7 Data Quality

**US-ROUTE-031: View routes needing review**
As a schedule editor, I want to see routes flagged for data quality issues (missing colors, insufficient contrast, missing names), so that I can prioritize corrections.

**US-ROUTE-032: Validate color contrast**
As a schedule editor, I want the system to warn me when route color and text color have insufficient contrast, so that I can ensure readability.

---

## 4. Acceptance Criteria

### 4.1 Route List View

**AC-ROUTE-001: Route list displays required columns**
- Given I navigate to the Routes section
- When the route list loads
- Then I see columns for: Route Name (with color badge), Short Identifier, Mode, Agency, and active status indicator
- And the list displays all routes in the current dataset

**AC-ROUTE-002: Route list is sortable**
- Given I am viewing the route list
- When I click on any column header
- Then the list sorts by that column in ascending order
- And clicking the same header again sorts in descending order

**AC-ROUTE-003: Route list is filterable**
- Given I am viewing the route list
- When I apply filters for mode, agency, or active status
- Then only routes matching the filter criteria are displayed
- And I can combine multiple filters

**AC-ROUTE-004: Route list supports search**
- Given I am viewing the route list
- When I enter text in the search field
- Then the list filters to show routes whose name or short identifier contains the search text

**AC-ROUTE-005: Route badge preview**
- Given I am viewing the route list
- Then each route displays a color badge showing route_color with route_short_name in route_text_color
- And the badge accurately represents how the route will appear in trip planners

### 4.2 Route Creation

**AC-ROUTE-006: Create route via Add Route button**
- Given I am viewing the Routes Dashboard
- When I click the "Add a Route" button
- Then a dialog appears with fields for route configuration
- And I can enter route details and save

**AC-ROUTE-007: Route short name or long name required**
- Given I am creating a route
- When I attempt to save without either short name or long name
- Then the system displays a validation error
- And the route is not saved

**AC-ROUTE-008: Route type is required**
- Given I am creating a route
- When I attempt to save without selecting a route type
- Then the system displays a validation error indicating route type is required
- And the route is not saved

**AC-ROUTE-009: Route ID auto-generation**
- Given I am creating a new route
- When I save the route
- Then the system generates a unique route_id
- And the route_id is visible in the route details

**AC-ROUTE-010: Duplicate short name warning**
- Given I am creating or editing a route
- When I enter a short name that already exists for another route
- Then the system displays a warning (not blocking) about the duplicate
- And I can proceed with saving if intentional

### 4.3 Route Editing

**AC-ROUTE-011: Edit route via list selection**
- Given I am viewing the route list
- When I click on a route name
- Then the route details page opens for editing

**AC-ROUTE-012: Edit route short name**
- Given I am editing a route
- When I modify the short name field and save
- Then the updated short name is persisted
- And the route badge preview updates to reflect the change

**AC-ROUTE-013: Edit route long name**
- Given I am editing a route
- When I modify the long name field and save
- Then the updated long name is persisted

**AC-ROUTE-014: Clear one name when other is provided**
- Given I am editing a route with both short name and long name
- When I clear the short name field and save
- Then the route saves successfully with only the long name
- And the GTFS export uses route_long_name

**AC-ROUTE-015: Save route changes**
- Given I have made changes to a route
- When I click the Save button
- Then my changes are persisted
- And a success confirmation is displayed

**AC-ROUTE-016: Unsaved changes warning**
- Given I have unsaved changes to a route
- When I navigate away without saving
- Then the system warns me about unsaved changes
- And gives me the option to save or discard

### 4.4 Route Colors

**AC-ROUTE-017: Set route color via picker**
- Given I am editing a route
- When I click the color picker for Route Color
- Then a color selection interface appears
- And selecting a color updates the route_color field

**AC-ROUTE-018: Set route color via hex entry**
- Given I am editing a route
- When I enter a 6-character hexadecimal value in the Route Color field
- Then the color preview updates to show the specified color

**AC-ROUTE-019: Invalid hex color validation**
- Given I am editing a route
- When I enter an invalid hexadecimal color value
- Then the system displays a validation error
- And the route cannot be saved until corrected

**AC-ROUTE-020: Set text color**
- Given I am editing a route
- When I set the Text Color field
- Then the route badge preview updates to show text in the specified color against the route color background

**AC-ROUTE-021: Default colors when empty**
- Given I am creating a route
- When I leave Route Color empty
- Then the GTFS export uses FFFFFF (white) for route_color
- And when Text Color is empty, the export uses 000000 (black) for route_text_color

**AC-ROUTE-022: Color contrast warning**
- Given I am editing route colors
- When route_color and route_text_color have insufficient contrast for accessibility
- Then the system displays a warning about low contrast
- And I can still save but am informed of the accessibility issue

### 4.5 Route Mode

**AC-ROUTE-023: Select route type from picklist**
- Given I am creating or editing a route
- When I click the Route Type dropdown
- Then I see options for: Tram, Subway, Rail, Bus, Ferry, Cable Tram, Aerial Lift, Funicular, Trolleybus, Monorail

**AC-ROUTE-024: Route type displays mode name**
- Given I am viewing the route list
- Then the Mode column displays the human-readable mode name (e.g., "Bus") not the numeric code

**AC-ROUTE-025: Change route type**
- Given I am editing an existing route
- When I change the route type and save
- Then the updated route type is persisted
- And the mode column reflects the change

### 4.6 Route Sort Order

**AC-ROUTE-026: Set route sort order**
- Given I am editing a route
- When I enter a value in the Preferred Display Order field
- And I save the route
- Then the route_sort_order is persisted

**AC-ROUTE-027: Sort order affects display**
- Given multiple routes have sort_order values
- When viewing routes sorted by "Preferred Display Order"
- Then routes with lower values appear first
- And routes without sort_order appear after those with values

**AC-ROUTE-028: Sort order validation**
- Given I am editing a route
- When I enter a negative number for sort order
- Then the system displays a validation error
- And the route cannot be saved until corrected

### 4.7 Route URL

**AC-ROUTE-029: Set route URL**
- Given I am editing a route
- When I enter a URL in the Route URL field
- And I save the route
- Then the route_url is persisted

**AC-ROUTE-030: URL format validation**
- Given I am editing a route
- When I enter an invalid URL format
- Then the system displays a validation error
- And the route cannot be saved until corrected

**AC-ROUTE-031: Route URL different from agency URL**
- Given I am editing a route
- When I enter a URL identical to the agency's agency_url
- Then the system displays a warning that route URL should be route-specific
- And I can acknowledge and proceed

### 4.8 Route Deletion and Deactivation

**AC-ROUTE-032: Mark route inactive**
- Given I am viewing a route that has no active scheduled trips
- When I toggle the route to inactive
- Then the route is marked as inactive
- And it is excluded from future GTFS exports
- And it remains visible in the route inventory

**AC-ROUTE-033: Inactive routes display indicator**
- Given the route list contains inactive routes
- When viewing the route list
- Then inactive routes display a visual indicator (e.g., grayed out, "Inactive" badge)

**AC-ROUTE-034: Reactivate inactive route**
- Given I am viewing an inactive route
- When I toggle the route to active
- Then the route is marked as active
- And it will be included in future GTFS exports

**AC-ROUTE-035: Delete unused route**
- Given I am viewing a route that has no patterns or scheduled trips
- When I click "Delete Route" and confirm
- Then the route is permanently removed
- And it no longer appears in the route list

**AC-ROUTE-036: Cannot delete route with patterns**
- Given I am viewing a route that has one or more patterns defined
- When I attempt to delete the route
- Then the system displays an error indicating the route has patterns
- And the route is not deleted
- And I am informed to delete patterns first

**AC-ROUTE-037: Cannot delete route with trips**
- Given I am viewing a route that has scheduled trips
- When I attempt to delete the route
- Then the system displays an error indicating the route has scheduled trips
- And the route is not deleted

### 4.9 Route Navigation

**AC-ROUTE-038: Navigate to Route Details**
- Given I am viewing the route list
- When I click on a route
- Then I navigate to the Route Details tab for that route

**AC-ROUTE-039: Navigate to Patterns**
- Given I am viewing a route's details
- When I click the "Patterns" tab or link
- Then I navigate to the Patterns view for that route

**AC-ROUTE-040: Navigate to Schedules**
- Given I am viewing a route's details
- When I click the "Schedules" tab or link
- Then I navigate to the Schedules view for that route

**AC-ROUTE-041: Patterns link displays count**
- Given I am viewing the route list
- Then each route displays the number of patterns defined
- And clicking this navigates to the Patterns tab

### 4.10 Continuous Stopping

**AC-ROUTE-042: Enable continuous pickup**
- Given I am editing a route
- When I set Continuous Pickup to a value other than "No continuous stopping"
- And I save the route
- Then the continuous_pickup value is persisted

**AC-ROUTE-043: Enable continuous drop-off**
- Given I am editing a route
- When I set Continuous Drop-off to a value other than "No continuous stopping"
- And I save the route
- Then the continuous_drop_off value is persisted

**AC-ROUTE-044: Continuous stopping requires shape**
- Given I am enabling continuous pickup or drop-off for a route
- When the route's patterns do not have associated shapes
- Then the system displays a warning that continuous stopping requires shape data
- And I am informed that trips must have shapes defined

### 4.11 Multi-Agency Support

**AC-ROUTE-045: Assign route to agency**
- Given the dataset contains multiple agencies
- When I create or edit a route
- Then an Agency dropdown is displayed
- And I must select the operating agency

**AC-ROUTE-046: Agency required for multi-agency feeds**
- Given the dataset contains multiple agencies
- When I attempt to save a route without selecting an agency
- Then the system displays a validation error
- And the route cannot be saved

**AC-ROUTE-047: Single agency auto-assignment**
- Given the dataset contains only one agency
- When I create a route
- Then the agency_id is automatically assigned
- And the Agency field may be hidden or displayed as read-only

### 4.12 Data Quality

**AC-ROUTE-048: Flag routes missing required fields**
- Given a route is missing route_type
- When viewing the route list
- Then the route displays a "Needs Review" indicator

**AC-ROUTE-049: Flag routes with no patterns**
- Given a route has no patterns defined
- When viewing the route list
- Then the route displays an indicator showing "0 patterns"
- And this serves as a reminder to complete route configuration

**AC-ROUTE-050: GTFS export includes all active routes**
- Given I have active routes in my inventory
- When I export GTFS
- Then routes.txt contains all active routes with required fields populated
- And inactive routes are excluded from the export

---

## 5. Non-Functional Requirements

### 5.1 Performance
- Route list must load within 2 seconds for inventories up to 500 routes
- Search and filter operations must return results within 500ms
- Color picker interactions must respond within 100ms

### 5.2 Usability
- Save buttons must use high-visibility styling (bright green) per existing UI conventions
- Delete operations must require confirmation to prevent accidental data loss
- Color fields must accept both picker selection and direct hex entry
- Route badge preview must update in real-time as colors are changed

### 5.3 Data Integrity
- Route deletion must be prevented while route has patterns or scheduled trips
- System must maintain referential integrity between routes and patterns
- Agency assignment must be enforced for multi-agency datasets

### 5.4 Accessibility
- All form fields must have associated labels
- Color contrast warnings must be provided for route color combinations
- Route badges must not rely solely on color to convey information (include text)

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** The route list prioritizes data visibility. Route badges encode color and name information efficiently. Avoid decorative elements that don't convey route information.

**Grid System:** List views and forms follow a consistent grid. Route details use a predictable form layout with clear field groupings.

**Typography:** Use system sans-serif fonts. Route names display in standard weight; field labels in lighter weight for hierarchy. Short identifiers may display in bold within badges.

**Color for Information:** Route colors are functional data, not decoration. The route badge directly represents how routes appear in trip planners. Color contrast warnings ensure accessibility compliance.

**Plain Language:** Field labels use plain, direct language. "Short Identifier" instead of "route_short_name." Help text explains GTFS implications in rider-focused terms.

**Input Efficiency:** Minimize clicks. Provide both color picker and hex entry. Auto-generate route_id. Support keyboard navigation through forms.

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** Route management belongs to a `Routes` context that encapsulates all route-related business logic. The context owns `Route` and related schemas. Cross-context communication with `Patterns` and `Trips` contexts uses public functions.

**Data Validation:** Use Ecto changesets with explicit validations:
- At least one of `route_short_name` or `route_long_name` required
- `route_type` required and within valid enum range
- Color fields validate as 6-character hexadecimal
- URL fields validate format
- `route_sort_order` must be non-negative integer when present

Return tagged tuples (`{:ok, route}` or `{:error, changeset}`) from context functions.

**LiveView Architecture:** Route list implements as LiveView. Use streams for the route list to handle large inventories efficiently. Delegate to function components for route badges and reusable UI elements.

**Real-Time Updates:** Use Phoenix PubSub to broadcast route changes. Multiple users editing the same dataset see updates without manual refresh.

**Testing Strategy:**
- Context tests validate business rules (required fields, color validation, deletion constraints)
- LiveView tests verify user flows (create, edit, delete, navigation)
- Focus on behavior over implementation
- Test GTFS export integration to verify correct field mapping
