# System Configuration Requirements Document

**Section:** System Configuration  
**Version:** 1.0  
**Status:** Draft

---

## 1. GTFS Data Overview

The System Configuration section manages the foundational organizational entities that define a GTFS feed: agencies, feed metadata, and export settings. This section governs two GTFS files—`agency.txt` (required) and `feed_info.txt` (conditionally required)—along with system-level export configurations that affect how identifiers appear across the entire dataset.

### 1.1 Agency Data Fields (agency.txt)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `agency_id` | Unique ID | Conditionally Required | Identifies a transit brand, often synonymous with a transit agency. Required when the dataset contains data for multiple agencies; recommended otherwise. |
| `agency_name` | Text | Required | Full name of the transit agency as it should appear to riders. |
| `agency_url` | URL | Required | Top-level homepage URL for the transit agency. |
| `agency_timezone` | Timezone | Required | Timezone where the transit agency is located. All agencies in a multi-agency feed must share the same timezone. |
| `agency_lang` | Language Code | Optional | Primary language used by the agency. Helps GTFS consumers choose capitalization rules and language-specific settings. |
| `agency_phone` | Phone Number | Optional | Voice telephone number for the agency, formatted as typical for the service area. May include punctuation and dialable text (e.g., "503-238-RIDE"). |
| `agency_fare_url` | URL | Optional | URL to a web page where riders can purchase tickets or find fare information for the agency. |
| `agency_email` | Email | Optional | Customer service email address actively monitored by the agency. |

### 1.2 Feed Information Data Fields (feed_info.txt)

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `feed_publisher_name` | Text | Required | Full name of the organization publishing the dataset. May differ from agency names if a third party publishes the feed. |
| `feed_publisher_url` | URL | Required | URL of the publishing organization's website. May be the same as an agency URL. |
| `feed_lang` | Language Code | Required | Default language for text in the dataset. Use "mul" for multilingual datasets with translations.txt. |
| `default_lang` | Language Code | Optional | Language to use when the data consumer doesn't know the rider's language. Often "en" (English). |
| `feed_start_date` | Date | Recommended | Start of the period for which the dataset provides complete, reliable schedule information. |
| `feed_end_date` | Date | Recommended | End of the period for which the dataset provides complete, reliable schedule information. Must not precede feed_start_date. |
| `feed_version` | Text | Recommended | String indicating the current version of the dataset. Helps consumers verify they have incorporated the latest data. |
| `feed_contact_email` | Email | Optional | Technical contact email for GTFS-consuming applications (not customer service). |
| `feed_contact_url` | URL | Optional | Technical contact URL for communication regarding data publishing practices. |

### 1.3 Export Configuration Settings

Export settings control how identifiers are formatted in the GTFS output, primarily for real-time system integration.

| Setting | Options | Description |
|---------|---------|-------------|
| Stop ID Export Format | Internal ID / Stop Code | Determines whether `stop_id` exports as the system's internal identifier or the customer-facing stop code. |
| Block ID Export Format | Internal ID / Block Name | Determines whether `block_id` exports as the system's internal identifier or the user-assigned block name. |
| Route ID Export Format | Internal ID / Route Short Name | Determines whether `route_id` exports as the system's internal identifier or a derived value. |
| Interpolated Stop Times | Enabled / Disabled | When enabled, exports estimated arrival times for all stops, including those without explicit timepoints. |
| GTFS-flex | Enabled / Disabled | Enables export of GTFS-flex extensions for deviated-route and dial-a-ride services. |

### 1.4 Hierarchical Relationships

The system employs a three-tier hierarchy:

```
Feed (Dataset container)
├── Agency (Public-facing transit provider)
│   ├── Routes (assigned to agency)
│   ├── Trips (inherited from routes)
│   └── Fares (assigned to agency)
└── Feed-Level Entities (shared across agencies)
    ├── Stops
    ├── Calendars
    ├── Blocks
    ├── Headsigns
    └── Directions
```

**Hierarchy Rules:**
- A feed contains one dataset at a time, updated periodically
- A feed may contain multiple agencies (consortiums, regional partnerships)
- Routes and fares are assigned to specific agencies
- Stops, calendars, and blocks are shared at the feed level across all agencies

### 1.5 Operational Implications

