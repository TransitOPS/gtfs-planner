defmodule GtfsPlannerWeb.MapLineDownloadControllerTest do
  @moduledoc """
  Step 34 / EV-33: the authenticated, version-scoped map-line download. Expected
  values are literals chosen for the fixture, never computed by the code under
  test.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  # Two patterns on one route, each a straight rising line through three stops,
  # so the route-wide download is distinguishable from either pattern's own.
  @stops [
    {"S1", "40.0", "-74.0"},
    {"S2", "40.1", "-74.1"},
    {"S3", "40.2", "-74.2"}
  ]

  # The same corridor with each stop's one-based position, which is what an
  # occurrence carries.
  @stops_with_positions Enum.with_index(@stops, 1)

  test "serves one pattern's map lines as a KML attachment", %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    pattern_context(organization, version)

    conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, "R1") <> "?pattern=P1&format=kml")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/vnd.google-earth.kml+xml"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "R1-P1.kml"

    assert conn.resp_body =~ "<kml"
    assert conn.resp_body =~ "<name>Pattern P1</name>"
    refute conn.resp_body =~ "<name>Pattern P2</name>"
    assert conn.resp_body =~ "<name>Stop S1</name>"
  end

  test "serves every pattern of a route as one GeoJSON FeatureCollection", %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    pattern_context(organization, version)

    conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, "R1") <> "?pattern=all&format=geojson")

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/geo+json"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "R1-all.geojson"

    assert {:ok, document} = Jason.decode(conn.resp_body)
    assert document["type"] == "FeatureCollection"

    # Each pattern contributes its line plus one Point per stop, and both
    # patterns are in the one document.
    names = document["features"] |> Enum.map(& &1["properties"]["route_pattern_id"])
    assert names == ["P1", "P1", "P1", "P1", "P2", "P2", "P2", "P2"]

    assert Enum.map(document["features"], & &1["geometry"]["type"]) ==
             ["LineString", "Point", "Point", "Point", "LineString", "Point", "Point", "Point"]

    assert document["features"] |> Enum.map(& &1["properties"]["stop_id"]) ==
             [nil, "S1", "S2", "S3", nil, "S1", "S2", "S3"]

    # The line features carry the route's short name; the stop points carry
    # the stop instead.
    assert document["features"]
           |> Enum.filter(&(&1["geometry"]["type"] == "LineString"))
           |> Enum.map(& &1["properties"]["route"]) == ["1", "1"]

    coordinates = document["features"] |> hd() |> get_in(["geometry", "coordinates"])

    # The three visits with the interior point of each saved section between
    # them, longitude first (INV-1).
    assert coordinates == [
             [-74.0, 40.0],
             [-74.05, 40.05],
             [-74.1, 40.1],
             [-74.15, 40.15],
             [-74.2, 40.2]
           ]
  end

  test "returns 404 for another organization's version, an unknown format, and an unknown pattern",
       %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    pattern_context(organization, version)

    %{organization: other_organization, user: other_user} = editor_context()

    foreign_conn =
      conn
      |> log_in_user(other_user, organization: other_organization)
      |> get(download_path(version.id, "R1") <> "?pattern=P1&format=kml")

    assert foreign_conn.status == 404
    assert foreign_conn.resp_body == "Not Found"

    for path <- [
          download_path(version.id, "R1") <> "?pattern=P1&format=shp",
          download_path(version.id, "R1") <> "?pattern=P1&format=",
          download_path(version.id, "R1") <> "?pattern=P1",
          download_path(version.id, "R1") <> "?pattern=missing&format=kml",
          download_path(version.id, "missing-route") <> "?pattern=all&format=kml",
          download_path("not-a-uuid", "R1") <> "?pattern=all&format=kml"
        ] do
      response =
        build_conn()
        |> log_in_user(user, organization: organization)
        |> get(path)

      assert response.status == 404
      assert response.resp_body == "Not Found"
    end
  end

  test "requires a logged-in editor" do
    organization = organization()
    version = gtfs_version_fixture(organization.id)

    logged_out = get(build_conn(), download_path(version.id, "R1") <> "?format=kml")
    assert redirected_to(logged_out) == "/users/log_in"

    user = user_fixture()
    {:ok, _membership} = Organizations.add_user_to_organization(user.id, organization.id, [])

    role_conn =
      build_conn()
      |> log_in_user(user, organization: organization)
      |> get(download_path(version.id, "R1") <> "?pattern=all&format=kml")

    assert role_conn.status == 403
  end

  test "returns 404 for an unpublished version of the requesting organization", %{conn: conn} do
    %{organization: organization, version: version, user: user} = editor_context()
    pattern_context(organization, version)

    {:ok, staging} =
      Versions.create_staging_gtfs_version(organization.id, %{name: "Staging download version"})

    conn =
      conn
      |> log_in_user(user, organization: organization)
      |> get(download_path(staging.id, "R1") <> "?pattern=all&format=kml")

    assert conn.status == 404
    assert conn.resp_body == "Not Found"

    assert version.id != staging.id
  end

  # A UUID rather than `unique_organization_alias/0`: the counter restarts with
  # each test VM, and this partition's test database already holds organizations
  # created by earlier VMs under the same aliases.
  defp organization, do: organization_fixture(%{alias: "map-lines-#{Ecto.UUID.generate()}"})

  defp editor_context do
    organization = organization()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()

    {:ok, _membership} =
      Organizations.add_user_to_organization(user.id, organization.id, ["pathways_studio_editor"])

    %{organization: organization, version: version, user: user}
  end

  # Route `R1` (short name "1") with patterns `P1` and `P2`, each running the
  # three stops in order with a saved path on both of its sections. Each
  # pattern's line is its two sections joined: five points, longitude first.
  defp pattern_context(organization, version) do
    Enum.each(@stops, fn {id, lat, lon} ->
      stop_fixture(organization.id, version.id, %{
        stop_id: id,
        stop_name: "Stop #{id}",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end)

    route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})

    Enum.each(["P1", "P2"], fn pattern_id ->
      pattern =
        route_pattern_fixture(organization.id, version.id, %{
          route_id: "R1",
          route_pattern_id: pattern_id,
          route_pattern_name: "Pattern #{pattern_id}"
        })

      Enum.each(@stops_with_positions, fn {{id, _lat, _lon}, position} ->
        route_pattern_stop_fixture(pattern, id, position)
      end)
    end)

    # The shared path is saved once per stop pair for the version, so both
    # patterns draw the same two sections, each with its own interior point.
    Enum.each([{"S1", "S2", [-74.05, 40.05]}, {"S2", "S3", [-74.15, 40.15]}], fn {f, t, mid} ->
      %AlignmentSegment{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        from_stop_id: f,
        to_stop_id: t
      }
      |> AlignmentSegment.changeset(%{points: [mid]})
      |> Repo.insert!()
    end)
  end

  defp download_path(version_id, route_id), do: "/gtfs/#{version_id}/routes/#{route_id}/map-lines"
end
