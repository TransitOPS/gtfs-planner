defmodule GtfsPlanner.Gtfs.Routes.DeletionTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RouteCleanupFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
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
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The production SERIALIZABLE boundary is pinned for every case (step 4
  # convention) and restored afterward, so these committed fixtures exercise
  # the real public domain entrypoint with real transactions, not the Sandbox
  # adapter.
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

  describe "delete_route/4 reviewed cascade" do
    test "the reviewed matrix removes owned rows and retains shared and foreign rows" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      org_id = fixture.organization.id
      version_id = fixture.version.id

      route = seed_route(fixture)

      foreign_route =
        seed_route(fixture, %{route_id: "R2", route_short_name: "2", route_long_name: "Two"})

      stop_a = unboxed(fn -> stop_fixture(org_id, version_id) end)
      stop_b = unboxed(fn -> stop_fixture(org_id, version_id) end)

      %{
        pattern_one: pattern_one,
        pattern_two: pattern_two,
        timing: timing,
        seeded_log: seeded_log
      } =
        unboxed(fn ->
          pattern_one = route_pattern_fixture(org_id, version_id, %{route_id: "R1"})
          rps_one = route_pattern_stop_fixture(pattern_one, stop_a.stop_id, 1)
          timing = timed_pattern_fixture(pattern_one)
          timed_pattern_stop_fixture(timing, rps_one)

          pattern_two = route_pattern_fixture(org_id, version_id, %{route_id: "R1"})
          route_pattern_stop_fixture(pattern_two, stop_b.stop_id, 1)

          trip_linked =
            trip_fixture(org_id, version_id, "R1", %{
              trip_id: "trip_linked",
              block_id: "block_shared",
              shape_id: "shape_1"
            })

          trip_pattern_metadata_fixture(trip_linked, %{
            timed_pattern_id: timing.id,
            pattern_derivation_state: "linked"
          })

          trip_fixture(org_id, version_id, "R1", %{
            trip_id: "trip_custom",
            block_id: "block_shared"
          })

          trip_fixture(org_id, version_id, "R1", %{trip_id: "trip_pending"})

          trip_fixture(org_id, version_id, "R2", %{
            trip_id: "trip_other",
            block_id: "block_shared"
          })

          stop_time_fixture(org_id, version_id, "trip_linked", stop_a.stop_id, %{
            stop_sequence: 1
          })

          stop_time_fixture(org_id, version_id, "trip_linked", stop_b.stop_id, %{
            stop_sequence: 2
          })

          stop_time_fixture(org_id, version_id, "trip_custom", stop_a.stop_id, %{stop_sequence: 1})

          stop_time_fixture(org_id, version_id, "trip_other", stop_a.stop_id, %{stop_sequence: 1})
          frequency_fixture(org_id, version_id, "trip_linked")

          Repo.insert!(%Shape{
            organization_id: org_id,
            gtfs_version_id: version_id,
            shape_id: "shape_1",
            shape_pt_lat: Decimal.new("1.5"),
            shape_pt_lon: Decimal.new("2.5"),
            shape_pt_sequence: 1
          })

          calendar_attribute_fixture(org_id, version_id, %{service_id: "WKDY"})

          Repo.insert!(%FareAttribute{
            organization_id: org_id,
            gtfs_version_id: version_id,
            fare_id: "fare_keep",
            price: Decimal.new("2.50"),
            currency_type: "USD",
            payment_method: 0
          })

          Repo.insert!(%FareRule{
            organization_id: org_id,
            gtfs_version_id: version_id,
            fare_id: "fare_keep",
            route_id: "R1"
          })

          Repo.insert!(%FareRule{
            organization_id: org_id,
            gtfs_version_id: version_id,
            fare_id: "fare_keep",
            route_id: "R2"
          })

          Repo.insert!(%Attribution{
            organization_id: org_id,
            gtfs_version_id: version_id,
            attribution_id: "attr_own_route",
            route_id: "R1",
            organization_name: "Own route operator"
          })

          Repo.insert!(%Attribution{
            organization_id: org_id,
            gtfs_version_id: version_id,
            attribution_id: "attr_own_trip",
            trip_id: "trip_custom",
            organization_name: "Own trip operator"
          })

          Repo.insert!(%Attribution{
            organization_id: org_id,
            gtfs_version_id: version_id,
            attribution_id: "attr_keep_agency",
            agency_id: "agency_keep",
            organization_name: "Shared operator"
          })

          Repo.insert!(%Attribution{
            organization_id: org_id,
            gtfs_version_id: version_id,
            attribution_id: "attr_foreign",
            trip_id: "trip_other",
            organization_name: "Foreign operator"
          })

          Repo.insert!(%RouteNetwork{
            organization_id: org_id,
            gtfs_version_id: version_id,
            network_id: "net_1",
            route_id: "R1"
          })

          Repo.insert!(%RouteNetwork{
            organization_id: org_id,
            gtfs_version_id: version_id,
            network_id: "net_1",
            route_id: "R2"
          })

          Enum.each(
            [
              %{table_name: "routes", record_id: "R1", language: "fr", translation: "ligne"},
              %{
                table_name: "trips",
                record_id: "trip_custom",
                language: "fr",
                translation: "tour"
              },
              %{
                table_name: "stop_times",
                record_id: "trip_linked",
                record_sub_id: "1",
                language: "fr",
                translation: "arret"
              },
              %{
                table_name: "attributions",
                record_id: "attr_own_route",
                language: "fr",
                translation: "operateur"
              },
              %{
                table_name: "routes",
                field_value: "Fifteen",
                language: "de",
                translation: "funfzehn"
              },
              %{
                table_name: "trips",
                record_id: "trip_other",
                language: "fr",
                translation: "autre"
              },
              %{
                table_name: "attributions",
                record_id: "attr_keep_agency",
                language: "fr",
                translation: "partage"
              }
            ],
            fn attrs ->
              Repo.insert!(
                struct(
                  Translation,
                  Map.merge(
                    %{
                      organization_id: org_id,
                      gtfs_version_id: version_id,
                      field_name: "name"
                    },
                    attrs
                  )
                )
              )
            end
          )

          # Route-endpoint transfer plus a removed-trip transfer, and the
          # stopless in-seat 4/5 pair that identifies its trips only.
          transfer_fixture(org_id, version_id, %{
            from_stop_id: stop_a.stop_id,
            to_stop_id: stop_b.stop_id,
            from_route_id: "R1",
            to_route_id: "R2",
            transfer_type: 0
          })

          transfer_fixture(org_id, version_id, %{
            from_stop_id: stop_a.stop_id,
            to_stop_id: stop_b.stop_id,
            from_trip_id: "trip_linked",
            to_trip_id: "trip_custom",
            transfer_type: 3
          })

          transfer_fixture(org_id, version_id, %{
            from_trip_id: "trip_linked",
            to_trip_id: "trip_pending",
            transfer_type: 4
          })

          transfer_fixture(org_id, version_id, %{
            from_stop_id: stop_a.stop_id,
            to_stop_id: stop_b.stop_id,
            transfer_type: 0
          })

          transfer_fixture(org_id, version_id, %{
            from_stop_id: stop_a.stop_id,
            to_stop_id: stop_b.stop_id,
            from_route_id: "R2",
            to_route_id: "R2",
            from_trip_id: "trip_other",
            to_trip_id: "trip_other",
            transfer_type: 1
          })

          # A pre-existing audit entry must survive the cascade.
          {:ok, seeded_log} =
            Gtfs.record_change_in_transaction(fixture.audit, :route, route, "created", %{
              after: Gtfs.route_audit_snapshot(route)
            })

          %{
            pattern_one: pattern_one,
            pattern_two: pattern_two,
            timing: timing,
            seeded_log: seeded_log
          }
        end)

      assert {:ok, review} = review(fixture, "R1")
      assert review.route_uuid == route.id

      assert {:ok, %{deleted: deleted, operation_id: operation_id}} =
               delete(fixture, "R1", review.fingerprint, true)

      assert deleted == %{
               "route" => 1,
               "patterns" => 2,
               "pattern_stops" => 2,
               "timed_patterns" => 1,
               "timed_pattern_stops" => 1,
               "trips" => 3,
               "stop_times" => 3,
               "frequencies" => 1,
               "transfers" => 3,
               "fare_rules" => 1,
               "attributions" => 2,
               "route_networks" => 1,
               "translations" => 4
             }

      assert is_binary(operation_id)

      unboxed(fn ->
        # Owned rows are gone.
        refute Repo.exists?(from r in Route, where: r.id == ^route.id)

        assert Repo.all(
                 from(p in RoutePattern,
                   where: p.organization_id == ^org_id and p.route_id == "R1",
                   select: p.id
                 )
               ) == []

        assert Repo.all(
                 from(tp in TimedPattern, where: tp.organization_id == ^org_id, select: tp.id)
               ) == []

        assert Repo.all(
                 from(tps in TimedPatternStop,
                   where: tps.timed_pattern_id == ^timing.id,
                   select: tps.id
                 )
               ) == []

        assert Repo.all(
                 from(rps in RoutePatternStop,
                   where: rps.organization_id == ^org_id,
                   select: rps.id
                 )
               ) == []

        assert Repo.all(from(t in Trip, where: t.organization_id == ^org_id, select: t.trip_id)) ==
                 ["trip_other"]

        assert Repo.all(from(st in StopTime, where: st.organization_id == ^org_id, select: st.id))
               |> length() == 1

        assert Repo.all(from(f in Frequency, where: f.organization_id == ^org_id, select: f.id)) ==
                 []

        assert Enum.map(
                 Repo.all(
                   from tr in Transfer,
                     where: tr.organization_id == ^org_id,
                     order_by: tr.transfer_type
                 ),
                 & &1.transfer_type
               ) == [0, 1]

        assert Repo.all(from(fr in FareRule, where: fr.organization_id == ^org_id, select: fr.id))
               |> length() == 1

        assert Enum.map(
                 Repo.all(
                   from a in Attribution,
                     where: a.organization_id == ^org_id,
                     order_by: a.attribution_id,
                     select: a.attribution_id
                 ),
                 & &1
               ) == ["attr_foreign", "attr_keep_agency"]

        assert Repo.all(
                 from(rn in RouteNetwork, where: rn.organization_id == ^org_id, select: rn.id)
               )
               |> length() == 1

        remaining_translations =
          Repo.all(
            from tr in Translation,
              where: tr.organization_id == ^org_id,
              order_by: [tr.table_name, tr.record_id],
              select: {tr.table_name, tr.record_id}
          )

        assert remaining_translations == [
                 {"attributions", "attr_keep_agency"},
                 {"routes", nil},
                 {"trips", "trip_other"}
               ]

        # Shared and historical rows survive untouched.
        assert Repo.exists?(from r in Route, where: r.id == ^foreign_route.id)
        assert Repo.exists?(from s in Stop, where: s.stop_id == ^stop_a.stop_id)
        assert Repo.exists?(from s in Stop, where: s.stop_id == ^stop_b.stop_id)
        assert Repo.exists?(from s in Shape, where: s.shape_id == "shape_1")
        assert Repo.exists?(from c in CalendarAttribute, where: c.service_id == "WKDY")
        assert Repo.exists?(from f in FareAttribute, where: f.fare_id == "fare_keep")

        # One operation id joins the checked route summary and the existing
        # trip/pattern audit semantics (AC-10, AC-14).
        logs =
          Repo.all(
            from l in ChangeLog,
              where: l.organization_id == ^org_id and l.action == "deleted",
              order_by: [l.entity_type, l.entity_external_id]
          )

        route_log = Enum.find(logs, &(&1.entity_type == "route"))
        assert route_log.entity_external_id == "R1"
        assert route_log.changed_fields["operation_id"] == operation_id
        assert route_log.changed_fields["affected_counts"]["trips"] == 3
        assert route_log.changed_fields["affected_counts"]["blocks"] == 1

        assert route_log.changed_fields["affected_identities"]["trips"] == [
                 "trip_custom",
                 "trip_linked",
                 "trip_pending"
               ]

        assert is_map(route_log.changed_fields["before"])

        trip_logs = Enum.filter(logs, &(&1.entity_type == "trip"))
        assert length(trip_logs) == 3

        assert Enum.map(trip_logs, & &1.entity_external_id) == [
                 "trip_custom",
                 "trip_linked",
                 "trip_pending"
               ]

        assert Enum.all?(trip_logs, &(&1.changed_fields["operation_id"] == operation_id))

        pattern_logs = Enum.filter(logs, &(&1.entity_type == "route_pattern"))
        assert length(pattern_logs) == 2

        assert Enum.sort(Enum.map(pattern_logs, & &1.entity_external_id)) ==
                 Enum.sort([pattern_one.route_pattern_id, pattern_two.route_pattern_id])

        assert Enum.all?(pattern_logs, &(&1.changed_fields["operation_id"] == operation_id))

        assert Repo.exists?(from l in ChangeLog, where: l.id == ^seeded_log.id)
      end)
    end

    test "an empty plan deletes only the route and reports zero counts" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route =
        seed_route(fixture, %{route_id: "R9", route_short_name: "9", route_long_name: "Nine"})

      assert {:ok, review} = review(fixture, "R9")
      assert review.empty?

      assert {:ok, %{deleted: deleted, operation_id: operation_id}} =
               delete(fixture, "R9", review.fingerprint, true)

      assert deleted == %{
               "route" => 1,
               "patterns" => 0,
               "pattern_stops" => 0,
               "timed_patterns" => 0,
               "timed_pattern_stops" => 0,
               "trips" => 0,
               "stop_times" => 0,
               "frequencies" => 0,
               "transfers" => 0,
               "fare_rules" => 0,
               "attributions" => 0,
               "route_networks" => 0,
               "translations" => 0
             }

      assert is_binary(operation_id)

      unboxed(fn ->
        refute Repo.exists?(from r in Route, where: r.id == ^route.id)

        assert Repo.exists?(
                 from l in ChangeLog,
                   where:
                     l.entity_type == "route" and l.action == "deleted" and
                       l.entity_id == ^route.id
               )
      end)
    end
  end

  describe "delete_route/4 refusals leave rows unchanged" do
    test "a stale fingerprint returns the fresh review and changes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      org_id = fixture.organization.id
      version_id = fixture.version.id
      route = seed_route(fixture)

      unboxed(fn ->
        trip_fixture(org_id, version_id, "R1", %{trip_id: "trip_a"})
      end)

      assert {:ok, review} = review(fixture, "R1")

      # A same-count-free addition after the review makes its fingerprint stale.
      unboxed(fn ->
        trip_fixture(org_id, version_id, "R1", %{trip_id: "trip_b"})
      end)

      assert {:error, {:stale_review, fresh}} = delete(fixture, "R1", review.fingerprint, true)
      refute fresh.fingerprint == review.fingerprint

      changes = Routes.deletion_review_changes(review.categories, fresh.categories)
      trips_change = Enum.find(changes, &(&1.key == "trips"))
      assert trips_change.key == "trips"
      assert :count_changed in trips_change.markers

      unboxed(fn ->
        assert Repo.exists?(from r in Route, where: r.id == ^route.id)

        assert Enum.sort(
                 Repo.all(from t in Trip, where: t.organization_id == ^org_id, select: t.trip_id)
               ) == ["trip_a", "trip_b"]

        assert Repo.all(
                 from l in ChangeLog,
                   where: l.organization_id == ^org_id and l.action == "deleted",
                   select: l.id
               ) == []
      end)
    end

    test "malformed cross-route timing ownership blocks deletion atomically" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      org_id = fixture.organization.id
      version_id = fixture.version.id
      route = seed_route(fixture)

      seed_route(fixture, %{route_id: "R2", route_short_name: "2", route_long_name: "Two"})

      stop = unboxed(fn -> stop_fixture(org_id, version_id) end)

      timing =
        unboxed(fn ->
          pattern = route_pattern_fixture(org_id, version_id, %{route_id: "R1"})
          rps = route_pattern_stop_fixture(pattern, stop.stop_id, 1)
          timing = timed_pattern_fixture(pattern)
          timed_pattern_stop_fixture(timing, rps)
          timing
        end)

      assert {:ok, review} = review(fixture, "R1")

      # A foreign trip referencing our timing is cross-route timing ownership.
      unboxed(fn ->
        trip = trip_fixture(org_id, version_id, "R2", %{trip_id: "trip_foreign"})

        trip_pattern_metadata_fixture(trip, %{
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked"
        })
      end)

      assert {:error, :malformed_cross_route_timing} =
               delete(fixture, "R1", review.fingerprint, true)

      unboxed(fn ->
        assert Repo.exists?(from r in Route, where: r.id == ^route.id)
        assert Repo.exists?(from p in RoutePattern, where: p.organization_id == ^org_id)
        assert Repo.exists?(from t in Trip, where: t.trip_id == "trip_foreign")
        assert Repo.exists?(from t in TimedPattern, where: t.id == ^timing.id)

        assert Repo.all(
                 from l in ChangeLog,
                   where: l.organization_id == ^org_id and l.action == "deleted",
                   select: l.id
               ) == []
      end)
    end

    test "a failed audit rolls back every row" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      org_id = fixture.organization.id
      version_id = fixture.version.id
      route = seed_route(fixture)

      unboxed(fn ->
        trip_fixture(org_id, version_id, "R1", %{trip_id: "trip_a"})
      end)

      assert {:ok, review} = review(fixture, "R1")

      # The trip audit is the first log write; an unrecordable audit rolls the
      # whole cascade back (AC-10) even though authorization passed.
      assert {:error, %Ecto.Changeset{}} =
               delete(fixture, "R1", review.fingerprint, true, %{fixture.audit | actor_email: nil})

      unboxed(fn ->
        assert Repo.exists?(from r in Route, where: r.id == ^route.id)
        assert Repo.exists?(from t in Trip, where: t.trip_id == "trip_a")

        assert Repo.all(
                 from l in ChangeLog,
                   where: l.organization_id == ^org_id and l.action == "deleted",
                   select: l.id
               ) == []
      end)
    end

    test "an unacknowledged or malformed apply is refused before any effect" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      org_id = fixture.organization.id
      route = seed_route(fixture)
      assert {:ok, review} = review(fixture, "R1")

      assert {:error, :not_acknowledged} = delete(fixture, "R1", review.fingerprint, false)
      assert {:error, :invalid_input} = delete(fixture, "R1", review.fingerprint, "true")

      unboxed(fn ->
        assert Repo.exists?(from r in Route, where: r.id == ^route.id)

        assert Repo.all(
                 from l in ChangeLog,
                   where: l.organization_id == ^org_id and l.action == "deleted",
                   select: l.id
               ) == []
      end)
    end

    test "foreign scope and denied actors are refused without effects" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route = seed_route(fixture)
      assert {:ok, review} = review(fixture, "R1")

      foreign = create_fixture()
      on_exit(fn -> cleanup_fixture(foreign) end)

      assert {:error, :not_found} =
               delete(fixture, "R1", review.fingerprint, true, foreign.audit)

      injected = %{
        foreign.audit
        | organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id
      }

      assert {:error, :forbidden} = delete(fixture, "R1", review.fingerprint, true, injected)

      unboxed(fn ->
        assert Repo.exists?(from r in Route, where: r.id == ^route.id)
      end)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # The real public domain entrypoint runs outside the shared Sandbox against
  # committed fixtures through the production serializable adapter.
  defp review(fixture, route_id, audit \\ nil),
    do: unboxed(fn -> Gtfs.review_route_deletion(route_id, audit || fixture.audit) end)

  defp delete(fixture, route_id, fingerprint, acknowledged, audit \\ nil),
    do:
      unboxed(fn ->
        Gtfs.delete_route(route_id, fingerprint, acknowledged, audit || fixture.audit)
      end)

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
      organization = organization_fixture(%{alias: "route-delete-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "route-delete-#{System.unique_integer([:positive])}@example.com"})

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: actor.id,
          organization_id: organization.id,
          roles: [
            "pathways_studio_editor"
          ]
        })

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

      delete_org_or_version!(FareAttribute, org_id, version_id)

      delete_org_or_version!(Attribution, org_id, version_id)

      delete_org_or_version!(RouteNetwork, org_id, version_id)

      delete_org_or_version!(Translation, org_id, version_id)

      delete_org_or_version!(Shape, org_id, version_id)

      delete_org_or_version!(CalendarAttribute, org_id, version_id)

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
