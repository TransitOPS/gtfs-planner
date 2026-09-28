defmodule GtfsPlanner.Gtfs.Alignments.ConcurrencyTest do
  @moduledoc false
  # Committing-session races through the production SERIALIZABLE
  # ReviewedApplyTransaction.Repo (CL-8 / AC-11). Each test owns one unique
  # organization and deletes every owned row on exit. Nothing here runs in
  # the SQL sandbox: every DB call goes through `unboxed/1` so rows commit
  # on real connections and SERIALIZABLE snapshots genuinely overlap.

  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @race_timeout 10_000

  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )

    on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)

        :error ->
          Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    :ok
  end

  test "same-base shared race keeps exactly one winner's points without losing updates" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.SameBaseSupervisor})

    fixture =
      unboxed(fn ->
        organization = fresh_org("same-base")
        version = gtfs_version_fixture(organization.id)
        actor = user_fixture()
        audit = audit_context(organization, version, actor)

        coord_stop(organization.id, version.id, "A", "40.712800", "-74.006000")
        coord_stop(organization.id, version.id, "B", "40.713800", "-74.005000")
        pattern = routed_pattern(organization, version, "R1", "P1", ["A", "B"])

        insert_shared(organization, version, "A", "B", [[-74.0057, 40.7130]])

        section = section_at(pattern, 1)
        base = section.revision

        points_a = [[-74.0055, 40.7131]]
        points_b = [[-74.0052, 40.7129]]

        {:ok, review_a} =
          Gtfs.review_alignment_save(pattern.id, [set_entry(section, points_a)], audit)

        {:ok, review_b} =
          Gtfs.review_alignment_save(pattern.id, [set_entry(section, points_b)], audit)

        %{
          org_id: organization.id,
          actor_id: actor.id,
          audit: audit,
          pattern_id: pattern.id,
          base_lock: base.lock_version,
          racers: [
            {pattern.id, [set_entry(section, points_a)], %{}, review_a.fingerprint, points_a},
            {pattern.id, [set_entry(section, points_b)], %{}, review_b.fingerprint, points_b}
          ]
        }
      end)

    on_exit(fn -> cleanup(fixture.org_id, fixture.actor_id) end)

    outcomes = race_applies(supervisor, fixture)

    oks = for {_index, {:ok, result}} <- outcomes, do: result
    conflicts = for {_index, {:error, {:conflict, sections}}} <- outcomes, do: sections

    assert length(oks) == 1
    assert length(conflicts) == 1
    assert hd(oks).segments_written == 1
    assert is_list(hd(conflicts)) and hd(conflicts) != []

    winner_points =
      outcomes
      |> Enum.find(fn {_index, result} -> match?({:ok, _}, result) end)
      |> then(fn {index, _} -> elem(Enum.at(fixture.racers, index), 4) end)

    final =
      unboxed(fn ->
        Repo.one!(
          from(s in AlignmentSegment,
            where:
              s.organization_id == ^fixture.org_id and is_nil(s.from_occurrence_id) and
                s.from_stop_id == "A" and s.to_stop_id == "B"
          )
        )
      end)

    assert final.lock_version == fixture.base_lock + 1
    assert final.points == winner_points
  end

  test "first-create race returns a conflict, not a raw constraint error" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.FirstCreateSupervisor})

    fixture =
      unboxed(fn ->
        organization = fresh_org("first-create")
        version = gtfs_version_fixture(organization.id)
        actor = user_fixture()
        audit = audit_context(organization, version, actor)

        coord_stop(organization.id, version.id, "A", "40.712800", "-74.006000")
        coord_stop(organization.id, version.id, "B", "40.713800", "-74.005000")
        pattern_a = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
        pattern_b = routed_pattern(organization, version, "R2", "P2", ["A", "B"])

        section_a = section_at(pattern_a, 1)
        section_b = section_at(pattern_b, 1)
        points_a = [[-74.0055, 40.7131]]
        points_b = [[-74.0052, 40.7129]]
        choices = %{"scopes" => %{"1" => "shared"}}

        {:ok, review_a} =
          Gtfs.review_alignment_save(pattern_a.id, [set_entry(section_a, points_a)], audit)

        {:ok, review_b} =
          Gtfs.review_alignment_save(pattern_b.id, [set_entry(section_b, points_b)], audit)

        %{
          org_id: organization.id,
          actor_id: actor.id,
          audit: audit,
          racers: [
            {pattern_a.id, [set_entry(section_a, points_a)], choices, review_a.fingerprint, nil},
            {pattern_b.id, [set_entry(section_b, points_b)], choices, review_b.fingerprint, nil}
          ]
        }
      end)

    on_exit(fn -> cleanup(fixture.org_id, fixture.actor_id) end)

    outcomes = race_applies(supervisor, fixture)

    assert 1 == Enum.count(outcomes, fn {_index, result} -> match?({:ok, _}, result) end)

    assert 1 ==
             Enum.count(outcomes, fn {_index, result} ->
               match?({:error, {:conflict, _}}, result)
             end)

    shared_count =
      unboxed(fn ->
        Repo.aggregate(
          from(s in AlignmentSegment,
            where:
              s.organization_id == ^fixture.org_id and is_nil(s.from_occurrence_id) and
                s.from_stop_id == "A" and s.to_stop_id == "B"
          ),
          :count
        )
      end)

    assert shared_count == 1
  end

  test "a committed 01 stop replacement between review and apply fails the save as stale" do
    box =
      unboxed(fn ->
        organization = fresh_org("stale-review")
        version = gtfs_version_fixture(organization.id)
        actor = user_fixture()
        audit = audit_context(organization, version, actor)

        coord_stop(organization.id, version.id, "A", "40.712800", "-74.006000")
        coord_stop(organization.id, version.id, "B", "40.713800", "-74.005000")
        coord_stop(organization.id, version.id, "C", "40.714800", "-74.004000")

        pattern_p2 = routed_pattern(organization, version, "R2", "P2", ["A", "B"])
        timing = timed_pattern_fixture(pattern_p2)
        [occ_a, occ_b] = occurrences(pattern_p2.id)

        timed_pattern_stop_fixture(timing, occ_a, %{arrival_offset: 0, departure_offset: 0})
        timed_pattern_stop_fixture(timing, occ_b, %{arrival_offset: 600, departure_offset: 660})
        stamp_timing_rows(timing)

        link_trip(organization, version, pattern_p2, timing, "T-P2")

        section_p2 = section_at(pattern_p2, 1)
        points_p2 = [[-74.0057, 40.7130]]

        {:ok, review_p2} =
          Gtfs.review_alignment_save(pattern_p2.id, [set_entry(section_p2, points_p2)], audit)

        assert {:ok, _} =
                 Gtfs.apply_alignment_save(
                   pattern_p2.id,
                   [set_entry(section_p2, points_p2)],
                   %{},
                   review_p2.fingerprint,
                   audit
                 )

        assert [_ | _] =
                 trip_distances(organization.id, version.id, "T-P2") |> Enum.reject(&is_nil/1)

        pattern_p1 = routed_pattern(organization, version, "R1", "P1", ["A", "B"])
        section_p1 = section_at(pattern_p1, 1)
        new_points = [[-74.0055, 40.7131]]
        choices = %{"scopes" => %{"1" => "shared"}}
        draft = [set_entry(section_p1, new_points)]

        {:ok, review_p1} = Gtfs.review_alignment_save(pattern_p1.id, draft, audit)

        reviewed_section = Enum.find(review_p1.sections, &(&1.position == 1))
        assert Enum.any?(reviewed_section.shared_rematerialize, &(&1.route_pattern_id == "P2"))

        %{
          org_id: organization.id,
          version_id: version.id,
          actor_id: actor.id,
          audit: audit,
          pattern_p1: pattern_p1.id,
          pattern_p2: pattern_p2.id,
          timing_id: timing.id,
          occ_a_id: occ_a.id,
          occ_b_id: occ_b.id,
          draft: draft,
          choices: choices,
          fingerprint: review_p1.fingerprint
        }
      end)

    on_exit(fn -> cleanup(box.org_id, box.actor_id) end)

    unboxed(fn ->
      {:ok, %{source_fingerprint: source}} =
        Gtfs.get_pattern(box.org_id, box.version_id, "R2", box.pattern_p2)

      # Remove visit B and add a new visit for stop C: retained order is
      # preserved so the 01 structural validation accepts it with linked
      # trips, while the stop-pair change invalidates P1's review
      # fingerprint. R14 distance clearing is step 14's work; here the
      # assertion is that the failed apply changes nothing, whatever the
      # post-edit values are.
      operation =
        {:stops, [%{id: box.occ_a_id, stop_id: "A"}, %{key: "new-c", stop_id: "C"}],
         %{
           box.timing_id => %{
             "new-c" => %{arrival_offset: 900, departure_offset: 900},
             acknowledged: true
           }
         }}

      {:ok, %{fingerprint: reorder_fingerprint}} =
        Gtfs.review(box.pattern_p2, operation, source, box.audit)

      assert {:ok, _} =
               Gtfs.apply_review(box.pattern_p2, operation, reorder_fingerprint, box.audit)
    end)

    post_reorder =
      unboxed(fn ->
        %{
          distances: trip_distances(box.org_id, box.version_id, "T-P2"),
          shape_id: trip_shape_id(box.org_id, box.version_id, "T-P2"),
          shapes: shape_points(box.org_id, box.version_id, "P2")
        }
      end)

    assert {:error, :stale_review} =
             unboxed(fn ->
               Gtfs.apply_alignment_save(
                 box.pattern_p1,
                 box.draft,
                 box.choices,
                 box.fingerprint,
                 box.audit
               )
             end)

    post_apply =
      unboxed(fn ->
        %{
          distances: trip_distances(box.org_id, box.version_id, "T-P2"),
          shape_id: trip_shape_id(box.org_id, box.version_id, "T-P2"),
          shapes: shape_points(box.org_id, box.version_id, "P2")
        }
      end)

    assert post_apply == post_reorder
  end

  defp race_applies(supervisor, fixture) do
    parent = self()

    workers =
      fixture.racers
      |> Enum.with_index()
      |> Enum.map(fn {{pattern_id, draft, choices, fingerprint, _points}, index} ->
        racer(parent, supervisor, fixture.audit, pattern_id, draft, choices, fingerprint, index)
      end)

    assert_receive {:align_racer_ready, 0}, @race_timeout
    assert_receive {:align_racer_ready, 1}, @race_timeout

    Enum.each(Enum.with_index(workers), fn {worker, index} ->
      send(worker.pid, {:align_commit, index})
    end)

    outcomes =
      for _ <- 1..2 do
        assert_receive {:align_racer_done, index, result}, @race_timeout
        {index, result}
      end

    Enum.each(workers, &Task.await(&1, @race_timeout))
    outcomes
  end

  defp racer(parent, supervisor, audit, pattern_id, draft, choices, fingerprint, index) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      send(parent, {:align_racer_ready, index})

      receive do
        {:align_commit, ^index} ->
          result =
            unboxed(fn ->
              Gtfs.apply_alignment_save(pattern_id, draft, choices, fingerprint, audit)
            end)

          send(parent, {:align_racer_done, index, result})
          result
      end
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp fresh_org(suffix) do
    organization_fixture(%{
      alias: "align-concurrency-#{suffix}-#{System.unique_integer([:positive])}"
    })
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp coord_stop(org_id, version_id, stop_id, lat, lon) do
    stop_fixture(org_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Stop #{stop_id}",
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp routed_pattern(organization, version, route_id, pattern_id, stop_ids) do
    route_fixture(organization.id, version.id, %{route_id: route_id})

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_pattern_id: pattern_id
      })

    Enum.each(Enum.with_index(stop_ids, 1), fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    Repo.reload!(pattern)
  end

  defp insert_shared(organization, version, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp set_entry(section, points) do
    %{
      "position" => section.position,
      "from_occurrence_id" => section.from_occurrence_id,
      "to_stop_id" => section.to_stop_id,
      "op" => "set",
      "points" => points,
      "base" => %{
        "segment_id" => section.revision.segment_id,
        "lock_version" => section.revision.lock_version
      }
    }
  end

  defp section_at(pattern, position) do
    pattern
    |> Alignments.resolve()
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.position == position))
  end

  defp occurrences(pattern_id) do
    Repo.all(
      from(o in RoutePatternStop, where: o.route_pattern_id == ^pattern_id, order_by: o.position)
    )
  end

  defp stamp_timing_rows(timing) do
    Repo.all(
      from(r in TimedPatternStop,
        join: occurrence in RoutePatternStop,
        on: occurrence.id == r.route_pattern_stop_id,
        where: r.timed_pattern_id == ^timing.id,
        order_by: occurrence.position
      )
    )
    |> Enum.each(fn row ->
      row
      |> Ecto.Changeset.change(%{
        timepoint: 1,
        pickup_type: 2,
        drop_off_type: 3,
        stop_headsign: "Local"
      })
      |> Repo.update!()
    end)
  end

  defp link_trip(organization, version, pattern, timing, trip_id) do
    trip = trip_fixture(organization.id, version.id, pattern.route_id, %{trip_id: trip_id})

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    Enum.each(1..2, fn sequence ->
      stop_time_fixture(organization.id, version.id, trip.trip_id, "A", %{stop_sequence: sequence})
    end)

    Repo.reload!(trip)
  end

  defp trip_distances(org_id, version_id, trip_id) do
    Repo.all(
      from(st in StopTime,
        where:
          st.organization_id == ^org_id and st.gtfs_version_id == ^version_id and
            st.trip_id == ^trip_id,
        order_by: st.stop_sequence,
        select: st.shape_dist_traveled
      )
    )
  end

  defp trip_shape_id(org_id, version_id, trip_id) do
    Repo.one!(
      from(t in Trip,
        where:
          t.organization_id == ^org_id and t.gtfs_version_id == ^version_id and
            t.trip_id == ^trip_id,
        select: t.shape_id
      )
    )
  end

  defp shape_points(org_id, version_id, shape_id) do
    Repo.all(
      from(s in Shape,
        where:
          s.organization_id == ^org_id and s.gtfs_version_id == ^version_id and
            s.shape_id == ^shape_id,
        order_by: s.shape_pt_sequence,
        select: {s.shape_pt_lat, s.shape_pt_lon, s.shape_dist_traveled}
      )
    )
  end

  defp cleanup(org_id, actor_id) do
    unboxed(fn ->
      Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^org_id))
      Repo.delete_all(from(st in StopTime, where: st.organization_id == ^org_id))
      Repo.delete_all(from(t in Trip, where: t.organization_id == ^org_id))

      timing_ids =
        Repo.all(from(t in TimedPattern, where: t.organization_id == ^org_id, select: t.id))

      Repo.delete_all(from(r in TimedPatternStop, where: r.timed_pattern_id in ^timing_ids))
      Repo.delete_all(from(t in TimedPattern, where: t.organization_id == ^org_id))
      Repo.delete_all(from(s in AlignmentSegment, where: s.organization_id == ^org_id))
      Repo.delete_all(from(s in Shape, where: s.organization_id == ^org_id))
      Repo.delete_all(from(o in RoutePatternStop, where: o.organization_id == ^org_id))
      Repo.delete_all(from(p in RoutePattern, where: p.organization_id == ^org_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^org_id))
      Repo.delete_all(from(s in Stop, where: s.organization_id == ^org_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^org_id))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^org_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^org_id))
      Repo.delete_all(from(u in User, where: u.id == ^actor_id))

      refute Repo.exists?(from(o in Organization, where: o.id == ^org_id))
      refute Repo.exists?(from(u in User, where: u.id == ^actor_id))
      :ok
    end)
  end
end
