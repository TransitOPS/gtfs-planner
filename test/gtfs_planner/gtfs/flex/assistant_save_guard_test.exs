defmodule GtfsPlanner.Gtfs.Flex.AssistantSaveGuardTest do
  @moduledoc """
  Merge evidence (EV-5) for the guarded native Flex save
  (`GtfsPlanner.Gtfs.Flex.save_service/5`) and the reviewed guard it is fenced
  with.

  The expectations are hand-derived from the acceptance cases and from the
  native fixtures, not from a second invocation of the code under test:

    * A reviewed guard carries six server-computed digests, and a save that
      presents one persists the whole native page — the replaced hours and
      booking rules, and every contact, eligibility, area name and polygon the
      candidate did not touch.
    * The reviewed baseline is `Assistant.fingerprint/1` over the saved service,
      its areas with their stored geometry, and the weekly rows, exceptions and
      attributes of every calendar its stored fields name. A calendar-only
      commit therefore refuses the save even though the service's
      `lock_version` never moved, and an area-only commit refuses it without the
      guarded save overwriting the other editor's area.
    * A field edited after the review refuses the save too, because the guard
      carries the digest of the whole page the review showed.
    * A calendar only the proposal names, which the baseline does not cover,
      refuses the save through the guard's own calendar digest.
    * The exclusive fence is proven with two real independent connections: a
      guarded save that holds it excludes both a calendar `FOR UPDATE` writer
      and an ordinary Flex `FOR SHARE` writer, and a calendar writer that
      commits first leaves the guarded save refusing as stale.
    * Revoked membership is `{:error, :forbidden}` before the version lock, an
      unavailable version is `{:error, :version_unavailable}` and a service
      that is gone is `{:error, :stale}`: the native outcomes are unchanged, and
      ordinary `save_service/4` still saves.

  Contention is proven by polling `pg_blocking_pids/1` for the holder's own
  backend until the writer is genuinely waiting, so no timing sleep is the
  proof. Every unboxed case commits its own fixtures and deletes exactly those.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.GtfsFixtures, only: [calendar_fixture: 3]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.Flex.Assistant.Guard
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @collect_timeout 15_000
  @contention_timeout 10_000
  @fence_handler {__MODULE__, :hold_version_fence}
  # How long a participant may hold the fence before it releases itself, so a
  # failed case cannot hang the suite. Every poll below finishes well inside it.
  @fence_timeout 30_000

  # The complete replacement `hours` array the prepared cases review: the same
  # four rows the fixture saves, with both weekday windows moved to 08:00–17:00.
  @hours_patch [
    %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
    %{"area_key" => "a2", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
    %{"area_key" => "a1", "service_id" => "saturday", "start" => "09:00", "end" => "17:00"},
    %{"area_key" => "a2", "service_id" => "saturday", "start" => "09:00", "end" => "17:00"}
  ]

  # The one calendar write the interleaving cases commit: the saved service's
  # weekday calendar gains Saturday, which changes no flex service row at all.
  @weekday_command {:save, "weekday", %{saturday: 1}}

  # The same kind of write on a calendar no saved row of the service names.
  @holiday_command {:save, "holiday", %{saturday: 1}}

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})}
  end

  describe "a reviewed guard saves the whole native page (AC-10, AC-11)" do
    setup :flex_context

    test "persists the reviewed candidate and nothing else changes", context do
      reviewed = reviewed(context)
      before = row_counts(context.organization.id)

      assert {:ok, saved} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      # The reviewed hours are the ones the preparation compared, in the
      # reviewed order.
      assert Enum.map(saved.hours, &{&1.area_key, &1.service_id, &1.start, &1.end}) ==
               Enum.map(reviewed.draft.hours, &{&1.area_key, &1.service_id, &1.start, &1.end})

      assert Enum.map(saved.hours, &{&1.start, &1.end}) ==
               [{"08:00", "17:00"}, {"08:00", "17:00"}, {"09:00", "17:00"}, {"09:00", "17:00"}]

      # The hours-only preparation retained every booking rule exactly.
      assert Enum.map(saved.booking_rules, &{&1.service_id, &1.office_service_id, &1.minutes}) ==
               Enum.map(
                 reviewed.loaded.booking_rules,
                 &{&1.service_id, &1.office_service_id, &1.minutes}
               )

      # Contacts, eligibility, area names and geometry are the saved ones, not
      # the candidate's: the whole page was written, so nothing was dropped.
      assert saved.phone == "(541) 555-0142"
      assert saved.eligibility == reviewed.loaded.eligibility
      assert saved.include_registered == reviewed.loaded.include_registered
      assert Enum.map(saved.areas, &{&1.key, &1.name}) == [{"a1", "Newport"}, {"a2", "Toledo"}]

      assert Geometry.get_geojson(Enum.map(saved.areas, & &1.id)) |> map_size() == 2
      assert saved.lock_version == reviewed.loaded.lock_version + 1

      # The save itself writes no flex audit row, before or after the guard.
      assert row_counts(context.organization.id) == before

      refute Repo.exists?(
               from(l in ChangeLog, where: l.organization_id == ^context.organization.id)
             )
    end

    test "an ordinary save_service/4 is unchanged", context do
      reviewed = reviewed(context)

      assert {:ok, saved} =
               Flex.save_service(context.audit, reviewed.loaded, %{"note" => "Typed by hand"}, [
                 area_input(reviewed.loaded.areas, 1),
                 area_input(reviewed.loaded.areas, 2)
               ])

      assert saved.note == "Typed by hand"
      assert saved.hours == reviewed.loaded.hours
      assert Enum.map(saved.areas, &{&1.key, &1.name}) == [{"a1", "Newport"}, {"a2", "Toledo"}]
    end

    test "an options map that is not a guard writes nothing", context do
      reviewed = reviewed(context)
      forged = Map.from_struct(reviewed.guard)

      for options <- [
            %{},
            %{assistant_guard: reviewed.guard, extra: true},
            %{assistant_guard: Map.delete(forged, :candidate_digest)},
            %{assistant_guard: %{forged | candidate_digest: String.duplicate("a", 64)}}
          ] do
        assert {:error, :assistant_stale} =
                 Flex.save_service(
                   context.audit,
                   reviewed.loaded,
                   reviewed.attrs,
                   reviewed.area_inputs,
                   options
                 )
      end

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == reviewed.loaded.lock_version
      assert unchanged.hours == reviewed.loaded.hours
    end
  end

  describe "a changed dependency refuses the save (AC-10)" do
    setup :flex_context

    test "a calendar-only commit is assistant_stale with no service, area or audit write",
         context do
      reviewed = reviewed(context)

      # The saved service names `weekday` in two of its hours rows, and this
      # commit changes only that calendar's weekly row.
      assert {:ok, _result} = save_weekday_calendar(context)

      after_calendar = row_counts(context.organization.id)
      assert after_calendar.calendar_logs == 1

      assert {:error, :assistant_stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      # The service row never moved, so only the dependency check can have
      # refused this save.
      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == reviewed.loaded.lock_version
      assert unchanged.hours == reviewed.loaded.hours

      assert Enum.map(unchanged.areas, &{&1.key, &1.name}) == [
               {"a1", "Newport"},
               {"a2", "Toledo"}
             ]

      assert row_counts(context.organization.id) == after_calendar
    end

    test "a commit to a calendar only the proposal names is assistant_stale", context do
      # The saved rows name weekday, saturday and office. The proposal adds an
      # hours row on `holiday`, which none of them name, so the baseline
      # fingerprint cannot see it.
      calendar_fixture(context.organization.id, context.version.id, %{service_id: "holiday"})

      holiday_row = %{
        "area_key" => "a1",
        "service_id" => "holiday",
        "start" => "10:00",
        "end" => "14:00"
      }

      reviewed = reviewed(context, @hours_patch ++ [holiday_row])

      baseline = fn ->
        context.organization.id
        |> Assistant.dependencies(context.version.id, reviewed.loaded)
        |> Assistant.fingerprint()
      end

      before = baseline.()
      assert {:ok, _result} = save_holiday_calendar(context)
      assert baseline.() == before

      after_calendar = row_counts(context.organization.id)

      assert {:error, :assistant_stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == reviewed.loaded.lock_version
      assert unchanged.hours == reviewed.loaded.hours
      assert row_counts(context.organization.id) == after_calendar
    end

    test "an area-only commit is assistant_stale and the other editor's area survives", context do
      reviewed = reviewed(context)

      baseline =
        context.organization.id
        |> then(&Assistant.dependencies(&1, context.version.id, reviewed.loaded))
        |> Assistant.fingerprint()

      # An ordinary native area write: the page's own area editor renaming one
      # area, with no service field changed.
      assert {:ok, _saved} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 %{},
                 renamed_area_inputs(reviewed.area_inputs, "a1", "Newport zone")
               )

      assert {:ok, reloaded} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      after_area = Assistant.dependencies(context.organization.id, context.version.id, reloaded)

      # The area content is inside the baseline digest in its own right: holding
      # the service row at its pre-write value still moves the digest.
      assert Assistant.fingerprint(after_area) != baseline
      assert Assistant.fingerprint(%{after_area | service: reviewed.loaded}) != baseline

      after_write = row_counts(context.organization.id)

      assert {:error, :assistant_stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      # The refused save did not put its own area names back over the other
      # editor's.
      assert Enum.map(unchanged.areas, &{&1.key, &1.name}) == [
               {"a1", "Newport zone"},
               {"a2", "Toledo"}
             ]

      assert unchanged.hours == reviewed.loaded.hours
      assert row_counts(context.organization.id) == after_write
    end

    test "a page edited after the review is assistant_stale", context do
      reviewed = reviewed(context)

      # The contact is not one the preparation touched, but it is one the review
      # showed, and it is on the page the guard digest covers.
      assert {:ok, _saved} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      assert {:ok, reloaded} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert {:ok, _saved} =
               Flex.save_service(
                 context.audit,
                 reloaded,
                 %{"phone" => "(541) 555-0100"},
                 area_inputs(reloaded)
               )

      # The fresh baseline is the one this second review would have to carry, and
      # the page this guard was built for no longer matches it.
      fresh = reviewed(context)

      assert {:error, :assistant_stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: fresh.guard}
               )
    end

    test "a renamed area after the review is assistant_stale", context do
      reviewed = reviewed(context)

      assert {:error, :assistant_stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 renamed_area_inputs(reviewed.area_inputs, "a2", "Toledo zone"),
                 %{assistant_guard: reviewed.guard}
               )

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert Enum.map(unchanged.areas, &{&1.key, &1.name}) == [
               {"a1", "Newport"},
               {"a2", "Toledo"}
             ]
    end
  end

  describe "the native outcomes are unchanged (AC-1, AC-11)" do
    setup :flex_context

    test "a revoked membership is forbidden before the version lock", context do
      reviewed = reviewed(context)

      # A guard that is also out of date: membership still answers first.
      revoke(context)

      assert {:error, :forbidden} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == reviewed.loaded.lock_version
    end

    test "an unavailable version is version_unavailable", context do
      reviewed = reviewed(context)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      for version_id <- [Ecto.UUID.generate(), staging.id] do
        assert {:error, :version_unavailable} =
                 Flex.save_service(
                   %{context.audit | gtfs_version_id: version_id},
                   reviewed.loaded,
                   reviewed.attrs,
                   reviewed.area_inputs,
                   %{assistant_guard: reviewed.guard}
                 )
      end

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == reviewed.loaded.lock_version
    end

    test "a service that is gone is stale", context do
      reviewed = reviewed(context)

      assert :ok = Flex.delete_service(context.audit, context.service.id)

      assert {:error, :stale} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 reviewed.attrs,
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )
    end

    test "attrs the native changeset refuses keep their own changeset", context do
      reviewed = reviewed(context)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Flex.save_service(
                 context.audit,
                 reviewed.loaded,
                 Map.put(reviewed.attrs, "phone", "not a phone number"),
                 reviewed.area_inputs,
                 %{assistant_guard: reviewed.guard}
               )

      assert %{phone: ["Enter the phone number as 10 digits, for example (541) 555-0142."]} =
               errors_on(changeset)
    end
  end

  describe "the exclusive fence excludes the version's other writers (AC-10)" do
    test "an ordinary Flex FOR SHARE write waits behind a guarded save's fence", %{
      supervisor: supervisor
    } do
      context = in_task(supervisor, fn -> seed_scope() end)
      on_exit(fn -> cleanup([context]) end)

      {saver, saver_backend} = start_fenced_save(supervisor, context)

      # An ordinary Flex write from a page loaded before the guarded save asks
      # for the same scoped version row `FOR SHARE`, so it waits behind the
      # exclusive lock and then finds its own loaded struct replaced.
      {writer, writer_backend} =
        start_writer(supervisor, fn -> ordinary_save(context) end)

      send(writer.pid, :go)
      assert_blocked_by(writer_backend, saver_backend)
      assert Process.alive?(writer.pid)

      send(saver.pid, :release)
      assert {:ok, _saved} = Task.await(saver, @collect_timeout)

      # The ordinary write keeps the native optimistic-locking outcome rather
      # than an assistant answer: the guarded save persisted, and this page's
      # own draft was refused.
      assert {:error, :stale} = Task.await(writer, @collect_timeout)

      assert {:ok, saved} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert Enum.map(saved.hours, &{&1.start, &1.end}) ==
               [{"08:00", "17:00"}, {"08:00", "17:00"}, {"09:00", "17:00"}, {"09:00", "17:00"}]

      assert saved.note == context.service.note
    end

    test "a calendar FOR UPDATE write waits behind a guarded save's fence", %{
      supervisor: supervisor
    } do
      context = in_task(supervisor, fn -> seed_scope() end)
      on_exit(fn -> cleanup([context]) end)

      # The calendar command is reviewed before the fence is taken, the way the
      # Calendars page reviews a command before applying it.
      {:ok, review} = in_task(supervisor, fn -> review_weekday_calendar(context) end)

      {saver, saver_backend} = start_fenced_save(supervisor, context)

      {writer, writer_backend} =
        start_writer(supervisor, fn ->
          Gtfs.apply_calendar_change(@weekday_command, review.fingerprint, context.audit)
        end)

      send(writer.pid, :go)
      assert_blocked_by(writer_backend, saver_backend)
      assert Process.alive?(writer.pid)

      send(saver.pid, :release)
      assert {:ok, _saved} = Task.await(saver, @collect_timeout)
      assert {:ok, _result} = Task.await(writer, @collect_timeout)

      # The reviewed save landed first and the calendar change after it, so the
      # exclusion cost this version nothing but ordering.
      assert {:ok, saved} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert Enum.map(saved.hours, &{&1.start, &1.end}) ==
               [{"08:00", "17:00"}, {"08:00", "17:00"}, {"09:00", "17:00"}, {"09:00", "17:00"}]

      assert %{saturday: 1} = calendar_row(context, "weekday")
    end

    test "a calendar write that commits first leaves the guarded save assistant_stale", %{
      supervisor: supervisor
    } do
      context = in_task(supervisor, fn -> seed_scope() end)
      on_exit(fn -> cleanup([context]) end)
      parent = self()

      {calendar, _calendar_announced} =
        start_writer(supervisor, fn ->
          {:ok, review} = review_weekday_calendar(context)
          hold_version_fence(parent)
          Gtfs.apply_calendar_change(@weekday_command, review.fingerprint, context.audit)
        end)

      send(calendar.pid, :go)
      calendar_pid = calendar.pid
      assert_receive {:fence_held, ^calendar_pid, calendar_backend}, @contention_timeout

      {saver, saver_backend} = start_writer(supervisor, fn -> guarded_save(context) end)
      send(saver.pid, :go)
      assert_blocked_by(saver_backend, calendar_backend)

      send(calendar.pid, :release)
      assert {:ok, _result} = Task.await(calendar, @collect_timeout)

      assert {:error, :assistant_stale} = Task.await(saver, @collect_timeout)

      assert {:ok, unchanged} =
               Flex.get_service(context.organization.id, context.version.id, context.service.id)

      assert unchanged.lock_version == context.service.lock_version

      assert Enum.map(unchanged.hours, &{&1.start, &1.end}) ==
               Enum.map(context.service.hours, &{&1.start, &1.end})
    end
  end

  # --- the reviewed save the cases above share ------------------------------

  # One real preparation, one real guard and the whole page the review showed,
  # exactly as the service page would hold them: the loaded struct, the native
  # page attrs and the native area inputs, all from the same workspace read.
  defp reviewed(context, hours \\ @hours_patch) do
    assert {:ok, workspace, _evidence} =
             Assistant.workspace(context.scope, context.service.id)

    assert {:ok, prepared} =
             Assistant.prepare(context.scope, %{
               "scope" => "hours_only",
               "hours" => hours
             })

    loaded = workspace.dependencies.service
    draft = %{prepared.candidate | areas: loaded.areas}
    attrs = page_attrs(draft)
    area_inputs = area_inputs(draft)

    %{
      workspace: workspace,
      prepared: prepared,
      loaded: loaded,
      draft: draft,
      attrs: attrs,
      area_inputs: area_inputs,
      guard: guard(prepared, workspace, loaded, attrs, area_inputs)
    }
  end

  defp guard(prepared, workspace, loaded, attrs, area_inputs) do
    assert {:ok, guard} =
             Guard.new(%{
               source_digest: prepared.source_digest,
               context_digest: prepared.context_digest,
               saved_fingerprint: workspace.fingerprint,
               patch_digest: Guard.patch_digest(prepared.patch),
               candidate_digest:
                 Guard.candidate_digest(loaded, attrs, area_inputs)
                 |> then(fn
                   {:ok, digest} -> digest
                 end),
               calendars_digest: elem(Guard.calendars_digest(loaded, attrs), 1)
             })

    guard
  end

  defp guarded_save(context) do
    Flex.save_service(
      context.audit,
      context.loaded,
      context.attrs,
      context.area_inputs,
      %{assistant_guard: context.guard}
    )
  end

  defp ordinary_save(context) do
    Flex.save_service(context.audit, context.loaded, %{"note" => "Ordinary save"}, [
      area_input(context.loaded.areas, 1),
      area_input(context.loaded.areas, 2)
    ])
  end

  # The page's own whole-page attrs, with the string keys the native form
  # submits, so this test exercises the real `FlexService.changeset/2` cast.
  defp page_attrs(%FlexService{} = service) do
    %{
      "hours" => Enum.map(service.hours, &row(&1, [:area_key, :service_id, :start, :end])),
      "booking_rules" =>
        service.booking_rules
        |> Enum.reject(&is_nil(&1.when))
        |> Enum.map(
          &row(&1, [
            :service_id,
            :when,
            :minutes,
            :days,
            :by,
            :business_days,
            :office_service_id,
            :max_days
          ])
        ),
      "phone" => service.phone,
      "phone_hours" => service.phone_hours,
      "booking_url" => service.booking_url,
      "info_url" => service.info_url,
      "note" => service.note,
      "riders" => service.riders,
      "eligibility" => service.eligibility,
      "include_registered" => service.include_registered,
      "hub_stop_ids" => service.hub_stop_ids
    }
  end

  defp row(struct, fields) do
    Map.new(fields, fn field ->
      value = Map.fetch!(struct, field)
      {Atom.to_string(field), value}
    end)
  end

  # The draft's areas with the geometry the page read for them, the same shape
  # the service page's area list submits.
  defp area_inputs(%FlexService{} = service) do
    geojson = Geometry.get_geojson(Enum.map(service.areas, & &1.id))

    Enum.map(service.areas, fn area ->
      area
      |> Map.take([
        :key,
        :name,
        :source,
        :census_geoid,
        :census_layer,
        :census_vintage,
        :route_ids,
        :distance_m
      ])
      |> Map.put(:geojson, Map.get(geojson, area.id))
    end)
  end

  defp area_input(areas, position) do
    area = Enum.at(areas, position - 1)
    geojson = Geometry.get_geojson([area.id])

    area
    |> Map.take([
      :key,
      :name,
      :source,
      :census_geoid,
      :census_layer,
      :census_vintage,
      :route_ids,
      :distance_m
    ])
    |> Map.put(:geojson, Map.get(geojson, area.id))
  end

  defp renamed_area_inputs(area_inputs, key, name) do
    Enum.map(area_inputs, fn input ->
      if input.key == key, do: %{input | name: name}, else: input
    end)
  end

  # --- the calendar writer the cases above commit through --------------------

  defp review_weekday_calendar(context) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "weekday")

    Gtfs.review_calendar_change(
      @weekday_command,
      %{"weekday" => payload.fingerprint},
      context.audit
    )
  end

  defp save_holiday_calendar(context) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "holiday")

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               @holiday_command,
               %{"holiday" => payload.fingerprint},
               context.audit
             )

    Gtfs.apply_calendar_change(@holiday_command, review.fingerprint, context.audit)
  end

  defp save_weekday_calendar(context) do
    assert {:ok, review} = review_weekday_calendar(context)
    Gtfs.apply_calendar_change(@weekday_command, review.fingerprint, context.audit)
  end

  # --- fixtures ---------------------------------------------------------------

  # The sandboxed fixture the ordinary cases use: one organization, its
  # published version, the representative flex feed and the area service, plus
  # an accepted `flex_policy` source bound to that service.
  defp flex_context(context) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    feed = flex_representative_fixture(organization, version)
    service = feed.services.area

    Map.merge(context, %{
      organization: organization,
      version: version,
      service: service,
      audit: flex_audit_fixture(organization.id, version.id),
      scope: scope_for(organization, version, service.id)
    })
  end

  # The same scope and the same reviewed save, committed, so the interleaving
  # cases have rows their own connections can see.
  defp seed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    feed = flex_representative_fixture(organization, version)
    service = feed.services.area

    context = %{
      organization: organization,
      version: version,
      service: service,
      audit: flex_audit_fixture(organization.id, version.id),
      scope: scope_for(organization, version, service.id)
    }

    Map.merge(context, reviewed(context))
  end

  defp scope_for(organization, version, service_id) do
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "flex_policy",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
    |> with_source(service_id)
  end

  # The accepted `flex_policy` source a host freezes after explicit editor
  # acceptance, with the loaded service bound beside it.
  defp with_source(%Scope{} = scope, service_id) do
    payload = %{
      "service_id" => service_id,
      "section" => "hours_booking",
      "source" => %{
        "text" => "Weekdays 8 am to 5 pm. Saturdays 9 am to 5 pm.",
        "label" => "Approved hours policy",
        "accepted" => true
      }
    }

    {:ok, resource_context} =
      Scope.with_source_snapshot(scope.resource_context, %{
        kind: "flex_policy",
        payload: payload
      })

    %{scope | resource_context: resource_context}
  end

  defp calendar_row(context, service_id) do
    Repo.one(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    )
  end

  defp revoke(context) do
    Repo.delete_all(
      from(m in UserOrgMembership, where: m.organization_id == ^context.organization.id)
    )
  end

  defp row_counts(organization_id) do
    %{
      services:
        Repo.aggregate(
          from(s in FlexService, where: s.organization_id == ^organization_id),
          :count
        ),
      areas:
        Repo.aggregate(from(a in FlexArea, where: a.organization_id == ^organization_id), :count),
      calendar_logs:
        Repo.aggregate(
          from(l in ChangeLog,
            where: l.organization_id == ^organization_id and l.entity_type == "calendar"
          ),
          :count
        )
    }
  end

  # -- concurrency plumbing ---------------------------------------------------

  # Each participant gets its own committing connection. The writer announces
  # its backend and waits for `:go`, so the parent decides when it enters the
  # transaction.
  defp start_writer(supervisor, run) do
    parent = self()

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:writer_ready, self(), backend})

          receive do
            :go -> :ok
          end

          run.()
        end)
      end)

    assert_receive {:writer_ready, writer_pid, backend}, @contention_timeout
    assert writer_pid == writer.pid
    {writer, backend}
  end

  # One guarded save that pauses inside its own transaction while it holds the
  # scoped version row `FOR UPDATE`, and the backend holding it.
  defp start_fenced_save(supervisor, context) do
    parent = self()

    {saver, _announced} =
      start_writer(supervisor, fn ->
        hold_version_fence(parent)
        guarded_save(context)
      end)

    send(saver.pid, :go)
    saver_pid = saver.pid
    assert_receive {:fence_held, ^saver_pid, backend}, @contention_timeout
    {saver, backend}
  end

  # The participant pauses inside its own transaction, holding the scoped
  # version row `FOR UPDATE`, until the parent releases it. The pause is a
  # telemetry handler on that exact lock statement, so it happens after the lock
  # is really taken and before the transaction can commit.
  defp hold_version_fence(parent) do
    :telemetry.attach(
      @fence_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner do
          maybe_hold_fence(metadata, parent)
        end
      end,
      self()
    )
  end

  defp maybe_hold_fence(metadata, parent) do
    query = metadata |> Map.get(:query) |> to_string() |> String.replace("\n", " ")

    if String.contains?(query, "gtfs_versions") and String.contains?(query, "FOR UPDATE") do
      :telemetry.detach(@fence_handler)
      send(parent, {:fence_held, self(), backend_pid()})

      receive do
        :release -> :ok
      after
        @fence_timeout -> :ok
      end

      send(parent, {:fence_left, self()})
    end
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw blocking pids #{inspect(blocked_by)}"
        )
    end
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(contexts) do
    unboxed(fn ->
      contexts |> Enum.map(& &1.organization.id) |> delete_committed_scope!()
    end)
  end
end
