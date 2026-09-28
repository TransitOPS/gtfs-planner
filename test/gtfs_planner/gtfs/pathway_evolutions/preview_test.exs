defmodule GtfsPlanner.Gtfs.PathwayEvolutions.PreviewTest do
  @moduledoc """
  Merge evidence (EV-18) for `PathwayEvolutions.preview_closures/5`: the real
  repeatable-read boundary, PostgreSQL-derived service-day origins, agency-zone
  refusals, the bounded candidate envelope and the exact preview result.

  Every expectation is hand-derived from the acceptance cases and from PostgreSQL's
  timezone catalog, not from the pure `Schedule` evaluator, so the assertions reject
  an origin computed as local midnight, as civil-day addition or in Elixir time.
  The instants that matter here are:

      America/New_York    2027-03-14 (EDT, 23-hour date)  origin 04:00Z
      America/New_York    2027-11-07 (EST, 25-hour date)  origin 05:00Z
      America/Los_Angeles 2027-01-15 (PST)                origin 08:00Z
      America/Los_Angeles 2027-07-15 (PDT)                origin 07:00Z

  The serial cases pair the ordinary configured snapshot adapter with the
  production `Export.Snapshot.Repo` adapter, and a real two-session race reads a
  committed calendar and closure change wholly before or wholly after the
  repeatable-read snapshot.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Snapshot
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 10_000
  @pause_timeout 30_000
  @race_handler {__MODULE__, :preview_snapshot_race}

  # 2027-03-14 is the second Sunday of March: America/New_York springs forward, so
  # the service date is 23 elapsed hours long and its origin is 04:00Z.
  @spring_forward ~D[2027-03-14]
  # 2027-11-07 is the first Sunday of November: a 25-hour service date, origin 05:00Z.
  @fall_back ~D[2027-11-07]
  # 2027-04-12 is a Monday, so `25:00:00-26:00:00` is Tuesday 01:00-02:00 local.
  @monday ~D[2027-04-12]

  describe "preview_closures/5 service-day instants" do
    test "resolves a New York spring-forward service date to 04:15Z at 00:15:00" do
      scope = station_scope()
      assert {:ok, closure} = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})

      assert {:ok, preview} = preview(scope, @spring_forward, 900)

      # origin(2027-03-14) is 04:00Z, so 00:15:00 of service time is 04:15Z and
      # 23:15 the previous evening on the agency's own local clock.
      assert preview.service_date == @spring_forward
      assert preview.service_time == 900
      assert preview.instant == ~U[2027-03-14 04:15:00.000000Z]
      assert preview.local_time == ~N[2027-03-13 23:15:00.000000]
      assert preview.timezone == "America/New_York"
      assert %DateTime{} = preview.computed_at

      # Half-open: the 00:00:00-00:30:00 instance covers 00:15:00 and ends at
      # 00:30:00, which is 04:30Z on the same UTC day.
      assert [instance] = preview.closed
      assert instance.evolution_id == closure.evolution.id
      assert instance.service_date == @spring_forward
      assert instance.pathway_id == "PW_ENTRY"
      assert instance.service_id == "SVC"
      assert instance.start_time == 0
      assert instance.end_time == 1800
      assert instance.starts_at == ~U[2027-03-14 04:00:00.000000Z]
      assert instance.ends_at == ~U[2027-03-14 04:30:00.000000Z]

      assert preview.day_instances == preview.closed
      # The displayed span runs to the next origin; a 00:30 window does not reach
      # it, and the previous service date's 00:30 instance ended the day before.
      assert preview.timeline_start == ~U[2027-03-14 04:00:00.000000Z]
      assert preview.timeline_end == ~U[2027-03-15 04:00:00.000000Z]
      assert preview.timeline_instances == preview.day_instances

      # before/closes/during/reopens are exact service-day seconds; `before` falls
      # before its own origin and therefore walks back to 2027-03-13.
      assert boundary(preview, closure, :before) == {~D[2027-03-13], 82_740}
      assert boundary(preview, closure, :closes) == {@spring_forward, 0}
      assert boundary(preview, closure, :during) == {@spring_forward, 900}
      assert boundary(preview, closure, :reopens) == {@spring_forward, 1800}
    end

    test "resolves a New York fall-back service date to 05:00Z at 00:00:00" do
      scope = station_scope(calendar: daily_calendar("SVC", ~D[2027-11-01], ~D[2027-11-30]))
      _closure = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})
      assert {:ok, preview} = preview(scope, @fall_back, 0)

      assert preview.instant == ~U[2027-11-07 05:00:00.000000Z]
      # Local noon on 2027-11-07 is already EST, so the origin is 05:00Z. That
      # instant is still 01:00 EDT: the transition to EST happens an hour later, so
      # the extra hour of the 25-hour day sits between 01:00 and 02:00 local.
      assert preview.local_time == ~N[2027-11-07 01:00:00.000000]

      assert [%{starts_at: ~U[2027-11-07 05:00:00.000000Z], service_date: @fall_back}] =
               preview.closed

      assert [%{starts_at: ~U[2027-11-07 05:00:00.000000Z], service_date: @fall_back}] =
               preview.day_instances

      assert preview.timeline_end == ~U[2027-11-08 05:00:00.000000Z]
    end

    test "keeps Los Angeles winter and summer origins at 08:00Z and 07:00Z" do
      scope =
        station_scope(
          agencies: [%{agency_timezone: "America/Los_Angeles"}],
          calendar: daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31])
        )

      _closure = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})

      assert {:ok, winter} = preview(scope, ~D[2027-01-15], 0)
      assert winter.timezone == "America/Los_Angeles"
      assert winter.instant == ~U[2027-01-15 08:00:00.000000Z]
      assert winter.local_time == ~N[2027-01-15 00:00:00.000000]

      assert {:ok, summer} = preview(scope, ~D[2027-07-15], 0)
      assert summer.timezone == "America/Los_Angeles"
      assert summer.instant == ~U[2027-07-15 07:00:00.000000Z]
      assert summer.local_time == ~N[2027-07-15 00:00:00.000000]
    end
  end

  describe "preview_closures/5 comparison" do
    test "reports a closed walkway as four lost directions and a platform without step-free" do
      scope = station_scope()
      _closure = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})

      assert {:ok, preview} = preview(scope, @spring_forward, 900)

      assert preview.base.status == :complete
      assert preview.base.incomplete_reasons == []

      assert [pair] = preview.base.pairs
      assert pair.entrance_id == "ENT_1"
      assert pair.platform_id == "PLAT_1"
      assert pair.walking_to_platform
      assert pair.step_free_to_platform
      assert pair.walking_to_exit
      assert pair.step_free_to_exit

      # The one bidirectional walkway is the only connection, so removing it in
      # both directions empties every reachability flag.
      assert [effective_pair] = preview.effective.pairs
      refute effective_pair.walking_to_platform
      refute effective_pair.step_free_to_platform
      refute effective_pair.walking_to_exit
      refute effective_pair.step_free_to_exit

      assert preview.comparison.baseline_gaps == []

      assert preview.comparison.lost == [
               %{
                 platform_id: "PLAT_1",
                 entrance_id: "ENT_1",
                 mode: :step_free,
                 direction: :to_exit
               },
               %{
                 platform_id: "PLAT_1",
                 entrance_id: "ENT_1",
                 mode: :step_free,
                 direction: :to_platform
               },
               %{
                 platform_id: "PLAT_1",
                 entrance_id: "ENT_1",
                 mode: :walking,
                 direction: :to_exit
               },
               %{
                 platform_id: "PLAT_1",
                 entrance_id: "ENT_1",
                 mode: :walking,
                 direction: :to_platform
               }
             ]

      assert preview.comparison.platforms_without_step_free == %{
               to_platform: ["PLAT_1"],
               to_exit: ["PLAT_1"]
             }
    end
  end

  describe "preview_closures/5 timeline" do
    test "keeps a 25:00 window, previous-service-date spill-over and unclipped targets" do
      scope = station_scope(calendar: daily_calendar("SVC", ~D[2027-04-01], ~D[2027-04-30]))

      assert {:ok, overnight} = save_closure(scope, %{start_time: "25:00", end_time: "26:00"})
      assert {:ok, first_hour} = save_closure(scope, %{start_time: "00:00", end_time: "01:00"})

      assert {:ok, preview} = preview(scope, @monday, 0)

      assert preview.instant == ~U[2027-04-12 04:00:00.000000Z]

      # At local midnight only the 00:00 window is active: a 25:00:00 window starts
      # 25 hours after the origin, which is Tuesday 01:00 local.
      assert [only] = preview.closed
      assert only.evolution_id == first_hour.evolution.id
      assert preview.closed |> MapSet.new(& &1.pathway_id) == MapSet.new(["PW_ENTRY"])

      assert [first_hour_instance, overnight_instance] = preview.day_instances
      assert first_hour_instance.evolution_id == first_hour.evolution.id
      assert first_hour_instance.starts_at == ~U[2027-04-12 04:00:00.000000Z]
      assert first_hour_instance.ends_at == ~U[2027-04-12 05:00:00.000000Z]
      assert overnight_instance.evolution_id == overnight.evolution.id
      assert overnight_instance.starts_at == ~U[2027-04-13 05:00:00.000000Z]
      assert overnight_instance.ends_at == ~U[2027-04-13 06:00:00.000000Z]

      # The displayed span reaches past the next origin because the 25:00 window
      # ends at 06:00Z on 2027-04-13, two hours after that origin.
      assert preview.timeline_start == ~U[2027-04-12 04:00:00.000000Z]
      assert preview.timeline_end == ~U[2027-04-13 06:00:00.000000Z]

      # Spill-over from the previous service date and from the next one is visible
      # in the timeline, and the previous date's 00:00 window is not.
      assert Enum.map(preview.timeline_instances, &{&1.service_date, &1.start_time}) == [
               {@monday, 0},
               {~D[2027-04-11], 90_000},
               {~D[2027-04-13], 0},
               {@monday, 90_000}
             ]

      # `before` of the midnight window resolves before the displayed span, and
      # `reopens` keeps 25:00:00/26:00:00 instead of being reparsed as clock labels.
      assert boundary(preview, first_hour, :before) == {~D[2027-04-11], 86_340}
      assert boundary(preview, first_hour, :closes) == {@monday, 0}
      assert boundary(preview, first_hour, :during) == {@monday, 1800}
      assert boundary(preview, first_hour, :reopens) == {@monday, 3600}
      assert boundary(preview, overnight, :before) == {@monday, 89_940}
      assert boundary(preview, overnight, :closes) == {@monday, 90_000}
      assert boundary(preview, overnight, :during) == {@monday, 91_800}
      assert boundary(preview, overnight, :reopens) == {@monday, 93_600}

      # The same Monday finds the 25:00 window at 25:00:00 - Tuesday 01:00 local -
      # and is open again at 26:00:00, so a window is closed at its start and open
      # at its end.
      assert {:ok, during_overnight} = preview(scope, @monday, 90_000)
      assert during_overnight.instant == ~U[2027-04-13 05:00:00.000000Z]
      assert during_overnight.local_time == ~N[2027-04-13 01:00:00.000000]
      assert [open_window] = during_overnight.closed
      assert open_window.evolution_id == overnight.evolution.id
      assert open_window.service_date == @monday
      assert open_window.start_time == 90_000

      assert {:ok, after_overnight} = preview(scope, @monday, 93_600)
      assert after_overnight.instant == ~U[2027-04-13 06:00:00.000000Z]
      assert after_overnight.closed == []
    end

    test "expands an insufficient candidate envelope instead of omitting an instance" do
      scope = station_scope(calendar: daily_calendar("SVC", ~D[2027-03-01], ~D[2027-03-31]))

      # A 25:00:00 window on the 23-hour spring-forward date ends at 05:00Z, an hour
      # after the next origin, so the 82,800-second candidate estimate cannot bound
      # the displayed span and the envelope must widen past it.
      assert {:ok, long} = save_closure(scope, %{start_time: "00:00", end_time: "25:00"})
      _short = save_closure(scope, %{start_time: "00:00", end_time: "01:00"})

      assert {:ok, preview} = preview(scope, @spring_forward, 0)

      assert preview.instant == ~U[2027-03-14 04:00:00.000000Z]
      assert preview.timeline_start == ~U[2027-03-14 04:00:00.000000Z]
      assert preview.timeline_end == ~U[2027-03-15 05:00:00.000000Z]

      # The previous service date's long window still covers the instant, so all
      # three covering windows are reported for the one pathway.
      assert Enum.map(preview.closed, &{&1.service_date, &1.end_time}) == [
               {~D[2027-03-13], 90_000},
               {@spring_forward, 3600},
               {@spring_forward, 90_000}
             ]

      # 2027-03-15's own instances intersect the displayed span, and they need the
      # origin the initial envelope did not load.
      assert Enum.map(preview.timeline_instances, &{&1.service_date, &1.start_time}) == [
               {~D[2027-03-13], 0},
               {@spring_forward, 0},
               {@spring_forward, 0},
               {~D[2027-03-15], 0},
               {~D[2027-03-15], 0}
             ]

      refute Enum.any?(preview.timeline_instances, &(&1.service_date == ~D[2027-03-16]))
      assert boundary(preview, long, :reopens) == {@spring_forward, 90_000}
    end
  end

  describe "preview_closures/5 agency zone" do
    test "refuses a missing, invalid or conflicting zone while authoring still works" do
      cases = [
        {:missing, []},
        {:invalid, [%{agency_timezone: "Not/AZone"}]},
        {:conflicting,
         [%{agency_timezone: "America/New_York"}, %{agency_timezone: "Europe/Paris"}]}
      ]

      for {reason, agencies} <- cases do
        scope =
          station_scope(
            agencies: agencies,
            calendar: daily_calendar("SVC", ~D[2027-01-01], ~D[2027-12-31])
          )

        assert preview(scope, ~D[2027-01-15], 0) == {:error, {:timezone_unavailable, reason}}

        # The UTC fallback is never used for analysis, and the refusal does not
        # block authoring: the closure is still saved and audited.
        assert {:ok, mutation} = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})
        assert mutation.evolution.pathway_id == "PW_ENTRY"
        assert mutation.evolution.start_time == 0
        assert mutation.evolution.end_time == 1800
        assert mutation.fingerprint == PathwayEvolutions.fingerprint(mutation.evolution)
        assert mutation.notices == []
      end
    end
  end

  describe "preview_closures/5 scope" do
    test "returns not_found for foreign, unpublished, non-station and malformed scopes" do
      scope = station_scope()
      _closure = save_closure(scope, %{start_time: "00:00", end_time: "00:30"})

      organization_id = scope.organization.id
      version_id = scope.version.id

      # A platform is not a station, and an unknown stop does not exist.
      assert Gtfs.preview_closures(organization_id, version_id, "PLAT_1", @spring_forward, 900) ==
               {:error, :not_found}

      assert Gtfs.preview_closures(organization_id, version_id, "NOPE", @spring_forward, 900) ==
               {:error, :not_found}

      assert Gtfs.preview_closures("not-a-uuid", version_id, "STN_1", @spring_forward, 900) ==
               {:error, :not_found}

      assert Gtfs.preview_closures(organization_id, "12345", "STN_1", @spring_forward, 900) ==
               {:error, :not_found}

      # An unpublished staging version holds its own rows and stays invisible.
      {:ok, staging} = Versions.create_staging_gtfs_version(organization_id, %{name: "Staging"})
      level_fixture(organization_id, staging.id, %{level_id: "L_STREET", level_index: 0.0})

      staging_station =
        stop_fixture(organization_id, staging.id, %{stop_id: "STN_S", location_type: 1})

      pathway_fixture(organization_id, staging.id, staging_station.stop_id, "OUT_S", %{
        pathway_id: "PW_S"
      })

      assert Gtfs.preview_closures(organization_id, staging.id, "STN_S", @spring_forward, 900) ==
               {:error, :not_found}

      # A foreign organization's version never resolves this organization's station.
      foreign_version = gtfs_version_fixture(organization_fixture().id)

      assert Gtfs.preview_closures(
               organization_id,
               foreign_version.id,
               "STN_1",
               @spring_forward,
               900
             ) == {:error, :not_found}
    end
  end

  describe "preview_closures/5 bounds" do
    setup do
      scope = station_scope(calendar: daily_calendar("SVC", ~D[2027-01-01], ~D[2098-12-31]))

      for hour <- 0..7 do
        {:ok, _} = save_closure(scope, %{start_time: "#{hour}:00", end_time: "#{hour}:30"})
      end

      %{scope: scope}
    end

    test "refuses more than 200000 instances before building them", %{scope: scope} do
      # The candidate envelope reaches about 25,938 civil dates, so eight daily
      # windows on a schedule that covers them produce about 207,000 instances.
      assert preview(scope, ~D[2027-01-15], 2_147_483_647) == {:error, :analysis_too_large}

      # The same scope answers an ordinary request, so the refusal is the bound and
      # not a broken scope.
      assert {:ok, small} = preview(scope, ~D[2027-01-15], 3600)
      assert small.instant == ~U[2027-01-15 06:00:00.000000Z]
      assert length(small.day_instances) == 8
    end

    test "refuses candidate arithmetic beyond the supported date span", %{scope: scope} do
      assert preview(scope, ~D[2027-01-15], 10_000_000_000) == {:error, :analysis_too_large}
    end
  end

  describe "preview_closures/5 snapshot adapters" do
    setup do
      %{supervisor: start_supervised!({Task.Supervisor, name: __MODULE__.RaceSupervisor})}
    end

    test "the configured adapter and the production adapter read the same preview", %{
      supervisor: supervisor
    } do
      # Ordinary test configuration: the sandbox already owns an open transaction,
      # so the configured adapter is the no-op one.
      assert Application.get_env(:gtfs_planner, :gtfs_export_snapshot) == Snapshot.Sandbox

      sandboxed = station_scope()
      {:ok, _} = save_closure(sandboxed, %{start_time: "00:00", end_time: "00:30"})
      assert {:ok, default_result} = preview(sandboxed, @spring_forward, 900)

      # The same scope through the production adapter, on its own committing
      # connection, must reach the identical answer.
      committed = in_task(supervisor, fn -> station_scope() end)
      on_exit(fn -> cleanup([committed]) end)

      {:ok, _} =
        in_task(supervisor, fn ->
          save_closure(committed, %{start_time: "00:00", end_time: "00:30"})
        end)

      use_production_snapshot()

      assert {:ok, production_result} =
               in_task(supervisor, fn -> preview(committed, @spring_forward, 900) end)

      assert observable(default_result) == observable(production_result)
      assert production_result.instant == ~U[2027-03-14 04:15:00.000000Z]
    end

    test "reads a concurrent calendar and closure change wholly before or wholly after", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> station_scope() end)
      on_exit(fn -> cleanup([scope]) end)

      saved =
        in_task(supervisor, fn ->
          save_closure(scope, %{start_time: "00:00", end_time: "00:30"})
        end)

      assert {:ok, saved} = saved
      use_production_snapshot()
      parent = self()

      reader =
        Task.Supervisor.async_nolink(supervisor, fn ->
          send(parent, {:reader_ready, self()})

          receive do
            :start_read -> :ok
          end

          production_preview(scope, @spring_forward, 900)
        end)

      assert_receive {:reader_ready, reader_pid}, @collect_timeout
      assert reader_pid == reader.pid

      # The reader pauses inside its repeatable-read transaction, after it has read
      # the station's closures and before it reads the native calendars.
      pause_after_closure_read(parent, reader.pid)
      send(reader.pid, :start_read)
      assert_receive {:preview_paused, ^reader_pid}, @collect_timeout

      writer =
        Task.Supervisor.async_nolink(supervisor, fn ->
          in_task(supervisor, fn -> commit_concurrent_change(scope, saved) end)
        end)

      assert :ok = Task.await(writer, @collect_timeout)

      send(reader.pid, :resume_preview)
      assert {:ok, before_change} = Task.await(reader, @collect_timeout)

      # Read wholly before the commit: the service date is still active and the
      # window is still the midnight one.
      assert before_change.instant == ~U[2027-03-14 04:15:00.000000Z]

      assert [%{service_date: @spring_forward, start_time: 0, end_time: 1800}] =
               before_change.day_instances

      assert [%{start_time: 0}] = before_change.closed

      # Read wholly after the commit: the removal exception takes 2027-03-14 out of
      # the schedule, so the same request has no instance at all. Two whole states,
      # never one of each.
      assert {:ok, after_change} =
               in_task(supervisor, fn -> preview(scope, @spring_forward, 900) end)

      assert after_change.instant == ~U[2027-03-14 04:15:00.000000Z]
      assert after_change.day_instances == []
      assert after_change.closed == []
      assert after_change.timeline_instances == []
      assert after_change.timeline_end == ~U[2027-03-15 04:00:00.000000Z]
    end
  end

  # -- station scope ----------------------------------------------------------

  # One station with a single bidirectional walkway between its entrance and its
  # platform, so closing that walkway empties every direction. `SVC` is a daily
  # calendar over the requested span unless another one is supplied.
  defp station_scope(opts \\ []) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    for attrs <- Keyword.get(opts, :agencies, [%{agency_timezone: "America/New_York"}]) do
      agency_fixture(organization.id, version.id, attrs)
    end

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})
    stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    stop_fixture(organization.id, version.id, %{
      stop_id: "ENT_1",
      location_type: 2,
      parent_station: "STN_1",
      level_id: "L_STREET"
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "PLAT_1",
      location_type: 0,
      parent_station: "STN_1",
      level_id: "L_PLAT"
    })

    pathway_fixture(organization.id, version.id, "ENT_1", "PLAT_1", %{
      pathway_id: "PW_ENTRY",
      pathway_mode: 1
    })

    calendar_fixture(
      organization.id,
      version.id,
      Keyword.get(opts, :calendar, daily_calendar("SVC", ~D[2027-03-01], ~D[2027-03-31]))
    )

    %{
      organization: organization,
      version: version,
      actor: actor,
      service_id: "SVC",
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "STN_1",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp daily_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: first,
      end_date: last
    }
  end

  defp save_closure(scope, attrs) do
    Gtfs.create_pathway_evolution(
      Map.merge(%{pathway_id: "PW_ENTRY", service_id: scope.service_id}, attrs),
      scope.audit
    )
  end

  defp preview(scope, service_date, service_time) do
    Gtfs.preview_closures(
      scope.organization.id,
      scope.version.id,
      "STN_1",
      service_date,
      service_time
    )
  end

  defp boundary(preview, saved, phase) do
    key = {saved.evolution.id, preview.service_date, phase}
    %{date: date, time: time} = Map.fetch!(preview.boundary_targets, key)

    {date, time}
  end

  # Two provisioned scopes have different closure UUIDs, so the adapter pairing
  # compares the observable preview rather than the identities.
  defp observable(preview) do
    %{
      instant: preview.instant,
      local_time: preview.local_time,
      timezone: preview.timezone,
      timeline: {preview.timeline_start, preview.timeline_end},
      closed: window(preview.closed),
      day_instances: window(preview.day_instances),
      timeline_instances: window(preview.timeline_instances),
      boundary_targets:
        Map.new(preview.boundary_targets, fn {{_id, _date, phase}, value} -> {phase, value} end),
      base: preview.base,
      effective: preview.effective,
      comparison: preview.comparison
    }
  end

  defp window(instances) do
    Enum.map(instances, &{&1.service_date, &1.start_time, &1.end_time, &1.starts_at, &1.ends_at})
  end

  # -- snapshot adapter plumbing ----------------------------------------------

  # Runs `fun` on its own committing PostgreSQL connection, outside the test's
  # sandbox transaction, so the rows it writes are visible to another session.
  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  # `SET TRANSACTION ISOLATION LEVEL` only applies at the top of a transaction, so
  # the production adapter needs a connection that holds no enclosing transaction.
  # The reader's task therefore calls `unboxed/1` directly; the adapter itself is
  # selected here, in the test process, so the restore belongs to this test's
  # `on_exit` and survives a task that is killed before it can restore anything.
  defp use_production_snapshot do
    previous = Application.get_env(:gtfs_planner, :gtfs_export_snapshot)
    on_exit(fn -> Application.put_env(:gtfs_planner, :gtfs_export_snapshot, previous) end)

    Application.put_env(:gtfs_planner, :gtfs_export_snapshot, Snapshot.Repo)
  end

  defp production_preview(scope, service_date, service_time) do
    unboxed(fn -> preview(scope, service_date, service_time) end)
  end

  # Pauses the reader's session the first time it reads the station's closure rows,
  # which is inside its repeatable-read transaction and before it reads the native
  # calendars. The pause is a rendezvous, not a sleep.
  defp pause_after_closure_read(parent, reader_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, reader} ->
        if self() == reader and
             String.contains?(to_string(metadata[:query]), ~s(FROM "pathway_evolutions")) do
          :telemetry.detach(@race_handler)
          send(owner, {:preview_paused, self()})

          receive do
            :resume_preview -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      {parent, reader_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  # A committed calendar and closure change in another session: the window moves to
  # midday and a removal exception takes the previewed service date out of service.
  defp commit_concurrent_change(scope, saved) do
    Repo.transaction(fn ->
      {:ok, _} =
        Gtfs.update_pathway_evolution(
          saved.evolution.id,
          %{start_time: "12:00", end_time: "12:30"},
          saved.fingerprint,
          scope.audit
        )

      calendar_date_fixture(scope.organization.id, scope.version.id, %{
        service_id: scope.service_id,
        date: @spring_forward,
        exception_type: 2
      })
    end)

    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(scopes) do
    unboxed(fn ->
      organization_ids = Enum.map(scopes, & &1.organization.id)
      user_ids = Enum.map(scopes, & &1.actor.id)

      Repo.delete_all(from(l in ChangeLog, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(e in PathwayEvolution, where: e.organization_id in ^organization_ids))
      Repo.delete_all(from(p in Pathway, where: p.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(l in Level, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id in ^organization_ids))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(
               from(e in PathwayEvolution, where: e.organization_id in ^organization_ids)
             )

      refute Repo.exists?(from(c in Calendar, where: c.organization_id in ^organization_ids))
      refute Repo.exists?(from(s in Stop, where: s.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end
