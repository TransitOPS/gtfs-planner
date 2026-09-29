defmodule GtfsPlanner.Gtfs.Routes.DeletionReviewTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RouteCleanupFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The production SERIALIZABLE boundary is pinned for every case (step 4
  # convention) and restored afterward, so these committed fixtures exercise
  # the real public entrypoint with real transactions, not the Sandbox adapter.
  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

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

  describe "review_route_deletion/2 semantic digests" do
    test "replacing a trip with equal totals changes the fingerprint and marks contents_changed" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route = seed_route(fixture)
      stop = unboxed(fn -> stop_fixture(fixture.organization.id, fixture.version.id) end)

      unboxed(fn ->
        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{
          trip_id: "trip_a",
          block_id: "block_1",
          shape_id: "shape_1"
        })

        stop_time_fixture(fixture.organization.id, fixture.version.id, "trip_a", stop.stop_id, %{
          stop_sequence: 1
        })

        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{trip_id: "trip_b"})

        stop_time_fixture(fixture.organization.id, fixture.version.id, "trip_b", stop.stop_id, %{
          stop_sequence: 1
        })

        Repo.insert!(%Shape{
          organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id,
          shape_id: "shape_1",
          shape_pt_lat: Decimal.new("1.5"),
          shape_pt_lon: Decimal.new("2.5"),
          shape_pt_sequence: 1
        })
      end)

      assert {:ok, review_one} = review(fixture, "R1")
      assert review_one.route_uuid == route.id
      assert category(review_one, "trips").identities == ["trip_a", "trip_b"]
      assert category(review_one, "blocks").count == 1
      assert category(review_one, "blocks").identities == ["block_1"]

      retained = Map.new(review_one.retained, &{&1.key, &1})
      assert retained["shapes"].count == 1
      assert retained["shapes"].identities == ["shape_1"]

      # Replace trip_b with trip_c keeping every count equal.
      unboxed(fn ->
        Repo.delete_all(
          from(st in StopTime,
            where: st.trip_id == "trip_b" and st.organization_id == ^fixture.organization.id
          )
        )

        Repo.delete_all(
          from(t in Trip,
            where: t.trip_id == "trip_b" and t.organization_id == ^fixture.organization.id
          )
        )

        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{trip_id: "trip_c"})

        stop_time_fixture(fixture.organization.id, fixture.version.id, "trip_c", stop.stop_id, %{
          stop_sequence: 1
        })
      end)

      assert {:ok, review_two} = review(fixture, "R1")
      refute review_two.fingerprint == review_one.fingerprint

      trips_one = category(review_one, "trips")
      trips_two = category(review_two, "trips")
      assert trips_one.count == trips_two.count
      assert trips_two.identities == ["trip_a", "trip_c"]

      changes = Routes.deletion_review_changes(review_one.categories, review_two.categories)
      assert %{key: "trips", markers: [:contents_changed]} = find_change(changes, "trips")
    end

    test "editing a stop time with equal totals changes the fingerprint" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      stop = unboxed(fn -> stop_fixture(fixture.organization.id, fixture.version.id) end)

      unboxed(fn ->
        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{trip_id: "trip_a"})

        stop_time_fixture(fixture.organization.id, fixture.version.id, "trip_a", stop.stop_id, %{
          stop_sequence: 1
        })

        stop_time_fixture(fixture.organization.id, fixture.version.id, "trip_a", stop.stop_id, %{
          stop_sequence: 2
        })
      end)

      assert {:ok, review_one} = review(fixture, "R1")
      assert category(review_one, "stop_times").count == 2

      unboxed(fn ->
        stop_time =
          Repo.one!(
            from(st in StopTime,
              where: st.trip_id == "trip_a" and st.stop_sequence == 2,
              where: st.organization_id == ^fixture.organization.id
            )
          )

        stop_time
        |> Ecto.Changeset.change(departure_time: "08:15:00")
        |> Repo.update!()
      end)

      assert {:ok, review_two} = review(fixture, "R1")
      refute review_two.fingerprint == review_one.fingerprint
      assert category(review_two, "stop_times").count == 2

      changes = Routes.deletion_review_changes(review_one.categories, review_two.categories)

      assert %{key: "stop_times", markers: [:contents_changed]} =
               find_change(changes, "stop_times")

      refute Enum.any?(changes, &(&1.key == "trips"))
    end
  end

  describe "review_route_deletion/2 zero-pattern relationships and scope" do
    test "a route with no patterns or trips but a fare rule gets a consequence review" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route = seed_route(fixture)

      fare_rule =
        unboxed(fn ->
          Repo.insert!(%FareRule{
            organization_id: fixture.organization.id,
            gtfs_version_id: fixture.version.id,
            fare_id: "fare_1",
            route_id: "R1"
          })
        end)

      assert {:ok, review} = review(fixture, "R1")
      refute review.empty?
      assert review.route_uuid == route.id
      assert category(review, "route").count == 1
      assert category(review, "patterns").count == 0
      assert category(review, "trips").count == 0
      assert category(review, "fare_rules").count == 1
      assert category(review, "fare_rules").identities == [fare_rule.id]

      # The simple unused dialog is allowed only for an empty entire plan.
      _unused = seed_route(fixture, %{route_id: "R9"})
      assert {:ok, unused_review} = review(fixture, "R9")
      assert unused_review.empty?
    end

    test "foreign references never enter the scoped counts" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      stop = unboxed(fn -> stop_fixture(fixture.organization.id, fixture.version.id) end)

      unboxed(fn ->
        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{trip_id: "trip_own"})

        route_fixture(fixture.organization.id, fixture.version.id, %{
          route_id: "R2",
          route_short_name: "22",
          route_long_name: "Twentytwo",
          route_type: 3
        })

        trip_fixture(fixture.organization.id, fixture.version.id, "R2", %{trip_id: "trip_foreign"})

        stop_time_fixture(
          fixture.organization.id,
          fixture.version.id,
          "trip_foreign",
          stop.stop_id,
          %{stop_sequence: 1}
        )

        Repo.insert!(%FareRule{
          organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id,
          fare_id: "fare_foreign",
          route_id: "R2"
        })

        # A foreign-only transfer and a stop-only transfer never count.
        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id,
          from_route_id: "R2",
          to_route_id: "R2",
          transfer_type: 0
        })

        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id,
          transfer_type: 0
        })

        # An explicit route endpoint on this route counts once.
        transfer_fixture(fixture.organization.id, fixture.version.id, %{
          from_stop_id: stop.stop_id,
          to_stop_id: stop.stop_id,
          from_route_id: "R1",
          to_route_id: "R2",
          transfer_type: 0
        })

        Repo.insert!(%Attribution{
          organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id,
          attribution_id: "attr_foreign",
          trip_id: "trip_foreign",
          organization_name: "Foreign operator"
        })
      end)

      assert {:ok, review} = review(fixture, "R1")
      assert category(review, "trips").count == 1
      assert category(review, "trips").identities == ["trip_own"]
      assert category(review, "stop_times").count == 0
      assert category(review, "fare_rules").count == 0
      assert category(review, "transfers").count == 1
      assert category(review, "attributions").count == 0
    end

    test "foreign scope and denied actors are refused without counts" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route = seed_route(fixture)

      foreign = create_fixture()
      on_exit(fn -> cleanup_fixture(foreign) end)

      # A foreign scope never sees this route and gets no counts (AC-1).
      assert {:error, :not_found} = review(fixture, "R1", foreign.audit)

      injected = %{
        foreign.audit
        | organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id
      }

      assert {:error, :forbidden} = review(fixture, "R1", injected)

      assert {:ok, first} = review(fixture, "R1")
      assert first.route_uuid == route.id

      # A recreated natural ID never carries the old review's identity (AC-9).
      unboxed(fn -> Repo.delete!(route) end)
      replacement = seed_route(fixture)

      assert {:ok, second} = review(fixture, "R1")
      refute second.route_uuid == first.route_uuid
      assert second.route_uuid == replacement.id
      refute second.fingerprint == first.fingerprint
    end
  end

  describe "review_route_deletion/2 timing ownership" do
    test "malformed cross-route timing ownership blocks the review" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)

      seed_route(fixture, %{
        route_id: "R2",
        route_short_name: "2",
        route_long_name: "Two"
      })

      stop = unboxed(fn -> stop_fixture(fixture.organization.id, fixture.version.id) end)

      {rps1, tp1} =
        unboxed(fn ->
          p1 =
            route_pattern_fixture(fixture.organization.id, fixture.version.id, %{route_id: "R1"})

          rps1 = route_pattern_stop_fixture(p1, stop.stop_id, 1)
          tp1 = timed_pattern_fixture(p1)
          timed_pattern_stop_fixture(tp1, rps1)
          {rps1, tp1}
        end)

      # Well-formed: our own linked trip references our own timing.
      unboxed(fn ->
        trip =
          trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{
            trip_id: "trip_linked"
          })

        trip_pattern_metadata_fixture(trip, %{
          timed_pattern_id: tp1.id,
          pattern_derivation_state: "linked"
        })
      end)

      assert {:ok, review} = review(fixture, "R1")
      assert category(review, "patterns").count == 1
      assert category(review, "timed_patterns").count == 1
      assert category(review, "timed_pattern_stops").count == 1

      # A foreign trip referencing our timing is cross-route timing ownership.
      unboxed(fn ->
        trip =
          trip_fixture(fixture.organization.id, fixture.version.id, "R2", %{
            trip_id: "trip_foreign"
          })

        trip_pattern_metadata_fixture(trip, %{
          timed_pattern_id: tp1.id,
          pattern_derivation_state: "linked"
        })
      end)

      assert {:error, :malformed_cross_route_timing} = review(fixture, "R1")

      # A timing row spanning routes is refused at the shared write boundary;
      # the review's own check blocks such rows atomically if one ever bypassed
      # the writer.
      unboxed(fn ->
        Repo.delete_all(
          from(t in Trip,
            where: t.trip_id == "trip_foreign" and t.organization_id == ^fixture.organization.id
          )
        )

        p2 = route_pattern_fixture(fixture.organization.id, fixture.version.id, %{route_id: "R2"})
        rps2 = route_pattern_stop_fixture(p2, stop.stop_id, 1)
        tp2 = timed_pattern_fixture(p2)

        changeset =
          TimedPatternStop.changeset(%TimedPatternStop{}, %{
            timed_pattern_id: tp2.id,
            route_pattern_stop_id: rps1.id,
            timed_pattern: tp2,
            route_pattern_stop: rps1,
            arrival_offset: 0,
            departure_offset: 0
          })

        assert {"must belong to the timed pattern's route pattern", _} =
                 changeset.errors[:route_pattern_stop_id]

        _ = rps2
      end)

      # With no malformed ownership stored, the review proceeds normally and
      # still counts only this route's pattern.
      assert {:ok, after_refusal} = review(fixture, "R1")
      assert category(after_refusal, "patterns").count == 1
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # The real public domain entrypoint runs outside the shared Sandbox against
  # committed fixtures through the production serializable adapter.
  defp review(fixture, route_id, audit \\ nil),
    do: unboxed(fn -> Gtfs.review_route_deletion(route_id, audit || fixture.audit) end)

  defp category(review, key), do: Enum.find(review.categories, &(&1.key == key))

  defp find_change(changes, key), do: Enum.find(changes, &(&1.key == key))

  defp seed_route(fixture, overrides \\ %{}) do
    unboxed(fn ->
      route_fixture(
        fixture.organization.id,
        fixture.version.id,
        Enum.into(overrides, %{
          route_id: "R1",
          route_short_name: "15",
          route_long_name: "Fifteen",
          route_type: 3,
          route_color: "1B4F72",
          route_text_color: "111111"
        })
      )
    end)
  end

  defp create_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "route-review-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "route-review-#{System.unique_integer([:positive])}@example.com"})

      {:ok, _membership} =
        Organizations.add_user_to_organization(actor.id, organization.id, [
          "pathways_studio_editor"
        ])

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      %{organization: organization, version: version, actor: actor, audit: audit}
    end)
  end

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      org_id = fixture.organization.id
      version_id = fixture.version.id

      delete_org_or_version!(Frequency, org_id, version_id)

      delete_org_or_version!(StopTime, org_id, version_id)

      delete_org_or_version!(Trip, org_id, version_id)

      Repo.delete_all(
        from(tps in TimedPatternStop,
          where:
            tps.timed_pattern_id in subquery(
              from(tp in TimedPattern, where: tp.organization_id == ^org_id, select: tp.id)
            )
        )
      )

      Repo.delete_all(from tp in TimedPattern, where: tp.organization_id == ^org_id)
      Repo.delete_all(from rps in RoutePatternStop, where: rps.organization_id == ^org_id)

      delete_org_or_version!(Transfer, org_id, version_id)

      delete_org_or_version!(FareRule, org_id, version_id)

      delete_org_or_version!(Attribution, org_id, version_id)

      delete_org_or_version!(RouteNetwork, org_id, version_id)

      delete_org_or_version!(Translation, org_id, version_id)

      delete_org_or_version!(Shape, org_id, version_id)

      delete_org_or_version!(RoutePattern, org_id, version_id)

      delete_org_or_version!(Stop, org_id, version_id)

      delete_org_or_version!(ChangeLog, org_id, version_id)

      delete_org_or_version!(Route, org_id, version_id)

      delete_org_or_version!(GtfsPlanner.Gtfs.Agency, org_id, version_id)

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^org_id or m.user_id == ^fixture.actor.id
      )

      Repo.delete_all(from v in GtfsVersion, where: v.id == ^version_id)
      Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      Repo.delete_all(from o in Organization, where: o.id == ^org_id)
      :ok
    end)
  end
end
