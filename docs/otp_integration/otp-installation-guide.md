# 🗺️ Multimodal Trip Planner (OTP2)

This repository documents the complete local setup for **OpenTripPlanner 2 (OTP2)**. It combines OpenStreetMap (OSM) data with MBTA transit schedules to create a multimodal routing engine.

---
<br>

## 🛠️ 1. Prerequisites

Before starting, ensure your system has the following installed:

* **Java Development Kit (JDK) 21+**: Verify with `java -version`.
* **Maven** (Global Install): Verify with `mvn -version`.
* **Git**: To clone the repository.
* **Python 3**: For filtering MBTA gtfs data (optional)

---
<br>

## 🚀 2. Installation & Build

Since we are building from source, we must compile the project to create the executable JAR.

### A. Clone the Repository
```bash
git clone https://github.com/opentripplanner/OpenTripPlanner.git  

cd OpenTripPlanner
```

### B. Build The Project

Use Maven to compile the code and package dependencies into a single "shaded" JAR file.

```bash
mvn package -DskipTests
```
Wait for the `[INFO] BUILD SUCCESS` message (this may take 2-10 minutes).

### C. Build The Executable

Copy the built JAR to your root directory for easier access. (Note: Check `otp-shaded/target/` if the version number differs slightly).

```bash
cp otp-shaded/target/otp-shaded-2.9.0-SNAPSHOT.jar ./otp.jar
```

---
<br>

## 📂 3. Preparing the Data Directory

OTP requires a specific directory structure to recognize map and transit files.


### A. Create The Directory

Create a folder named data in the project root:

```bash
mkdir data
```

### B. Add Source Files

Download your region's OSM and gtfs file and place it in the data folder.

* **Map Data**: `malden.osm.pbf` (Must be a .pbf file). 
* **Transit Data**: `mbta_gtfs.zip` (Must be .zip format).

### C. Filtering GTFS Data (Optional)

To prevent OTP from loading MBTA stops that are outside your local map area (which may cause "floating stop" warnings), we use a Python script to filter the GTFS data to keep only the stops inside our region bounds, along with their associated trips, routes, facilities, and rules.



#### Prepare and Run Script

1. **Unzip** the downloaded gtfs file if not done already.
2. Locate the file `filter_gtfs.py` included in this repository.
3. Ensure it is placed in the project root (next to your `otp.jar` and `data` folder).
4. If you wish to change the target area, open `filter_gtfs.py` and adjust the `MIN_LAT`, `MAX_LAT`, `MIN_LON`, and `MAX_LON` variables.


#### Execute the script to generate the filtered data

```bash
python filter_gtfs.py
```
> You should see output indicating that Stops, Routes, Facilities, and other dependencies are being filtered.

#### Package the Data

The script creates a folder named `data/mbta_gtfs_filtered`. Navigate to the folder and zip its contents creating the `mbta_gtfs.zip` file needed for step 4.


---
<br>

## 🏗️ 4. Building The Routing Graph

Before you can run the server, you must compile the data files into a routing graph (Graph.obj).

Run the following command:
```bash
java -Xmx4G -jar otp.jar --build --save data
```
> **Memory Note**: If you receive an "Out of Memory" error, reduce the heap size to 2GB:  
> `java -Xmx2G -jar otp.jar --build --save data`

---
<br>

## 🚦 5. Starting the Server

Once the graph build is complete, you can launch the OTP web server.

Run the load command:
```bash
java -Xmx4G -jar otp.jar --load data
```

Wait for the terminal to display "Grizzly server running". Then open your web browser to:

👉 [http://localhost:8080/](http://localhost:8080/)

---
<br>

## ✅ 6. Verification

Run the following GraphQL request in the terminal to confirm the router is active and calculating trips:

```bash
curl -X POST -H "Content-Type: application/json" -d '{ "query": "{ plan(from: {lat: 42.4266, lon: -71.0741}, to: {lat: 42.4223, lon: -71.0632}) { itineraries { duration } } }" }' http://localhost:8080/otp/routers/default/index/graphql
```

You should receive a JSON response like this:

```json
{
    "data":{
        "plan":{
            "itineraries":[
                {"duration":981 },
                {"duration":590 },
                {"duration":524 }]
}}}
```

---
<br>

## 🛑 7. Troubleshooting

| Issue | Solution |
|----------|----------|
| Port 8080 is busy   | Run with a different port: --port 9090  |
| Graph not found   | Ensure Graph.obj exists in the data folder.  |
| Build Failure   | Check that you are using Java 21+ (java -version)  |
| Floating Transit Stops (Graph Islands)   | Verify OSM bounds  |

---
<br>

## 📝 License

This project uses OpenTripPlanner, licensed under the [LGPL](https://github.com/opentripplanner/OpenTripPlanner/blob/master/LICENSE).