#### Data Consumer Integration
Feed URLs should remain stable over time. Data consumers like Google Maps, Apple Maps, and Transit App reference these URLs to fetch schedule updates. Changing a feed URL breaks integrations and requires re-registration with each consumer platform. The system should maintain a permanent, predictable feed URL.

#### Multi-Agency Coordination
When a feed contains multiple agencies, all agencies must share the same timezone. This constraint reflects operational reality—coordinated regional services operate on common schedules. The system must enforce timezone consistency across agencies within a feed.

#### Real-Time System Compatibility
Export format settings directly affect real-time integration with Automatic Vehicle Location (AVL) and Computer-Aided Dispatch (CAD) systems. When AVL systems reference stops by customer-facing codes, the GTFS must export `stop_code` as `stop_id` to maintain consistency between static and real-time feeds. Mismatched identifiers cause real-time arrival predictions to fail.

#### Version Tracking
The `feed_version` field enables data consumers to verify they have incorporated the latest dataset. Agencies publishing frequent updates should maintain a consistent versioning scheme (date-based, semantic versioning) so consumers can detect stale data.

#### Service Period Boundaries
`feed_start_date` and `feed_end_date` define the authoritative service period. Schedule data outside this range should be treated as provisional. The GTFS best practice requires feeds to cover at least 7 days of future service, with 30 days recommended. The system should warn when feed dates approach expiration.

#### Language and Accessibility
`feed_lang` affects how trip planning applications render text, including capitalization rules and text-to-speech pronunciation. For multilingual service areas, proper language configuration ensures riders receive information in appropriate languages.

---

## 2. Job Stories

Job Stories follow the Jobs to be Done framework format: **When [situation], I want to [motivation], so I can [expected outcome].**

### 2.1 Agency Configuration

**JS-CONFIG-001: Initial agency setup**
When I am setting up a new transit agency in the system, I want to enter the agency's public-facing details (name, URL, phone, timezone), so I can establish the identity that riders will see in trip planning applications.

**JS-CONFIG-002: Updating agency contact information**
When our agency's phone number or website changes, I want to update these details in the system, so I can ensure riders have accurate contact information in Google Maps and other applications.

**JS-CONFIG-003: Adding a fare information page**
When our agency publishes fare information online, I want to link that page to our agency configuration, so I can direct riders to purchase tickets or learn about fare options.

**JS-CONFIG-004: Configuring agency language**
When our agency serves a primarily non-English speaking community, I want to set the agency language, so I can ensure GTFS consumers apply appropriate language-specific formatting rules.

### 2.2 Multi-Agency Management

**JS-CONFIG-005: Adding a partner agency**
When a regional partner joins our consortium, I want to add their agency to our shared feed, so I can enable seamless trip planning across agency boundaries.

**JS-CONFIG-006: Differentiating agency branding**
When riders search for routes in a multi-agency region, I want each agency's routes to display under the correct brand name, so I can preserve distinct agency identities within the shared feed.

**JS-CONFIG-007: Ensuring timezone consistency**
When adding a new agency to a multi-agency feed, I want the system to enforce that all agencies share the same timezone, so I can avoid scheduling inconsistencies that confuse riders.

### 2.3 Feed Information

**JS-CONFIG-008: Identifying the feed publisher**
When data consumers need to contact us about data quality issues, I want the feed to include publisher contact information, so I can receive and respond to technical inquiries.

**JS-CONFIG-009: Setting feed validity dates**
When publishing a new schedule effective next month, I want to specify the feed's start and end dates, so I can communicate the authoritative service period to data consumers.

**JS-CONFIG-010: Versioning feed updates**
When I publish schedule updates, I want to increment the feed version, so I can help data consumers verify they've incorporated the latest dataset.

**JS-CONFIG-011: Configuring multilingual support**
When our service area spans multiple language communities, I want to set the feed language appropriately, so I can ensure proper text rendering across languages.

### 2.4 Export Settings

**JS-CONFIG-012: Aligning with real-time systems**
When our AVL system references stops by customer-facing codes, I want to export stop codes as stop_id, so I can ensure real-time arrivals match static schedule data.

**JS-CONFIG-013: Matching block identifiers**
When our dispatch system uses specific block naming conventions, I want to export block names as block_id, so I can maintain consistency between scheduling and operations systems.

