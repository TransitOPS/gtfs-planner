defmodule GtfsPlanner.Gtfs.DisplayClock do
  @moduledoc """
  Resolves the display timezone for a GTFS organization/version and localizes
  stored UTC timestamps for presentation only.

  Audit timestamps stay stored in UTC. This module derives the display zone from
  the agencies of one organization/version, validates it against PostgreSQL's
  timezone catalog, and converts collections of UTC timestamps in a single
  ordered query. When the scoped agencies supply no usable zone, resolution falls
  back to UTC and reports why, so callers can disclose the fallback.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Repo

  @utc "UTC"

  @type fallback_reason :: :missing | :invalid | :conflicting | nil
  @type zone_resolution :: %{
          timezone: String.t(),
          fallback?: boolean(),
          fallback_reason: fallback_reason()
        }
  @type today_resolution :: %{
          timezone: String.t(),
          fallback?: boolean(),
          fallback_reason: fallback_reason(),
          date: Date.t()
        }

  @doc """
  Resolves the display zone for one organization/version.

  Considers only distinct, trimmed, non-empty `agency_timezone` values inside the
  supplied scope. Exactly one PostgreSQL-valid IANA name resolves to that zone.
  No usable value resolves to `:missing`, an unknown name to `:invalid`, and more
  than one distinct name to `:conflicting`; each falls back to UTC.
  """
  @spec resolve_zone(Ecto.UUID.t(), Ecto.UUID.t()) :: zone_resolution()
  def resolve_zone(organization_id, gtfs_version_id) do
    organization_id
    |> distinct_zone_candidates(gtfs_version_id)
    |> case do
      [] -> fallback(:missing)
      [candidate] -> validated_zone(candidate)
      [_ | _] -> fallback(:conflicting)
    end
  end

  @doc """
  Reports whether `name` is an exact zone name in PostgreSQL's timezone catalog.

  The comparison is exact, so callers trim their own input first:
  `"America/New_York"` is a zone, `" America/New_York "` is not. Validation
  through this function accepts exactly the zones `resolve_zone/2` resolves.
  """
  @spec valid_zone?(String.t()) :: boolean()
  def valid_zone?(name) do
    %Postgrex.Result{rows: [[valid?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)",
        [name]
      )

    valid?
  end

  @doc """
  Lists the zone names the display clock accepts, sorted ascending.

  Excludes the `posix/…` and `right/…` alias trees and PostgreSQL's `localtime`
  pseudo-zone, which are catalog artifacts rather than agency zones. The result
  is safe to offer directly as timezone choices.
  """
  @spec zone_names() :: [String.t()]
  def zone_names do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT name
        FROM pg_timezone_names
        WHERE name !~ '^(posix|right)/' AND name <> 'localtime'
        ORDER BY name
        """,
        []
      )

    rows
    |> Enum.map(fn [name] -> name end)
    # `ORDER BY` follows the server's collation, which for some names differs
    # from byte order (`en_US.UTF-8` reorders 124 of 598 names on PostgreSQL
    # 18.1). Sorting here keeps one order for every caller, independent of the
    # server's locale.
    |> Enum.sort()
  end

  @doc """
  Converts stored UTC timestamps to the resolved zone's local wall-clock values.

  Runs one PostgreSQL conversion for the whole collection and returns naive local
  values in the same order as the input. Stored values are never modified.
  """
  @spec localize_many([DateTime.t()], zone_resolution()) :: [NaiveDateTime.t()]
  def localize_many([], %{timezone: _}), do: []

  def localize_many(timestamps, %{timezone: timezone}) when is_list(timestamps) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT source.at AT TIME ZONE $2
        FROM unnest($1::timestamptz[]) WITH ORDINALITY AS source(at, ordinality)
        ORDER BY source.ordinality
        """,
        [timestamps, timezone]
      )

    Enum.map(rows, fn [local] -> local end)
  end

  @doc """
  Converts one UTC instant to the resolved zone's civil date.

  The conversion happens in PostgreSQL, so no Elixir IANA timezone database is
  required. A UTC fallback resolution returns the UTC civil date, which lets a
  caller disclose the fallback instead of silently using the wrong agency day.
  """
  @spec local_date(DateTime.t(), zone_resolution()) :: Date.t()
  def local_date(%DateTime{} = utc, %{timezone: timezone}) do
    %Postgrex.Result{rows: [[local_date]]} =
      Repo.query!(
        "SELECT ($1::timestamptz AT TIME ZONE $2)::date",
        [DateTime.truncate(utc, :microsecond), timezone]
      )

    local_date
  end

  @doc """
  Resolves the agency-local current date for one organization/version scope.

  Combines `resolve_zone/2` with `local_date/2`, so the returned map carries both
  the civil date and the disclosed zone resolution (including any
  `:missing`/`:invalid`/`:conflicting` UTC fallback).
  """
  @spec today(Ecto.UUID.t(), Ecto.UUID.t()) :: today_resolution()
  def today(organization_id, gtfs_version_id) do
    resolution = resolve_zone(organization_id, gtfs_version_id)
    Map.put(resolution, :date, local_date(DateTime.utc_now(), resolution))
  end

  @doc """
  Formats a local time as unpadded 12-hour time with uppercase AM/PM.

  Pass `seconds: true` to include seconds.
  """
  @spec format_time(NaiveDateTime.t() | Time.t(), keyword()) :: String.t()
  def format_time(local_time, opts \\ []) do
    format =
      if Keyword.get(opts, :seconds, false) do
        "%-I:%M:%S %p"
      else
        "%-I:%M %p"
      end

    Calendar.strftime(local_time, format)
  end

  @doc """
  Formats a timestamp as a date with unpadded 12-hour time.

  The form is `"Oct 1, 2026, 2:05 PM"`. A `DateTime` whose `time_zone` is
  `"Etc/UTC"` gains a `" UTC"` suffix so a stored UTC timestamp names its zone;
  a `NaiveDateTime` and a `DateTime` in any other zone are already the intended
  wall-clock display value and carry no suffix.
  """
  @spec format_datetime(DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_datetime(%DateTime{time_zone: "Etc/UTC"} = datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y, %-I:%M %p") <> " UTC"
  end

  def format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y, %-I:%M %p")
  end

  def format_datetime(%NaiveDateTime{} = naive_datetime) do
    Calendar.strftime(naive_datetime, "%b %-d, %Y, %-I:%M %p")
  end

  defp distinct_zone_candidates(organization_id, gtfs_version_id) do
    from(a in Agency,
      where:
        a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
          fragment("btrim(?) <> ''", a.agency_timezone),
      distinct: true,
      select: fragment("btrim(?)", a.agency_timezone),
      limit: 2
    )
    |> Repo.all()
  end

  defp validated_zone(candidate) do
    if valid_zone?(candidate) do
      %{timezone: candidate, fallback?: false, fallback_reason: nil}
    else
      fallback(:invalid)
    end
  end

  defp fallback(reason) do
    %{timezone: @utc, fallback?: true, fallback_reason: reason}
  end
end
