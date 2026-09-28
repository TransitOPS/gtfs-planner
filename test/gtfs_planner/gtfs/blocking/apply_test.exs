defmodule GtfsPlanner.Gtfs.Blocking.ApplyTest do
  @moduledoc """
  Merge evidence (EV-11) for the assign and unassign commands.

  One case covers each observation EV-11 rejects FH-8, FH-9 and FH-10 with:

  - a safe single-trip assign returns `{:ok, %{changed_trip_ids: [id]}}`, changes
    only that trip's `block_id`, advances its `updated_at`, and stores one `"trip"`
    change log whose `changed_fields["before"]["block_id"]` and
    `["after"]["block_id"]` are the old and the new ID, with the command's
    `operation_id` and `affected_trip_ids == [id]`;
  - a three-trip assign returns `{:needs_confirmation, review}` and writes nothing;
    confirming with `review.fingerprint` writes three logs that share one
    `operation_id` and list all three IDs;
  - a confirmation with a different fingerprint returns `{:error, {:stale_review,
    review}}` and writes nothing;
  - a batch containing another organization's trip returns `{:error, :not_found}`
    and writes nothing;
  - assigning a frequency trip or an unplottable trip returns
    `{:error, {:ineligible, [id]}}`, while unassigning a frequency trip succeeds;
  - `:new` with weekday trips using 1–3 and Saturday-only trips using 4 resolves to
    "4" and the review shows it;
  - with the `change_logs` rejection trigger installed, the command returns
    `{:error, {:audit_failed, %Postgrex.Error{}}}` and every `block_id` is unchanged;
  - assigning trips already in the target returns `{:ok, %{changed_trip_ids: []}}`
    with no logs;
  - transfer rows are identical before and after an assign and an unassign;
  - 501 changed trips return `{:error, :too_many_trips}` and an unknown day key
    returns `{:error, {:unknown_day_type, _}}`;
  - assigning weekday trips to "101" leaves the Saturday "101" trips untouched;
  - the ordinary entry `Gtfs.apply_block_change/4`, with an `AuditContext` built
    like `RouteSchedulesLive.audit_context/1`, runs through the configured
    `ReviewedApplyTransaction.Sandbox` module.

  Every value is read back from the database inside the SQL Sandbox transaction —
  the stored `block_id`, `updated_at`, `change_logs.changed_fields` and the transfer
  rows — and the audit-rejection trigger is created and dropped inside the test. The
  focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/apply_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    %{scope: new_scope()}
  end

  describe "assign" do
    test "a safe single-trip assign changes one trip and audits it", %{scope: scope} do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x", first: "08:00:00", last: "09:00:00"})

      other =
        trip(scope, %{trip_id: "other", block_id: "9", first: "10:00:00", last: "11:00:00"})

      assert {:ok, result} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [x.id], "101"},
                 scope.audit
               )

      assert result.changed_trip_ids == [x.id]
      assert result.block_id == "101"
      assert is_binary(result.operation_id)
      refute result.review.needs_confirmation?

      assert persisted(x).block_id == "101"
      assert DateTime.compare(persisted(x).updated_at, x.updated_at) == :gt
      assert persisted(other).block_id == "9"
      assert persisted(other).updated_at == other.updated_at

      assert [log] = trip_logs(scope, x)
      assert log.entity_type == "trip"
      assert log.action == "updated"
      assert log.changed_fields["before"]["block_id"] == nil
      assert log.changed_fields["after"]["block_id"] == "101"
      assert log.changed_fields["operation_id"] == result.operation_id
      assert log.changed_fields["affected_trip_ids"] == [x.id]

      assert Map.drop(log.changed_fields["before"], ["block_id"]) ==
               Map.drop(log.changed_fields["after"], ["block_id"])
    end

    test "a three-trip assign reviews, then writes the three logs it promised", %{scope: scope} do
      weekday_service(scope)

      trips =
        for index <- 1..3 do
          trip(scope, %{
            trip_id: "t#{index}",
            first: "0#{index + 7}:00:00",
            last: "0#{index + 7}:30:00"
          })
        end

      ids = Enum.map(trips, & &1.id)
      command = {:assign, ids, "101"}

      assert {:needs_confirmation, review} =
               Gtfs.apply_block_change(weekday_key(scope), command, scope.audit)

      assert length(review.changes) == 3
      assert review.needs_confirmation?
      assert Enum.all?(trips, &(persisted(&1).block_id == nil))
      assert change_log_count(scope) == 0

      assert {:ok, result} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 command,
                 scope.audit,
                 review.fingerprint
               )

      assert result.changed_trip_ids == Enum.sort(ids)
      assert Enum.all?(trips, &(persisted(&1).block_id == "101"))

      logs = trip_logs_for(scope, ids)
      assert length(logs) == 3

      assert logs |> Enum.map(& &1.changed_fields["operation_id"]) |> Enum.uniq() ==
               [result.operation_id]

      assert Enum.all?(logs, &(&1.changed_fields["affected_trip_ids"] == Enum.sort(ids)))
      assert Enum.all?(logs, &(&1.changed_fields["before"]["block_id"] == nil))
      assert Enum.all?(logs, &(&1.changed_fields["after"]["block_id"] == "101"))
    end

    test "a confirmation with a different fingerprint is stale and writes nothing", %{
      scope: scope
    } do
      weekday_service(scope)

      trips =
        for index <- 1..3 do
          trip(scope, %{
            trip_id: "s#{index}",
            first: "0#{index + 7}:00:00",
            last: "0#{index + 7}:30:00"
          })
        end

      command = {:assign, Enum.map(trips, & &1.id), "101"}

      assert {:needs_confirmation, review} =
               Gtfs.apply_block_change(weekday_key(scope), command, scope.audit)

      assert {:error, {:stale_review, refreshed}} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 command,
                 scope.audit,
                 review.fingerprint <> "0"
               )

      assert refreshed.fingerprint == review.fingerprint
      assert Enum.all?(trips, &(persisted(&1).block_id == nil))
      assert change_log_count(scope) == 0
    end

    test "a trip of another organization or version is not found and writes nothing", %{
      scope: scope
    } do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x"})

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        blocked_trip_fixture(
          other_organization.id,
          other_version.id,
          route_fixture(other_organization.id, other_version.id).route_id,
          %{trip_id: "foreign"}
        )

      second_version = gtfs_version_fixture(scope.organization.id)

      other_version_in_scope =
        blocked_trip_fixture(
          scope.organization.id,
          second_version.id,
          scope.route.route_id,
          %{trip_id: "second-version"}
        )

      for ids <- [[x.id, foreign.id], [x.id, other_version_in_scope.id]] do
        assert {:error, :not_found} =
                 Gtfs.apply_block_change(
                   weekday_key(scope),
                   {:assign, ids, "101"},
                   scope.audit
                 )
      end

      assert persisted(x).block_id == nil
      assert change_log_count(scope) == 0
    end

    test "a frequency or unplottable trip cannot be assigned but can be unassigned", %{
      scope: scope
    } do
      weekday_service(scope)

      frequency = trip(scope, %{trip_id: "freq", block_id: "7"})
      frequency_row_fixture(scope.organization.id, scope.version.id, %{trip_id: "freq"})
      untimed = trip(scope, %{trip_id: "untimed", last: nil})
      frequency_id = frequency.id
      untimed_id = untimed.id

      assert {:error, {:ineligible, [^frequency_id]}} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [frequency_id], "101"},
                 scope.audit
               )

      assert {:error, {:ineligible, [^untimed_id]}} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [untimed_id], "101"},
                 scope.audit
               )

      assert persisted(frequency).block_id == "7"
      assert persisted(untimed).block_id == nil
      assert change_log_count(scope) == 0

      assert {:ok, result} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:unassign, [frequency.id]},
                 scope.audit
               )

      assert result.changed_trip_ids == [frequency.id]
      assert persisted(frequency).block_id == nil
      assert change_log_count(scope) == 1

      assert {:ok, _} =
               Gtfs.apply_block_change(weekday_key(scope), {:unassign, [untimed.id]}, scope.audit)

      assert change_log_count(scope) == 1
    end

    test "a new block ID avoids the IDs used on the changed trips' dates", %{scope: scope} do
      weekday_service(scope)
      saturday_service(scope)

      assigned =
        for {trip_id, block_id} <- [{"w1", "1"}, {"w2", "2"}, {"w3", "3"}] do
          trip(scope, %{trip_id: trip_id, block_id: block_id})
        end

      saturday = trip(scope, %{trip_id: "s1", service_id: "SA", block_id: "4"})
      [moving | _] = assigned

      assert {:ok, result} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [moving.id], :new},
                 scope.audit
               )

      assert result.block_id == "4"
      assert result.review.target == "4"
      assert Enum.map(result.review.effects, & &1.day_type.service_ids) == [["WK"]]

      assert persisted(moving).block_id == "4"
      assert persisted(saturday).block_id == "4"
      assert persisted(saturday).updated_at == saturday.updated_at
      assert Enum.sort(Enum.map(assigned, &persisted(&1).block_id)) == ["2", "3", "4"]
      assert change_log_count(scope) == 1
    end

    test "an audit rejection is refused and rolls every block change back", %{scope: scope} do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x"})
      install_trip_audit_rejection_trigger!()

      assert {:error, {:audit_failed, reason}} =
               Gtfs.apply_block_change(weekday_key(scope), {:assign, [x.id], "101"}, scope.audit)

      assert %Postgrex.Error{} = reason

      remove_trip_audit_rejection_trigger!()

      assert persisted(x).block_id == nil
      assert change_log_count(scope) == 0
    end

    test "a block already holding the trip is a no-op with no logs", %{scope: scope} do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x", block_id: "101"})
      unblocked = trip(scope, %{trip_id: "unblocked"})

      assert {:ok, result} =
               Gtfs.apply_block_change(weekday_key(scope), {:assign, [x.id], "101"}, scope.audit)

      assert result.changed_trip_ids == []
      assert result.block_id == "101"
      assert result.operation_id == nil
      assert result.review == nil
      assert persisted(x).updated_at == x.updated_at

      assert {:ok, unassigned} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:unassign, [unblocked.id]},
                 scope.audit
               )

      assert unassigned.changed_trip_ids == []
      assert unassigned.block_id == nil
      assert unassigned.review == nil
      assert change_log_count(scope) == 0
    end

    test "assign and unassign leave every transfer row untouched", %{scope: scope} do
      weekday_service(scope)

      p = trip(scope, %{trip_id: "p", block_id: "101", first: "08:00:00", last: "09:00:00"})
      q = trip(scope, %{trip_id: "q", block_id: "101", first: "09:10:00", last: "10:00:00"})

      in_seat_transfer_fixture(scope.organization.id, scope.version.id, p, q)
      before = transfer_rows(scope)
      assert length(before) == 1

      assert {:needs_confirmation, review} =
               Gtfs.apply_block_change(weekday_key(scope), {:assign, [p.id], "202"}, scope.audit)

      assert Enum.any?(hd(review.effects).added, &(&1.code == :in_seat_stale))
      assert transfer_rows(scope) == before

      assert {:ok, _} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [p.id], "202"},
                 scope.audit,
                 review.fingerprint
               )

      assert transfer_rows(scope) == before

      assert {:ok, _} =
               Gtfs.apply_block_change(weekday_key(scope), {:unassign, [q.id]}, scope.audit)

      assert transfer_rows(scope) == before
    end

    test "assigning weekday trips to 101 leaves the Saturday 101 trips untouched", %{scope: scope} do
      weekday_service(scope)
      saturday_service(scope)

      weekday = trip(scope, %{trip_id: "weekday", first: "08:00:00", last: "09:00:00"})
      saturday = trip(scope, %{trip_id: "saturday", service_id: "SA", block_id: "101"})

      assert {:ok, result} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, [weekday.id], "101"},
                 scope.audit
               )

      assert result.changed_trip_ids == [weekday.id]
      assert Enum.map(result.review.effects, & &1.day_type.service_ids) == [["WK"]]

      assert persisted(weekday).block_id == "101"
      assert persisted(saturday).block_id == "101"
      assert persisted(saturday).updated_at == saturday.updated_at
      assert change_log_count(scope) == 1
    end
  end

  describe "command limits" do
    test "more than 500 changed trips is refused without writing", %{scope: scope} do
      weekday_service(scope)

      first_stop = stop_fixture(scope.organization.id, scope.version.id)
      last_stop = stop_fixture(scope.organization.id, scope.version.id)

      ids =
        for index <- 1..501 do
          trip(scope, %{
            trip_id: "many_#{index}",
            first_stop: first_stop.stop_id,
            last_stop: last_stop.stop_id
          }).id
        end

      assert {:error, :too_many_trips} =
               Gtfs.apply_block_change(
                 weekday_key(scope),
                 {:assign, ids, "101"},
                 scope.audit
               )

      blocked =
        Repo.aggregate(
          from(t in Trip,
            where:
              t.organization_id == ^scope.organization.id and t.id in ^ids and
                not is_nil(t.block_id)
          ),
          :count
        )

      assert blocked == 0
      assert change_log_count(scope) == 0
    end

    test "an unknown day key is refused without writing", %{scope: scope} do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x"})

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.apply_block_change(
                 "not-a-day-type-key",
                 {:assign, [x.id], "101"},
                 scope.audit
               )

      assert day_types != []
      assert Enum.all?(day_types, &(&1.key != "not-a-day-type-key"))
      assert persisted(x).block_id == nil
      assert change_log_count(scope) == 0
    end
  end

  describe "the ordinary entry" do
    test "runs the command through the configured reviewed-apply module", %{scope: scope} do
      weekday_service(scope)
      x = trip(scope, %{trip_id: "x"})

      assert Application.get_env(:gtfs_planner, :reviewed_apply_transaction) ==
               ReviewedApplyTransaction.Sandbox

      assert {:ok, result} =
               Gtfs.apply_block_change(weekday_key(scope), {:assign, [x.id], "101"}, scope.audit)

      assert result.changed_trip_ids == [x.id]
      assert persisted(x).block_id == "101"
      assert change_log_count(scope) == 1

      # The configured module is the one the command enters: a delegating stub
      # observes exactly one `run/1` and the second command still persists.
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, 1, fn transaction ->
        {:ok, transaction.()}
      end)

      assert {:ok, %{changed_trip_ids: [second_id]}} =
               Gtfs.apply_block_change(weekday_key(scope), {:assign, [x.id], "202"}, scope.audit)

      assert second_id == x.id
      assert persisted(x).block_id == "202"
      assert change_log_count(scope) == 2
    end
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
    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "SA",
      name: "Saturday",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1
    })
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

  defp persisted(%{id: id}), do: Repo.get!(Trip, id)

  defp trip_logs(scope, %{id: id}), do: trip_logs_for(scope, [id])

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

  defp use_reviewed_apply_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next trip audit insert, after the trip rows are written. It is created inside the
  # sandbox transaction, so the guaranteed test rollback removes it, and this test
  # also drops it explicitly. No production failure switch exists.
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
