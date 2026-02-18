defmodule GtfsPlanner.Otp.Preflight do
  @moduledoc """
  OTP materialization preflight checks.

  This module currently provides:
    * required-file presence checks
    * referential-integrity checks
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.{Calendar, CalendarDate, Pathway, Route, Stop, StopTime, Trip}
  alias GtfsPlanner.Otp.Manifest
  alias GtfsPlanner.Repo

  @type issue :: %{
          code: atom(),
          severity: :error,
          message: String.t(),
          details: map()
        }

  @spec run(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, [issue()]}
  def run(organization_id, gtfs_version_id) do
    issues =
      required_file_issues(organization_id, gtfs_version_id) ++
        referential_integrity_issues(organization_id, gtfs_version_id)

    case issues do
      [] -> :ok
      _ -> {:error, issues}
    end
  end

  @spec required_file_issues(Ecto.UUID.t(), Ecto.UUID.t()) :: [issue()]
  def required_file_issues(organization_id, gtfs_version_id) do
    required_presence_issues(organization_id, gtfs_version_id) ++
      calendar_presence_issues(organization_id, gtfs_version_id)
  end

  @spec referential_integrity_issues(Ecto.UUID.t(), Ecto.UUID.t()) :: [issue()]
  def referential_integrity_issues(organization_id, gtfs_version_id) do
    [
      stop_times_trip_id_issues(organization_id, gtfs_version_id),
      stop_times_stop_id_issues(organization_id, gtfs_version_id),
      trips_route_id_issues(organization_id, gtfs_version_id),
      pathways_from_stop_id_issues(organization_id, gtfs_version_id),
      pathways_to_stop_id_issues(organization_id, gtfs_version_id)
    ]
    |> List.flatten()
  end

  defp required_presence_issues(organization_id, gtfs_version_id) do
    Manifest.required_base_specs()
    |> Enum.filter(fn spec ->
      not scoped_records_exist?(spec.schema, organization_id, gtfs_version_id)
    end)
    |> Enum.map(fn spec ->
      %{
        code: :missing_required_file_data,
        severity: :error,
        message: "Required GTFS file data is missing",
        details: %{
          file: spec.filename
        }
      }
    end)
  end

  defp calendar_presence_issues(organization_id, gtfs_version_id) do
    has_calendar = scoped_records_exist?(Calendar, organization_id, gtfs_version_id)
    has_calendar_dates = scoped_records_exist?(CalendarDate, organization_id, gtfs_version_id)

    if has_calendar or has_calendar_dates do
      []
    else
      [
        %{
          code: :missing_calendar_or_calendar_dates,
          severity: :error,
          message: "Either calendar.txt or calendar_dates.txt data is required",
          details: %{
            one_of: Manifest.file_requirements().one_of
          }
        }
      ]
    end
  end

  defp stop_times_trip_id_issues(organization_id, gtfs_version_id) do
    source_query =
      from(st in StopTime,
        left_join: t in Trip,
        on:
          t.organization_id == st.organization_id and
            t.gtfs_version_id == st.gtfs_version_id and
            t.trip_id == st.trip_id,
        where:
          st.organization_id == ^organization_id and
            st.gtfs_version_id == ^gtfs_version_id and
            is_nil(t.id)
      )

    integrity_issues(source_query, :stop_times_trip_id_missing_trip, %{
      source_file: "stop_times.txt",
      source_field: "trip_id",
      target_file: "trips.txt",
      target_field: "trip_id"
    })
  end

  defp stop_times_stop_id_issues(organization_id, gtfs_version_id) do
    source_query =
      from(st in StopTime,
        left_join: s in Stop,
        on:
          s.organization_id == st.organization_id and
            s.gtfs_version_id == st.gtfs_version_id and
            s.stop_id == st.stop_id,
        where:
          st.organization_id == ^organization_id and
            st.gtfs_version_id == ^gtfs_version_id and
            is_nil(s.id)
      )

    integrity_issues(source_query, :stop_times_stop_id_missing_stop, %{
      source_file: "stop_times.txt",
      source_field: "stop_id",
      target_file: "stops.txt",
      target_field: "stop_id"
    })
  end

  defp trips_route_id_issues(organization_id, gtfs_version_id) do
    source_query =
      from(t in Trip,
        left_join: r in Route,
        on:
          r.organization_id == t.organization_id and
            r.gtfs_version_id == t.gtfs_version_id and
            r.route_id == t.route_id,
        where:
          t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id and
            is_nil(r.id)
      )

    integrity_issues(source_query, :trips_route_id_missing_route, %{
      source_file: "trips.txt",
      source_field: "route_id",
      target_file: "routes.txt",
      target_field: "route_id"
    })
  end

  defp pathways_from_stop_id_issues(organization_id, gtfs_version_id) do
    source_query =
      from(p in Pathway,
        left_join: s in Stop,
        on:
          s.organization_id == p.organization_id and
            s.gtfs_version_id == p.gtfs_version_id and
            s.stop_id == p.from_stop_id,
        where:
          p.organization_id == ^organization_id and
            p.gtfs_version_id == ^gtfs_version_id and
            is_nil(s.id)
      )

    integrity_issues(source_query, :pathways_from_stop_id_missing_stop, %{
      source_file: "pathways.txt",
      source_field: "from_stop_id",
      target_file: "stops.txt",
      target_field: "stop_id"
    })
  end

  defp pathways_to_stop_id_issues(organization_id, gtfs_version_id) do
    source_query =
      from(p in Pathway,
        left_join: s in Stop,
        on:
          s.organization_id == p.organization_id and
            s.gtfs_version_id == p.gtfs_version_id and
            s.stop_id == p.to_stop_id,
        where:
          p.organization_id == ^organization_id and
            p.gtfs_version_id == ^gtfs_version_id and
            is_nil(s.id)
      )

    integrity_issues(source_query, :pathways_to_stop_id_missing_stop, %{
      source_file: "pathways.txt",
      source_field: "to_stop_id",
      target_file: "stops.txt",
      target_field: "stop_id"
    })
  end

  defp integrity_issues(source_query, code, details) do
    invalid_count = Repo.aggregate(source_query, :count)

    if invalid_count > 0 do
      [
        %{
          code: code,
          severity: :error,
          message: "Referential integrity check failed",
          details: Map.put(details, :invalid_count, invalid_count)
        }
      ]
    else
      []
    end
  end

  defp scoped_records_exist?(schema, organization_id, gtfs_version_id) do
    from(s in schema,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.exists?()
  end
end
