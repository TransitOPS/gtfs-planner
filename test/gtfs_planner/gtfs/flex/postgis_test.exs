defmodule GtfsPlanner.Gtfs.Flex.PostgisTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Repo

  @polygon "POLYGON((0 0, 0 1, 1 1, 1 0, 0 0))"

  test "the postgis extension is registered and reports its library version" do
    assert %Postgrex.Result{rows: [[extension_version]]} =
             Repo.query!("SELECT extversion FROM pg_extension WHERE extname = 'postgis'")

    assert %Postgrex.Result{rows: [[library_version]]} =
             Repo.query!("SELECT postgis_lib_version()")

    assert library_version =~ ~r/^\d+\.\d+/
    assert library_version == extension_version
  end

  test "the geometry functions flex areas rely on execute on a literal polygon" do
    assert %Postgrex.Result{rows: [[reduced]]} =
             Repo.query!(
               "SELECT ST_AsText(ST_ReducePrecision(ST_ForcePolygonCCW(ST_GeomFromText($1)), 0.000001))",
               [@polygon]
             )

    assert reduced =~ "POLYGON"

    assert %Postgrex.Result{rows: [[valid, reason]]} =
             Repo.query!(
               "SELECT valid, reason FROM ST_IsValidDetail(ST_GeomFromText($1))",
               [@polygon]
             )

    assert valid
    assert reason == nil

    assert %Postgrex.Result{rows: [[buffered_area]]} =
             Repo.query!(
               "SELECT ST_Area(ST_Buffer(ST_GeogFromText($1), 10))",
               [@polygon]
             )

    assert buffered_area > 0
  end
end
