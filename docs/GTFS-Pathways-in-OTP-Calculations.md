# How OpenTripPlanner Calculates In-Station Traversal Time

When a trip plan routes a rider through a station with GTFS Pathways data, OTP models the station interior as a network of graph edges. Each edge represents a physical segment — a corridor, a staircase, an elevator ride, a fare gate. The total walk leg duration is the **sum of time increments from traversing each edge**, computed by the A\* street routing algorithm.

This document describes the exact time and cost calculation for each edge type.

---

## The Core Algorithm: PathwayEdge

The primary edge type for GTFS pathways is `PathwayEdge`. It handles walkways, fare gates, and generic pathway segments. The time calculation uses a **cascading priority** based on which GTFS fields are available.

Source: `street/src/main/java/org/opentripplanner/street/model/edge/PathwayEdge.java`

### Time Calculation

```
1. If traversal_time > 0:
       time = traversal_time (seconds)

2. Else if distance > 0:
       time = distance / walk_speed

3. Else if stair_count > 0:
       time = (0.4 × |stair_count|) / walk_speed

4. Else:
       weight = 1 (minimal cost, analogous to a FreeEdge)
```

- **Step 1** uses the GTFS `traversal_time` directly. This is the highest-priority input and is always preferred when available.
- **Step 2** falls back to `length / walk_speed`. The default walk speed is 1.33 m/s (~3 mph).
- **Step 3** estimates distance from stair count, treating each step as 0.4 meters of walking. This accounts for both the horizontal and vertical components of a staircase.
- **Step 4** applies to edges like elevator entry points that lack time, distance, and stair data. The real cost for these is added by other edge types (e.g., `ElevatorHopEdge`).

### Weight (Routing Cost) Calculation

After computing time, the routing weight determines how the A\* search ranks this path against alternatives:

```
weight = time × walk_reluctance × (stairs_reluctance if stairs else 1)
```

For wheelchair routing, the calculation substitutes a wheelchair-specific reluctance that factors in slope penalties, accessibility status, and a much higher stair penalty:

```
reluctance = (inaccessible_street_reluctance if not wheelchair accessible else 1)
           × walk_reluctance
           × (wheelchair_stairs_reluctance if stairs else 1)
           × (1 + 100 × slope_exceeded_by × slope_exceeded_reluctance)
```

Source: `street/src/main/java/org/opentripplanner/street/model/edge/StreetEdgeReluctanceCalculator.java`

---

## Stairs (StreetEdge)

Stairs sourced from OpenStreetMap are modeled as `StreetEdge` instances with the `isStairs` flag set. These use a different time calculation than GTFS pathway stairs.

Source: `street/src/main/java/org/opentripplanner/street/model/edge/StreetEdge.java`

### Time Calculation

```
effective_speed = walk_speed / stairs_time_factor
               = 1.33 / 3.0
               = 0.443 m/s

time = distance / effective_speed
```

The `stairsTimeFactor` (default **3.0**) divides the walking speed, so stairs take **3x longer** than flat ground for the same distance. The routing weight then applies `stairsReluctance` on top of this slower speed to further discourage stair routes.

---

## Elevator (Three Edge Types)

Elevators are modeled as three separate edges representing the three phases of an elevator trip: waiting to board, riding between floors, and stepping off.

### 1. ElevatorBoardEdge — Waiting for the Elevator

Source: `street/src/main/java/org/opentripplanner/street/model/edge/ElevatorBoardEdge.java`

```
time   = board_slack              (default: 90 seconds)
weight = board_cost + reluctance × time
       = 15 + 2.0 × 90
       = 195
```

The 90-second `boardSlack` models the average wait time for an elevator to arrive. The `boardCost` is a flat penalty added to the routing weight.

For wheelchair routing, additional costs are applied based on the elevator's accessibility status:
- Accessible (`POSSIBLE`): no extra cost
- Unknown accessibility: adds `unknownCost` to weight
- Not accessible (`NOT_POSSIBLE`): adds `inaccessibleCost` to weight
- If configured to only consider accessible elevators, inaccessible ones are excluded entirely

### 2. ElevatorHopEdge — Riding Between Floors

Source: `street/src/main/java/org/opentripplanner/street/model/edge/ElevatorHopEdge.java`

```
if travel_time > 0 (from GTFS):
    time = travel_time
else:
    time = hop_time × number_of_levels
         = 20 × levels

weight = reluctance × time
       = 2.0 × time
```

Each floor costs 20 seconds by default. The `levels` value comes from the difference in GTFS `level_index` between the two stops connected by the elevator. If no level data is available, a default of 1 level is assumed.

Intermediate floors that the elevator passes through without stopping do not add extra cost. For example, an elevator going from level 0 to level 3 creates hop edges with the total level difference, not three separate single-floor hops:

```
level   0     3
        X --- X
levels     3        → time = 20 × 3 = 60s
```

### 3. ElevatorAlightEdge — Exiting the Elevator

Source: `street/src/main/java/org/opentripplanner/street/model/edge/ElevatorAlightEdge.java`

