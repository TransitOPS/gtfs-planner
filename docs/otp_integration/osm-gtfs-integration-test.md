# Test Case: Multimodal Station Navigation

## 1. Objective
To verify that the OpenTripPlanner (OTP2) router correctly transitions from the street network (OpenStreetMap) to the internal station network (GTFS Pathways) when routing a passenger from the city sidewalk to a specific train platform.

**Success Criteria:**
1.  The router finds a path from the street coordinate to the station entrance.
2.  The router utilizes internal station features (stairs, elevators, pathways).
3.  The total duration accounts for walking time inside the station structure.


## 2. Test Configuration

| Parameter | Value | Description |
| :--- | :--- | :--- |
| **Start Point** | `42.42727, -71.07270` | Malden City Hall - Pleasant St (outside Malden Center) |
| **End Point** | `Stop ID: 70034` | Malden Center Orange Line Platform (Forest Hills bound) |
| **Mode** | `WALK` | Testing walking connectivity |

> **Note:** We target a specific **Platform ID** (not the parent station) to force the router to navigate internal pathways.


## 3. The Query (GraphQL)
We used the following GraphQL query to request the itinerary steps:

```graphql
{
   plan(
    from: { lat: 42.42727, lon: -71.07270 }
    to: { lat: 42.42668, lon: -71.07438 } # Replacing with platform coordinates
    transportModes: [
            {
                mode: WALK
            }
    ]
    numItineraries: 1
  ) {
    itineraries {
      duration
      walkDistance
      legs {
        mode
        from { name }
        to { name }
        steps {
          streetName
          distance
          absoluteDirection
          relativeDirection
        }
      }
    }
  }
}
```

## 4. Results

### A. Routing Visuals

The router correctly displays the granular path, traversing multiple internal graph nodes (entrance, stairs, platform edge).

<p align="center">
  <img src="https://github.com/user-attachments/assets/56ee76f4-1c2e-4368-807c-0c20c0c4df05" width="600" alt="Pleasant St to Malden Center Routing">
</p>


> The "black line" on the map follows the expected path through the building structure



### B. Navigation Instructions

While the geometry is correct, the JSON steps array collapses the internal pathway nodes into a single, generic instruction called `platform`.

* **Finding**: The detailed substeps (e.g., "Climb stairs") are merged by OTP into a single "platform" step because the underlying edges share the same `location_type`.

#### JSON Extract
```json
   {
  "data": {
    "plan": {
      "itineraries": [
        {
          "duration": 175,          //Total trip time in SECONDS
          "walkDistance": 191.34,   //Total trip distance in METERS
          "legs": [
            {
              "mode": "WALK",
              "from": {
                "name": "Origin"
              },
              "to": {
                "name": "Destination"
              },
              "steps": [
                {
                  "streetName": "Pleasant Street",
                  "distance": 67.91,
                  "absoluteDirection": "WEST",
                  "relativeDirection": "DEPART"
                },
                {
                  "streetName": "path",
                  "distance": 13.69,
                  "absoluteDirection": "SOUTH",
                  "relativeDirection": "LEFT"
                },
                {
                  "streetName": "sidewalk",
                  "distance": 57.35,
                  "absoluteDirection": "SOUTHEAST",
                  "relativeDirection": "SLIGHTLY_LEFT"
                },
                {
                  "streetName": "path",
                  "distance": 27.5,
                  "absoluteDirection": "WEST",
                  "relativeDirection": "RIGHT"
                },
                {
                  "streetName": "platform",
                  "distance": 24.89,
                  "absoluteDirection": "SOUTHWEST",
                  "relativeDirection": "LEFT"
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

### C. Conclusion

The graph build successfully linked the OSM Street Node (Pleasant St) to the GTFS Parent Station. The fact that the visual route enters the building proves the "Pathways" logic is active and functioning.


#### Entrance Transition Logic (The "Connector" Step)

The JSON response sequence confirms the router's specific logic for transitioning layers. We observed consecutive steps labeled "path", which represent distinct segments of the graph:

* **Step A (External)**: The instruction `"streetName": "sidewalk"` represents the final approach on the public plaza.

* **Step B (The Connector)**: The following instruction labeled `"streetName": "path"` (27.5m) represents the transition edge from the OSM street network to the internal GTFS pathways layer via the entrance door node.

* **Step C (Internal)**: The final instruction `"streetName": "platform"` represents the internal station segments (stairs, concourse).


#### The Collapsed Step Phenomenon (The "Platform" Step)

**Issue**: The router internally navigates the complex path, but the instruction generator simplifies consecutive edges (like station hallways) into one block to avoid user fatigue. This feature is heavily influenced by the `location_type` field in `stops.txt`.

**Resolution**: To provide detailed guidance, a client-side application must decode the legGeometry polyline (the visual line) to generate "micro steps" for the user, rather than using the raw steps text from the JSON extract.