**JS-CONFIG-014: Including interpolated times**
When riders need arrival estimates at all stops (not just timepoints), I want to enable interpolated stop time export, so I can provide complete arrival information throughout each trip.

**JS-CONFIG-015: Enabling demand-responsive service**
When our agency operates dial-a-ride or deviated-route services, I want to enable GTFS-flex export, so I can represent flexible service options to trip planning applications that support them.

### 2.5 Feed Publishing

**JS-CONFIG-016: Maintaining feed URL stability**
When data consumers register our feed URL, I want the URL to remain permanent, so I can avoid breaking integrations when I publish schedule updates.

**JS-CONFIG-017: Reviewing feed before export**
When preparing to publish a new dataset, I want to review feed configuration settings, so I can verify all metadata is current before distribution.

---

## 3. User Stories

User Stories follow Agile format: **As a [role], I want [feature], so that [benefit].**

### 3.1 Agency Management

**US-CONFIG-001: View agency list**
As a schedule editor, I want to view all agencies in the feed, so that I can understand the organizational structure of my dataset.

**US-CONFIG-002: View agency details**
As a schedule editor, I want to view an agency's complete configuration (name, URL, phone, timezone, language, fare URL), so that I can verify information is accurate.

**US-CONFIG-003: Edit agency name**
As a schedule editor, I want to edit an agency's public-facing name, so that I can correct errors or reflect rebranding.

**US-CONFIG-004: Edit agency URL**
As a schedule editor, I want to edit an agency's homepage URL, so that I can update links when websites change.

**US-CONFIG-005: Edit agency phone**
As a schedule editor, I want to edit an agency's customer service phone number, so that I can ensure riders can reach the agency.

**US-CONFIG-006: Edit agency timezone**
As a schedule editor, I want to set an agency's timezone, so that I can ensure schedules display in the correct local time.

**US-CONFIG-007: Edit agency language**
As a schedule editor, I want to set an agency's primary language, so that I can configure language-specific formatting for data consumers.

**US-CONFIG-008: Edit agency fare URL**
As a schedule editor, I want to set a URL for the agency's fare information, so that I can direct riders to ticket purchasing options.

**US-CONFIG-009: Edit agency email**
As a schedule editor, I want to set an agency's customer service email, so that I can provide riders an additional contact method.

### 3.2 Multi-Agency Feeds

**US-CONFIG-010: Add agency to feed**
As a schedule editor, I want to add a new agency to an existing feed, so that I can support regional partnerships or consortium arrangements.

**US-CONFIG-011: Remove agency from feed**
As a schedule editor, I want to remove an agency from a feed (after removing all associated routes), so that I can reorganize the feed structure when partnerships change.

**US-CONFIG-012: View agency route count**
As a schedule editor, I want to see how many routes are assigned to each agency, so that I can understand the scope of each agency's service.

### 3.3 Feed Information

**US-CONFIG-013: View feed information**
As a schedule editor, I want to view the feed's publisher information, language settings, and validity dates, so that I can verify metadata accuracy.

**US-CONFIG-014: Edit feed publisher name**
As a schedule editor, I want to set the feed publisher's organization name, so that I can identify who is responsible for the dataset.

**US-CONFIG-015: Edit feed publisher URL**
As a schedule editor, I want to set the feed publisher's website URL, so that I can direct technical contacts to the appropriate organization.

**US-CONFIG-016: Edit feed language**
As a schedule editor, I want to set the feed's default language, so that I can configure text rendering for data consumers.

**US-CONFIG-017: Edit feed validity dates**
As a schedule editor, I want to set the feed's start and end dates, so that I can define the authoritative service period.

**US-CONFIG-018: Edit feed version**
As a schedule editor, I want to set or update the feed version string, so that I can help data consumers track dataset updates.

**US-CONFIG-019: Edit feed contact email**
As a schedule editor, I want to set a technical contact email for the feed, so that I can receive data quality inquiries from GTFS consumers.

**US-CONFIG-020: Edit feed contact URL**
As a schedule editor, I want to set a technical contact URL for the feed, so that I can direct data-related inquiries to the appropriate support channel.

### 3.4 Export Settings

**US-CONFIG-021: View export settings**
As a schedule editor, I want to view current export configuration options, so that I can understand how identifiers will appear in the published GTFS.