```
weight = 1 (minimal cost)
time   = 0 (no time added)
```

Exiting the elevator is effectively free. All narrative generation (the walk step with floor information) happens at this edge.

### Total Elevator Time

For a 2-floor elevator ride with default settings:

```
Board:  90s (wait)
Hop:    20 × 2 = 40s (ride)
Alight:  0s
Total: 130s
```

---

## Escalator

Escalators are modeled as `EscalatorEdge` instances. They can only be traversed by walking — wheelchair routing excludes them entirely.

Source: `street/src/main/java/org/opentripplanner/street/model/edge/EscalatorEdge.java`

### Time Calculation

```
if duration is set (from OSM data):
    time = duration (seconds)
else:
    time = distance / escalator_speed
         = distance / 0.45

weight = reluctance × time
       = 1.5 × time
```

The default escalator speed of 0.45 m/s is derived from a typical short escalator at a 30-degree angle moving at 0.5 m/s, giving a horizontal speed component of approximately 0.43 m/s (rounded to 0.45).

---

## Default Parameter Values

All parameters are configurable through the OTP routing request. These are the defaults:

### Walking

| Parameter | Default | Effect |
|---|---|---|
| `walk.speed` | 1.33 m/s (~3 mph) | Base speed for flat walkways |
| `walk.reluctance` | 2.0 | Multiplier on all walking time for routing cost |
| `walk.stairsReluctance` | 2.0 | Additional multiplier for stairs (stacks with walk reluctance) |
| `walk.stairsTimeFactor` | 3.0 | Divides walk speed on stairs (1.33 / 3.0 = 0.443 m/s) |

### Escalator

| Parameter | Default | Effect |
|---|---|---|
| `walk.escalator.speed` | 0.45 m/s | Horizontal traversal speed on escalators |
| `walk.escalator.reluctance` | 1.5 | Routing cost multiplier for escalator time |

### Elevator

| Parameter | Default | Effect |
|---|---|---|
| `elevator.boardSlack` | 90s | Wait time before boarding (added to leg duration) |
| `elevator.boardCost` | 15s equivalent | Flat routing cost penalty for boarding |
| `elevator.hopTime` | 20s per floor | Time to travel one level |
| `elevator.reluctance` | 2.0 | Routing cost multiplier for elevator time |

---

## Time vs. Weight

It is important to distinguish between **time** and **weight** in OTP's routing:

- **Time** is added to the leg duration and directly affects the trip's start/end timestamps. This is what the rider sees.
- **Weight** is the generalized cost used by the A\* search algorithm to compare routes. It includes time but is scaled by reluctance factors, flat cost penalties, and accessibility adjustments.

A route with lower weight is preferred by the router, even if it takes the same amount of real time. For example:
- Walking 100m on flat ground: time = 75s, weight = 75 × 2.0 = 150
- Walking 100m on stairs: time = 225s (3x slower), weight = 225 × 2.0 × 2.0 = 900

The stairs path takes 3x longer in real time and costs 6x more in routing weight, making OTP strongly prefer the flat path.

---

## Worked Example

A rider enters a station at ground level and navigates to an elevated platform: walk across the main hall, go up stairs, pass through a fare gate, take an elevator down one floor to the platform level, and follow signs to the boarding area.

| Segment | Edge Type | Distance | Time Calculation | Time | Weight |
|---|---|---|---|---|---|
| Enter station | StreetTransitEntranceLink | ~0m | Free | 0s | 0 |
| Walk through main hall | PathwayEdge | 150m | 150 / 1.33 | 113s | 113 × 2.0 = 226 |
| Climb stairs | StreetEdge (isStairs) | 12m | 12 / (1.33 / 3.0) | 27s | 27 × 2.0 × 2.0 = 108 |
| Pass through fare gate | PathwayEdge | 2m | 2 / 1.33 | 2s | 2 × 2.0 = 4 |
| Wait for elevator | ElevatorBoardEdge | — | board_slack | 90s | 15 + 2.0 × 90 = 195 |
| Ride elevator (1 floor) | ElevatorHopEdge | — | hop_time × 1 | 20s | 2.0 × 20 = 40 |
| Exit elevator | ElevatorAlightEdge | — | Free | 0s | 1 |
| Walk to platform | PathwayEdge | 85m | 85 / 1.33 | 64s | 64 × 2.0 = 128 |
| Cross platform | PathwayEdge | 30m | 30 / 1.33 | 23s | 23 × 2.0 = 46 |
| **Total** | | **279m** | | **339s (~5.7 min)** | **748** |

If the GTFS feed provides `traversal_time` values on any of these pathways, those values replace the calculated times for those segments.

---

## How GTFS Data Overrides Defaults

The GTFS `traversal_time` field always takes priority. When present and greater than zero:

- **PathwayEdge**: uses `traversal_time` directly as seconds, ignoring distance and stair count
- **ElevatorHopEdge**: uses `traversal_time` directly, ignoring `hopTime × levels`

This means transit agencies that provide accurate traversal times in their GTFS feeds will produce more realistic trip plans than those relying on OTP's distance-based estimates.
