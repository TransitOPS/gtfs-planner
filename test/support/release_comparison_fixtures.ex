defmodule GtfsPlanner.ReleaseComparisonFixtures do
  @moduledoc """
  Retained native-shaped export artifacts for the release comparison suites and
  the browser seed.

  Each artifact is a ZIP with the member names, headers and row shapes the native
  exporter writes, published through the real `ExportRuns`/`ArtifactStorage`
  path, so a comparison of them reads genuine retained bytes rather than a
  manufactured result. The fixtures use readable identifiers, which is what lets
  a rename be proven; a genuinely exported feed carries stored references there.

  The pair `left_zip/0` and `right_zip/1` is counted by hand over Wed 2026-11-25
  and Thu 2026-11-26:

    * earlier file: route R1 runs trips T1 and T2 on the weekday service WEEK,
      route R2 runs trip U1 on WEEK, and one stop is named "Twin";
    * candidate file: R1 runs T1 on WEEK and T2 on HOL, which a calendar
      exception removes on 2026-11-26, so R1 runs 2 trips on the 25th and 1 on
      the 26th (the loss). Route R2 and trip U1 are renamed R2X and U1X with every
      other field equal (the churn). With `twins?: true` the candidate holds two
      stops named "Twin" at one point, so the earlier stop has two candidates.

  `many_routes_zip/1` states one weekday trip on each of many routes, so a
  comparison of two such files has more route and date rows than the shared
  helper context can hold and needs an explicit narrowing.
  """

  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns

  @agency "agency_id,agency_name,agency_url,agency_timezone\nA,Metro,http://a.example,UTC"
  @routes_header "route_id,agency_id,route_short_name,route_long_name,route_type\n"
  @stops_header "stop_id,stop_name,stop_lat,stop_lon\n"
  @weekdays "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
  @weekday_service "WEEK,1,1,1,1,1,0,0,20260101,20261231"

  @doc "Publishes `bytes` as the one ready full-feed artifact of `version`."
  def publish_run!(organization, version, bytes) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, actor(), :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  @doc "The earlier file of the hand-counted pair."
  def left_zip do
    zip([
      {"agency.txt", @agency},
      {"routes.txt", @routes_header <> "R1,A,1,Main,3\nR2,A,2,Harbor,3"},
      {"stops.txt",
       @stops_header <> "S1,First,40.1,-74.1\nS2,Second,40.2,-74.2\nS3,Twin,40.3,-74.3"},
      {"trips.txt",
       "route_id,service_id,trip_id,direction_id\nR1,WEEK,T1,0\nR1,WEEK,T2,0\nR2,WEEK,U1,0"},
      {"stop_times.txt", stop_times("U1")},
      {"calendar.txt", @weekdays <> @weekday_service}
    ])
  end

  @doc "The candidate file of the hand-counted pair; `twins?: true` splits the Twin stop."
  def right_zip(opts \\ []) do
    twins =
      if Keyword.get(opts, :twins?, true),
        do: "S3A,Twin,40.3,-74.3\nS3B,Twin,40.3,-74.3",
        else: "S3,Twin,40.3,-74.3"

    zip([
      {"agency.txt", @agency},
      {"routes.txt", @routes_header <> "R1,A,1,Main,3\nR2X,A,2,Harbor,3"},
      {"stops.txt", @stops_header <> "S1,First,40.1,-74.1\nS2,Second,40.2,-74.2\n" <> twins},
      {"trips.txt",
       "route_id,service_id,trip_id,direction_id\nR1,WEEK,T1,0\nR1,HOL,T2,0\nR2X,WEEK,U1X,0"},
      {"stop_times.txt", stop_times("U1X")},
      {"calendar.txt", @weekdays <> @weekday_service <> "\nHOL,1,1,1,1,1,0,0,20260101,20261231"},
      {"calendar_dates.txt", "service_id,date,exception_type\nHOL,20261126,2"}
    ])
  end

  @doc """
  An export with `count` routes, each running one weekday trip.

  Two such files compare as unchanged, with one route and date row per route and
  date, which is what makes the whole result larger than the helper may hold.
  """
  def many_routes_zip(count) do
    ids = Enum.map(1..count, &"M#{String.pad_leading(Integer.to_string(&1), 3, "0")}")

    zip([
      {"agency.txt", @agency},
      {"routes.txt", @routes_header <> Enum.map_join(ids, "\n", &"#{&1},A,#{&1},Route #{&1},3")},
      {"stops.txt", @stops_header <> "S1,First,40.1,-74.1\nS2,Second,40.2,-74.2"},
      {"trips.txt",
       "route_id,service_id,trip_id,direction_id\n" <>
         Enum.map_join(ids, "\n", &"#{&1},WEEK,T#{&1},0")},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <>
         Enum.map_join(ids, "\n", fn id ->
           "T#{id},08:00:00,08:00:00,S1,1\nT#{id},08:10:00,08:10:00,S2,2"
         end)},
      {"calendar.txt", @weekdays <> @weekday_service}
    ])
  end

  defp actor, do: %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  defp stop_times(unit_trip) do
    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <>
      "T1,08:00:00,08:00:00,S1,1\nT1,08:10:00,08:10:00,S2,2\n" <>
      "T2,09:00:00,09:00:00,S1,1\nT2,09:10:00,09:10:00,S2,2\n" <>
      "#{unit_trip},10:00:00,10:00:00,S1,1\n#{unit_trip},10:10:00,10:10:00,S2,2"
  end

  defp zip(members) do
    entries = Enum.map(members, fn {name, body} -> {String.to_charlist(name), body <> "\n"} end)
    {:ok, {_, bytes}} = :zip.create(~c"network.zip", entries, [:memory])
    bytes
  end
end
