# GTFS Pathways in OpenTripPlanner

GTFS pathways describe the physical connections inside transit stations — walkways, stairs, escalators, elevators, and fare gates. When a GTFS feed includes `pathways.txt`, OpenTripPlanner (OTP) can use that data to generate more accurate transfer times and detailed walking directions through stations.

This document explains how each pathway field from the GTFS specification is handled by OTP: whether it's used, what it's used for, and where it shows up in trip plan responses.

---

## Field-by-Field Summary

### `pathway_mode`

- **Used?** Yes
- **What it does:** Tells OTP what kind of physical connection this is: walkway, stairs, escalator, elevator, fare gate, or exit gate.
- **When it matters:** During graph building. Elevators are modeled with specialized edges (board, ride, alight) rather than a simple walking edge. Stairs and escalators are flagged as not wheelchair-accessible.
- **Where it appears:** Not directly exposed in the API response. Its effects are baked into the routing cost and wheelchair accessibility of each edge. You will not see a `pathwayMode` field in the JSON, but you may observe its impact — for example, a step with `relativeDirection: "ELEVATOR"` indicates an elevator pathway was used.

### `signposted_as`

- **Used?** Yes
- **What it does:** Provides the text shown on physical signs within the station (e.g., "Follow signs to Platform 3"). OTP uses this to generate human-readable walking directions.
- **When it matters:** Only when the field is non-empty in the GTFS feed. If blank, the step will show a generic name like `"pathway"` instead.
- **Where it appears:** In the API response as the `streetName` field on a walk step, paired with `relativeDirection: "FOLLOW_SIGNS"`. This is the primary way pathway sign information reaches the end user.

### `reverse_signposted_as`

- **Used?** Yes
- **What it does:** Same as `signposted_as`, but for travel in the reverse direction on a bidirectional pathway.
- **When it matters:** Only when `is_bidirectional` is `1` and the trip traverses the pathway in reverse.
- **Where it appears:** Same as `signposted_as` — it becomes the `streetName` on the reverse-direction walk step with `relativeDirection: "FOLLOW_SIGNS"`.

### `traversal_time`

- **Used?** Yes
- **What it does:** The number of seconds it takes to walk through this pathway. This is the primary input for calculating how long a transfer takes.
- **When it matters:** Always, when provided. This is the highest-priority cost input — if set, OTP uses it directly rather than estimating from distance or stair count.
- **Where it appears:** Reflected in the overall `duration` and timing of walk legs. Not shown as a separate field on individual steps.

### `length`

- **Used?** Yes
- **What it does:** The length of the pathway in meters. Used to calculate traversal time when `traversal_time` is not provided (distance / walking speed).
- **When it matters:** As a fallback when `traversal_time` is zero or not set. If neither `length` nor `traversal_time` is provided, OTP estimates distance from the coordinates of the two endpoints.
- **Where it appears:** Reflected in the `distance` field on walk steps and in overall walk distance calculations.

### `stair_count`

- **Used?** Yes
- **What it does:** The number of stairs in the pathway. Positive means ascending, negative means descending. Used for cost estimation and to apply stair reluctance (stairs are penalized in routing to prefer level paths when available).
- **When it matters:** As a fallback when both `traversal_time` and `length` are zero or missing. OTP estimates each step as 0.4 meters of walking distance. Also triggers a stair reluctance multiplier during routing, making stair paths less preferred.
- **Where it appears:** Not directly shown in the API response. Its effect is reflected in the overall routing cost and duration.

### `max_slope`

- **Used?** Yes
- **What it does:** The maximum slope ratio of the pathway (e.g., 0.08 for an 8% grade). Used to apply a wheelchair reluctance penalty — steeper slopes are more costly for wheelchair users.
- **When it matters:** Only during wheelchair-accessible routing. Has no effect on standard walking routes.
- **Where it appears:** Not directly shown in the API response. Its effect is reflected in the routing cost when wheelchair mode is enabled.

### `min_width`

- **Used?** No
- **What it does:** In the GTFS spec, this represents the minimum width of the pathway in meters.
- **When it matters:** Never. OTP does not read or store this field. It is silently ignored during import.
- **Where it appears:** Nowhere.

### `is_bidirectional`

- **Used?** Yes
- **What it does:** When set to `1`, OTP creates edges in both directions (using `reverse_signposted_as` for the return direction and negating `stair_count` and `max_slope`). When `0`, the pathway is one-way only.
- **When it matters:** During graph building. A one-way pathway (like a fare gate entry) will only be usable in one direction.
- **Where it appears:** Not directly shown in the API response. Its effect is structural — it determines which routes through a station are possible.

### `level` (from `levels.txt`, referenced on stops)

