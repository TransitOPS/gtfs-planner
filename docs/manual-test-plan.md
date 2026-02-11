**Manual QA Test Plan: GTFS Planner**

**Goal**
Verify that a tester can import GTFS data, build out a station's internal structure (levels, child stops, pathways between them), validate the data against the MobilityData spec, and export a working GTFS ZIP, all without needing deep GTFS expertise.

**Key concepts for testers**

- **Station**: A top-level stop (location_type 1) that acts as a container for platforms, entrances, and internal nodes.
- **Child stop**: A stop nested inside a station, for example a platform (boarding area), an entrance/exit, or a generic node used as a waypoint.
- **Level**: A floor or vertical position within a station (e.g. ground = 0, basement = -1, mezzanine = 1). Each child stop can be assigned to a level.
- **Pathway**: A navigable connection between two child stops: walkways, stairs, elevators, escalators, etc. Pathways carry metadata like traversal time, width, and signage.
- **Diagram**: A floorplan image uploaded per level. Child stops are placed on it visually and pathways are drawn as lines between them.

**Test data packs**

1. `Pack A (valid)`: A clean set containing `stops.txt`, `levels.txt`, `pathways.txt`, `routes.txt`, `trips.txt`, `stop_times.txt` with at least one station that has multiple levels, child stops, and pathways.
2. `Pack B (invalid)`: Files with intentional problems: missing required fields, references to non-existent levels, malformed pathway rows.
3. Two floorplan images per level (one `.png`, one `.svg`) for upload and replacement tests.
4. One file over 200 MB and one file with a `.pdf` extension for upload-error tests.

---

## 1. Stations list

### ST-01 Stations list loads

**Steps:**
Navigate to the Stations page for a version that has data.

**Expected:**
A table of stations appears showing columns for Stop ID, Station Name, Location Type, Accessibility, and Routes. Each station row has a clickable Stop ID link and route-colored badges. No errors or empty-state message.

### ST-02 Filter by route

**Steps:**
In the filter bar, open the "Route" dropdown and select a route (shown as `short_name (route_id)`).

**Expected:**
The table immediately filters to show only stations served by that route. The "Showing X–Y of Z stations" count updates to reflect the smaller result set.

### ST-03 Direction filter appears after route selection

**Steps:**
With no route selected, check the filter bar. There should be no direction dropdown. Now select a route.

**Expected:**
A "Direction" dropdown appears with options "All directions", "Direction 0", and "Direction 1". Selecting a direction further filters the station list. Clearing the route hides the direction dropdown again.

### ST-04 Accessibility filter

**Steps:**
Open the "Accessibility" dropdown and cycle through "Accessible", "Not accessible", and "No info".

**Expected:**
Each selection filters the table to stations matching that wheelchair-boarding status. Returning to "All accessibility" shows all stations again.

### ST-05 Search stations

**Steps:**
Type a partial station name or stop ID into the "Search stations..." field.

**Expected:**
After a brief delay (~300 ms debounce), the table filters to stations whose name or ID matches the search text. Clearing the field restores the full list.

### ST-06 Sort columns

**Steps:**
Click the "Stop ID" column header once, note the order. Click it again. Click it a third time.

**Expected:**
First click sorts ascending, second click sorts descending, third click resets to the default order. Repeat for "Station Name" and "Location Type" to confirm they behave the same way.

### ST-07 Pagination

**Steps:**
On a dataset with more than 50 stations, note the "Showing 1–50 of N stations" text. Click "Next".

**Expected:**
The table shows rows 51–100 (or up to N). The "Previous" button is now enabled. Click "Previous" to return to page 1. "Previous" should be disabled on the first page, and "Next" should be disabled on the last page.

### ST-08 Station detail page

**Steps:**
Click a station's Stop ID link to open its detail page.

**Expected:**
The page shows a metadata grid (Station ID, Station Name, Location Type, Latitude, Longitude, etc.), a "Child Stops" section grouped by level with count badges, a "Levels" table showing Level ID/Name/Index/Stop count/Diagram indicator, and a "Pathways" table showing Pathway ID/From/To/Mode/Time.

