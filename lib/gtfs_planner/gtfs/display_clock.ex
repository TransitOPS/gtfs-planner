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

  alias Ecto.Adapters.SQL
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Repo

  @utc "UTC"

  @type fallback_reason :: :missing | :invalid | :conflicting | nil
  @type zone_resolution :: %{
          timezone: String.t(),
          fallback?: boolean(),
          fallback_reason: fallback_reason()
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
  Converts stored UTC timestamps to the resolved zone's local wall-clock values.

  Runs one PostgreSQL conversion for the whole collection and returns naive local
  values in the same order as the input. Stored values are never modified.
  """
  @spec localize_many([DateTime.t()], zone_resolution()) :: [NaiveDateTime.t()]
  def localize_many([], %{timezone: _}), do: []

  def localize_many(timestamps, %{timezone: timezone}) when is_list(timestamps) do
    %Postgrex.Result{rows: rows} =
      SQL.query!(
        Repo,
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
  Formats a local time as unpadded 12-hour time with uppercase AM/PM.

  Pass `seconds: true` to include seconds.
  """
  @spec format_time(NaiveDateTime.t(), keyword()) :: String.t()
  def format_time(local_time, opts \\ []) do
    format =
      if Keyword.get(opts, :seconds, false) do
        "%-I:%M:%S %p"
      else
        "%-I:%M %p"
      end

    Calendar.strftime(local_time, format)
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
    %Postgrex.Result{rows: [[valid?]]} =
      SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = $1)",
        [candidate]
      )

    if valid? do
      %{timezone: candidate, fallback?: false, fallback_reason: nil}
    else
      fallback(:invalid)
    end
  end

  defp fallback(reason) do
    %{timezone: @utc, fallback?: true, fallback_reason: reason}
  end
end
