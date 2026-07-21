defmodule GtfsPlanner.Gtfs.DisplayClockTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.DisplayClock

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: version.id}
  end

  describe "resolve_zone/2" do
    test "returns the single valid agency timezone in scope", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "treats repeated equal zones as one zone regardless of surrounding whitespace", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      insert_raw_agency(organization_id, gtfs_version_id, "  America/New_York  ")

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "returns UTC with :missing when the version has no agencies", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      assert %{timezone: "UTC", fallback?: true, fallback_reason: :missing} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "returns UTC with :missing when the only agency timezone is blank", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      insert_raw_agency(organization_id, gtfs_version_id, "   ")

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :missing} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "returns UTC with :invalid when the zone is not a PostgreSQL timezone", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      insert_raw_agency(organization_id, gtfs_version_id, "Mars/Olympus_Mons")

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :invalid} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "treats a zone value carrying SQL syntax as data and reports :invalid", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      insert_raw_agency(organization_id, gtfs_version_id, "UTC'; DROP TABLE agencies; --")

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :invalid} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      assert 1 == Repo.aggregate(Agency, :count)
    end

    test "returns UTC with :conflicting when the version has two distinct zones", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/Chicago"})

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :conflicting} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "ignores agencies belonging to another organization", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      agency_fixture(other_organization.id, other_version.id, %{agency_timezone: "Asia/Tokyo"})
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "ignores agencies belonging to another version of the same organization", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      other_version = gtfs_version_fixture(organization_id)
      agency_fixture(organization_id, other_version.id, %{agency_timezone: "Asia/Tokyo"})
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "an out-of-scope zone cannot make the scoped version conflict", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      other_version = gtfs_version_fixture(organization_id)
      agency_fixture(organization_id, other_version.id, %{agency_timezone: "Asia/Tokyo"})
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} ==
               DisplayClock.resolve_zone(organization_id, gtfs_version_id)
    end

    test "an empty version resolves to UTC even when another version has a valid zone", %{
      organization_id: organization_id
    } do
      other_version = gtfs_version_fixture(organization_id)
      empty_version = gtfs_version_fixture(organization_id)
      agency_fixture(organization_id, other_version.id, %{agency_timezone: "Asia/Tokyo"})

      assert %{timezone: "UTC", fallback?: true, fallback_reason: :missing} ==
               DisplayClock.resolve_zone(organization_id, empty_version.id)
    end
  end

  describe "localize_many/2" do
    test "returns an empty list without querying for an empty collection", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      {result, queries} = with_query_log(fn -> DisplayClock.localize_many([], zone) end)

      assert [] == result
      assert [] == queries
    end

    test "converts the whole collection in one query and preserves input order", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      timestamps = [
        ~U[2026-07-04 16:00:00Z],
        ~U[2026-01-15 02:30:00Z],
        ~U[2026-07-04 15:00:00Z]
      ]

      {result, queries} = with_query_log(fn -> DisplayClock.localize_many(timestamps, zone) end)

      assert [
               ~N[2026-07-04 12:00:00.000000],
               ~N[2026-01-14 21:30:00.000000],
               ~N[2026-07-04 11:00:00.000000]
             ] == result

      assert 1 == length(queries)
    end

    test "crosses the UTC/local date boundary in both directions", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      assert [~N[2026-01-14 21:30:00.000000], ~N[2026-01-15 19:05:00.000000]] ==
               DisplayClock.localize_many(
                 [~U[2026-01-15 02:30:00Z], ~U[2026-01-16 00:05:00Z]],
                 zone
               )
    end

    test "applies standard time before and daylight time after the spring transition", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      assert [~N[2026-03-08 01:59:00.000000], ~N[2026-03-08 03:00:00.000000]] ==
               DisplayClock.localize_many(
                 [~U[2026-03-08 06:59:00Z], ~U[2026-03-08 07:00:00Z]],
                 zone
               )
    end

    test "renders both repeated local hours across the fall transition", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      assert [~N[2026-11-01 01:30:00.000000], ~N[2026-11-01 01:30:00.000000]] ==
               DisplayClock.localize_many(
                 [~U[2026-11-01 05:30:00Z], ~U[2026-11-01 06:30:00Z]],
                 zone
               )
    end

    test "keeps wall-clock values unchanged for a UTC fallback resolution", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      assert %{timezone: "UTC", fallback?: true} = zone

      assert [~N[2026-01-15 02:30:00.000000]] ==
               DisplayClock.localize_many([~U[2026-01-15 02:30:00Z]], zone)
    end

    test "raises for a hand-built resolution naming an unknown zone", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})
      unknown = %{timezone: "Mars/Olympus_Mons", fallback?: false, fallback_reason: nil}

      assert_raise Postgrex.Error, fn ->
        DisplayClock.localize_many([~U[2026-01-15 02:30:00Z]], unknown)
      end
    end

    test "does not modify the stored UTC timestamp it localizes", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency = agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "Asia/Tokyo"})
      zone = DisplayClock.resolve_zone(organization_id, gtfs_version_id)

      [localized] = DisplayClock.localize_many([agency.inserted_at], zone)
      reloaded = Repo.get!(Agency, agency.id)

      assert reloaded.inserted_at == agency.inserted_at
      assert reloaded.inserted_at.time_zone == "Etc/UTC"
      refute localized == reloaded.inserted_at
    end
  end

  describe "format_time/2" do
    test "renders morning hours without a leading zero" do
      assert "9:05 AM" == DisplayClock.format_time(~N[2026-01-15 09:05:00])
    end

    test "renders afternoon hours in uppercase 12-hour form" do
      assert "1:07 PM" == DisplayClock.format_time(~N[2026-01-15 13:07:00])
    end

    test "renders midnight and noon as 12" do
      assert "12:00 AM" == DisplayClock.format_time(~N[2026-01-15 00:00:00])
      assert "12:00 PM" == DisplayClock.format_time(~N[2026-01-15 12:00:00])
    end

    test "renders zero-padded minutes" do
      assert "11:00 PM" == DisplayClock.format_time(~N[2026-01-15 23:00:00])
    end

    test "renders seconds only when requested" do
      assert "9:05:03 AM" == DisplayClock.format_time(~N[2026-01-15 09:05:03], seconds: true)
      assert "9:05 AM" == DisplayClock.format_time(~N[2026-01-15 09:05:03], seconds: false)
    end
  end

  describe "Gtfs delegates" do
    test "expose the clock through the context", %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    } do
      agency_fixture(organization_id, gtfs_version_id, %{agency_timezone: "America/New_York"})

      zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)

      assert %{timezone: "America/New_York", fallback?: false, fallback_reason: nil} == zone

      assert [~N[2026-01-14 21:30:00.000000]] ==
               Gtfs.localize_display_times([~U[2026-01-15 02:30:00Z]], zone)

      assert "9:30 PM" == Gtfs.format_display_time(~N[2026-01-14 21:30:00])
    end
  end

  defp insert_raw_agency(organization_id, gtfs_version_id, timezone) do
    Repo.insert!(%Agency{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      agency_id: "agency_raw_#{System.unique_integer([:positive])}",
      agency_name: "Raw Agency",
      agency_url: "http://example.com",
      agency_timezone: timezone
    })
  end

  defp with_query_log(fun) do
    test_pid = self()
    handler_id = "display-clock-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {handler_id, metadata.query})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain_queries(handler_id, [])}
  end

  defp drain_queries(handler_id, acc) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