---

## 2. Station diagram: levels

### SD-01 Add an existing level to a station

**Steps:**
On a station's Diagram tab, click "Add Level". In the drawer, select "Use existing level", pick a level from the dropdown, and click "Save".

**Expected:**
The level appears in the level-selector dropdown in the action strip. Switching to it shows its diagram (or an empty-state prompt to upload one).

### SD-02 Create a new level

**Steps:**
Click "Add Level", select "Create new level". Enter a level name (e.g. "Mezzanine"), set the level index (e.g. 1 for above ground), and click "Save".

**Expected:**
The Level ID field auto-fills based on the station and name (e.g. `STATION_STOPID_MEZZANINE`). The new level appears in the level-selector dropdown and in the station detail's Levels table.

### SD-03 Level ID auto-generation and manual override

**Steps:**
In the "Create new level" form, type a level name and watch the Level ID field populate automatically. Now manually edit the Level ID to something custom. Then change the level name again.

**Expected:**
After manual edit, the Level ID no longer auto-updates when the name changes. The manual value is preserved.

### SD-04 Edit a level

**Steps:**
Select a level in the dropdown, click "Edit Level". Change its name, index, or ID and save.

**Expected:**
The updated values are reflected in the level-selector dropdown, the station detail Levels table, and any child stops referencing that level.

---

## 3. Station diagram: floorplans

### SD-05 Upload a floorplan

**Steps:**
Select a level that has no diagram (you should see "No diagram for this level"). Click "Upload Diagram" and choose a `.png` or `.svg` image under 10 MB.

**Expected:**
The image loads onto the canvas area. The "Add Stop" and "Connect" mode buttons become usable.

### SD-06 Replace a floorplan

**Steps:**
On a level that already has a diagram, click "Upload Diagram" and upload a different image.

**Expected:**
The canvas immediately shows the new image. The old floorplan is no longer displayed. Any existing child stops and pathways remain in their positions.

### SD-07 Floorplan upload validation

**Steps:**
Try uploading a `.pdf` file or a file larger than 10 MB.

**Expected:**
An error message appears (e.g. "Only .txt and .csv files accepted" or size error). The canvas does not change.

---

## 4. Station diagram: child stops

### SD-08 Add a child stop by clicking the diagram

**Steps:**
With a level selected and its floorplan visible, click the "Add Stop" toggle in the action strip (the action strip should show "Click diagram to add a child stop"). Click an empty spot on the floorplan.

**Expected:**
An orange triangle marker appears at the click point and a drawer opens on the right with fields for Stop ID, Stop Name, Location Type (dropdown with Entrance/Exit, Generic Node, Boarding Area), and Level. Fill in the fields and click "Create Stop". The marker becomes a cyan circle and appears in the "Child Stops on Level" list below the diagram.

### SD-09 Edit a child stop

**Steps:**
In "Add Stop" mode, click an existing cyan stop circle on the diagram (or click its row in the "Child Stops on Level" list).

**Expected:**
The edit drawer opens pre-filled with the stop's data. The Stop ID field is read-only. Change the Stop Name or Location Type and click "Update Stop". The updated values appear on the canvas tooltip and in the list.

### SD-10 Delete a child stop that has pathways

**Steps:**
Select a child stop that is connected to at least one pathway. In the edit drawer, scroll to the red "Delete Stop" section and click it.

**Expected:**
The child stop is removed from the diagram and list. All pathways connected to that stop are also removed. No orphan pathway lines remain on the canvas or in the pathways list.

### SD-11 Child stop location types

**Steps:**
Create three child stops, one with each type: "Entrance/Exit" (type 2), "Generic Node" (type 3), and "Boarding Area" (type 4).

**Expected:**
Each saves successfully. The location type labels display correctly in the child stops list and on the diagram.

---

## 5. Station diagram: pathways

### SD-12 Create a pathway between two stops on the same level

**Steps:**
Click the "Connect" toggle in the action strip (the strip should show "Choose a child stop to begin pathway"). Click a child stop. The strip updates to "From: [stop name] -- select destination stop" and the stop turns blue. Click a second stop on the same level.

