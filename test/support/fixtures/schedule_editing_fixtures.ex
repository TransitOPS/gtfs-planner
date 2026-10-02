defmodule GtfsPlanner.ScheduleEditingFixtures do
  @moduledoc """
  Editing scopes, trips and independent readbacks for the advanced trip-editing
  package (spec 18).

  Every builder only creates rows; expected values stay in the tests. The
  readback helpers (`stop_time_clocks/1`, `trip_row/1`, `frequency_rows/1`,
  `trip_logs/1`) re-read through `GtfsPlanner.Repo` instead of reusing the
  structs the builders returned, so a test observes what was persisted.

  ## Scopes

  `editing_scope!/2` creates one organization, version, editor, audit context, a
  weekly calendar (Mon–Fri over 2026), a route and one schedule pattern with its
  timing, and returns them as a map:

      %{
        organization: %Organization{},
        version: %GtfsVersion{},
        actor: %User{},
        audit: %AuditContext{},
        service: "service id",
        route: %Route{},
        bundle: %{pattern: %RoutePattern{}, occurrences: [...], timing: %TimedPattern{}, rows: [...]}
      }

  Its `attrs` may override `:organization`, `:version`, `:actor`, `:audit` and
  `:service`, and otherwise forwards to `GtfsFixtures.schedule_pattern_fixture/3`
  (`:direction_id`, `:route_pattern_id`, `:headsign`, `:timing_name`,
  `:timing_headsign`, `:stops`). Extra timings come from `extra_timing!/3`.

  `weekday_and_saturday!/1` adds two weekly services with disjoint dates and
  returns `%{weekday: service_id, saturday: service_id}`;
  `shared_dates_calendars!/1` adds two services sharing dates and returns
  `%{daily: service_id, school: service_id}`.

  ## Trips

  `linked_trip!/3`, `custom_trip!/3`, `frequency_trip!/3` and `blocked_pair!/3`
  create trips on the scope's pattern and return the `%Trip{}` structs.
  `frequency_trip!/3` takes windows as `%{start_secs:, end_secs:,
  headway_secs:, exact_times:}` maps or `{start, end, headway_secs}` tuples whose
  clocks are integer seconds or `"H:MM:SS"` strings.
  """

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @default_stops [{"A", 0, 0, 1}, {"B", 300, 330, 1}, {"C", 720, 720, 1}]

  @doc """
  Creates an editing scope on `route_id` and returns it as the map described in
  the moduledoc.
  """
  @spec editing_scope!(String.t(), map()) :: map()
  def editing_scope!(route_id, attrs \\ %{}) do
    attrs = Map.new(attrs)
    organization = Map.get(attrs, :organization) || organization_fixture()
    version = Map.get(attrs, :version) || gtfs_version_fixture(organization.id)
    actor = Map.get(attrs, :actor) || editor_fixture(organization)
    audit = Map.get(attrs, :audit) || audit_context(organization, version, actor)
    # A named `:service` names the calendar rather than replacing one: the
    # trips below run on it, so the scope still owns the weekly calendar row the
    # editor's pages read. Passing no `:service` gets the default generated id.
    service =
      case Map.fetch(attrs, :service) do
        {:ok, named} ->
          calendar_service!(organization.id, version.id, %{service_id: named})
          named

        :error ->
          calendar_service!(organization.id, version.id, %{})
      end

    route = route_fixture(organization.id, version.id, %{route_id: route_id})

    bundle =
      attrs
      |> Map.put(:route_id, route_id)
      |> Map.put_new(:stops, @default_stops)
      |> then(&schedule_pattern_fixture(organization.id, version.id, &1))

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit,
      service: service,
      route: route,
      bundle: bundle
    }
  end

  @doc """
  Adds a Mon–Fri and a Saturday weekly service to `scope`.

  Their dates are disjoint over the shared 2026 range. Returns
  `%{weekday: service_id, saturday: service_id}`.
  """
  @spec weekday_and_saturday!(map()) :: %{weekday: String.t(), saturday: String.t()}
  def weekday_and_saturday!(scope) do
    weekday = calendar_service!(scope.organization.id, scope.version.id, %{})

    saturday =
      calendar_service!(scope.organization.id, scope.version.id, %{
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

    %{weekday: weekday, saturday: saturday}
  end

  @doc """
  Adds two weekly services that share dates to `scope`: a daily service and a
  Mon–Fri school service over the same 2026 range.

  Returns `%{daily: service_id, school: service_id}`.
  """
  @spec shared_dates_calendars!(map()) :: %{daily: String.t(), school: String.t()}
  def shared_dates_calendars!(scope) do
    daily =
      calendar_service!(scope.organization.id, scope.version.id, %{
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1
      })

    school = calendar_service!(scope.organization.id, scope.version.id, %{})

    %{daily: daily, school: school}
  end

  @doc """
  Adds a named timing to the scope's pattern and returns the `%TimedPattern{}`.

  `offsets` is a list of `{arrival_offset, departure_offset, timepoint}` tuples
  in pattern occurrence order, as `GtfsFixtures.schedule_pattern_fixture/3`
  takes them.
  """
  @spec extra_timing!(map(), [{integer(), integer(), integer()}], String.t()) :: TimedPattern.t()
  def extra_timing!(bundle, offsets, name) do
    timing = timed_pattern_fixture(bundle.pattern, %{name: name})

    bundle.occurrences
    |> Enum.zip(offsets)
    |> Enum.each(fn {occurrence, {arrival, departure, timepoint}} ->
      timed_pattern_stop_fixture(timing, occurrence, %{
        arrival_offset: arrival,
        departure_offset: departure,
        timepoint: timepoint
      })
    end)

    timing
  end

  @doc """
  Creates a linked trip starting at `start` (a `"H:MM:SS"` clock or integer
  seconds) on `scope.service` and returns the `%Trip{}`.

  `attrs` may override `:service_id`, `:timed_pattern_id`, `:trip_id`,
  `:trip_headsign`, `:trip_short_name`, `:block_id` and `:direction_id`.
  """
  @spec linked_trip!(map(), String.t() | non_neg_integer(), map()) :: Trip.t()
  def linked_trip!(scope, start, attrs \\ %{}) do
    attrs =
      %{service_id: scope.service}
      |> Map.merge(Map.new(attrs))
      |> Map.put_new(:timed_pattern_id, scope.bundle.timing.id)
      |> Map.put(:state, "linked")
      |> Map.put(:start_time, clock!(start))

    schedule_trip!(scope, attrs)
  end

  @doc """
  Creates a custom trip from `stop_times` (as
  `[{stop_id, arrival_time, departure_time}]` in sequence order) on
  `scope.service` and returns the `%Trip{}`.

  `attrs` may override `:service_id`, `:trip_id`, `:trip_headsign`,
  `:trip_short_name`, `:block_id` and `:reason` (default `"stops_mismatch"`).
  """
  @spec custom_trip!(map(), [{String.t(), String.t(), String.t()}], map()) :: Trip.t()
  def custom_trip!(scope, stop_times, attrs \\ %{}) do
    attrs =
      %{service_id: scope.service, reason: "stops_mismatch"}
      |> Map.merge(Map.new(attrs))
      |> Map.put(:state, "custom")
      |> Map.put(:stop_times, stop_times)

    schedule_trip!(scope, attrs)
  end

  @doc """
  Creates a frequency trip on `scope.service` and returns the `%Trip{}`.

  The template stop times materialize the scope's timing at the first window's
  start; `attrs` may override `:service_id`, `:timed_pattern_id`, `:trip_id`,
  `:trip_headsign`, `:trip_short_name`, `:block_id`, `:state`, `:start_time`
  and `:exact_times` (default 0).

  A window is a `%{start_secs:, end_secs:, headway_secs:, exact_times:}` map or
  a `{start, end, headway_secs}` tuple whose clocks are integer seconds or
  `"H:MM:SS"` strings.
  """
  @spec frequency_trip!(map(), [map() | tuple()], map()) :: Trip.t()
  def frequency_trip!(scope, windows, attrs \\ %{}) do
    attrs = Map.new(attrs)
    windows = Enum.map(windows, &window!/1)
    [first_window | _rest] = windows

    attrs =
      %{
        service_id: scope.service,
        state: "linked",
        start_time: GtfsTime.format(first_window.start_secs),
        frequencies: Enum.map(windows, &frequency_attrs(&1, attrs))
      }
      |> Map.merge(attrs)

    schedule_trip!(scope, attrs)
  end

  @doc """
  Creates two linked trips sharing `block_id`, starting at `starts`
  (`[start_a, start_b]`, clocks or integer seconds), and returns
  `[trip_a, trip_b]`.
  """
  @spec blocked_pair!(map(), String.t(), [String.t() | non_neg_integer()]) :: [Trip.t()]
  def blocked_pair!(scope, block_id, starts) do
    [first, second] = Enum.to_list(starts)

    [
      linked_trip!(scope, first, %{block_id: block_id}),
      linked_trip!(scope, second, %{block_id: block_id})
    ]
  end

  @doc """
  Reads the stored stop times of `trip` in sequence order as independent
  `{arrival, departure, timepoint, pickup_type}` tuples.
  """
  @spec stop_time_clocks(Trip.t()) ::
          [{String.t() | nil, String.t() | nil, integer() | nil, integer() | nil}]
  def stop_time_clocks(trip) do
    Repo.all(
      from(st in StopTime,
        where:
          st.trip_id == ^trip.trip_id and st.organization_id == ^trip.organization_id and
            st.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: st.stop_sequence, asc: st.id],
        select: {st.arrival_time, st.departure_time, st.timepoint, st.pickup_type}
      )
    )
  end

  @doc "Reads `trip` back from `Repo`, so a test sees the persisted row."
  @spec trip_row(Trip.t()) :: Trip.t()
  def trip_row(trip), do: Repo.get!(Trip, trip.id)

  @doc "Reads `trip`'s stored frequency rows, ordered by start time."
  @spec frequency_rows(Trip.t()) :: [Frequency.t()]
  def frequency_rows(trip) do
    Repo.all(
      from(f in Frequency,
        where:
          f.trip_id == ^trip.trip_id and f.organization_id == ^trip.organization_id and
            f.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: f.start_time, asc: f.id]
      )
    )
  end

  @doc "Reads the `\"trip\"` change logs for `trip` by entity ID."
  @spec trip_logs(Trip.t()) :: [ChangeLog.t()]
  def trip_logs(trip) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.entity_type == "trip" and l.entity_id == ^trip.id and
            l.organization_id == ^trip.organization_id and
            l.gtfs_version_id == ^trip.gtfs_version_id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end

  defp schedule_trip!(scope, attrs) do
    scope.organization.id
    |> schedule_trip_fixture(
      scope.version.id,
      scope.bundle.pattern.route_id,
      scope.bundle,
      attrs
    )
    |> Map.fetch!(:trip)
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp calendar_service!(organization_id, version_id, attrs) do
    attrs =
      Map.merge(
        %{service_id: "svc_#{System.unique_integer([:positive])}"},
        Map.new(attrs)
      )

    calendar_fixture(organization_id, version_id, attrs).service_id
  end

  defp window!(%{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs} = window) do
    %{
      start_secs: start_secs,
      end_secs: end_secs,
      headway_secs: headway_secs,
      exact_times: Map.get(window, :exact_times)
    }
  end

  defp window!({start, finish, headway_secs}) do
    %{
      start_secs: secs!(start),
      end_secs: secs!(finish),
      headway_secs: headway_secs,
      exact_times: nil
    }
  end

  defp frequency_attrs(window, attrs) do
    %{
      start_time: GtfsTime.format(window.start_secs),
      end_time: GtfsTime.format(window.end_secs),
      headway_secs: window.headway_secs,
      exact_times: window.exact_times || Map.get(attrs, :exact_times, 0)
    }
  end

  defp clock!(value) when is_integer(value), do: GtfsTime.format(value)

  defp clock!(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, _seconds} -> value
      {:error, :invalid_time} -> raise ArgumentError, "invalid fixture clock #{inspect(value)}"
    end
  end

  defp secs!(value) when is_integer(value), do: value

  defp secs!(value) when is_binary(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> raise ArgumentError, "invalid fixture clock #{inspect(value)}"
    end
  end
end
