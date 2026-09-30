defmodule GtfsPlanner.Gtfs.Blocking.RenameMergeTest do
  @moduledoc """
  Merge evidence (EV-13) for the rename and merge commands.

  One case covers each observation EV-13 rejects FH-10 with:

  - renaming 101 to 201 on the `{A, B}` day type returns
    `{:needs_confirmation, review}` whose `{A, C}` effect splits 101 with two trips
    left behind, and confirming the fingerprint writes 201 on the A and B trips
    while the C-only trips keep 101;
  - renaming to an ID another trip uses on the renamed trips' dates returns
    `{:error, :block_id_taken}`, while an ID only a disjoint Saturday day type uses
    is accepted and leaves the Saturday trip alone;
  - a Unicode block ID is accepted; a 256-character ID and a blank ID return
    `{:error, :invalid_block_id}`; one ID twice returns `{:error, :invalid_command}`,
    before any transaction;
  - merging 102 into 101 returns a review whose selected effect adds the overlap the
    merge creates, and confirming it moves every 102 trip of the day type onto 101;
  - a source absent from the selected day type and a merge destination absent from it
    return `{:error, :not_found}` and write nothing;
  - a frequency-based trip and an untimed trip move with the block they are renamed
    with.

  Every value is read back from the database inside the SQL Sandbox transaction —
  the stored `block_id`, `updated_at`, `change_logs.changed_fields` and the transfer
  rows — so the command's result and the refused paths are observed on the stored
  data and not only on its return value. The focused gate command is deferred to
  branch review: `mix test test/gtfs_planner/gtfs/blocking/rename_merge_test.exs`.

  The attribute cases below read `block_attributes` back from the database the
  same way:

  - renaming 101 to 201 on `{WKDY}`, where every 101 trip of that day type moves,
    leaves `(WKDY, 201)` holding 101's garage and vehicle type and no `(WKDY, 101)`
    row behind;
  - a rename on `{A, B}` that moves A and B's trips copies A's row to
    `(A, 201)`, deletes `(A, 101)` and leaves C's `(C, 101)` row alone, because no
    trip of C moved;
  - merging 102 into 101 keeps 101's own row, values and identity, and deletes
    `(WK, 102)` when no trip keeps 102;
  - merging into a block with no row copies the source's row to the destination;
  - an `:assign` and an `:unassign` write no row and change no row's `updated_at`;
  - a rejected change log rolls the copied and the deleted row back with the trip
    update.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    %{scope: new_scope()}
  end

  test "a rename changes the selected day type's trips and reviews the split", %{scope: scope} do
    split_services(scope)
    weekday_key = day_type_key(scope, ["A", "B"])

    a = trip(scope, %{trip_id: "a", service_id: "A", block_id: "101"})
    b = trip(scope, %{trip_id: "b", service_id: "B", block_id: "101"})
    c1 = trip(scope, %{trip_id: "c1", service_id: "C", block_id: "101"})
    c2 = trip(scope, %{trip_id: "c2", service_id: "C", block_id: "101"})

    command = {:rename, "101", "201"}

    assert {:needs_confirmation, review} =
             Gtfs.apply_block_change(weekday_key, command, scope.audit)

    assert review.target == "201"
    assert review.needs_confirmation?

    # A and B run on every Monday and A and C on every Tuesday of the fixture year,
    # so the review covers both day types' dates.
    assert review.affected_date_count ==
             review.effects |> Enum.map(& &1.day_type.date_count) |> Enum.sum()

    assert Enum.map(review.changes, & &1.trip.trip_id) == ["a", "b"]
    assert Enum.all?(review.changes, &(&1.from == "101" and &1.to == "201"))

    # The selected day type has no 101 left after the rename; the day type that
    # shares service A keeps the two C-only trips on 101.
    assert effect_for(review, ["A", "B"]).splits == []
    assert effect_for(review, ["A", "C"]).splits == [%{block_id: "101", remaining: 2}]

    assert persisted(a).block_id == "101"
    assert change_log_count(scope) == 0

    assert {:ok, result} =
             Gtfs.apply_block_change(weekday_key, command, scope.audit, review.fingerprint)

    assert result.block_id == "201"
    assert result.changed_trip_ids == Enum.sort([a.id, b.id])
    assert persisted(a).block_id == "201"
    assert persisted(b).block_id == "201"
    assert persisted(c1).block_id == "101"
    assert persisted(c2).block_id == "101"
    assert persisted(c1).updated_at == c1.updated_at
    assert persisted(c2).updated_at == c2.updated_at

    logs = trip_logs_for(scope, [a.id, b.id])
    assert length(logs) == 2

    assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() ==
             [result.operation_id]

    assert Enum.all?(logs, &(&1.changed_fields["before"]["block_id"] == "101"))
    assert Enum.all?(logs, &(&1.changed_fields["after"]["block_id"] == "201"))
    assert Enum.all?(logs, &(&1.changed_fields["affected_trip_ids"] == Enum.sort([a.id, b.id])))
  end

  test "a rename refuses an ID used on its dates and accepts one only a disjoint day uses",
       %{scope: scope} do
    split_services(scope)
    saturday_service(scope)
    weekday_key = day_type_key(scope, ["A", "B"])

    a = trip(scope, %{trip_id: "a", service_id: "A", block_id: "101"})
    b = trip(scope, %{trip_id: "b", service_id: "B", block_id: "101"})
    c = trip(scope, %{trip_id: "c", service_id: "C", block_id: "301"})
    saturday = trip(scope, %{trip_id: "saturday", service_id: "SA", block_id: "401"})

    # 301 is a Tuesday trip's block and the A trips run on Tuesday too, so the ID is
    # in use on the renamed trips' dates even though no trip of the selected day
    # type carries it.
    assert {:error, :block_id_taken} =
             Gtfs.apply_block_change(weekday_key, {:rename, "101", "301"}, scope.audit)

    assert persisted(a).block_id == "101"
    assert persisted(c).block_id == "301"
    assert change_log_count(scope) == 0

    # 401 is used only by a Saturday trip, whose dates are disjoint from the renamed
    # trips', so it is another vehicle's ID and the rename is accepted (R2).
    command = {:rename, "101", "401"}

    assert {:needs_confirmation, review} =
             Gtfs.apply_block_change(weekday_key, command, scope.audit)

    assert Enum.map(review.effects, & &1.day_type.service_ids) |> Enum.sort() ==
             [["A", "B"], ["A", "C"]]

    assert {:ok, result} =
             Gtfs.apply_block_change(weekday_key, command, scope.audit, review.fingerprint)

    assert result.block_id == "401"
    assert persisted(a).block_id == "401"
    assert persisted(b).block_id == "401"
    assert persisted(saturday).block_id == "401"
    assert persisted(saturday).updated_at == saturday.updated_at
    assert change_log_count(scope) == 2
  end

  test "a rename validates its block IDs before any transaction", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)
    x = trip(scope, %{trip_id: "x", service_id: "WK", block_id: "101"})

    assert {:error, :invalid_block_id} =
             Gtfs.apply_block_change(
               key,
               {:rename, "101", String.duplicate("a", 256)},
               scope.audit
             )

    assert {:error, :invalid_block_id} =
             Gtfs.apply_block_change(key, {:merge, "   ", "101"}, scope.audit)

    assert {:error, :invalid_command} =
             Gtfs.apply_block_change(key, {:rename, "101", "101"}, scope.audit)

    assert {:error, :invalid_command} =
             Gtfs.apply_block_change(key, {:merge, "101", "101"}, scope.audit)

    # The IDs are trimmed before the same-ID rule, so a padded copy of the source is
    # the same command.
    assert {:error, :invalid_command} =
             Gtfs.apply_block_change(key, {:rename, " 101 ", "101"}, scope.audit)

    assert persisted(x).block_id == "101"
    assert change_log_count(scope) == 0

    # A trimmed Unicode ID is 1-255 characters and is accepted as it stands.
    command = {:rename, "101", "Bloc é-7"}

    assert {:needs_confirmation, review} =
             Gtfs.apply_block_change(key, command, scope.audit)

    assert review.target == "Bloc é-7"

    assert {:ok, result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)
    assert result.block_id == "Bloc é-7"
    assert persisted(x).block_id == "Bloc é-7"
    assert change_log_count(scope) == 1
  end

  test "a merge moves every trip of the source block and reviews the overlap", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    p = trip(scope, %{trip_id: "p", service_id: "WK", block_id: "101", last: "09:00:00"})

    q =
      trip(scope, %{
        trip_id: "q",
        service_id: "WK",
        block_id: "102",
        first: "08:30:00",
        last: "09:30:00"
      })

    r =
      trip(scope, %{
        trip_id: "r",
        service_id: "WK",
        block_id: "102",
        first: "10:00:00",
        last: "11:00:00"
      })

    in_seat_transfer_fixture(scope.organization.id, scope.version.id, p, q)
    transfers = transfer_rows(scope)
    assert length(transfers) == 1

    command = {:merge, "102", "101"}

    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)

    assert review.target == "101"
    assert Enum.map(review.changes, & &1.trip.trip_id) == ["q", "r"]

    effect = effect_for(review, ["WK"])
    assert effect.joins == ["101"]
    assert Enum.any?(effect.added, &(&1.code == :overlap))

    assert persisted(q).block_id == "102"
    assert persisted(r).block_id == "102"
    assert change_log_count(scope) == 0

    assert {:ok, result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert result.block_id == "101"
    assert result.changed_trip_ids == Enum.sort([q.id, r.id])
    assert persisted(p).block_id == "101"
    assert persisted(p).updated_at == p.updated_at
    assert persisted(q).block_id == "101"
    assert persisted(r).block_id == "101"
    assert change_log_count(scope) == 2

    assert transfer_rows(scope) == transfers
  end

  test "a source or destination absent from the selected day type is not found", %{scope: scope} do
    weekday_service(scope)
    saturday_service(scope)
    key = weekday_key(scope)

    weekday = trip(scope, %{trip_id: "weekday", service_id: "WK", block_id: "303"})
    saturday = trip(scope, %{trip_id: "saturday", service_id: "SA", block_id: "101"})

    # 101 exists on the version but only on the Saturday day type.
    assert {:error, :not_found} =
             Gtfs.apply_block_change(key, {:rename, "101", "201"}, scope.audit)

    assert {:error, :not_found} =
             Gtfs.apply_block_change(key, {:merge, "101", "303"}, scope.audit)

    # The source is here, but 505 is not a block of the weekday day type.
    assert {:error, :not_found} =
             Gtfs.apply_block_change(key, {:merge, "303", "505"}, scope.audit)

    assert persisted(weekday).block_id == "303"
    assert persisted(saturday).block_id == "101"
    assert persisted(saturday).updated_at == saturday.updated_at
    assert change_log_count(scope) == 0
  end

  test "a frequency trip and an untimed trip move with their renamed block", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    frequency = trip(scope, %{trip_id: "frequency", service_id: "WK", block_id: "101"})
    frequency_row_fixture(scope.organization.id, scope.version.id, %{trip_id: "frequency"})
    untimed = trip(scope, %{trip_id: "untimed", service_id: "WK", block_id: "101", last: nil})
    other = trip(scope, %{trip_id: "other", service_id: "WK", block_id: "7"})

    command = {:rename, "101", "201"}

    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)

    assert Enum.map(review.changes, & &1.trip.trip_id) == ["frequency", "untimed"]

    assert {:ok, result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert result.changed_trip_ids == Enum.sort([frequency.id, untimed.id])
    assert persisted(frequency).block_id == "201"
    assert persisted(untimed).block_id == "201"
    assert persisted(other).block_id == "7"
    assert persisted(other).updated_at == other.updated_at
    assert change_log_count(scope) == 2
  end

  test "a rename that moves every trip of a service moves its attribute row", %{scope: scope} do
    wkdy_service(scope)
    key = day_type_key(scope, ["WKDY"])

    a = trip(scope, %{trip_id: "a", service_id: "WKDY", block_id: "101"})
    b = trip(scope, %{trip_id: "b", service_id: "WKDY", block_id: "101"})
    garage = garage_fixture(scope.organization.id, %{"name" => "Main"})
    type = vehicle_type_fixture(scope.organization.id, %{"name" => "35-ft diesel"})

    source =
      block_attribute_fixture(scope.organization.id, scope.version.id, %{
        service_id: "WKDY",
        block_id: "101",
        garage_id: garage.id,
        vehicle_type_id: type.id
      })

    command = {:rename, "101", "201"}
    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)
    assert {:ok, _result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert persisted(a).block_id == "201"
    assert persisted(b).block_id == "201"

    assert attribute_row(scope, "WKDY", "201") == %{
             garage_id: garage.id,
             vehicle_type_id: type.id
           }

    # The source row is gone rather than left beside the moved one.
    assert attribute_row(scope, "WKDY", "101") == nil
    refute attribute_rows(scope) |> Enum.any?(&(&1.id == source.id))
  end

  test "a split keeps the source rows and copies the moved service's row", %{scope: scope} do
    split_services(scope)
    key = day_type_key(scope, ["A", "B"])

    a = trip(scope, %{trip_id: "a", service_id: "A", block_id: "101"})
    b = trip(scope, %{trip_id: "b", service_id: "B", block_id: "101"})
    c1 = trip(scope, %{trip_id: "c1", service_id: "C", block_id: "101"})
    main = garage_fixture(scope.organization.id, %{"name" => "Main"})
    yard = garage_fixture(scope.organization.id, %{"name" => "Yard"})

    # A and B move to 201 on this day type; C keeps its 101 trips and its row.
    block_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: "A",
      block_id: "101",
      garage_id: main.id
    })

    block_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: "C",
      block_id: "101",
      garage_id: yard.id
    })

    command = {:rename, "101", "201"}
    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)
    assert {:ok, _result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert persisted(a).block_id == "201"
    assert persisted(b).block_id == "201"
    assert persisted(c1).block_id == "101"

    assert attribute_row(scope, "A", "201") == %{garage_id: main.id, vehicle_type_id: nil}
    assert attribute_row(scope, "A", "101") == nil

    # The service that keeps 101 keeps its row untouched, and gains no copy: no
    # trip of C moved, so the command never reached it.
    assert attribute_row(scope, "C", "101") == %{garage_id: yard.id, vehicle_type_id: nil}
    assert attribute_row(scope, "C", "201") == nil
  end

  test "a merge keeps the destination's row and deletes the source's", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    p = trip(scope, %{trip_id: "p", service_id: "WK", block_id: "101"})
    q = trip(scope, %{trip_id: "q", service_id: "WK", block_id: "102", first: "10:00:00"})
    main = garage_fixture(scope.organization.id, %{"name" => "Main"})
    yard = garage_fixture(scope.organization.id, %{"name" => "Yard"})

    destination =
      block_attribute_fixture(scope.organization.id, scope.version.id, %{
        service_id: "WK",
        block_id: "101",
        garage_id: main.id
      })

    block_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: "WK",
      block_id: "102",
      garage_id: yard.id
    })

    command = {:merge, "102", "101"}
    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)
    assert {:ok, _result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert persisted(p).block_id == "101"
    assert persisted(q).block_id == "101"

    # The destination's own row is not overwritten by the source's values.
    assert attribute_row(scope, "WK", "101") == %{garage_id: main.id, vehicle_type_id: nil}

    assert attribute_rows(scope)
           |> Enum.find(&(&1.block_id == "101"))
           |> Map.get(:id) == destination.id

    assert attribute_row(scope, "WK", "102") == nil
  end

  test "a merge into a block with no row copies the source's", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    p = trip(scope, %{trip_id: "p", service_id: "WK", block_id: "101"})
    q = trip(scope, %{trip_id: "q", service_id: "WK", block_id: "102", first: "10:00:00"})
    main = garage_fixture(scope.organization.id, %{"name" => "Main"})
    type = vehicle_type_fixture(scope.organization.id, %{"name" => "Cutaway"})

    block_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: "WK",
      block_id: "102",
      garage_id: main.id,
      vehicle_type_id: type.id
    })

    command = {:merge, "102", "101"}
    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)
    assert {:ok, _result} = Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert persisted(p).block_id == "101"
    assert persisted(q).block_id == "101"

    assert attribute_row(scope, "WK", "101") == %{garage_id: main.id, vehicle_type_id: type.id}
    assert attribute_row(scope, "WK", "102") == nil
  end

  test "an assign and an unassign leave the attribute rows untouched", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    x = trip(scope, %{trip_id: "x", service_id: "WK", block_id: "101"})
    y = trip(scope, %{trip_id: "y", service_id: "WK", block_id: nil})
    main = garage_fixture(scope.organization.id, %{"name" => "Main"})

    before =
      block_attribute_fixture(scope.organization.id, scope.version.id, %{
        service_id: "WK",
        block_id: "101",
        garage_id: main.id
      })

    assert {:ok, _result} = Gtfs.apply_block_change(key, {:unassign, [x.id]}, scope.audit)
    assert {:ok, _result} = Gtfs.apply_block_change(key, {:assign, [y.id], "101"}, scope.audit)

    assert persisted(x).block_id == nil
    assert persisted(y).block_id == "101"

    assert attribute_rows(scope) == [
             %{
               id: before.id,
               service_id: "WK",
               block_id: "101",
               garage_id: main.id,
               vehicle_type_id: nil,
               updated_at: before.updated_at
             }
           ]
  end

  test "a failed audit rolls the attribute changes back with the trips", %{scope: scope} do
    weekday_service(scope)
    key = weekday_key(scope)

    x = trip(scope, %{trip_id: "x", service_id: "WK", block_id: "101"})
    main = garage_fixture(scope.organization.id, %{"name" => "Main"})

    block_attribute_fixture(scope.organization.id, scope.version.id, %{
      service_id: "WK",
      block_id: "101",
      garage_id: main.id
    })

    install_trip_audit_rejection_trigger!()

    command = {:rename, "101", "201"}
    assert {:needs_confirmation, review} = Gtfs.apply_block_change(key, command, scope.audit)

    assert {:error, {:audit_failed, reason}} =
             Gtfs.apply_block_change(key, command, scope.audit, review.fingerprint)

    assert %Postgrex.Error{} = reason

    remove_trip_audit_rejection_trigger!()

    # The copy and the delete both went out with the update and came back with it.
    assert persisted(x).block_id == "101"
    assert attribute_row(scope, "WK", "101") == %{garage_id: main.id, vehicle_type_id: nil}
    assert attribute_row(scope, "WK", "201") == nil
    assert change_log_count(scope) == 0
  end

  defp new_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  defp weekday_service(scope) do
    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "WK",
      name: "Weekday"
    })
  end

  defp saturday_service(scope) do
    service(scope, "SA", %{saturday: 1})
  end

  # WKDY runs Monday to Friday all year, so the version derives the `{WKDY}` day
  # type and the case needs no second service.
  defp wkdy_service(scope) do
    service(scope, "WKDY", %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1})
  end

  # A runs Monday and Tuesday, B Monday alone and C Tuesday alone, so `{A, B}` and
  # `{A, C}` are two day types that share service A (R2, R3).
  defp split_services(scope) do
    service(scope, "A", %{monday: 1, tuesday: 1})
    service(scope, "B", %{monday: 1})
    service(scope, "C", %{tuesday: 1})
  end

  defp service(scope, service_id, weekdays) do
    calendar_service_fixture(
      scope.organization.id,
      scope.version.id,
      Map.merge(
        %{
          service_id: service_id,
          name: service_id,
          monday: 0,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 0,
          sunday: 0
        },
        weekdays
      )
    )
  end

  # A trip on the weekday service unless `:service_id` says otherwise; `:first` and
  # `:last` are the endpoint clocks and `last: nil` stores an untimed last stop.
  defp trip(scope, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route.route_id,
      attrs
      |> Map.put_new(:service_id, "WK")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp weekday_key(scope), do: day_type_key(scope, ["WK"])

  defp day_type_key(scope, service_ids) do
    {:ok, calendars} = Calendars.list_calendars(scope.organization.id, scope.version.id)
    day_type = Enum.find(DayTypes.derive(calendars), &(&1.service_ids == service_ids))
    assert day_type, "no day type for #{inspect(service_ids)}"
    day_type.key
  end

  defp effect_for(review, service_ids) do
    effect = Enum.find(review.effects, &(&1.day_type.service_ids == service_ids))
    assert effect, "no review effect for #{inspect(service_ids)}"
    effect
  end

  defp persisted(%{id: id}), do: Repo.get!(Trip, id)

  defp trip_logs_for(scope, ids) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id and
            l.entity_type == "trip" and l.entity_id in ^ids,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end

  defp change_log_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization.id and
            l.gtfs_version_id == ^scope.version.id and l.entity_type == "trip"
      ),
      :count
    )
  end

  defp transfer_rows(scope) do
    Repo.all(
      from(t in Transfer,
        where:
          t.organization_id == ^scope.organization.id and
            t.gtfs_version_id == ^scope.version.id,
        order_by: t.id
      )
    )
  end

  # The version's attribute rows, read back with their stored values and identity.
  defp attribute_rows(scope) do
    Repo.all(
      from(a in BlockAttribute,
        where:
          a.organization_id == ^scope.organization.id and
            a.gtfs_version_id == ^scope.version.id,
        order_by: a.id,
        select:
          map(a, [
            :id,
            :service_id,
            :block_id,
            :garage_id,
            :vehicle_type_id,
            :updated_at
          ])
      )
    )
  end

  defp attribute_row(scope, service_id, block_id) do
    scope
    |> attribute_rows()
    |> Enum.find(&(&1.service_id == service_id and &1.block_id == block_id))
    |> case do
      nil -> nil
      row -> Map.take(row, [:garage_id, :vehicle_type_id])
    end
  end

  # The audit rejection fixture `apply_test.exs` uses: a constraint trigger that
  # refuses every `trip` change log, so the command's write is rolled back after
  # the trip update has gone out.
  defp install_trip_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION trip_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'trip' THEN
        RAISE EXCEPTION 'trip audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER trip_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION trip_audit_rejection();
    """)
  end

  defp remove_trip_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS trip_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS trip_audit_rejection()")
  end
end