**Expected:**
A cyan pathway line appears between the two stops on the canvas. The pathway is added to the "Pathways on Level" list with a default mode of Walkway and bidirectional enabled.

### SD-13 Create a cross-level pathway

**Steps:**
In Connect mode, click a stop on the current level, then switch to another level and click a stop there.

**Expected:**
A pathway is created between the two stops. The stop connected on the other level shows an orange border ring to indicate it has a cross-level connection (e.g. stairs or elevator to another floor).

### SD-14 Edit pathway details

**Steps:**
Click a pathway line on the canvas (or click its row in the "Pathways on Level" list) to open the pathway drawer. Change the mode (e.g. from Walkway to Elevator), set a traversal time (in seconds), length (in meters), and minimum width (in meters). Add signage text. Click "Save Pathway".

**Expected:**
All values persist. Close and reopen the drawer to confirm the saved values are still there.

### SD-15 Stairs-specific stair count

**Steps:**
Open a pathway's drawer and set the mode to "Stairs".

**Expected:**
A "Stair Count" field appears that was not visible before. Enter a value and save. Switch the mode to something else (e.g. Walkway) and the stair count field should disappear.

### SD-16 Bidirectional signage toggle

**Steps:**
Open a pathway drawer. With "Bidirectional" checked, look for a "Reversed Signposted As" field. It should be visible. Uncheck "Bidirectional".

**Expected:**
The "Reversed Signposted As" field disappears. Re-check "Bidirectional" and it reappears. Values entered before unchecking should still be there if you re-enable it.

### SD-17 Delete a pathway

**Steps:**
Open a pathway's drawer and click "Delete Pathway" in the red section at the bottom.

**Expected:**
The pathway line disappears from the canvas and the pathway is removed from the "Pathways on Level" list.

### SD-18 Clear selection in Connect mode

**Steps:**
In Connect mode, click a stop to start a pathway (the stop turns blue and the action strip shows its name). Click the "X" clear button in the action strip.

**Expected:**
The stop returns to its normal cyan color. The action strip resets to "Choose a child stop to begin pathway". You can now pick a different starting stop.

---

## 6. Import

### IM-01 Import valid GTFS files

**Steps:**
Navigate to Import GTFS. Drag (or click to browse) valid `.txt` files from Pack A into the upload area. Each file shows a progress bar. Once all uploads complete, click "Import Files".

**Expected:**
A progress indicator shows which file is being processed and how many rows have been imported. When finished, a green success summary appears listing counts for each entity type (e.g. "123 stops, 5 levels, 42 pathways").

### IM-02 Import with unrecognized files mixed in

**Steps:**
Upload a mix of valid GTFS files and non-GTFS files (e.g. `readme.txt`, `notes.csv`).

**Expected:**
A yellow warning banner lists the unrecognized filenames and states they will be skipped. Click "Import Files" and the recognized files import successfully while unrecognized ones are ignored.

### IM-03 Create a new version during import

**Steps:**
Check the "Create a new GTFS version" toggle. Enter a version name (e.g. "Spring 2025 Schedule"). Upload files and click "Import Files".

**Expected:**
The import targets the new version. After success, switch to the new version using the version selector in the header. The imported data (stations, routes, etc.) appears on all pages.

### IM-04 Version name required

**Steps:**
Check the "Create a new GTFS version" toggle but leave the version name field blank. Click away from the field (blur) or try to import.

**Expected:**
An inline error appears: "Version name is required". The "Import Files" button is blocked until a name is provided.

### IM-05 Cancel a file before importing

**Steps:**
Upload several files. Before clicking "Import Files", click the "Cancel" button next to one of the queued files.

**Expected:**
That file is removed from the upload queue. The remaining files can still be imported normally.

---

## 7. Export

### EX-01 Full export

**Steps:**
Navigate to Export & Validate. Select "Full Export" (should be the default). Review the file inventory table, which should list all GTFS files with their row counts. Click "Export GTFS".

