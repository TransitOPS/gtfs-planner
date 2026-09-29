defmodule GtfsPlanner.Gtfs.Blocking.BlockAttributesTest do
  @moduledoc """
  Merge evidence (EV-15) for CL-15: a block's garage and vehicle type are saved
  through one review that names every day type the rows reach, so FH-15's two
  failures — a shared service's other day type changing without review, and a stale
  confirmation writing anyway — stay rejected.

  One case covers each observation EV-15 rejects FH-15 with:

  - `WKDY` (Mon–Fri all year) and `SCHOOL` (two school weekdays) derive
    `{SCHOOL, WKDY}` and `{WKDY}`; setting block 101's garage on the school day
    type returns `{:needs_confirmation, review}` whose second effect is `{WKDY}`
    with that day type's own date count, and the review covers both day types'
    dates;
  - confirming that fingerprint writes one `(WKDY, 101)` row, and both day types
    then resolve the block to `Main` through the same `Context.resolve_block/3`
    the page and the plan read;
  - a block with `WKDY` and `SCHOOL` trips writes one row per service;
  - a block whose trips run only on `SCHOOL` affects only the school day type, so
    a garage change there applies without confirmation, while a vehicle type the
    route does not require adds `:type_mismatch` and needs confirmation even
    though one day type is affected;
  - a confirmation offered before another writer entered a driving time returns
    `{:error, {:stale_review, review}}` and writes nothing (INV-7);
  - a garage or a vehicle type of another organization, an unknown UUID and a
    block the day type does not run are each `:not_found`; a malformed UUID is a
    changeset error raised before the transaction opens;
  - blank values store `nil`;
  - the save writes no `transfers` row of its own and leaves the records already
    stored exactly as they were (INV-3);
  - the writer waits for `Blocking.lock_blocking!/1` and completes after the
    release (INV-1, AC-5).

  Every value is read back from the database inside the SQL Sandbox transaction —
  the stored rows, the loaded day's `resolution` and the `transfers` table — so
  each claim is observed on stored data and not only on a return value. The day
  types themselves are derived from the fixture's own calendars through
  `Calendars.list_calendars/3`, never hand-written.

  Rows are created inside the SQL Sandbox transaction and rolled back. The one
  exception is the lock case, which needs an organization and version another
  connection can see: it commits its own disposable rows on an own connection and
  deletes exactly those rows in `on_exit`, like `route_operating_settings_test.exs`.

  The module is `async: false` because the lock case observes another backend's
  `pg_stat_activity` wait.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/block_attributes_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @moduletag timeout: 120_000

  # The lock case holds one lock open and observes another backend's wait, so it is
  # bounded: EV-15's 120 s command deadline per test, and a 10 s self-release for a
  # hold the test never gets to release.
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  # The two school weekdays inside `WKDY`'s Mon–Fri year, so the version derives
  # `{SCHOOL, WKDY}` on those two dates and `{WKDY}` on every other weekday.
  @school_dates [~D[2026-09-01], ~D[2026-09-02]]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "30", route_short_name: "30"})
    actor = editor_fixture(organization)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WKDY",
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SCHOOL",
      name: "School",
      dates: @school_dates
    })

    for {stop_id, name, lat} <- [
          {"S1", "Riverside", "40.0000"},
          {"S2", "Market Square", "40.0300"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    main = garage(organization, "Main", "40.0400")
    yard = garage(organization, "Yard", "40.0500")
    diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})
    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

    scope = %{
      organization: organization,
      organization_id: organization.id,
      version: version,
      version_id: version.id,
      route: route,
      main: main,
      yard: yard,
      diesel: diesel,
      cutaway: cutaway,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }

    %{scope: scope}
  end

  describe "set_block_attributes/5 reviewed over every affected day type" do
    test "the school day type's save names the {WKDY} day type and needs confirmation", %{
      scope: scope
    } do
      assert day_type(scope, ["SCHOOL", "WKDY"]).date_count == 2
      assert day_type(scope, ["WKDY"]).date_count > 2

      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      trip(scope, %{trip_id: "sc_1", service_id: "SCHOOL", block_id: "102"})

      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])
      weekday = day_type(scope, ["WKDY"])

      assert {:needs_confirmation, review} =
               save(scope, school_key, "101", %{"garage_id" => scope.main.id})

      assert review.needs_confirmation?
      assert review.command == {:attributes, "101", scope.main.id, nil}
      assert review.changes == []
      assert review.added_problem_count == 0

      # The selected day type is the current view, so its effect comes first; the
      # second is the day type the same `(WKDY, 101)` row is read on, carrying its
      # own date count (AC-19).
      assert [selected, other] = review.effects
      assert selected.selected?
      assert selected.day_type.service_ids == ["SCHOOL", "WKDY"]
      assert other.selected? == false
      assert other.day_type.service_ids == ["WKDY"]
      assert other.day_type.date_count == weekday.date_count
      assert other.changed_trip_ids == []

      assert review.affected_date_count ==
               Enum.sum(Enum.map(review.effects, & &1.day_type.date_count))

      # Nothing is stored before the confirmation.
      assert attribute_rows(scope) == []
    end

    test "confirming the fingerprint writes one row and both day types resolve it", %{
      scope: scope
    } do
      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])
      weekday_key = day_type_key(scope, ["WKDY"])

      assert {:needs_confirmation, review} =
               save(scope, school_key, "101", %{"garage_id" => scope.main.id})

      assert {:ok, %{review: confirmed}} =
               Gtfs.set_block_attributes(
                 school_key,
                 "101",
                 %{"garage_id" => scope.main.id},
                 scope.audit,
                 review.fingerprint
               )

      assert confirmed.fingerprint == review.fingerprint

      assert [%{service_id: "WKDY", block_id: "101", garage_id: garage_id}] =
               attribute_rows(scope)

      assert garage_id == scope.main.id

      # R4 reads the row on both day types, so the resolution the page, the plan and
      # the export use is the same one on each (INV-9).
      assert resolution(scope, school_key, "101").garage_id == scope.main.id
      assert resolution(scope, weekday_key, "101").garage_id == scope.main.id
    end

    test "a block with WKDY and SCHOOL trips writes one row per service", %{scope: scope} do
      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      trip(scope, %{trip_id: "sc_1", service_id: "SCHOOL", block_id: "101"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:needs_confirmation, review} =
               save(scope, school_key, "101", %{"garage_id" => scope.main.id})

      assert {:ok, _result} =
               Gtfs.set_block_attributes(
                 school_key,
                 "101",
                 %{"garage_id" => scope.main.id},
                 scope.audit,
                 review.fingerprint
               )

      assert [%{service_id: "SCHOOL"}, %{service_id: "WKDY"}] =
               attribute_rows(scope)
               |> Enum.map(&%{service_id: &1.service_id})
               |> Enum.sort_by(& &1.service_id)
    end

    test "a garage change reaching only the selected day type applies without confirmation",
         %{scope: scope} do
      # A `SCHOOL` trip runs on the two school dates only, so the block is on the
      # school day type and nowhere else: the save reaches no other day type.
      trip(scope, %{trip_id: "sc_1", service_id: "SCHOOL", block_id: "103"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:ok, %{review: review}} =
               save(scope, school_key, "103", %{"garage_id" => scope.main.id})

      refute review.needs_confirmation?
      assert review.added_problem_count == 0
      assert [%{selected?: true} = selected] = review.effects
      assert selected.added == []

      assert [%{garage_id: garage_id}] = attribute_rows(scope)
      assert garage_id == scope.main.id
    end

    test "a vehicle type the route does not require is added and needs confirmation", %{
      scope: scope
    } do
      assert :ok =
               Gtfs.update_route_operating_settings(scope.organization.id, scope.version.id, [
                 %{"route_id" => "30", "required_vehicle_type_id" => scope.diesel.id}
               ])

      trip(scope, %{trip_id: "sc_1", service_id: "SCHOOL", block_id: "103"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:needs_confirmation, review} =
               save(scope, school_key, "103", %{"vehicle_type_id" => scope.cutaway.id})

      # One day type is affected, so only the added problem can ask for the
      # confirmation (AC-19, R12).
      assert [%{selected?: true}] = review.effects

      assert [
               %{
                 code: :type_mismatch,
                 severity: :error,
                 block_id: "103",
                 trip_ids: [trip_id],
                 detail: detail
               }
             ] = effect_for(review, ["SCHOOL", "WKDY"]).added

      assert trip_id == stored_trip_id(scope, "sc_1")

      assert detail == %{
               vehicle_type_id: scope.cutaway.id,
               required_vehicle_type_id: scope.diesel.id
             }

      assert review.added_problem_count == 1

      assert {:ok, _result} =
               Gtfs.set_block_attributes(
                 school_key,
                 "103",
                 %{"vehicle_type_id" => scope.cutaway.id},
                 scope.audit,
                 review.fingerprint
               )

      assert [%{vehicle_type_id: type_id}] = attribute_rows(scope)
      assert type_id == scope.cutaway.id
    end

    test "a confirmation after another writer entered a driving time is stale and writes nothing",
         %{scope: scope} do
      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:needs_confirmation, review} =
               save(scope, school_key, "101", %{"garage_id" => scope.main.id})

      # A driving-time writer takes `lock_blocking!/1` too, so it can land between
      # the review and the confirmation; the context digest moves with it (INV-7).
      assert {:ok, _pair} =
               Gtfs.put_deadhead_time(
                 scope.organization.id,
                 scope.version.id,
                 {"garage:#{scope.yard.id}", "stop:S1"},
                 12
               )

      assert {:error, {:stale_review, stale}} =
               Gtfs.set_block_attributes(
                 school_key,
                 "101",
                 %{"garage_id" => scope.main.id},
                 scope.audit,
                 review.fingerprint
               )

      assert stale.fingerprint != review.fingerprint
      assert attribute_rows(scope) == []
    end

    test "a foreign garage or type, an unknown UUID and an absent block are each refused",
         %{scope: scope} do
      other_organization = organization_fixture()
      foreign_garage = garage(other_organization, "Foreign", "40.0000")
      foreign_type = vehicle_type_fixture(other_organization.id, %{"name" => "Foreign"})
      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert save(scope, school_key, "101", %{"garage_id" => foreign_garage.id}) ==
               {:error, :not_found}

      assert save(scope, school_key, "101", %{"vehicle_type_id" => foreign_type.id}) ==
               {:error, :not_found}

      assert save(scope, school_key, "101", %{"garage_id" => Ecto.UUID.generate()}) ==
               {:error, :not_found}

      assert save(scope, school_key, "999", %{"garage_id" => scope.main.id}) ==
               {:error, :not_found}

      # A value that is not a UUID at all never opens a transaction.
      assert {:error, %Ecto.Changeset{} = changeset} =
               save(scope, school_key, "101", %{"garage_id" => "not-a-uuid"})

      assert %{garage_id: ["is invalid"]} = errors_on(changeset)

      # An unknown day type key selects nothing and falls back to no other day
      # type (INV-6); a staging or foreign version is not found (AC-5).
      assert {:error, {:unknown_day_type, day_types}} = save(scope, "not-a-day-type", "101", %{})

      assert Enum.map(day_types, & &1.service_ids) |> Enum.sort() == [
               ["SCHOOL", "WKDY"],
               ["WKDY"]
             ]

      {:ok, staging} =
        Versions.create_staging_gtfs_version(scope.organization.id, %{name: "Staging"})

      assert Gtfs.set_block_attributes(
               school_key,
               "101",
               %{"garage_id" => scope.main.id},
               %{scope.audit | gtfs_version_id: staging.id}
             ) == {:error, :not_found}

      assert attribute_rows(scope) == []
    end

    test "blank values store nil and a second save replaces both value columns", %{scope: scope} do
      trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:ok, _result} = confirmed_save(scope, school_key, "101", %{"garage_id" => ""})
      assert [%{garage_id: nil, vehicle_type_id: nil}] = attribute_rows(scope)

      assert {:needs_confirmation, review} =
               save(
                 scope,
                 school_key,
                 "101",
                 %{"garage_id" => scope.yard.id, "vehicle_type_id" => scope.diesel.id}
               )

      assert {:ok, _result} =
               Gtfs.set_block_attributes(
                 school_key,
                 "101",
                 %{"garage_id" => scope.yard.id, "vehicle_type_id" => scope.diesel.id},
                 scope.audit,
                 review.fingerprint
               )

      assert [%{garage_id: yard_id, vehicle_type_id: type_id}] = attribute_rows(scope)
      assert yard_id == scope.yard.id
      assert type_id == scope.diesel.id

      # Clearing one value must not leave the other behind on the same row.
      assert {:ok, _result} = confirmed_save(scope, school_key, "101", %{"vehicle_type_id" => ""})
      assert [%{garage_id: yard_id, vehicle_type_id: nil}] = attribute_rows(scope)
      assert yard_id == scope.yard.id

      # A repeated save is the same row, not a second one.
      assert {:ok, _result} = confirmed_save(scope, school_key, "101", %{"garage_id" => ""})
      assert [%{garage_id: nil, vehicle_type_id: nil}] = attribute_rows(scope)
    end

    test "the save writes no transfer row and leaves the stored ones alone", %{scope: scope} do
      first = trip(scope, %{trip_id: "wk_1", service_id: "WKDY", block_id: "101"})

      second =
        trip(scope, %{trip_id: "wk_2", service_id: "WKDY", block_id: "101", first: "09:10:00"})

      record =
        in_seat_transfer_fixture(
          scope.organization.id,
          scope.version.id,
          first,
          second
        )

      before = transfer_rows(scope)
      school_key = day_type_key(scope, ["SCHOOL", "WKDY"])

      assert {:ok, _result} =
               confirmed_save(scope, school_key, "101", %{"garage_id" => scope.main.id})

      assert transfer_rows(scope) == before
      assert Map.fetch!(transfer_row(scope), record.id).updated_at == record.updated_at
      assert attribute_rows(scope) != []
    end
  end

  describe "set_block_attributes/5 under a held blocking lock" do
    test "the writer waits for lock_blocking!1 and stores the row after the release" do
      scope =
        unboxed(fn ->
          organization = organization_fixture()
          version = gtfs_version_fixture(organization.id)
          route = route_fixture(organization.id, version.id, %{route_id: "30"})

          calendar_service_fixture(organization.id, version.id, %{
            service_id: "WKDY",
            name: "Weekday"
          })

          blocked_trip_fixture(organization.id, version.id, route.route_id, %{
            trip_id: "wk_1",
            service_id: "WKDY",
            block_id: "101",
            first_arrival: "08:00:00",
            last_arrival: "09:00:00"
          })

          %{
            organization_id: organization.id,
            version_id: version.id,
            garage_id: garage(organization, "Main", "40.0400").id,
            # An attribute save writes no change log, so the actor is never
            # resolved; a bare UUID keeps this committed scope free of a user row.
            audit: %AuditContext{
              organization_id: organization.id,
              gtfs_version_id: version.id,
              station_stop_id: nil,
              actor_id: Ecto.UUID.generate(),
              actor_email: "lock-case@example.com"
            }
          }
        end)

      on_exit(fn -> cleanup_committed_scope(scope) end)

      key = unboxed(fn -> day_type_key(scope) end)
      parent = self()

      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      writer =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:writer_pid, backend_pid})

            Gtfs.set_block_attributes(key, "101", %{"garage_id" => scope.garage_id}, scope.audit)
          end)
        end)

      assert_receive {:writer_pid, writer_pid}, @receive_timeout

      # The writer is inside its own transaction and waiting for the advisory lock
      # the holder's connection owns; `lock_blocking!/1` issues exactly this lock.
      assert wait_until_locked(writer_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)

      assert {:ok, %{review: review}} = Task.await(writer, @task_timeout)
      refute review.needs_confirmation?

      assert [%{service_id: "WKDY", block_id: "101", garage_id: garage_id, vehicle_type_id: nil}] =
               unboxed(fn -> attribute_rows(scope) end)

      assert garage_id == scope.garage_id
    end
  end

  # --- helpers --------------------------------------------------------------

  defp save(scope, day_type_key, block_id, attrs) do
    Gtfs.set_block_attributes(day_type_key, block_id, attrs, scope.audit)
  end

  # The single-day-type fixture block needs no confirmation, so a case that wants
  # the fingerprint it would have returned takes the review from the same call.
  defp confirmed_save(scope, day_type_key, block_id, attrs) do
    case save(scope, day_type_key, block_id, attrs) do
      {:ok, result} ->
        {:ok, result}

      {:needs_confirmation, review} ->
        Gtfs.set_block_attributes(day_type_key, block_id, attrs, scope.audit, review.fingerprint)
    end
  end

  defp garage(organization, name, lat) do
    garage_fixture(organization.id, %{
      "name" => name,
      "lat" => Decimal.new(lat),
      "lon" => Decimal.new("-74.0")
    })
  end

  # A trip on the given service and block; `:first` and `:last` are the endpoint
  # clocks, and the two named stops are shared by every trip so a driving time and
  # an in-seat record can name them.
  defp trip(scope, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route.route_id,
      attrs
      |> Map.put_new(:service_id, "WKDY")
      |> Map.put(:first_stop, "S1")
      |> Map.put(:last_stop, "S2")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp stored_trip_id(scope, trip_id) do
    Repo.one!(
      from(t in GtfsPlanner.Gtfs.Trip,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id and
            t.trip_id == ^trip_id,
        select: t.id
      )
    )
  end

  defp day_types(scope) do
    {:ok, calendars} = Calendars.list_calendars(scope.organization.id, scope.version.id)
    DayTypes.derive(calendars)
  end

  defp day_type(scope, service_ids) do
    day_type = Enum.find(day_types(scope), &(&1.service_ids == service_ids))
    assert day_type, "no day type for #{inspect(service_ids)}"
    day_type
  end

  defp day_type_key(scope, service_ids), do: day_type(scope, service_ids).key

  # The lock case's scope is a bare map of IDs, not the setup context.
  defp day_type_key(scope) do
    {:ok, calendars} = Calendars.list_calendars(scope.organization_id, scope.version_id)
    [day_type] = DayTypes.derive(calendars)
    day_type.key
  end

  defp effect_for(review, service_ids) do
    effect = Enum.find(review.effects, &(&1.day_type.service_ids == service_ids))
    assert effect, "no review effect for #{inspect(service_ids)}"
    effect
  end

  defp resolution(scope, day_type_key, block_id) do
    assert {:ok, day} =
             Gtfs.load_blocking_day(scope.organization.id, scope.version.id, day_type_key)

    block = Enum.find(day.blocks, &(&1.summary.block_id == block_id))
    assert block, "no block #{block_id} on that day type"
    block.resolution
  end

  defp attribute_rows(scope) do
    Repo.all(
      from(a in BlockAttribute,
        where:
          a.organization_id == ^scope.organization_id and a.gtfs_version_id == ^scope.version_id,
        order_by: [asc: a.service_id, asc: a.block_id],
        select: %{
          service_id: a.service_id,
          block_id: a.block_id,
          garage_id: a.garage_id,
          vehicle_type_id: a.vehicle_type_id
        }
      )
    )
  end

  defp transfer_rows(scope) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization_id and t.gtfs_version_id == ^scope.version_id,
        order_by: [asc: t.id],
        select: %{
          id: t.id,
          transfer_type: t.transfer_type,
          from_trip_id: t.from_trip_id,
          to_trip_id: t.to_trip_id,
          from_stop_id: t.from_stop_id,
          to_stop_id: t.to_stop_id,
          updated_at: t.updated_at
        }
      )
    )
  end

  defp transfer_row(scope), do: Map.new(transfer_rows(scope), &{&1.id, &1})

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Holds the version's blocking lock on an own connection, with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Deletes exactly the rows the lock case committed, keyed to their own
  # organization, on an own connection so the deletion is not part of the sandboxed
  # test transaction. The version foreign keys cascade to its trips, stop times,
  # calendars and attribute rows; `stops` and `routes` hang off the organization
  # itself, so they are deleted by their own key first.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      Repo.delete_all(
        from(s in GtfsPlanner.Gtfs.Stop, where: s.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(
        from(r in GtfsPlanner.Gtfs.Route, where: r.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
    end)
  end

  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end
end
