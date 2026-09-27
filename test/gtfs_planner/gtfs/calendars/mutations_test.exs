defmodule GtfsPlanner.Gtfs.Calendars.MutationsTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "save" do
    test "reviewed save writes metadata and weekly changes with exact audit rows", context do
      calendar_fixture(context.organization.id, context.version.id,
        service_id: "imp_a",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      )

      calendar_attribute_fixture(context.organization.id, context.version.id,
        service_id: "imp_a",
        service_description: "Imported Duplicate"
      )

      calendar_attribute_fixture(context.organization.id, context.version.id,
        service_id: "imp_b",
        service_description: "Imported Duplicate"
      )

      source = source!(context, "imp_a")

      metadata_attrs = %{
        name: " imported duplicate ",
        service_schedule_typicality: 6,
        rating_description: "Saved"
      }

      assert {:ok, review} = review(context, {:save, "imp_a", metadata_attrs}, source)

      assert review.changes.action == :save
      assert review.changes.metadata_changed
      refute review.changes.weekly_changed
      assert review.changes.changed_count == 1

      assert {:ok, result} =
               apply_change(context, {:save, "imp_a", metadata_attrs}, review.fingerprint)

      assert result.changed_count == 1
      assert result.action == :save

      assert [weekly] = weekly_rows(context, "imp_a")
      assert weekly.monday == 0
      assert weekly.saturday == 0

      assert [attribute] = attribute_rows(context, "imp_a")
      assert attribute.service_description == "Imported Duplicate"
      assert attribute.service_schedule_typicality == 6

      assert [log] = calendar_logs(context, "imp_a")
      assert log.action == "updated"
      assert log.changed_fields["before"]["attributes"]["service_schedule_typicality"] == 1
      assert log.changed_fields["after"]["attributes"]["service_schedule_typicality"] == 6
      assert log.changed_fields["before"]["weekly"]["monday"] == 0

      updated = source!(context, "imp_a")

      weekly_attrs = %{
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-02-27]
      }

      assert {:ok, weekly_review} = review(context, {:save, "imp_a", weekly_attrs}, updated)
      assert weekly_review.changes.weekly_changed
      assert weekly_review.changes.active_date_count == 40

      assert {:ok, weekly_result} =
               apply_change(context, {:save, "imp_a", weekly_attrs}, weekly_review.fingerprint)

      assert weekly_result.changed_count == 1

      assert [row] = weekly_rows(context, "imp_a")
      assert row.monday == 1
      assert row.end_date == ~D[2026-02-27]

      assert [_created, log] = calendar_logs(context, "imp_a")
      assert log.changed_fields["after"]["weekly"]["end_date"] == "2026-02-27"

      assert {:error, %Ecto.Changeset{errors: errors}} =
               review(
                 context,
                 {:save, "imp_a",
                  Map.merge(weekly_attrs, %{
                    monday: 0,
                    tuesday: 0,
                    wednesday: 0,
                    thursday: 0,
                    friday: 0
                  })},
                 source!(context, "imp_a")
               )

      assert Keyword.has_key?(errors, :service_days)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               review(
                 context,
                 {:save, "imp_a", %{start_date: ~D[2026-02-01], end_date: ~D[2026-01-01]}},
                 source!(context, "imp_a")
               )

      assert Keyword.has_key?(errors, :end_date)
    end

    test "an identical save changes nothing and adds no log", context do
      payload = create_weekly!(context, "noop_save")

      assert {:ok, review} =
               review(
                 context,
                 {:save, "noop_save",
                  %{
                    name: "Weekly noop_save",
                    monday: 1,
                    tuesday: 1,
                    wednesday: 1,
                    thursday: 1,
                    friday: 1,
                    start_date: ~D[2026-01-05],
                    end_date: ~D[2026-02-27]
                  }},
                 payload
               )

      assert review.changes.changed_count == 0

      assert {:ok, result} =
               apply_change(
                 context,
                 {:save, "noop_save",
                  %{
                    name: "Weekly noop_save",
                    monday: 1,
                    tuesday: 1,
                    wednesday: 1,
                    thursday: 1,
                    friday: 1,
                    start_date: ~D[2026-01-05],
                    end_date: ~D[2026-02-27]
                  }},
                 review.fingerprint
               )

      assert result.changed_count == 0
      assert result.action == :unchanged
      assert length(calendar_logs(context, "noop_save")) == 1
    end
  end

  describe "stale review" do
    test "review binds exact source fingerprints and apply recomputes source and command",
         context do
      payload = create_weekly!(context, "stale_svc")
      attrs = %{rating_description: "Reviewed"}

      assert {:error, :stale_review} = review(context, {:save, "stale_svc", attrs}, %{})

      assert {:error, :stale_review} =
               review(context, {:save, "stale_svc", attrs}, %{"stale_svc" => nil})

      assert {:error, :stale_review} =
               review(context, {:save, "stale_svc", attrs}, %{
                 "stale_svc" => payload.fingerprint,
                 "other" => payload.fingerprint
               })

      assert {:ok, review} = review(context, {:save, "stale_svc", attrs}, payload)

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "stale_svc",
        date: ~D[2026-01-07],
        exception_type: 1
      })

      assert {:error, :stale_review} =
               apply_change(context, {:save, "stale_svc", attrs}, review.fingerprint)

      assert length(exception_rows(context, "stale_svc")) == 1

      assert [attribute] = attribute_rows(context, "stale_svc")
      assert attribute.rating_description == nil

      assert [_created] = calendar_logs(context, "stale_svc")

      fresh = source!(context, "stale_svc")

      assert {:ok, fresh_review} = review(context, {:save, "stale_svc", attrs}, fresh)

      assert {:error, :stale_review} =
               apply_change(
                 context,
                 {:save, "stale_svc", %{rating_description: "Other"}},
                 fresh_review.fingerprint
               )

      assert {:error, :stale_review} =
               apply_change(
                 context,
                 {:put_exceptions, "stale_svc", [~D[2026-01-07]], :added},
                 fresh_review.fingerprint
               )

      assert [_created] = calendar_logs(context, "stale_svc")

      assert {:ok, applied} =
               apply_change(context, {:save, "stale_svc", attrs}, fresh_review.fingerprint)

      assert applied.changed_count == 1
      assert length(calendar_logs(context, "stale_svc")) == 2
    end
  end

  describe "conversion" do
    test "weekly to dates-only persists the whole effective set including outside additions",
         context do
      calendar_fixture(context.organization.id, context.version.id,
        service_id: "conv_out",
        start_date: ~D[2026-01-05],
        end_date: ~D[2026-01-30]
      )

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "conv_out",
        date: ~D[2026-01-07],
        exception_type: 2
      })

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "conv_out",
        date: ~D[2026-02-02],
        exception_type: 1
      })

      expected =
        Enum.reject(
          Enum.filter(Date.range(~D[2026-01-05], ~D[2026-01-30]), &(Date.day_of_week(&1) <= 5)),
          &(&1 == ~D[2026-01-07])
        ) ++ [~D[2026-02-02]]

      source = source!(context, "conv_out")
      assert length(expected) == 20

      assert {:ok, review} =
               review(context, {:convert, "conv_out", :dates_only, %{}}, source)

      assert review.changes.kind == :dates_only
      assert review.changes.persisted_date_count == 20
      assert review.affected_service_ids == ["conv_out"]

      assert {:ok, result} =
               apply_change(context, {:convert, "conv_out", :dates_only, %{}}, review.fingerprint)

      assert result.calendar == nil
      assert result.kind == :dates_only
      assert weekly_rows(context, "conv_out") == []

      rows = exception_rows(context, "conv_out")
      assert Enum.map(rows, & &1.date) == expected
      assert Enum.all?(rows, &(&1.exception_type == 1))
      refute Enum.any?(rows, &(&1.date == ~D[2026-01-07]))

      assert [log] = calendar_logs(context, "conv_out")
      assert log.changed_fields["before"]["weekly"]["monday"] == 1
      assert log.changed_fields["after"]["weekly"] == nil
      assert log.changed_fields["after"]["kind"] == "dates_only"

      assert Enum.map(log.changed_fields["after"]["dates"], & &1["date"]) ==
               Enum.map(expected, &Date.to_iso8601/1)
    end

    test "dates-only to weekly is refused with trips and otherwise keeps exceptions", context do
      route = route_fixture(context.organization.id, context.version.id)

      create_dates_only!(context, "used_dates", [~D[2026-01-05]])

      trip_fixture(context.organization.id, context.version.id, route.route_id, %{
        service_id: "used_dates"
      })

      used = source!(context, "used_dates")

      assert {:error, {:in_use, 1, [route_id]}} =
               review(context, {:convert, "used_dates", :weekly, weekly_dates_attrs()}, used)

      assert route_id == route.route_id
      assert weekly_rows(context, "used_dates") == []
      assert length(exception_rows(context, "used_dates")) == 1

      created = create_dates_only!(context, "free_dates", [~D[2026-01-01], ~D[2026-01-05]])

      assert {:ok, review} =
               review(context, {:convert, "free_dates", :weekly, weekly_dates_attrs()}, created)

      assert review.changes.new_service_date_count > 0
      assert Enum.any?(review.warnings, &(&1.reason == :outside_range))

      assert {:ok, result} =
               apply_change(
                 context,
                 {:convert, "free_dates", :weekly, weekly_dates_attrs()},
                 review.fingerprint
               )

      assert result.kind == :weekly
      assert [weekly] = weekly_rows(context, "free_dates")
      assert weekly.start_date == ~D[2026-02-02]
      assert weekly.end_date == ~D[2026-02-06]

      dates = exception_rows(context, "free_dates") |> Enum.map(& &1.date)
      assert dates == [~D[2026-01-01], ~D[2026-01-05]]

      [log] = calendar_logs(context, "free_dates") |> Enum.filter(&(&1.action == "updated"))
      assert log.changed_fields["before"]["kind"] == "dates_only"
      assert log.changed_fields["after"]["kind"] == "weekly"

      assert {:error, :invalid_command} =
               review(context, {:convert, "free_dates", :weekly, weekly_dates_attrs()}, result)
    end
  end

  describe "breaks and exceptions" do
    test "a break removes only expected weekly dates and repeated writes stay no-ops", context do
      create_weekly!(context, "brk")

      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "brk",
        date: ~D[2026-03-02],
        exception_type: 1
      })

      payload = source!(context, "brk")

      assert {:ok, review} =
               review(context, {:add_break, "brk", ~D[2026-01-12], ~D[2026-01-18]}, payload)

      assert review.changes.expected_date_count == 5
      assert review.changes.removed_date_count == 5
      assert review.changes.service_id == "brk"
      assert Enum.any?(review.warnings, &(&1.reason == :coverage_gap))

      assert {:ok, result} =
               apply_change(
                 context,
                 {:add_break, "brk", ~D[2026-01-12], ~D[2026-01-18]},
                 review.fingerprint
               )

      assert result.changed_count == 5

      removed =
        exception_rows(context, "brk")
        |> Enum.filter(&(&1.exception_type == 2))
        |> Enum.map(& &1.date)

      assert removed == [
               ~D[2026-01-12],
               ~D[2026-01-13],
               ~D[2026-01-14],
               ~D[2026-01-15],
               ~D[2026-01-16]
             ]

      refute Enum.any?(removed, &(&1 in [~D[2026-01-17], ~D[2026-01-18]]))
      assert Enum.map(exception_rows(context, "brk"), & &1.date) |> Enum.member?(~D[2026-03-02])

      logs = length(calendar_logs(context, "brk"))
      assert logs == 2

      assert {:ok, repeated} =
               review(
                 context,
                 {:put_exceptions, "brk", removed, :removed},
                 source!(context, "brk")
               )

      assert repeated.changes.changed_row_count == 0
      assert repeated.affected_service_ids == []

      assert {:ok, repeated_result} =
               apply_change(
                 context,
                 {:put_exceptions, "brk", removed, :removed},
                 repeated.fingerprint
               )

      assert repeated_result.changed_count == 0
      assert repeated_result.action == :unchanged
      assert length(calendar_logs(context, "brk")) == logs

      assert {:ok, replace} =
               review(
                 context,
                 {:put_exceptions, "brk", [~D[2026-01-12]], :added},
                 source!(context, "brk")
               )

      assert replace.changes.changed_row_count == 1

      assert {:ok, replaced} =
               apply_change(
                 context,
                 {:put_exceptions, "brk", [~D[2026-01-12]], :added},
                 replace.fingerprint
               )

      assert replaced.changed_count == 1

      assert Enum.find(exception_rows(context, "brk"), &(&1.date == ~D[2026-01-12])).exception_type ==
               1

      assert {:ok, remove} =
               review(
                 context,
                 {:remove_exceptions, "brk", [~D[2026-01-12]]},
                 source!(context, "brk")
               )

      assert remove.changes.removed_row_count == 1

      assert {:ok, removed_row} =
               apply_change(
                 context,
                 {:remove_exceptions, "brk", [~D[2026-01-12]]},
                 remove.fingerprint
               )

      assert removed_row.changed_count == 1
      refute Enum.any?(exception_rows(context, "brk"), &(&1.date == ~D[2026-01-12]))
      assert length(calendar_logs(context, "brk")) == logs + 2
    end

    test "normalized ranges and duplicate inputs are deduplicated before counting", context do
      payload = create_weekly!(context, "norm")

      assert {:ok, review} =
               review(
                 context,
                 {:put_exceptions, "norm",
                  [Date.range(~D[2026-01-12], ~D[2026-01-14]), ~D[2026-01-14]], :added},
                 payload
               )

      assert review.changes.date_count == 3
      assert review.changes.changed_row_count == 3

      assert {:ok, result} =
               apply_change(
                 context,
                 {:put_exceptions, "norm",
                  [Date.range(~D[2026-01-12], ~D[2026-01-14]), ~D[2026-01-14]], :added},
                 review.fingerprint
               )

      assert result.changed_count == 3

      assert Enum.map(exception_rows(context, "norm"), & &1.date) ==
               [~D[2026-01-12], ~D[2026-01-13], ~D[2026-01-14]]

      assert {:ok, string_review} =
               review(
                 context,
                 {:put_exceptions, "norm", ["2026-01-20", "2026-01-20"], :removed},
                 source!(context, "norm")
               )

      assert string_review.changes.date_count == 1
      assert string_review.changes.exception_type == 2
    end
  end

  describe "cross-calendar date change" do
    test "one removed and one added calendar commit exact dates with one complete audit each",
         context do
      remove_a = create_weekly!(context, "rmv_a")
      remove_b = create_weekly!(context, "rmv_b")
      add_c = create_dates_only!(context, "add_c", [~D[2026-01-20]])
      dates = [~D[2026-01-06], ~D[2026-01-07]]

      fingerprints = %{
        "rmv_a" => remove_a.fingerprint,
        "rmv_b" => remove_b.fingerprint,
        "add_c" => add_c.fingerprint
      }

      assert {:ok, review} =
               review(context, {:date_change, dates, ["rmv_b", "rmv_a"], ["add_c"]}, fingerprints)

      assert review.affected_service_ids == ["add_c", "rmv_a", "rmv_b"]
      assert review.changes.calendars |> Map.keys() |> Enum.sort() == ["add_c", "rmv_a", "rmv_b"]
      assert review.changes.changed_count == 6

      assert {:ok, result} =
               apply_change(
                 context,
                 {:date_change, dates, ["rmv_b", "rmv_a"], ["add_c"]},
                 review.fingerprint
               )

      assert result.affected_service_ids == ["add_c", "rmv_a", "rmv_b"]
      assert is_binary(result.operation_id)

      for service_id <- ["rmv_a", "rmv_b"] do
        rows = exception_rows(context, service_id)
        assert Enum.map(rows, & &1.date) == dates
        assert Enum.all?(rows, &(&1.exception_type == 2))

        [log] =
          context
          |> calendar_logs(service_id)
          |> Enum.filter(&(&1.action == "updated"))

        assert log.changed_fields["operation_id"] == result.operation_id
        assert log.changed_fields["selected_dates"] == Enum.map(dates, &Date.to_iso8601/1)
        assert log.changed_fields["affected_service_ids"] == ["add_c", "rmv_a", "rmv_b"]
      end

      added = exception_rows(context, "add_c")
      assert Enum.map(added, & &1.date) == [~D[2026-01-06], ~D[2026-01-07], ~D[2026-01-20]]
      assert Enum.all?(added, &(&1.exception_type == 1))

      [add_log] =
        context
        |> calendar_logs("add_c")
        |> Enum.filter(&(&1.action == "updated"))

      assert add_log.changed_fields["operation_id"] == result.operation_id
      assert add_log.changed_fields["affected_service_ids"] == ["add_c", "rmv_a", "rmv_b"]
    end

    test "unknown ids, reversed ranges and overlapping targets reject every write", context do
      payload = create_weekly!(context, "keep")

      assert {:error, :not_found} =
               review(
                 context,
                 {:date_change, [~D[2026-01-06]], ["missing"], []},
                 %{"missing" => payload.fingerprint}
               )

      assert {:error, :invalid_command} =
               review(
                 context,
                 {:date_change, [~D[2026-01-06]], ["keep"], ["keep"]},
                 %{"keep" => payload.fingerprint}
               )

      assert {:error, :invalid_command} =
               review(
                 context,
                 {:date_change, [~D[2026-01-06]], [], []},
                 %{}
               )

      assert {:error, :invalid_command} =
               review(context, {:add_break, "keep", ~D[2026-01-10], ~D[2026-01-01]}, payload)

      assert {:error, :invalid_command} =
               review(
                 context,
                 {:put_exceptions, "keep", Date.range(~D[2026-01-10], ~D[2026-01-01], -1),
                  :added},
                 payload
               )

      assert {:error, :invalid_command} =
               review(context, {:put_exceptions, "keep", [], :added}, payload)

      assert {:error, :invalid_command} =
               review(context, {:put_exceptions, "keep", [~D[2026-01-06]], "added"}, payload)

      assert {:error, :invalid_command} =
               review(context, {:convert, "keep", "weekly", %{}}, payload)

      assert {:error, :invalid_command} = review(context, {:frobnicate, "keep"}, payload)

      assert exception_rows(context, "keep") == []
      assert length(calendar_logs(context, "keep")) == 1
    end

    test "outside-range and last-active-date effects appear in review, and a changed command is stale",
         context do
      weekly = create_weekly!(context, "effects")
      singles = create_dates_only!(context, "singles", [~D[2026-01-05]])

      assert {:ok, outside_review} =
               review(context, {:put_exceptions, "effects", [~D[2026-03-02]], :added}, weekly)

      assert Enum.any?(outside_review.warnings, fn warning ->
               warning.reason == :outside_range and warning.date == ~D[2026-03-02] and
                 warning.service_id == "effects"
             end)

      assert outside_review.affected_service_ids == ["effects"]

      assert {:ok, last_date_review} =
               review(context, {:remove_exceptions, "singles", [~D[2026-01-05]]}, singles)

      assert Enum.any?(last_date_review.warnings, fn warning ->
               warning.reason == :no_service and warning.service_id == "singles"
             end)

      assert last_date_review.changes.active_date_count == 0

      assert {:ok, applied} =
               apply_change(
                 context,
                 {:remove_exceptions, "singles", [~D[2026-01-05]]},
                 last_date_review.fingerprint
               )

      assert applied.active_date_count == 0
      assert exception_rows(context, "singles") == []

      assert {:error, :stale_review} =
               apply_change(
                 context,
                 {:remove_exceptions, "singles", [~D[2026-01-06]]},
                 last_date_review.fingerprint
               )

      assert exception_rows(context, "singles") == []
    end
  end

  defp review(context, command, payload) do
    case payload do
      %{fingerprint: fingerprint} ->
        Gtfs.review_calendar_change(command, %{elem(command, 1) => fingerprint}, context.audit)

      fingerprints when is_map(fingerprints) ->
        Gtfs.review_calendar_change(command, fingerprints, context.audit)
    end
  end

  defp source!(context, service_id) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, service_id)

    payload
  end

  defp apply_change(context, command, fingerprint) do
    Gtfs.apply_calendar_change(command, fingerprint, context.audit)
  end

  defp create_weekly!(context, service_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          service_id: service_id,
          name: "Weekly #{service_id}",
          kind: :weekly,
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: 0,
          sunday: 0,
          start_date: ~D[2026-01-05],
          end_date: ~D[2026-02-27]
        },
        attrs
      )

    assert {:ok, payload} = Gtfs.create_calendar(attrs, context.audit)
    payload
  end

  defp create_dates_only!(context, service_id, dates) do
    assert {:ok, payload} =
             Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Dates #{service_id}",
                 kind: :dates_only,
                 dates: dates
               },
               context.audit
             )

    payload
  end

  defp weekly_dates_attrs do
    %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-02-02],
      end_date: ~D[2026-02-06]
    }
  end

  defp weekly_rows(context, service_id) do
    Repo.all(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == ^service_id
      )
    )
  end

  defp attribute_rows(context, service_id) do
    Repo.all(
      from(a in CalendarAttribute,
        where:
          a.organization_id == ^context.organization.id and
            a.gtfs_version_id == ^context.version.id and a.service_id == ^service_id
      )
    )
  end

  defp exception_rows(context, service_id) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^context.organization.id and
            d.gtfs_version_id == ^context.version.id and d.service_id == ^service_id,
        order_by: [asc: d.date]
      )
    )
  end

  defp calendar_logs(context, service_id) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.gtfs_version_id == ^context.version.id and l.entity_type == "calendar" and
            l.entity_external_id == ^service_id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end
end