**US-CONFIG-022: Configure stop ID export format**
As a schedule editor, I want to choose whether stop_id exports as internal ID or stop code, so that I can align with our real-time system's expectations.

**US-CONFIG-023: Configure block ID export format**
As a schedule editor, I want to choose whether block_id exports as internal ID or block name, so that I can match our dispatch system's identifier format.

**US-CONFIG-024: Configure route ID export format**
As a schedule editor, I want to choose whether route_id exports as internal ID or a derived identifier, so that I can maintain consistency with external systems.

**US-CONFIG-025: Toggle interpolated stop times**
As a schedule editor, I want to enable or disable interpolated stop time export, so that I can control whether estimated times appear for non-timepoint stops.

**US-CONFIG-026: Toggle GTFS-flex export**
As a schedule editor, I want to enable or disable GTFS-flex extensions, so that I can include demand-responsive service information when applicable.

### 3.5 Feed URL and Publishing

**US-CONFIG-027: View feed URL**
As a schedule editor, I want to view the permanent URL where the feed is published, so that I can share it with data consumers and verify registration.

**US-CONFIG-028: Copy feed URL**
As a schedule editor, I want to copy the feed URL to my clipboard, so that I can easily share it via email or registration forms.

---

## 4. Acceptance Criteria

### 4.1 Agency List View

**AC-CONFIG-001: Agency list displays required columns**
- Given I navigate to the System Configuration section
- When the agency list loads
- Then I see columns for: Agency Name, Agency URL, Timezone, and Routes count
- And the list displays all agencies in the current feed

**AC-CONFIG-002: Agency list is sortable**
- Given I am viewing the agency list
- When I click on any column header
- Then the list sorts by that column in ascending order
- And clicking the same header again sorts in descending order

**AC-CONFIG-003: Single agency view for simple feeds**
- Given my feed contains only one agency
- When I navigate to the System Configuration section
- Then the interface displays the agency details directly without a list view
- And I can edit the agency configuration inline

### 4.2 Agency Creation

**AC-CONFIG-004: Create new agency**
- Given I am viewing the agency list in a multi-agency feed
- When I click "Add Agency"
- Then a form appears for entering agency details
- And required fields (name, URL, timezone) are indicated

**AC-CONFIG-005: Agency name is required**
- Given I am creating a new agency
- When I attempt to save without an agency name
- Then the system displays a validation error
- And the agency is not saved

**AC-CONFIG-006: Agency URL is required**
- Given I am creating a new agency
- When I attempt to save without an agency URL
- Then the system displays a validation error
- And the agency is not saved

**AC-CONFIG-007: Agency URL format validation**
- Given I am entering an agency URL
- When I enter an invalid URL format
- Then the system displays a validation error
- And the agency cannot be saved until corrected

**AC-CONFIG-008: Agency timezone is required**
- Given I am creating a new agency
- When I attempt to save without a timezone
- Then the system displays a validation error
- And the agency is not saved

**AC-CONFIG-009: Timezone consistency enforcement**
- Given a feed already contains agencies with a timezone set
- When I create a new agency with a different timezone
- Then the system displays a warning about timezone inconsistency
- And requires confirmation or correction before saving

### 4.3 Agency Editing

**AC-CONFIG-010: Edit agency via list selection**
- Given I am viewing the agency list
- When I click on an agency name
- Then the agency details panel opens for editing

**AC-CONFIG-011: Save agency changes**
- Given I have made changes to an agency
- When I click the Save button
- Then my changes are persisted
- And a success confirmation is displayed

**AC-CONFIG-012: Unsaved changes warning**
- Given I have unsaved changes to an agency
- When I navigate away without saving
- Then the system warns me about unsaved changes
- And gives me the option to save or discard

**AC-CONFIG-013: Phone number format flexibility**
- Given I am editing an agency's phone number
- When I enter a phone number with various formatting (parentheses, dashes, spaces)
- Then the system accepts the format
- And preserves the formatting as entered

**AC-CONFIG-014: Fare URL is optional**
- Given I am editing an agency
- When I leave the fare URL field empty
- Then the agency saves successfully
- And no fare_url is included in the GTFS export

### 4.4 Agency Deletion