**Expected:**
The button changes to "Exporting..." with a spinner. A ZIP file downloads to your machine with a filename like `gtfs_versionname_2025-01-15.zip`. The file inventory should match what is inside the ZIP.

### EX-02 Pathways-only export

**Steps:**
Select the "Pathways Export" radio button.

**Expected:**
The file inventory table updates to show only pathways-related files (stops, levels, pathways, and supporting files). Click "Export GTFS" and the downloaded ZIP contains only the pathways subset.

### EX-03 Double-click protection

**Steps:**
Click "Export GTFS" and immediately click it again several times while the export is in progress.

**Expected:**
Only one export runs. The button stays in its "Exporting..." disabled state and does not queue additional exports.

---

## 8. MobilityData validation

### MV-01 Validation requires selecting a validator

**Steps:**
On the Export & Validate page, without checking any validator checkbox, click "Run Validation".

**Expected:**
A flash message appears prompting you to select the "MobilityData GTFS Validator" checkbox first. No validation starts.

### MV-02 Run validation and observe progress

**Steps:**
Check "MobilityData GTFS Validator" and click "Run Validation".

**Expected:**
A progress bar appears and moves through phases: "Preparing..." → "Exporting GTFS data..." → "Running validator..." → "Processing results...". When complete, a summary shows counts for Errors (red), Warnings (yellow), and Infos (blue).

### MV-03 Review validation results in detail

**Steps:**
After a validation completes, click "View Full Results".

**Expected:**
The results page shows a status badge ("COMPLETED"), summary stats (Errors/Warnings/Infos with icons), and a list of notice cards. Each card shows a severity badge (ERROR/WARNING/INFO), a notice code, the affected filename, and an occurrence count. Click a card to expand it and a table appears with columns for File, Line, Column, and Message showing sample occurrences.

### MV-04 Validation history

**Steps:**
Run validation two or more times. On the Export & Validate page, check the "Recent Validations" table below the results. Also click "View History" on the results page.

**Expected:**
Each run appears with its timestamp, error/warning/info counts, and a clickable link. Clicking a past run opens its full results. The most recent run appears at the top.

### MV-05 Failed validation

**Steps:**
Run validation against Pack B (invalid data) or with a misconfigured validator environment.

**Expected:**
The results page shows a "FAILED" status badge in red and an error alert with a description of what went wrong. The page does not crash or enter a loading loop.

---

## 9. Cross-feature and regression

### RG-01 GTFS version switching

**Steps:**
Using the version selector dropdown in the page header, switch versions while on the Stations page, then Station Detail, Diagram, Import, Export, and Routes pages.

**Expected:**
Each page stays on its equivalent view but loads data for the newly selected version. Station counts, route lists, and diagram contents should reflect the chosen version's data.

### RG-02 Routes smoke test

**Steps:**
Open the Routes page. Filter by Mode (e.g. Bus), Agency, and Status. Search for a route by name. Sort by Short Name. Paginate through results. Click a route to open its detail page, then switch to the Patterns tab.

**Expected:**
All list controls (filters, search, sort, pagination) work correctly. The route detail page shows route metadata. The Patterns tab shows route patterns with Direction and Typicality badges (or an empty state if the route has no patterns).

---

## GTFS data integrity checks

Verify these during the test cases above:

1. Every child stop's `parent_station` field correctly references its parent station's stop ID.
2. When a child stop is assigned a level, that `level_id` corresponds to an actual level in the station's levels list.
3. Cross-level pathways use appropriate modes (stairs, elevators, or escalators), not walkways.
4. Both endpoints of every pathway are valid child stops within the same station.
5. After deleting a child stop, no orphan pathways reference it (check the pathways list and exported data).
6. The exported ZIP's `stops.txt`, `levels.txt`, and `pathways.txt` are internally consistent. All IDs cross-reference correctly.

---

## Pass criteria

1. All ST, SD, IM, EX, and MV test cases pass.
2. No data loss on edit, delete, or replace operations.
3. Exports download without errors and contain valid, consistent GTFS data.
4. Validation runs complete (or fail gracefully) without unhandled errors or page crashes.
