defmodule GtfsPlanner.Home do
  @moduledoc """
  The logged-in homepage's read boundary.

  Every function takes the organization and GTFS version ids from the mount
  assigns, so no request parameter selects a tenant or a version, and every read
  is read-only. The module composes the domain reads the page needs — access
  data, resume items, the station board and its statuses, station editors, the
  planner status and attention facts, and the check-and-share facts — into
  display-ready maps, which keeps `DashboardLive` free of context aliases and
  gives the region failure seam one module to substitute.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.RecentChanges.Describe
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Home.Attention
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Versions

  @admin_role "pathways_studio_admin"

  @doc """
  Returns the organization's active administrators' emails, sorted.

  A member is an administrator when their membership is not deactivated and
  carries the `#{@admin_role}` role. Members of another organization never
  appear.
  """
  @spec organization_admins(Ecto.UUID.t()) :: [String.t()]
  def organization_admins(organization_id) do
    organization_id
    |> Organizations.list_users_in_organization()
    |> Enum.filter(&active_admin?/1)
    |> Enum.map(& &1.user.email)
    |> Enum.sort()
  end

  @doc """
  Counts the organization's active members.

  A membership with a `deactivated_at` value does not count.
  """
  @spec member_count(Ecto.UUID.t()) :: non_neg_integer()
  def member_count(organization_id) do
    organization_id
    |> Organizations.list_users_in_organization()
    |> Enum.count(&is_nil(&1.deactivated_at))
  end

  @doc """
  Counts all organizations.
  """
  @spec organization_count() :: non_neg_integer()
  def organization_count do
    Organizations.count_organizations()
  end

  @doc """
  Returns one user's resume list for one version.

  The scope is `:own` when the user has changes in the version and `:team`
  otherwise. Items are the described recent-change destinations with the
  agency-local time; both the change scan and the description reads use the
  supplied organization and version ids.
  """
  @spec resume(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{scope: :own | :team, items: [Describe.resume_item()]}
  def resume(organization_id, gtfs_version_id, user_id) do
    zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)

    %{scope: scope, groups: groups} =
      Gtfs.recent_changes_for_user(organization_id, gtfs_version_id, user_id, zone)

    %{
      scope: scope,
      items: Describe.describe(organization_id, gtfs_version_id, groups, zone)
    }
  end

  @doc """
  Returns the station board's station summaries and per-station line counts.

  The summaries are `StationBoard.base/2`, each with `last_edited_local`, the
  agency-local wall clock of `last_edited_at` (nil when never edited). The UTC
  `last_edited_at` stays for ordering and staleness. `lines` maps every station
  `stop_id` to the number of routes its child platforms serve, so a station
  without served platforms reports 0. The count comes from the board's one
  platform-to-route query.
  """
  @spec station_board(Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{stations: [StationBoard.base()], lines: %{String.t() => non_neg_integer()}}
  def station_board(organization_id, gtfs_version_id) do
    stations = StationBoard.base(organization_id, gtfs_version_id)

    routes_by_station =
      Gtfs.routes_by_station(organization_id, gtfs_version_id, Enum.map(stations, & &1.stop_id))

    lines =
      Map.new(stations, fn station ->
        {station.stop_id, length(Map.get(routes_by_station, station.stop_id, []))}
      end)

    local_edits =
      local_times(organization_id, gtfs_version_id, Enum.map(stations, & &1.last_edited_at))

    stations =
      Enum.zip_with(stations, local_edits, &Map.put(&1, :last_edited_local, &2))

    %{stations: stations, lines: lines}
  end

  @doc """
  Returns the report issue count and latest reachability result per station.

  See `GtfsPlanner.Gtfs.StationBoard.statuses/3`.
  """
  @spec station_statuses(Ecto.UUID.t(), Ecto.UUID.t(), [StationBoard.base()]) ::
          %{String.t() => StationBoard.status()}
  def station_statuses(organization_id, gtfs_version_id, stations) do
    StationBoard.statuses(organization_id, gtfs_version_id, stations)
  end

  @doc """
  Lists station editing statuses with `started_at` localized for display.

  Returns the `Gtfs.list_station_editors/2` entries with `started_at` in the
  agency display zone. An empty version returns an empty list without resolving
  a zone.
  """
  @spec station_editors(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def station_editors(organization_id, gtfs_version_id) do
    case Gtfs.list_station_editors(organization_id, gtfs_version_id) do
      [] ->
        []

      editors ->
        zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)

        local_times =
          Gtfs.localize_display_times(Enum.map(editors, & &1.started_at), zone)

        editors
        |> Enum.zip(local_times)
        |> Enum.map(fn {editor, started_at} -> %{editor | started_at: started_at} end)
    end
  end

  @doc """
  Returns the GTFS Planner homepage's status facts for one version.

  Coverage comes from the version-wide calendar screen: `{:through, last_date}`
  when the read is complete and has a horizon, `:none` when the version has no
  calendars, and `:unknown` when calendars are unreadable or the read fails.
  `today` is the agency-local date the screen resolved; a failed read falls back
  to the UTC date because no agency zone was read. Counts are the route count,
  the calendar-screen row count and the top-level stop count. A version with no
  routes, no stops and no calendars is a first use. `published_on` is the
  agency-local date of the version's publication (its creation when it was never
  published), so the lede's day agrees with the clock times the page shows.

  Attention comes from the stopped imports — recoverable runs that are not
  active, so a `cleaning` run is not shown and a `failed` one is — and from the
  latest feed check when it found errors. A run outlives its version, so a
  stopped import can name a version other than this one and its item carries
  that version's name. A check item also carries `local_at`, its start on the
  agency-local wall clock. The calendar, count and check reads are scoped by the
  supplied organization and version ids; the import scan is scoped by the
  organization because a stopped import targets a version of its own. Nothing
  here writes or reconciles an import lease.
  """
  @spec planner_status(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          coverage: {:through, Date.t()} | :none | :unknown,
          today: Date.t(),
          published_on: Date.t(),
          counts: %{
            routes: non_neg_integer(),
            calendars: non_neg_integer(),
            stations: non_neg_integer()
          },
          first_use?: boolean(),
          attention: [Attention.item()]
        }
  def planner_status(organization_id, gtfs_version_id) do
    screen = calendar_screen(organization_id, gtfs_version_id)
    coverage = coverage(screen)
    today = screen_today(screen)
    counts = counts(organization_id, gtfs_version_id, screen_rows(screen))

    %{
      coverage: coverage,
      today: today,
      published_on: published_on(organization_id, gtfs_version_id),
      counts: counts,
      first_use?: first_use?(counts),
      attention:
        %{
          coverage: coverage,
          today: today,
          imports: stopped_imports(organization_id),
          check: Validations.latest_feed_check(organization_id, gtfs_version_id)
        }
        |> Attention.build(:planner)
        |> with_local_check_time(organization_id, gtfs_version_id)
    }
  end

  @doc """
  Returns the Pathways homepage's attention items for one version.

  The same stopped-import and check-error facts as `planner_status/2`, without
  reading calendars: a Pathways homepage never raises a service item.
  """
  @spec pathways_attention(Ecto.UUID.t(), Ecto.UUID.t()) :: [Attention.item()]
  def pathways_attention(organization_id, gtfs_version_id) do
    %{
      # Inert for :pathways: the builder never raises a service item, and this
      # read does not touch calendars.
      coverage: :unknown,
      today: Date.utc_today(),
      imports: stopped_imports(organization_id),
      check: Validations.latest_feed_check(organization_id, gtfs_version_id)
    }
    |> Attention.build(:pathways)
    |> with_local_check_time(organization_id, gtfs_version_id)
  end

  @doc """
  Returns the homepage's check-and-share facts for one version.

  The check is the newest completed or failed MobilityData run, with its error
  and warning counts and its start time; a reachability run is never reported
  as the feed check. The export is the product's own export type — `:full` for
  the GTFS Planner and `:pathways` for Pathways Studio. `expired?` covers both
  a swept `:expired` run and a `:ready` run whose `artifact_expires_at` is at
  or before now, so a run the maintenance sweep has not reached yet still
  reads as expired without this read changing it. The change count counts
  distinct operations (and distinct stations) logged after the export
  finished; an export that has not finished has no change count.

  `local_at` and `local_finished_at` are the check's start and the export's
  finish on the agency-local wall clock, for display.
  """
  @spec check_and_share(Ecto.UUID.t(), Ecto.UUID.t(), :planner | :pathways) :: %{
          check:
            nil
            | %{
                run_id: Ecto.UUID.t(),
                errors: non_neg_integer(),
                warnings: non_neg_integer(),
                at: DateTime.t(),
                local_at: NaiveDateTime.t()
              },
          export:
            nil
            | %{
                run_id: Ecto.UUID.t(),
                type: :full | :pathways,
                state: atom(),
                expired?: boolean(),
                finished_at: DateTime.t() | nil,
                local_finished_at: NaiveDateTime.t() | nil
              },
          since: nil | %{changes: non_neg_integer(), stations: non_neg_integer()}
        }
  def check_and_share(organization_id, gtfs_version_id, product) do
    run = ExportRuns.latest_for_version(organization_id, gtfs_version_id, export_type(product))
    check = Validations.latest_feed_check(organization_id, gtfs_version_id)

    [check_local_at, export_local_at] =
      local_times(organization_id, gtfs_version_id, [
        check && check.started_at,
        run && run.finished_at
      ])

    %{
      check: check_facts(check, check_local_at),
      export: export_facts(run, export_local_at),
      since: since_facts(organization_id, gtfs_version_id, run)
    }
  end

  defp export_type(:planner), do: :full
  defp export_type(:pathways), do: :pathways

  defp check_facts(nil, _local_at), do: nil

  defp check_facts(run, local_at) do
    %{
      run_id: run.id,
      errors: run.errors_count,
      warnings: run.warnings_count,
      at: run.started_at,
      local_at: local_at
    }
  end

  defp export_facts(nil, _local_finished_at), do: nil

  defp export_facts(run, local_finished_at) do
    %{
      run_id: run.id,
      type: run.export_type,
      state: run.state,
      expired?: expired?(run),
      finished_at: run.finished_at,
      local_finished_at: local_finished_at
    }
  end

  defp expired?(%{state: :expired}), do: true

  defp expired?(%{state: :ready, artifact_expires_at: expires_at}) when not is_nil(expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp expired?(_run), do: false

  defp since_facts(_organization_id, _gtfs_version_id, nil), do: nil
  defp since_facts(_organization_id, _gtfs_version_id, %{finished_at: nil}), do: nil

  defp since_facts(organization_id, gtfs_version_id, %{finished_at: finished_at}) do
    Gtfs.count_changes_since(organization_id, gtfs_version_id, finished_at)
  end

  defp published_on(organization_id, gtfs_version_id) do
    version = Versions.get_gtfs_version_for_lifecycle(organization_id, gtfs_version_id)

    [published_local] =
      local_times(organization_id, gtfs_version_id, [version.published_at || version.inserted_at])

    NaiveDateTime.to_date(published_local)
  end

  defp calendar_screen(organization_id, gtfs_version_id) do
    case Gtfs.load_calendar_screen(organization_id, gtfs_version_id) do
      {:ok, screen} -> screen
      {:error, _reason} -> nil
    end
  end

  defp screen_rows(nil), do: []
  defp screen_rows(screen), do: screen.rows

  defp screen_today(nil), do: Date.utc_today()
  defp screen_today(screen), do: screen.today

  defp coverage(nil), do: :unknown
  defp coverage(%{complete?: false}), do: :unknown
  defp coverage(%{horizon: nil, rows: []}), do: :none
  defp coverage(%{horizon: %{last_date: last_date}}), do: {:through, last_date}
  defp coverage(%{horizon: nil}), do: :unknown

  defp counts(organization_id, gtfs_version_id, rows) do
    %{
      routes: Gtfs.count_routes(organization_id, gtfs_version_id),
      calendars: length(rows),
      stations: Gtfs.count_stations(organization_id, gtfs_version_id)
    }
  end

  defp first_use?(%{routes: routes, calendars: calendars, stations: stations}) do
    routes == 0 and calendars == 0 and stations == 0
  end

  defp stopped_imports(organization_id) do
    stopped_states = Run.recoverable_states() -- Run.active_states()

    organization_id
    |> ImportRuns.list_recoverable()
    |> Enum.filter(&(&1.state in stopped_states))
  end

  defp with_local_check_time(items, organization_id, gtfs_version_id) do
    Enum.map(items, fn
      %{kind: :check_errors, at: at} = item ->
        [local_at] = local_times(organization_id, gtfs_version_id, [at])
        Map.put(item, :local_at, local_at)

      item ->
        item
    end)
  end

  # Stored instants are UTC; the page shows the agency's wall clock, like the
  # resume and editing-now times. One conversion covers the whole list, `nil`
  # stays `nil`, and a list without instants resolves no zone.
  defp local_times(organization_id, gtfs_version_id, instants) do
    case Enum.reject(instants, &is_nil/1) do
      [] ->
        Enum.map(instants, fn _instant -> nil end)

      present ->
        zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)
        local_by_instant = Map.new(Enum.zip(present, Gtfs.localize_display_times(present, zone)))
        Enum.map(instants, &Map.get(local_by_instant, &1))
    end
  end

  defp active_admin?(%{roles: roles, deactivated_at: deactivated_at}) do
    is_nil(deactivated_at) and @admin_role in roles
  end
end