**AC-CONFIG-015: Cannot delete agency with routes**
- Given an agency has routes assigned to it
- When I attempt to delete the agency
- Then the system displays an error indicating routes must be reassigned or deleted first
- And the agency is not deleted

**AC-CONFIG-016: Delete agency without routes**
- Given an agency has no routes assigned to it
- When I click "Delete Agency" and confirm
- Then the agency is permanently removed
- And it no longer appears in the agency list

**AC-CONFIG-017: Cannot delete last agency**
- Given the feed contains only one agency
- When I attempt to delete that agency
- Then the system prevents deletion
- And displays a message that at least one agency is required

### 4.5 Feed Information

**AC-CONFIG-018: View feed information**
- Given I navigate to the Feed Information section
- When the page loads
- Then I see fields for: Publisher Name, Publisher URL, Feed Language, Default Language, Start Date, End Date, Version, Contact Email, Contact URL

**AC-CONFIG-019: Feed publisher name is required**
- Given I am editing feed information
- When I attempt to save without a publisher name
- Then the system displays a validation error
- And the changes are not saved

**AC-CONFIG-020: Feed publisher URL is required**
- Given I am editing feed information
- When I attempt to save without a publisher URL
- Then the system displays a validation error
- And the changes are not saved

**AC-CONFIG-021: Feed language is required**
- Given I am editing feed information
- When I attempt to save without a feed language
- Then the system displays a validation error
- And the changes are not saved

**AC-CONFIG-022: Feed language dropdown**
- Given I am editing the feed language
- When I click the language field
- Then a dropdown displays available language codes
- And includes "mul" option for multilingual feeds

**AC-CONFIG-023: Date range validation**
- Given I am editing feed validity dates
- When I enter an end date that precedes the start date
- Then the system displays a validation error
- And the changes cannot be saved

**AC-CONFIG-024: Feed version auto-suggestion**
- Given I am editing the feed version
- When I focus on the version field
- Then the system suggests a version format (e.g., date-based: "2025-01-24")
- And allows manual entry of custom version strings

**AC-CONFIG-025: Save feed information**
- Given I have made changes to feed information
- When I click the Save button
- Then my changes are persisted
- And a success confirmation is displayed

### 4.6 Export Settings

**AC-CONFIG-026: View export settings**
- Given I navigate to the Export Settings section
- When the page loads
- Then I see toggle or dropdown controls for each export option
- And current settings are displayed

**AC-CONFIG-027: Stop ID export format selection**
- Given I am viewing export settings
- When I select "Export stop code as stop_id"
- And I save the settings
- Then future GTFS exports use stop_code values in the stop_id field

**AC-CONFIG-028: Block ID export format selection**
- Given I am viewing export settings
- When I select "Export block name as block_id"
- And I save the settings
- Then future GTFS exports use block name values in the block_id field

**AC-CONFIG-029: Route ID export format selection**
- Given I am viewing export settings
- When I select the route ID export format option
- And I save the settings
- Then future GTFS exports use the selected identifier format for route_id

**AC-CONFIG-030: Interpolated times toggle**
- Given I am viewing export settings
- When I toggle "Export interpolated stop times" on
- And I save the settings
- Then future GTFS exports include estimated arrival times for all stops

**AC-CONFIG-031: GTFS-flex toggle**
- Given I am viewing export settings
- When I toggle "Enable GTFS-flex" on
- And I save the settings
- Then future GTFS exports include GTFS-flex extension files when applicable

**AC-CONFIG-032: Export settings confirmation**
- Given I have changed export settings
- When I save the settings
- Then a confirmation message indicates the settings will apply to the next export
- And current exports are not retroactively affected

### 4.7 Feed URL

**AC-CONFIG-033: Display permanent feed URL**
- Given I navigate to the Feed URL section
- When the page loads
- Then I see the permanent URL where the GTFS feed is published
- And the URL is displayed in a read-only format

**AC-CONFIG-034: Copy feed URL to clipboard**
- Given I am viewing the feed URL
- When I click the "Copy" button
- Then the URL is copied to my clipboard
- And a confirmation indicates the copy succeeded

**AC-CONFIG-035: Feed URL is read-only**
- Given I am viewing the feed URL
- Then there is no option to edit the URL directly
- And a note explains that feed URLs are permanent for data consumer compatibility

### 4.8 Data Validation

