# GTFS-Pathways Station Dashboard: Metrics Guidance

## Purpose

This document defines the metrics, inventory items, and validation checks that should appear on a per-station GTFS-Pathways dashboard. The goal is to give data collectors, approvers, and administrators a single view that answers three questions:

1. **What is physically in this station?** (Inventory)
2. **Is the data structurally sound?** (Data Integrity)
3. **Is the data complete and useful?** (Accessibility & Attribute Completeness)

Metrics are organized into five sections, roughly in order of priority — though all sections should be visible simultaneously on the dashboard. A station with perfect inventory counts but broken graph connectivity is unusable; a station with perfect connectivity but missing measurement attributes is incomplete.

---

## 1. Station Inventory

The inventory provides a count-based summary of every modeled element in the station. It serves as a sanity check: an approver who knows the physical station should be able to glance at these counts and spot discrepancies (e.g., the data says 2 elevators but the station has 3).

### 1.1 Node Inventory (stops.txt)

Nodes are the locations within the station. The dashboard should show counts broken down by `location_type`:

| Location Type | Code | What to Count                       | Notes                                                                                                                                                    |
| ------------- | ---- | ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Station       | 1    | The parent station record itself    | There should be exactly 1 per dashboard view.                                                                                                            |
| Platform      | 0    | Platforms within the station        | Each platform should have at least one boarding area as a child. A platform with no boarding areas is a data gap.                                        |
| Boarding Area | 4    | Boarding areas across all platforms | Each platform should have at least 2 boarding areas (beginning and end). Show a per-platform breakdown if possible.                                      |
| Entrance/Exit | 2    | All station entrances and exits     | Cross-reference with the agency's known entrance count. Entrances within ~20 meters of each other that share signage should be modeled as a single stop. |
| Generic Node  | 3    | All generic nodes                   | These are structural connectors in the graph. See the sub-categories below.                                                                              |

**Generic Node Sub-Categories**

Generic nodes serve multiple purposes in GTFS-Pathways modeling. Where possible, the dashboard should categorize them:

- **Mechanical pathway endpoints:** Generic nodes placed at the top and bottom of escalators, elevators, and travelators. Per the Kisio methodology, each mechanical pathway should have a generic node at each end to ensure uniqueness and simplify data collection. Multiple mechanical pathways within ~10 meters of each other can share generic nodes.
- **Fare gate bookends:** Generic nodes placed immediately before and after fare gate and exit fare gate pathways. This modeling convention avoids confusion during data collection by isolating the fare gate as a single edge between two dedicated nodes.
- **Routing/junction nodes:** Generic nodes that exist purely to define the walking graph where pathways intersect or branch without a specific physical feature.

### 1.2 Edge Inventory (pathways.txt)

Edges are the connections between nodes. The dashboard should show counts broken down by `pathway_mode`:

| Pathway Mode                 | Code | What to Count                                    | Directionality Notes                                                                                   |
| ---------------------------- | ---- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Walkway                      | 1    | All walking pathways, including accessible ramps | Can be bidirectional or unidirectional.                                                                |
| Stairs                       | 2    | All stair connections                            | Typically bidirectional unless the station enforces one-way flow.                                      |
| Moving Sidewalk / Travelator | 3    | All travelators                                  | Unidirectional. If direction changes by time of day, this is captured in `pathway_evolutions.txt`.     |
| Escalator                    | 4    | All escalators                                   | Unidirectional. Direction changes are captured in `pathway_evolutions.txt`.                            |
| Elevator                     | 5    | All elevator pathways                            | Should be bidirectional unless explicitly specified otherwise by the transit authority.                |
| Fare Gate                    | 6    | All fare gates                                   | Unidirectional (entry direction). Fare gates within a ~30-meter area are modeled as a single ensemble. |
| Exit Fare Gate               | 7    | All exit fare gates                              | Unidirectional (exit direction). Same grouping convention as fare gates.                               |

**Additional edge-level details to surface:**

- **Bidirectional vs. unidirectional split:** Show how many pathways are `is_bidirectional = 1` vs. `0`, especially for elevators (which should almost always be bidirectional) and escalators (which should almost always be unidirectional).
- **Pathways with `pathway_evolutions` entries:** Count how many edges have time-dependent behavior (direction changes, scheduled closures).

### 1.3 Level Inventory (levels.txt)

- **Total number of levels** in the station.
- **Level names and indices** (e.g., Street Level, Mezzanine, Platform Level).
- **Nodes per level:** A breakdown of how many nodes exist on each level helps verify that vertical connections (elevators, escalators, stairs) actually stitch the station together.

The Kisio methodology recommends providing level data only when elevators are present in the station and level signage is available to the public.

### 1.4 Station Complexity Score

The Pathways Equivalent (PE) coefficient provides a rough measure of station complexity based on the number of physical elements. The dashboard should compute and display the PE score and the resulting classification:

