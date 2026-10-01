defmodule GtfsPlanner.Gtfs.StopEditingReplaceTest do
  @moduledoc """
  `StopEditing.replace_stop/4` (EV-20, AC-19).

  The review (step 18) says what a replace *would* do. This is the other half:
  the write. What matters here is that the feed the editor ends up with is the
  feed they were shown — every kind moved by its own rule, a colliding row
  deleted rather than raising a unique violation halfway through, and a
  fingerprint that no longer matches refusing the whole thing rather than
  applying half of it.

  Every case asserts the resulting *rows*, not the returned summary. A command
  that reported the right counts and wrote the wrong rows would pass a summary
  assertion, and the counts are the easier thing to get right.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest

  @naming_tables [
    {StopTime, :stop_id},
    {GtfsPlanner.Gtfs.RoutePatternStop, :stop_id},
    {ReliefPoint, :stop_id},
    {FlexService, :first_stop_id},
    {StopArea, :stop_id},
    {WalkabilityTest, :stop_id},
    {DeadheadTime, :to_ref},
    {AlignmentSegment, :from_stop_id}
  ]

  setup do
    fixture = staged_fixture()

    on_exit(fn -> cleanup_fixture(fixture) end)

    {:ok, fixture: fixture}
  end

  describe "applying the review" do
    test "no row names the old stop after the replace", context do
      fixture = context.fixture

      unboxed(fn ->
        trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}])
        pattern_stops(fixture, "P-1", ["1433", "1500"])
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})

        flex_fixture(fixture, %{
          key: "FLEX-1",
          hub_stop_ids: ["1433", "1500"],
          first_stop_id: "1433"
        })

        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1433",
          minutes: 20
        })
      end)

      assert {:ok, _result} = replace(fixture, "1433", "1391", %{})

      assert unboxed(fn -> count_naming(fixture, "1433") end) == 0
    end

    test "a colliding row is dropped and the replacement's row is kept", context do
      fixture = context.fixture

      unboxed(fn ->
        # Each of these has a row on the old stop *and* a row the rewrite would
        # land on, so each is a delete rather than a carry-over.
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1391"})

        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1433",
          to_stop_id: "1500",
          min_transfer_time: 240
        })

        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1391",
          to_stop_id: "1500",
          min_transfer_time: 600
        })

        stop_area_fixture(fixture, "AREA-1", "1433")
        stop_area_fixture(fixture, "AREA-1", "1391")
        walkability_fixture(fixture, "1433", "12 Main St")
        walkability_fixture(fixture, "1391", "12 Main St")

        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1433",
          minutes: 20
        })

        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:G",
          to_ref: "stop:1391",
          minutes: 5
        })
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      # What is left is the replacement's own row and nothing else — same id,
      # same minutes. An overwrite would keep the row and change what it says,
      # which a row count would not notice.
      survivors = unboxed(fn -> kept_ids(fixture) end)

      assert survivors.relief_points ==
               unboxed(fn -> replacement_relief_point_ids(fixture) end)

      assert survivors.transfers == [{"1391", "1500", 600}]
      assert length(survivors.stop_areas) == 1

      assert survivors.walkability_tests ==
               unboxed(fn -> replacement_walkability_ids(fixture) end)

      assert survivors.deadheads == [{"stop:1391", 5}]

      assert unboxed(fn -> count_naming(fixture, "1433") end) == 0

      # And the result says so in the review's own names, so a dialog and this
      # cannot disagree.
      assert result.replaced[:relief_points].dropped == 1
      assert result.replaced[:transfers].dropped == 1
      assert result.replaced[:stop_areas].dropped == 1
      assert result.replaced[:walkability_tests].dropped == 1
      assert result.replaced[:deadhead_to].dropped == 1

      # The replacement's own minutes are untouched — a drop deletes the old
      # row, it does not overwrite the survivor.
      assert unboxed(fn -> deadhead_minutes(fixture) end) == [5]
    end

    test "a row that collides with nothing is rewritten", context do
      fixture = context.fixture

      unboxed(fn ->
        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: "1433",
          to_stop_id: "1501",
          min_transfer_time: 240
        })

        stop_area_fixture(fixture, "AREA-2", "1433")
        walkability_fixture(fixture, "1433", "99 Other St")

        deadhead_time_fixture(fixture.organization.id, fixture.version.id, %{
          from_ref: "garage:H",
          to_ref: "stop:1433",
          minutes: 12
        })
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      assert result.replaced[:transfers] == %{key: :transfers, rewritten: 1, dropped: 0}
      assert result.replaced[:stop_areas] == %{key: :stop_areas, rewritten: 1, dropped: 0}
      assert result.replaced[:walkability_tests].rewritten == 1
      assert result.replaced[:deadhead_to].rewritten == 1

      assert unboxed(fn ->
               Repo.exists?(
                 from t in Transfer,
                   where:
                     t.from_stop_id == "1391" and t.to_stop_id == "1501" and
                       t.organization_id == ^fixture.organization.id
               )
             end)

      # The deadhead row keeps the encoding it was written with. Rewriting
      # `stop:1433` to the bare `1391` would point at a different kind of
      # endpoint.
      assert unboxed(fn -> deadhead_minutes(fixture) end) == [12]
      assert unboxed(fn -> deadhead_refs(fixture) end) == ["stop:1391"]
    end

    test "the old stop's translations go and the replacement's stay", context do
      fixture = context.fixture

      unboxed(fn ->
        translation_fixture(fixture, "1433", "es", "Calle Antigua")
        translation_fixture(fixture, "1391", "es", "Calle Nueva")
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      assert result.replaced[:translations] == %{key: :translations, rewritten: 1, dropped: 0}

      assert unboxed(fn -> translations(fixture) end) == [{"1391", "Calle Nueva"}]
    end

    test "a flex hub array loses the old stop and does not double the replacement", context do
      fixture = context.fixture

      unboxed(fn ->
        flex_fixture(fixture, %{key: "FLEX-1", hub_stop_ids: ["1433", "1391"]})
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      assert result.replaced[:flex_hubs].rewritten == 1
      assert unboxed(fn -> hubs(fixture, "FLEX-1") end) == ["1391"]
    end

    test "a segment is re-keyed, and dropped when it would collide or close in on itself",
         context do
      fixture = context.fixture

      unboxed(fn ->
        # (1500 -> 1433) becomes (1500 -> 1391), which already exists: dropped.
        segment_fixture(fixture, "1500", "1433", [[44.62, -124.05]])
        segment_fixture(fixture, "1500", "1391", [[44.62, -124.06]])

        # (1433 -> 1500) becomes (1391 -> 1500), which nothing holds: rewritten.
        segment_fixture(fixture, "1433", "1500", [[44.62, -124.04]])

        # (1391 -> 1433) becomes (1391 -> 1391): a zero-length line that would
        # draw as real service.
        segment_fixture(fixture, "1391", "1433", [[44.62, -124.07]])
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      # Three rows, one of each outcome: re-keyed, collided away, closed in on
      # itself.
      assert result.replaced[:segments_from].dropped == 0
      assert result.replaced[:segments_to].dropped == 2

      pairs = unboxed(fn -> segments(fixture) end)

      assert Enum.sort(pairs) == [{"1391", "1500"}, {"1500", "1391"}]
    end

    test "delete_old: false keeps the old stop, and it is no longer served", context do
      fixture = context.fixture

      unboxed(fn ->
        trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}])
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{})

      assert result.old != nil
      assert unboxed(fn -> stop_exists?(fixture, "1433") end)
      assert unboxed(fn -> count_naming(fixture, "1433") end) == 0
    end

    test "delete_old: true removes the old stop", context do
      fixture = context.fixture

      unboxed(fn ->
        trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}])
        relief_point_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1433"})
      end)

      assert {:ok, result} = replace(fixture, "1433", "1391", %{delete_old: true})

      refute unboxed(fn -> stop_exists?(fixture, "1433") end)
      assert result.old.stop_id == "1433"
    end

    test "a stale fingerprint refuses and changes nothing", context do
      fixture = context.fixture

      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}]) end)

      # A reference appeared after the editor read the review, so the
      # fingerprint they hold no longer describes the feed.
      stale = fingerprint(fixture, "1433", "1391")

      unboxed(fn -> trip_times(fixture, "T-2", [{"1433", 1}, {"1500", 2}]) end)

      before = unboxed(fn -> snapshot(fixture) end)

      assert {:error, :stale_review} =
               replace_with(fixture, "1433", "1391", stale, %{})

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "a fingerprint from another pair is refused", context do
      fixture = context.fixture

      # A review of a *different* pair is not this pair's review. Reading the
      # fingerprint as "some proof the editor saw a review" rather than "the
      # review of these two stops" would let one dialog's answer drive
      # another's apply.
      other_pair = fingerprint(fixture, "1433", "1500")

      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"500", 2}]) end)

      assert {:error, :stale_review} =
               replace_with(fixture, "1433", "1391", other_pair, %{})

      assert unboxed(fn -> count_naming(fixture, "1433") end) > 0
    end

    test "the refusals are re-derived inside the transaction, not trusted", context do
      fixture = context.fixture

      old = unboxed(fn -> stop_id(fixture, "1433") end)
      reviewed = fingerprint(fixture, "1433", "1391")

      # A caller who skips the review cannot talk the command out of a refusal
      # it would have made on its own.
      assert {:error, {:refused, [:same_stop]}} =
               unboxed(fn ->
                 StopEditing.replace_stop(
                   old.id,
                   old.id,
                   %{fingerprint: reviewed},
                   fixture.audit
                 )
               end)
    end

    test "a stop the actor may not edit is forbidden and writes nothing", context do
      fixture = context.fixture

      stranger =
        unboxed(fn -> user_fixture(%{email: "replace-forbid-#{stamp()}@example.com"}) end)

      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}]) end)
      reviewed = fingerprint(fixture, "1433", "1391")

      before = unboxed(fn -> snapshot(fixture) end)

      assert {:error, :forbidden} =
               unboxed(fn ->
                 StopEditing.replace_stop(
                   stop_id(fixture, "1433").id,
                   stop_id(fixture, "1391").id,
                   Map.put(%{delete_old: true}, :fingerprint, reviewed),
                   %{fixture.audit | actor_id: stranger.id}
                 )
               end)

      assert unboxed(fn -> snapshot(fixture) end) == before
    end

    test "the replace is recorded in the history of the old stop", context do
      fixture = context.fixture

      unboxed(fn -> trip_times(fixture, "T-1", [{"1433", 1}, {"1500", 2}]) end)

      assert {:ok, _result} = replace(fixture, "1433", "1391", %{delete_old: true})

      attrs =
        unboxed(fn ->
          Repo.one!(
            from log in ChangeLog,
              where:
                log.organization_id == ^fixture.organization.id and
                  log.entity_external_id == "1433",
              select: log.changed_fields
          )
        end)

      # The history says which stop took over and what moved, so a feed that
      # changed can be explained without reading the diff. The log diffs each
      # field, so a stop that never had one records `from: nil`.
      assert attrs["replaced_by"] == %{"from" => nil, "to" => "1391"}
      assert attrs["delete_old"] == %{"from" => nil, "to" => true}
      assert attrs["replaced"]["to"] == %{"stop_times" => 1}
    end
  end

  # --- drivers

  defp replace(fixture, old_id, new_id, options) do
    replace_with(fixture, old_id, new_id, fingerprint(fixture, old_id, new_id), options)
  end

  defp replace_with(fixture, old_id, new_id, fingerprint, options) do
    unboxed(fn ->
      StopEditing.replace_stop(
        stop_id(fixture, old_id).id,
        stop_id(fixture, new_id).id,
        Map.put(options, :fingerprint, fingerprint),
        fixture.audit
      )
    end)
  end

  defp fingerprint(fixture, old_id, new_id) do
    unboxed(fn ->
      {:ok, review} =
        StopEditing.replace_review(
          stop_id(fixture, old_id).id,
          stop_id(fixture, new_id).id,
          fixture.audit
        )

      review.fingerprint
    end)
  end

  defp stop_id(fixture, stop_id) do
    case Map.fetch(fixture.stops, stop_id) do
      {:ok, stop} -> stop
      :error -> Repo.get_by!(Stop, stop_id: stop_id, gtfs_version_id: fixture.version.id)
    end
  end

  # Every table a rewrite can leave pointing at the old stop. Asserting the
  # union is what a feed's dangling `stop_id` is made of; a count on one table
  # would pass while another still named the old stop.
  defp count_naming(fixture, stop_id) do
    Enum.reduce(@naming_tables, 0, fn {schema, column}, total ->
      count =
        schema
        |> where([r], field(r, ^column) == ^stop_id)
        |> where([r], field(r, :organization_id) == ^fixture.organization.id)
        |> Repo.aggregate(:count, :id)

      total + count
    end)
  end

  # The rows that must survive a drop: the survivor's own id and its value. An
  # overwrite would keep the row and change what it says, which a row count
  # would not notice.
  defp kept_ids(fixture) do
    %{
      relief_points: replacement_relief_point_ids(fixture),
      transfers: transfer_minutes(fixture),
      stop_areas: Repo.all(from r in StopArea, where: r.stop_id == "1391", select: r.id),
      walkability_tests: replacement_walkability_ids(fixture),
      deadheads:
        Repo.all(
          from d in DeadheadTime,
            where: d.organization_id == ^fixture.organization.id,
            select: {d.to_ref, d.minutes}
        )
    }
  end

  defp replacement_relief_point_ids(fixture) do
    Repo.all(
      from r in ReliefPoint,
        where: r.stop_id == "1391" and r.organization_id == ^fixture.organization.id,
        select: r.id
    )
  end

  defp replacement_walkability_ids(fixture) do
    Repo.all(
      from r in WalkabilityTest,
        where: r.stop_id == "1391" and r.organization_id == ^fixture.organization.id,
        select: r.id
    )
  end

  defp transfer_minutes(fixture) do
    Repo.all(
      from t in Transfer,
        where:
          t.from_stop_id in ["1391", "1433"] and
            t.organization_id == ^fixture.organization.id,
        order_by: t.min_transfer_time,
        select: {t.from_stop_id, t.to_stop_id, t.min_transfer_time}
    )
  end

  defp deadhead_minutes(fixture) do
    Repo.all(
      from d in DeadheadTime,
        where: d.organization_id == ^fixture.organization.id,
        order_by: [desc: d.from_ref],
        select: {d.from_ref, d.minutes}
    )
    |> Enum.map(&elem(&1, 1))
  end

  # Both stored forms of the endpoint, so a rewrite that dropped the `stop:`
  # prefix — pointing the row at a different kind of endpoint — is visible.
  defp deadhead_refs(fixture) do
    Repo.all(
      from d in DeadheadTime,
        where: d.organization_id == ^fixture.organization.id,
        select: d.to_ref,
        order_by: d.to_ref
    )
  end

  defp translations(fixture) do
    Repo.all(
      from t in Translation,
        where: t.organization_id == ^fixture.organization.id,
        order_by: t.record_id,
        select: {t.record_id, t.translation}
    )
  end

  defp hubs(fixture, key) do
    Repo.one!(
      from f in FlexService,
        where: f.key == ^key and f.organization_id == ^fixture.organization.id,
        select: f.hub_stop_ids
    )
  end

  defp segments(fixture) do
    Repo.all(
      from s in AlignmentSegment,
        where: s.organization_id == ^fixture.organization.id,
        select: {s.from_stop_id, s.to_stop_id}
    )
  end

  defp stop_exists?(fixture, stop_id) do
    Repo.exists?(
      from s in Stop,
        where: s.stop_id == ^stop_id and s.organization_id == ^fixture.organization.id
    )
  end

  # Every table this step reads or writes, compared as values. A row count
  # would pass a delete-and-reinsert with a new id.
  defp snapshot(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      %{
        stops:
          Repo.all(
            from s in Stop,
              where: s.organization_id in ^scope,
              order_by: s.stop_id,
              select: {s.id, s.stop_id, s.updated_at}
          ),
        stop_times:
          Repo.all(
            from t in StopTime,
              where: t.organization_id in ^scope,
              order_by: field(t, :id),
              select: {t.id, t.stop_id, t.updated_at}
          ),
        transfers: transfer_minutes(fixture),
        segments: segments(fixture),
        deadheads: Repo.all(from d in DeadheadTime, select: {d.id, d.to_ref, d.minutes}),
        logs: Repo.all(from l in ChangeLog, select: {l.id, l.entity_external_id})
      }
    end)
  end

  # --- fixtures. Every one runs inside `unboxed_run`: the fixture helpers open
  # their own transactions and the sandbox refuses a second checkout.

  defp pattern_stops(fixture, route_pattern_id, stop_ids) do
    pattern =
      route_pattern_fixture(fixture.organization.id, fixture.version.id, %{
        route_pattern_id: route_pattern_id
      })

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp trip_times(fixture, trip_id, stop_ids) do
    trip_fixture(fixture.organization.id, fixture.version.id, trip_id, %{
      trip_id: trip_id,
      service_id: "WEEKDAYS"
    })

    Enum.each(stop_ids, fn {stop_id, sequence} ->
      stop_time_fixture(fixture.organization.id, fixture.version.id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: "08:#{String.pad_leading(to_string(sequence), 2, "0")}:00",
        departure_time: "08:#{String.pad_leading(to_string(sequence), 2, "0")}:00"
      })
    end)
  end

  defp flex_fixture(fixture, attrs) do
    %FlexService{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      key: attrs[:key],
      name: "Flex #{attrs[:key]}",
      kind: :area,
      hub_stop_ids: [],
      lock_version: 1
    }
    |> FlexService.changeset(attrs)
    |> Repo.insert!()
  end

  defp stop_area_fixture(fixture, area_id, stop_id) do
    Repo.insert!(%StopArea{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      area_id: area_id,
      stop_id: stop_id
    })
  end

  defp walkability_fixture(fixture, stop_id, address) do
    Repo.insert!(%WalkabilityTest{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      stop_id: stop_id,
      address: address,
      address_lat: Decimal.from_float(44.6200),
      address_lon: Decimal.from_float(-124.0530)
    })
  end

  defp translation_fixture(fixture, record_id, language, text) do
    Repo.insert!(%Translation{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      table_name: "stops",
      field_name: "stop_name",
      language: language,
      translation: text,
      record_id: record_id
    })
  end

  defp segment_fixture(fixture, from_stop_id, to_stop_id, points) do
    Repo.insert!(%AlignmentSegment{
      organization_id: fixture.organization.id,
      gtfs_version_id: fixture.version.id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      points: points,
      lock_version: 1
    })
  end

  # --- staging

  # 1433 is the stop being replaced and 1391 is the one taking over, matching
  # step 18's worked example: 1391 is adjacent in the spec's pattern, so the
  # cases here stage their own patterns and trips rather than reusing one.
  defp staged_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-replace-apply-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id)

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      stops =
        Map.new(
          [
            {"1433", "Main St"},
            {"1391", "Court St"},
            {"1500", "Harbour Way"},
            {"1501", "Quay St"}
          ],
          fn {id, name} ->
            {id,
             stop_fixture(organization.id, version.id, %{
               stop_id: id,
               stop_name: name,
               stop_lat: Decimal.from_float(44.6200),
               stop_lon: Decimal.from_float(-124.0530)
             })}
          end
        )

      calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAYS"})

      %{
        organization: organization,
        version: version,
        actor: actor,
        audit: audit,
        stops: stops
      }
    end)
  end

  defp add_actor(organization_id) do
    actor = user_fixture(%{email: "stop-replace-apply-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: ["pathways_studio_editor"]
      })

    actor
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  @cleanup_tables [
    ChangeLog,
    Transfer,
    ReliefPoint,
    FlexService,
    StopArea,
    WalkabilityTest,
    StopTime,
    DeadheadTime,
    Translation,
    AlignmentSegment,
    Stop,
    GtfsPlanner.Gtfs.RoutePatternStop,
    GtfsPlanner.Gtfs.Trip,
    GtfsPlanner.Gtfs.Calendar
  ]

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      scope = [fixture.organization.id, fixture.version.id]

      Enum.each(@cleanup_tables, fn table ->
        Repo.delete_all(
          from row in table,
            where: row.organization_id in ^scope or row.gtfs_version_id in ^scope
        )
      end)

      Repo.delete_all(
        from m in UserOrgMembership, where: m.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)

      # An unboxed test commits the users its actor and stranger fixtures
      # created. Deleting the organization removes the membership but not the
      # user, and a leftover user breaks the first-administrator tests, which
      # need a database with no committed users.
      Repo.delete_all(
        from u in User,
          where: like(u.email, "replace-forbid-%") or like(u.email, "stop-replace-apply-%")
      )
    end)
  end
end