**AC-CONFIG-036: URL format validation**
- Given I am entering any URL field (agency URL, fare URL, publisher URL, contact URL)
- When I enter a value that is not a valid URL
- Then the system displays a validation error
- And the record cannot be saved

**AC-CONFIG-037: Email format validation**
- Given I am entering any email field (agency email, contact email)
- When I enter a value that is not a valid email format
- Then the system displays a validation error
- And the record cannot be saved

**AC-CONFIG-038: Timezone selection from list**
- Given I am editing an agency's timezone
- When I click the timezone field
- Then a dropdown displays valid IANA timezone identifiers
- And I can search/filter the list

**AC-CONFIG-039: Language code selection from list**
- Given I am editing a language field
- When I click the language field
- Then a dropdown displays valid ISO 639-1 language codes
- And includes common languages prominently

### 4.9 Integration Points

**AC-CONFIG-040: Agency available in route creation**
- Given I have created and saved an agency
- When I create a new route
- Then the new agency is available for selection in the agency dropdown

**AC-CONFIG-041: Timezone affects schedule display**
- Given an agency has a timezone configured
- When I view schedules for that agency's routes
- Then times display in the agency's local timezone

**AC-CONFIG-042: Export settings apply to GTFS export**
- Given I have configured export settings
- When I export the GTFS feed
- Then the exported files reflect the configured identifier formats
- And optional features (interpolated times, GTFS-flex) are included per settings

**AC-CONFIG-043: Feed info included in export**
- Given I have configured feed information
- When I export the GTFS feed
- Then feed_info.txt is included with all configured fields
- And required fields are populated

---

## 5. Non-Functional Requirements

### 5.1 Performance
- Agency list must load within 1 second for feeds with up to 20 agencies
- Export settings changes must save within 500ms
- Timezone and language dropdown searches must return results within 200ms

### 5.2 Usability
- Required fields must be visually distinguished from optional fields
- Save buttons must use high-visibility styling (bright green) per existing UI conventions
- URL fields should auto-detect and validate URLs as the user types
- Timezone dropdown should default to a sensible value based on user location or previous selections

### 5.3 Data Integrity
- Agency deletion must be prevented while routes are assigned to the agency
- The system must maintain at least one agency in every feed
- Timezone consistency must be enforced across all agencies in a multi-agency feed
- Feed start date must not exceed feed end date

### 5.4 Accessibility
- All form fields must have associated labels
- Error messages must be announced to screen readers
- Dropdown menus must be keyboard navigable
- Color-coding must not be the sole indicator of required vs. optional fields

---

## 6. Design Guidelines

Per our functionalist design philosophy:

**Data-Ink Ratio:** Configuration forms prioritize data entry efficiency. Avoid decorative elements that don't contribute to task completion.

**Grid System:** Form layouts follow a consistent grid. Labels align left, inputs span available width. Related fields group visually.

**Typography:** Use system sans-serif fonts. Field labels display in lighter weight for hierarchy; entered values in standard weight.

**Color for Information:** Use color to encode validation state (error, success) and required field status. Maintain high contrast for readability.

**Plain Language:** Field labels match GTFS specification terminology where possible, with help text providing context. Avoid jargon in explanatory text.

**Input Efficiency:** Provide dropdowns for constrained values (timezone, language). Auto-format URLs and emails. Support paste operations for bulk data entry.

---

## 7. Technical Considerations

Per our engineering standards:

**Context Structure:** System configuration belongs to a `Configuration` context that encapsulates agency, feed info, and export settings. The context owns `Agency`, `FeedInfo`, and `ExportSettings` schemas.

**Data Validation:** Use Ecto changesets with explicit validations. URL fields validate format. Email fields validate format. Timezone fields validate against IANA database. Return tagged tuples (`{:ok, record}` or `{:error, changeset}`) from context functions.

**LiveView Architecture:** Configuration views implement as LiveView. Use forms with phx-change for real-time validation feedback. Delegate to function components for reusable form elements.

**Real-Time Updates:** Use Phoenix PubSub to broadcast configuration changes. Multiple users editing the same feed see updates without manual refresh.

**Testing Strategy:**
- Context tests validate business rules (required fields, timezone consistency, URL format)
- LiveView tests verify user flows (create agency, edit feed info, change export settings)
- Focus on behavior over implementation