| Classification      | PE Range     | Implication                                                                                           |
| ------------------- | ------------ | ----------------------------------------------------------------------------------------------------- |
| Simple Station      | PE < 10      | Straightforward modeling, can be done without architectural plans.                                    |
| Medium Station      | 10 ≤ PE < 30 | More complex, likely has transfers or multiple entrances. Plans recommended.                          |
| Large Station / Hub | PE ≥ 30      | Complex multi-modal station. Plans required. May involve multiple operators and inconsistent signage. |

---

## 2. Data Integrity

Data integrity metrics answer the question: **Is the graph structurally valid and usable by a routing engine?** These are the highest-priority checks on the dashboard. A station that fails any of these checks produces broken routing results.

### 2.1 Isolated / Dangling Nodes

**Check:** Every node with `location_type` 2 (entrance/exit), 3 (generic node), or 4 (boarding area) must be connected to at least one other node by a pathway.

**Display:** Count of isolated nodes. Ideally show zero. If non-zero, list the offending node IDs so they can be fixed. This is a hard fail — any isolated node means the graph has an unreachable dead end.

### 2.2 Parent Station Consistency

Multiple checks fall under this heading:

- **Boarding areas** (`location_type` 4) must always have a platform (`location_type` 0) as their `parent_station`.
- **Generic nodes, entrances/exits, and platforms** (`location_type` 0, 2, 3) must always have the station (`location_type` 1) as their `parent_station`.
- **No orphaned platforms:** Every platform must have at least one boarding area as a child.
- **Minimum station children:** Every station must be the `parent_station` of at least 2 nodes — at minimum, one entrance/exit and one platform.

**Display:** Pass/fail for each sub-check, with counts of violations.

### 2.3 Entrance-to-Platform Connectivity

**Check:** There must be a valid route (possibly spanning multiple pathways) from every entrance/exit to at least one boarding area. This is the fundamental promise of GTFS-Pathways — a rider entering the station at any entrance can reach a train.

**Display:** A connectivity matrix or a simple pass/fail per entrance. If any entrance cannot reach any boarding area, this is a critical failure.

### 2.4 Boarding Area Interconnection

**Check:** Every boarding area must be connected to at least one other boarding area. A platform is always composed of at least two boarding areas (beginning and end), and they should be linked so that a rider can traverse the platform.

**Display:** Count of boarding areas with no connection to another boarding area. Should be zero.

### 2.5 GPS Coordinate Presence

**Check:** Every station (`location_type` 1), entrance/exit (`location_type` 2), and platform (`location_type` 0) must have valid `stop_lat` and `stop_lon` values. GPS coordinates are optional for generic nodes and boarding areas but recommended.

**Display:** Count of nodes missing GPS coordinates, broken down by location type. Flag any required nodes (types 0, 1, 2) that are missing coordinates as errors.

---

## 3. Accessibility Completeness

Accessibility metrics answer the question: **Can a rider with mobility needs navigate this station using the data?** This is the core purpose of GTFS-Pathways and is especially critical for Sound Transit's ADA compliance goals.

### 3.1 Step-Free Route Existence

**Check:** Does at least one fully step-free (wheelchair-accessible) route exist from every entrance/exit to every platform?

This is the single most important accessibility metric. A step-free route means a path that uses only walkways, elevators, ramps, and travelators — no stairs, no escalators. The routing engine must be able to find such a path through the graph.

**Display:** A matrix of entrances × platforms, showing whether a step-free route exists for each pair. Any cell marked "no route" is a critical accessibility gap (or a genuine physical limitation of the station that should be documented).

### 3.2 Wheelchair Boarding Flags

**Check:** Are `wheelchair_boarding` values populated for all relevant nodes?

- **Stations** (`location_type` 1): Should indicate overall wheelchair accessibility.
- **Platforms** (`location_type` 0): Should indicate whether at least some vehicles can be boarded by a wheelchair user. A value of `0` or empty means the platform inherits from its parent station, which may mask missing data.
- **Entrances/exits** (`location_type` 2): Should indicate whether the entrance is wheelchair accessible (e.g., elevator available to reach non-grade platforms). Again, `0` or empty means it inherits from the parent.

**Display:** Count of nodes by `wheelchair_boarding` value (0/empty, 1, 2) for each location type. Flag any nodes still at `0`/empty as "unconfirmed" — inheritance from the parent station may be intentional, but it's worth verifying.

### 3.3 Wheelchair Assistance Requirements

**Check:** Are any pathways flagged with `wheelchair_assistance` values?

- `0` or empty: No assistance required.
- `1`: Assistance required without prior notice (e.g., staff-operated ramp at turnstiles).
- `2`: Assistance required with prior notice.

**Display:** Count of pathways by assistance level. If any pathways require assistance, surface the `wheelchair_assistance_phone` number if provided. This information is critical for trip planners to surface to riders.

### 3.4 Elevator Coverage

**Check:** If the station has multiple levels, are elevators present to connect them?

- Count of elevator pathways vs. number of level transitions needed.
- Are all levels reachable by elevator from the entrance level?
- Do elevator pathways have associated `level_id` values on their endpoint nodes?

**Display:** A level-connectivity diagram or table showing which levels are connected by elevators vs. only by stairs/escalators. Any level reachable only by stairs is an accessibility barrier.

