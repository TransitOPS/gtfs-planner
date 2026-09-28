defmodule GtfsPlanner.Gtfs.PathwayEvolutions do
  @moduledoc """
  Scoped reads for scheduled pathway closures and their native calendar choices.

  Every read names one organization and GTFS version and accepts only a
  published scope with well-formed identifiers; anything else returns
  `{:error, :not_found}` (or a zero count) without exposing rows. Station reads
  accept only a real station stop (`location_type` 1) and reuse the station
  report snapshot, so a closure belongs to the station when its pathway has
  either endpoint among the station's descendant stops, boarding areas included.

  A closure row carries the persisted `Gtfs.Gtfs.PathwayEvolution` with its
  fingerprint, its exact snapshot pathway and its native calendar option. The
  option exists only for services with at least one `calendars` or
  `calendar_dates` row in the scope: a metadata-only identity (a
  `calendar_attributes` row alone) is not a valid closure reference, so it is
  excluded from `closure_calendars/2` and yields `calendar: nil` on a closure
  row. `Calendars.list_calendars/3` keeps showing metadata-only identities as
  editable calendars; that contract is unchanged here.

  Fingerprinting lives here because the mutation and editor handoffs compare the
  row they loaded against the current row. The digest covers exactly the
  persisted closure row, so editing a referenced calendar or pathway never makes
  a closure stale, while any write to the row itself does.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @type fingerprint :: String.t()
  @type calendar_option :: %{
          service_id: String.t(),
          name: String.t() | nil,
          label: String.t(),
          first_active_date: Date.t() | nil,
          last_active_date: Date.t() | nil,
          active_date_count: non_neg_integer(),
          trip_count: non_neg_integer(),
          closure_count: non_neg_integer()
        }
  @type closure_row :: %{
          evolution: PathwayEvolution.t(),
          fingerprint: fingerprint(),
          pathway: Pathway.t(),
          calendar: calendar_option() | nil
        }

  @doc """
  Lists one published station's scheduled closures beside its station snapshot.

  The result carries the `Gtfs.get_station_report_snapshot/3` map (station,
  child stops, levels, pathways) plus `:closures`, one row per closure whose
  pathway has either endpoint in the station, every pathway mode included.
  Rows are sorted by `pathway_id`, `start_time`, `service_id`, `end_time`, `id`
  and each carries its fingerprint, exact snapshot pathway and native calendar
  option (`nil` when the referenced service has no native row in scope).

  An unknown, non-station (`location_type` other than 1), unpublished or foreign
  target returns `{:error, :not_found}` without rows.
  """
  @spec station_closures(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok,
           %{
             station: Stop.t(),
             child_stops: [Stop.t()],
             levels: [map()],
             pathways: [Pathway.t()],
             closures: [closure_row()]
           }}
          | {:error, :not_found}
  def station_closures(organization_id, gtfs_version_id, stop_id) when is_binary(stop_id) do
    with :ok <- validate_scope(organization_id, gtfs_version_id),
         %Stop{location_type: 1} <-
           Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, stop_id),
         {:ok, snapshot} <-
           Gtfs.get_station_report_snapshot(organization_id, gtfs_version_id, stop_id),
         {:ok, closures} <- closures_for(snapshot, organization_id, gtfs_version_id) do
      {:ok, Map.put(snapshot, :closures, closures)}
    else
      _ -> {:error, :not_found}
    end
  end

  def station_closures(_organization_id, _gtfs_version_id, _stop_id), do: {:error, :not_found}

  @doc """
  Lists the native calendar choices for closures in one published scope.

  One option per service with a `calendars` or `calendar_dates` row, in
  `Calendars.list_calendars/3` order. Metadata-only identities are excluded;
  they remain visible in the calendars context. Options carry the display label
  (the calendar name, or the exact `service_id` when unnamed), effective first
  and last active dates with the active date count, the grouped trip count and
  the scope-wide count of closure rows referencing the service.

  A foreign, invalid or unpublished scope returns `{:error, :not_found}`.
  """
  @spec closure_calendars(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [calendar_option()]} | {:error, :not_found}
  def closure_calendars(organization_id, gtfs_version_id) do
    with :ok <- validate_scope(organization_id, gtfs_version_id),
         {:ok, options} <- calendar_options(organization_id, gtfs_version_id, nil) do
      {:ok, options}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns the count of closure rows in one published organization/version.

  Malformed identifiers, foreign scopes and unpublished versions count as 0.
  """
  @spec count_closures(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def count_closures(organization_id, gtfs_version_id) do
    if validate_scope(organization_id, gtfs_version_id) == :ok do
      scoped_evolutions(organization_id, gtfs_version_id)
      |> Repo.aggregate(:count)
    else
      0
    end
  end

  @doc """
  Returns the fingerprint of one persisted closure row.

  Mutations and the editor compare this digest against the row they loaded, so
  a save or delete whose fingerprint differs from the current row is refused as
  stale. It covers exactly the persisted row: referenced calendar or pathway
  edits leave it unchanged, any write to the row changes it.
  """
  @spec fingerprint(PathwayEvolution.t()) :: fingerprint()
  def fingerprint(%PathwayEvolution{} = evolution) do
    %{
      id: evolution.id,
      organization_id: evolution.organization_id,
      gtfs_version_id: evolution.gtfs_version_id,
      pathway_id: evolution.pathway_id,
      service_id: evolution.service_id,
      start_time: evolution.start_time,
      end_time: evolution.end_time,
      note: evolution.note,
      inserted_at: evolution.inserted_at,
      updated_at: evolution.updated_at
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp closures_for(snapshot, organization_id, gtfs_version_id) do
    pathway_by_id = Map.new(snapshot.pathways, &{&1.pathway_id, &1})

    evolutions =
      scoped_evolutions(organization_id, gtfs_version_id)
      |> where([e], e.pathway_id in ^Map.keys(pathway_by_id))
      |> order_by([e], asc: e.pathway_id, asc: e.start_time, asc: e.service_id, asc: e.end_time)
      |> order_by([e], asc: e.id)
      |> Repo.all()

    with {:ok, options} <-
           calendar_options(
             organization_id,
             gtfs_version_id,
             MapSet.new(evolutions, & &1.service_id)
           ) do
      options_by_service = Map.new(options, &{&1.service_id, &1})

      rows =
        Enum.map(evolutions, fn evolution ->
          %{
            evolution: evolution,
            fingerprint: fingerprint(evolution),
            pathway: Map.fetch!(pathway_by_id, evolution.pathway_id),
            calendar: Map.get(options_by_service, evolution.service_id)
          }
        end)

      {:ok, rows}
    end
  end

  defp calendar_options(organization_id, gtfs_version_id, only_service_ids) do
    with {:ok, summaries} <- Calendars.list_calendars(organization_id, gtfs_version_id) do
      native = native_service_ids(organization_id, gtfs_version_id)
      closure_counts = closure_counts_by_service(organization_id, gtfs_version_id)

      options =
        summaries
        |> Enum.filter(fn summary ->
          MapSet.member?(native, summary.service_id) and
            (is_nil(only_service_ids) or MapSet.member?(only_service_ids, summary.service_id))
        end)
        |> Enum.map(&calendar_option(&1, closure_counts))

      {:ok, options}
    end
  end

  defp calendar_option(summary, closure_counts) do
    %{
      service_id: summary.service_id,
      name: summary.name,
      label: calendar_label(summary),
      first_active_date: summary.first_active_date,
      last_active_date: summary.last_active_date,
      active_date_count: length(summary.active_dates),
      trip_count: summary.trip_count,
      closure_count: Map.get(closure_counts, summary.service_id, 0)
    }
  end

  defp calendar_label(%{name: name, service_id: service_id}) when is_binary(name) do
    case String.trim(name) do
      "" -> service_id
      trimmed -> trimmed
    end
  end

  defp calendar_label(%{service_id: service_id}), do: service_id

  # The native reference boundary for closures: a service counts only when a
  # weekly or exception row exists in the scope. A metadata-only identity does
  # not qualify.
  defp native_service_ids(organization_id, gtfs_version_id) do
    weekly =
      from(c in Calendar,
        where: c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id,
        select: c.service_id
      )

    dates =
      from(d in CalendarDate,
        where: d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id,
        select: d.service_id
      )

    from(s in subquery(union(weekly, ^dates)), select: s.service_id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp closure_counts_by_service(organization_id, gtfs_version_id) do
    scoped_evolutions(organization_id, gtfs_version_id)
    |> group_by([e], e.service_id)
    |> select([e], {e.service_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp scoped_evolutions(organization_id, gtfs_version_id) do
    from(e in PathwayEvolution,
      where: e.organization_id == ^organization_id and e.gtfs_version_id == ^gtfs_version_id
    )
  end

  defp validate_scope(organization_id, gtfs_version_id) do
    if uuid?(organization_id) and uuid?(gtfs_version_id) and
         Versions.published_gtfs_version_for_org?(organization_id, gtfs_version_id) do
      :ok
    else
      :error
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false
end
