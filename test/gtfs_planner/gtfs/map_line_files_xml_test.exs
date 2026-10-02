defmodule GtfsPlanner.Gtfs.MapLineFilesXmlTest do
  # The bounded-inflate test measures VM-wide memory, which includes concurrent
  # tests. Run this module after async cases so that measurement names this parse.
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.MapLineFiles

  # Boston Common to Downtown Crossing, split at a point the join tolerance
  # covers, and a second leg 2 km north that never meets it.
  @common [-71.0637, 42.3554]
  @mid [-71.0601, 42.3572]
  # The split between two My Maps pieces lands a few metres from the last point
  # rather than exactly on it, which is what the join tolerance is for.
  @after_mid [-71.0601, 42.3573]
  @crossing [-71.0565, 42.3590]
  @north [-71.0637, 42.3754]

  describe "parse/2 KML" do
    test "joins two Placemark LineStrings that meet end to end under the first name" do
      kmz =
        kmz([
          {~c"doc.kml", my_maps_kml()}
        ])

      assert MapLineFiles.parse(kmz, "my maps.kmz") ==
               {:ok,
                [
                  %{
                    name: "Walking Route",
                    points: [@common, @mid, @after_mid, @crossing],
                    joined_from: 2
                  },
                  %{
                    name: nil,
                    points: [@north, [-71.0601, 42.3772]],
                    joined_from: 1
                  }
                ]}
    end

    test "reads a gx:Track as one line and drops altitude" do
      kml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml xmlns:gx="http://www.google.com/kml/ext/2.2">
        <Document>
          <Placemark>
            <name>Recorded</name>
            <gx:Track>
              <when>2026-03-01T10:00:00Z</when>
              <when>2026-03-01T10:00:01Z</when>
              <gx:coord>-71.0637 42.3554 12</gx:coord>
              <gx:coord>-71.0601 42.3572 34</gx:coord>
            </gx:Track>
          </Placemark>
        </Document>
      </kml>
      """

      assert MapLineFiles.parse(kml, "track.kml") ==
               {:ok,
                [
                  %{
                    name: "Recorded",
                    points: [@common, @mid],
                    joined_from: 1
                  }
                ]}
    end

    test "reports points only for a KML of Point placemarks" do
      kml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml>
        <Document>
          <Placemark>
            <name>Stop</name>
            <Point><coordinates>-71.0637,42.3554,0</coordinates></Point>
          </Placemark>
        </Document>
      </kml>
      """

      assert MapLineFiles.parse(kml, "stops.kml") == {:error, :points_only}
    end

    test "reports areas only for a KML of a Polygon" do
      kml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml>
        <Document>
          <Placemark>
            <name>Zone</name>
            <Polygon>
              <outerBoundaryIs>
                <LinearRing>
                  <coordinates>
                    -71.0637,42.3554 -71.0500,42.3554 -71.0500,42.3700 -71.0637,42.3554
                  </coordinates>
                </LinearRing>
              </outerBoundaryIs>
            </Polygon>
          </Placemark>
        </Document>
      </kml>
      """

      assert MapLineFiles.parse(kml, "zones.kml") == {:error, :areas_only}
    end

    test "reports unreadable for an entity-expanding KML" do
      # The classic "billion laughs": the parse must fail on the entity rather
      # than expand it, so nothing here should cost memory or return lines.
      kml = """
      <?xml version="1.0"?>
      <!DOCTYPE lolz [
       <!ENTITY lol "lol">
       <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
       <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
       <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
       <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
      ]>
      <kml><Document><Placemark><name>&lol5;</name></Placemark></Document></kml>
      """

      assert MapLineFiles.parse(kml, "bomb.kml") == {:error, :unreadable}
    end

    test "reports unreadable for bytes that are not XML" do
      assert MapLineFiles.parse("this is not xml at all", "lines.kml") == {:error, :unreadable}
    end
  end

  describe "parse/2 GPX" do
    test "reads a trk's trkpt latitudes and longitudes as one line" do
      gpx = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1">
        <trk>
          <name>Morning Run</name>
          <trkseg>
            <trkpt lat="42.3554" lon="-71.0637"><ele>4</ele></trkpt>
            <trkpt lat="42.3572" lon="-71.0601"/>
          </trkseg>
        </trk>
      </gpx>
      """

      assert MapLineFiles.parse(gpx, "run.gpx") ==
               {:ok,
                [
                  %{
                    name: "Morning Run",
                    points: [@common, @mid],
                    joined_from: 1
                  }
                ]}
    end

    test "reads an rte's rtept as a second line" do
      gpx = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1">
        <trk>
          <name>Run</name>
          <trkseg>
            <trkpt lat="42.3554" lon="-71.0637"/>
            <trkpt lat="42.3572" lon="-71.0601"/>
          </trkseg>
        </trk>
        <rte>
          <name>Detour</name>
          <rtept lat="42.3754" lon="-71.0637"/>
          <rtept lat="42.3772" lon="-71.0601"/>
        </rte>
      </gpx>
      """

      assert {:ok, [run, detour]} = MapLineFiles.parse(gpx, "run.gpx")
      assert run == %{name: "Run", points: [@common, @mid], joined_from: 1}
      assert detour == %{name: nil, points: [@north, [-71.0601, 42.3772]], joined_from: 1}
    end
  end

  describe "parse/2 KMZ" do
    test "reports network_link for an archive whose only content is a NetworkLink" do
      kml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml>
        <Document>
          <NetworkLink>
            <name>Live feed</name>
            <Link><href>https://example.test/feed.kml</href></Link>
          </NetworkLink>
        </Document>
      </kml>
      """

      assert MapLineFiles.parse(kmz([{~c"doc.kml", kml}]), "feed.kmz") == {:error, :network_link}
    end

    test "reports too_large for an entry that inflates past 20 MB" do
      # 30 MB of zeros compresses to about 30 KB, so only a bounded inflate
      # keeps this cheap; the memory growth check keeps that honest.
      payload = :binary.copy(<<0>>, 30 * 1024 * 1024)

      before = :erlang.memory(:total)
      assert MapLineFiles.parse(kmz([{~c"doc.kml", payload}]), "big.kmz") == {:error, :too_large}
      assert :erlang.memory(:total) - before < 100 * 1024 * 1024
    end

    test "reads the first .kml entry when the archive holds several" do
      first = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml><Document><Placemark><name>First</name><LineString>
      <coordinates>-71.0637,42.3554 -71.0601,42.3572</coordinates>
      </LineString></Placemark></Document></kml>
      """

      second = """
      <?xml version="1.0" encoding="UTF-8"?>
      <kml><Document><Placemark><name>Second</name><LineString>
      <coordinates>-71.0637,42.3754 -71.0601,42.3772</coordinates>
      </LineString></Placemark></Document></kml>
      """

      archive = kmz([{~c"doc.kml", first}, {~c"overlay.kml", second}])

      assert {:ok, [%{name: "First"}]} = MapLineFiles.parse(archive, "both.kmz")
    end

    test "reports unreadable for bytes that are not a zip archive" do
      assert MapLineFiles.parse("PK not really a zip", "lines.kmz") == {:error, :unreadable}
    end

    test "reports unreadable for an archive with no .kml entry" do
      assert MapLineFiles.parse(kmz([{~c"readme.txt", "no map here"}]), "notes.kmz") ==
               {:error, :unreadable}
    end
  end

  defp my_maps_kml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Walking Route</name>
          <LineString>
            <tessellate>1</tessellate>
            <coordinates>
              -71.0637,42.3554,0 -71.0601,42.3572,0
            </coordinates>
          </LineString>
        </Placemark>
        <Placemark>
          <name>Walking Route continued</name>
          <LineString>
            <coordinates>-71.0601,42.3573,0 -71.0565,42.3590,0</coordinates>
          </LineString>
        </Placemark>
        <Placemark>
          <name>Unrelated</name>
          <LineString>
            <coordinates>-71.0637,42.3754,0 -71.0601,42.3772,0</coordinates>
          </LineString>
        </Placemark>
      </Document>
    </kml>
    """
  end

  # `:zip.create/3` writes a real archive to a temporary file, which is the
  # only way to build the fixtures these tests read back as bytes.
  defp kmz(entries) do
    path =
      Path.join(
        System.tmp_dir!(),
        "map-line-files-#{System.unique_integer([:positive])}.kmz"
      )

    try do
      {:ok, _path} = :zip.create(String.to_charlist(path), entries)
      File.read!(path)
    after
      File.rm(path)
    end
  end
end