### 3.5 Escalator and Travelator Coverage

While not accessibility-critical in the same way as elevators (escalators are not step-free), it's useful to verify:

- Escalator count and directional distribution (how many up vs. down).
- Whether escalators have `mechanical_stair_count` populated (used as a fallback when escalators are out of service — the routing engine treats them as stairs).
- Whether `pathway_evolutions.txt` entries exist for escalators and travelators that change direction.

---

## 4. Attribute Completeness

Attribute completeness metrics answer the question: **How thoroughly has this station been surveyed?** A station can have perfect graph connectivity but still be missing the measurement data that makes GTFS-Pathways genuinely useful for navigation and accessibility.

### 4.1 Pathway Measurement Attributes

For each pathway in the station, track whether the following fields are populated:

| Attribute         | Field Name                                 | Why It Matters                                                                                                                                   | Priority |
| ----------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ | -------- |
| Traversal time    | `traversal_time`                           | Core routing input. Without it, routing engines must estimate travel time.                                                                       | High     |
| Length            | `length`                                   | Needed for distance-based routing and accessibility assessments.                                                                                 | High     |
| Width             | `width`                                    | Critical for wheelchair users — narrow pathways may be impassable.                                                                               | High     |
| Slope / Incline   | `max_slope`                                | Steep slopes affect wheelchair users and riders with mobility impairments. Required for ramps.                                                   | High     |
| Stair count       | `stair_count`                              | Informs riders about physical effort. Useful for accessibility and routing when escalators are down.                                             | Medium   |
| Max stair flight  | `max_stair_flight`                         | Maximum steps between landings. Important for riders who can handle some stairs but need rest points.                                            | Medium   |
| Surface type      | `surface_type`                             | Uneven surfaces, gravel, or temporary surfaces affect wheelchair and mobility aid users.                                                         | Medium   |
| Handrail presence | `handrail`                                 | Relevant for riders with balance or mobility challenges.                                                                                         | Medium   |
| Signage           | `signposted_as` / `reversed_signposted_as` | What the pathway is called on station signage. Helps riders match directions to physical wayfinding.                                             | Medium   |
| Instructions      | `instructions` / `reversed_instructions`   | Free-text guidance for confusing or poorly-signed pathways (e.g., hidden elevators, unclear exits). Recommended only when signage is inadequate. | Low      |

**Display:** A completeness percentage for the station overall, calculated as (populated fields / total applicable fields) across all pathways. Break this down by attribute so it's clear what's well-covered and what's lagging. For example: "Traversal time: 92% complete. Width: 45% complete. Surface type: 12% complete."

### 4.2 Completeness by Pathway Mode

Different pathway types have different relevant attributes. The dashboard should show completeness tailored to each mode:

- **Walkways and ramps:** `traversal_time`, `length`, `width`, `max_slope`, `surface_type`.
- **Stairs:** `traversal_time`, `length`, `stair_count`, `max_stair_flight`, `handrail`.
- **Escalators:** `traversal_time`, `mechanical_stair_count` (fallback for outages), directionality confirmation.
- **Elevators:** `traversal_time`, `width` (door width matters for wheelchair access), `level_id` on endpoints.
- **Fare gates / exit fare gates:** `traversal_time`, `width`, `wheelchair_assistance`.

### 4.3 Signage Completeness

The `signposted_as` field captures what riders see on physical signs (e.g., "Exit 2", "To Platform A"). This is particularly important for large or hub stations where naming conventions may vary between operators.

**Display:** Percentage of pathways with `signposted_as` populated. For bidirectional pathways, also check `reversed_signposted_as`. Flag any entrances/exits missing signage names, as these are the most rider-facing elements.

### 4.4 Real-Time Data Readiness

If the station will participate in real-time pathway updates (e.g., elevator outage feeds via the Knaq API), the dashboard should check whether the prerequisite static data is in place:

- Do all elevators and escalators have entries in `pathway_evolutions.txt`?
- Are mechanical pathway IDs stable and mapped to the real-time feed?
- Is `mechanical_stair_count` populated for escalators (needed to fall back to stair routing during outages)?

**Display:** A readiness flag (ready / not ready) with a list of any missing prerequisites.

---

## Summary: Priority Ranking

When evaluating a station's data readiness, the metrics above cascade in importance:

1. **Data Integrity** comes first. If the graph is broken — isolated nodes, missing parent relationships, entrances that can't reach platforms — nothing downstream works. These are hard failures.

2. **Accessibility Completeness** comes next. The entire purpose of GTFS-Pathways is to inform riders about station accessibility. If step-free routes can't be computed, or wheelchair boarding flags are missing, the data fails its core mission.

3. **Station Inventory** is the ongoing sanity check. It doesn't fail on its own, but discrepancies between the inventory and physical reality indicate missing or incorrect data.

4. **Attribute Completeness** is the measure of data depth. A station can be structurally sound and accessible but still lack the measurement detail that makes navigation truly useful. This is the metric that improves over successive survey rounds.

Each station on the dashboard should have a clear, at-a-glance status that reflects where it stands across all four dimensions.