- **Used?** Yes, but only for elevators
- **What it does:** The level/floor information (name and index) attached to stops and pathway nodes. OTP uses it to determine how many floors an elevator travels and to label elevator edges.
- **When it matters:** Only for elevator pathways. The level index difference between the two endpoints determines the elevator hop count.
- **Where it appears:** Not directly shown in standard API responses. Used internally for elevator cost calculations.

---

## How Pathways Appear in API Responses

When a trip plan includes walking through a station with GTFS pathways, the pathway data appears within walk `steps` on a walk leg. The key indicators are:

- **`relativeDirection: "FOLLOW_SIGNS"`** — This step follows a signposted pathway. The `streetName` contains the sign text from `signposted_as`.
- **`relativeDirection: "ELEVATOR"`** — This step involves an elevator ride.
- **`streetName: "pathway"`** — A pathway without signposting information. This is the default name when `signposted_as` is empty.

Fields like `pathway_mode`, `stair_count`, `max_slope`, and `level` influence routing decisions and transfer times but do not appear as named fields in the response. Their effects are reflected in the chosen route, the overall `duration`, and `walkDistance`.

---

## Sample API Response

The scenario below shows a trip that starts with a bus ride, then requires the rider to transfer through a large train station on foot — navigating a walkway, stairs, an elevator, and a fare gate — before boarding a train. This demonstrates how different pathway types appear in a real response.

```json
{
  "data": {
    "plan": {
      "itineraries": [
        {
          "duration": 2340,
          "walkDistance": 487.6,
          "legs": [
            {
              "mode": "BUS",
              "duration": 720,
              "from": {
                "name": "5th Ave & Market St"
              },
              "to": {
                "name": "Central Station Bus Terminal"
              },
              "route": "Route 14",
              "steps": []
            },
            {
              "mode": "WALK",
              "duration": 390,
              "from": {
                "name": "Central Station Bus Terminal"
              },
              "to": {
                "name": "Central Station Platform 7"
              },
              "steps": [
                {
                  "streetName": "Central Station Main Hall",
                  "distance": 85.0,
                  "absoluteDirection": "NORTH",
                  "relativeDirection": "DEPART"
                },
                {
                  "streetName": "Follow signs to Platforms 5-8",
                  "distance": 120.5,
                  "absoluteDirection": "NORTHEAST",
                  "relativeDirection": "FOLLOW_SIGNS"
                },
                {
                  "streetName": "pathway",
                  "distance": 42.3,
                  "absoluteDirection": "NORTH",
                  "relativeDirection": "CONTINUE"
                },
                {
                  "streetName": "Elevator to Platform Level",
                  "distance": 0.0,
                  "relativeDirection": "ELEVATOR"
                },
                {
                  "streetName": "Tap card at fare gate",
                  "distance": 2.0,
                  "absoluteDirection": "NORTH",
                  "relativeDirection": "FOLLOW_SIGNS"
                },
                {
                  "streetName": "Follow signs to Platform 7",
                  "distance": 67.8,
                  "absoluteDirection": "EAST",
                  "relativeDirection": "FOLLOW_SIGNS"
                }
              ]
            },
            {
              "mode": "RAIL",
              "duration": 1020,
              "from": {
                "name": "Central Station Platform 7"
              },
              "to": {
                "name": "Riverside Station"
              },
              "route": "Northeast Regional",
              "steps": []
            },
            {
              "mode": "WALK",
              "duration": 210,
              "from": {
                "name": "Riverside Station"
              },
              "to": {
                "name": "425 River Rd"
              },
              "steps": [
                {
                  "streetName": "Follow signs to Main Exit",
                  "distance": 55.0,
                  "absoluteDirection": "WEST",
                  "relativeDirection": "FOLLOW_SIGNS"
                },
                {
                  "streetName": "River Rd",
                  "distance": 115.0,
                  "absoluteDirection": "SOUTH",
                  "relativeDirection": "RIGHT"
                }
              ]
            }
          ]
        }
      ]
    }
  }
}
```

### What to notice in this example

- **"Follow signs to Platforms 5-8"** — `signposted_as` in action. The `streetName` contains the sign text and `relativeDirection` is `FOLLOW_SIGNS`.
- **"pathway"** — A pathway segment without `signposted_as`. OTP falls back to the default name.
- **"Elevator to Platform Level"** — `pathway_mode = ELEVATOR`, shown with `relativeDirection: "ELEVATOR"` and zero distance. The `level` data determines the floor change and routing cost.
- **"Tap card at fare gate"** — `pathway_mode = FARE_GATE` with `signposted_as` providing the action description.
- **"Follow signs to Platform 7"** — Another `signposted_as` pathway guiding the rider to their platform.
- **"Follow signs to Main Exit"** — `reverse_signposted_as` in action. The rider is walking the pathway in the opposite direction, so the reverse sign text is used.
- **Transfer walk duration of 390s** — Reflects `traversal_time` values from the GTFS feed. If the rider had requested wheelchair-accessible routing, `max_slope` and `stair_count` would influence which route was chosen and its cost.
