defmodule GtfsPlanner.Gtfs.FeedSettings.AgencyDeletionTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Attribution
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @race_timeout 10_000
  @missing_fingerprint String.duplicate("0", 64)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    alpha = agency_fixture(organization.id, version.id, agency_attrs("A", "Alpha Transit"))
    bravo = agency_fixture(organization.id, version.id, agency_attrs("B", "Bravo Transit"))

    %{
      organization: organization,
      version: version,
      actor: actor,
      alpha: alpha,
      bravo: bravo,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "review_agency_deletion/3 (R7, INV-3)" do
    test "reports the routes that will move, the blockers and the command token", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r2",
        route_short_name: "2",
        route_long_name: "Second",
        agency_id: "A"
      })

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        route_short_name: "1",
        route_long_name: "First",
        agency_id: "A"
      })

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r3",
        route_short_name: "3",
        route_long_name: "Third",
        agency_id: "B"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert review.agency.id == context.alpha.id
      assert review.target.id == context.bravo.id
      assert review.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert review.blockers == %{fare_ids: [], attribution_ids: []}
      assert review.translation_count == 0

      assert review.routes == [
               %{route_id: "r1", route_short_name: "1", route_long_name: "First"},
               %{route_id: "r2", route_short_name: "2", route_long_name: "Second"}
             ]

      # The token binds the command: another receiving agency reviews to another token.
      charlie =
        agency_fixture(context.organization.id, context.version.id, agency_attrs("C", "Charlie"))

      assert {:ok, other_target} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 charlie.id
               )

      assert other_target.target.id == charlie.id
      refute other_target.fingerprint == review.fingerprint
    end

    test "an agency without routes reviews without a receiving agency", context do
      assert {:ok, review} =
               FeedSettings.review_agency_deletion(context.audit, context.alpha.id, nil)

      assert review.target == nil
      assert review.routes == []

      # A target given for an agency with no routes is ignored, so a caller that keeps
      # sending one still holds the token review returned.
      assert {:ok, ignored} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert ignored.target == nil
      assert ignored.fingerprint == review.fingerprint
    end

    test "refuses the last agency and refuses a deletion without a receiving agency", context do
      solo_version = gtfs_version_fixture(context.organization.id)

      solo =
        agency_fixture(context.organization.id, solo_version.id, agency_attrs("SOLO", "Solo"))

      audit = audit_context(context.organization, solo_version, context.actor)

      assert {:error, :last_agency} = FeedSettings.review_agency_deletion(audit, solo.id, nil)

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(audit, solo.id, nil, @missing_fingerprint)

      assert Repo.get(Agency, solo.id) != nil

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      assert {:error, :target_required} =
               FeedSettings.review_agency_deletion(context.audit, context.alpha.id, nil)

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 nil,
                 @missing_fingerprint
               )

      assert agency_ids(context.version) == ["A", "B"]
      assert route_agency_ids(context.version) == ["A"]
    end

    test "refuses a target that is the agency itself or outside the version", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        agency_fixture(other_organization.id, other_version.id, agency_attrs("A", "Foreign"))

      sibling_version = gtfs_version_fixture(context.organization.id)

      sibling =
        agency_fixture(context.organization.id, sibling_version.id, agency_attrs("A", "Sibling"))

      for target <- [
            context.alpha.id,
            Ecto.UUID.generate(),
            "not-a-uuid",
            nil,
            foreign.id,
            sibling.id
          ] do
        if target == nil do
          assert {:error, :target_required} =
                   FeedSettings.review_agency_deletion(context.audit, context.alpha.id, target)
        else
          assert {:error, :invalid_target} =
                   FeedSettings.review_agency_deletion(context.audit, context.alpha.id, target)
        end
      end

      # A target that does not resolve is refused even when the agency has no routes.
      assert {:error, :invalid_target} =
               FeedSettings.review_agency_deletion(context.audit, context.bravo.id, "not-a-uuid")

      assert agency_ids(context.version) == ["A", "B"]
      assert route_agency_ids(context.version) == ["A"]
    end

    test "an agency outside the scope is not found or is a stale review", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        agency_fixture(other_organization.id, other_version.id, agency_attrs("A", "Foreign"))

      sibling_version = gtfs_version_fixture(context.organization.id)

      sibling =
        agency_fixture(context.organization.id, sibling_version.id, agency_attrs("A", "Sibling"))

      malformed = ["not-a-uuid", nil]
      missing = [Ecto.UUID.generate(), foreign.id, sibling.id]

      for id <- malformed ++ missing do
        assert {:error, :not_found} =
                 FeedSettings.review_agency_deletion(context.audit, id, context.bravo.id)
      end

      # A malformed id is a protocol error; a well-formed id that no longer resolves in the
      # scope is the row set the review observed having changed.
      for id <- malformed do
        assert {:error, :not_found} =
                 FeedSettings.delete_agency(
                   context.audit,
                   id,
                   context.bravo.id,
                   @missing_fingerprint
                 )
      end

      for id <- missing do
        assert {:error, :stale_review} =
                 FeedSettings.delete_agency(
                   context.audit,
                   id,
                   context.bravo.id,
                   @missing_fingerprint
                 )
      end

      assert agency_ids(context.version) == ["A", "B"]
    end

    test "a fare attribute or attribution that names the agency blocks the deletion", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      fare = insert_fare_attribute(context, %{fare_id: "F1", agency_id: "A"})
      insert_fare_attribute(context, %{fare_id: "F2", agency_id: "B"})
      attribution = insert_attribution(context, %{attribution_id: "AT1", agency_id: "A"})
      insert_attribution(context, %{attribution_id: "AT2", agency_id: nil})

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert review.blockers.fare_ids == ["F1"]
      assert review.blockers.attribution_ids == ["AT1"]

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) != nil
      assert route_agency_ids(context.version) == ["A"]
      assert Repo.get(FareAttribute, fare.id) != nil
      assert Repo.get(Attribution, attribution.id) != nil
    end

    test "names an attribution that carries no ID of its own", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      insert_attribution(context, %{attribution_id: nil, agency_id: "A"})

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert review.blockers.attribution_ids == ["(no ID)"]
      assert review.blockers.fare_ids == []

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) != nil
    end
  end

  describe "delete_agency/4 (R7, INV-2, INV-3)" do
    test "moves every route of the agency to the receiving agency and deletes it", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        route_short_name: "1",
        route_long_name: "First",
        agency_id: "A"
      })

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r2",
        route_short_name: "2",
        route_long_name: "Second",
        agency_id: "A"
      })

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r3",
        route_short_name: "3",
        route_long_name: "Third",
        agency_id: "B"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert {:ok, %{moved_routes: 2, target: target}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert target.id == context.bravo.id
      assert Repo.get(Agency, context.alpha.id) == nil
      assert agency_ids(context.version) == ["B"]
      assert route_agency_ids(context.version) == ["B", "B", "B"]
      assert stored_agency(context.version, "B").id == context.bravo.id
    end

    test "deletes an agency without routes without a receiving agency", context do
      assert {:ok, review} =
               FeedSettings.review_agency_deletion(context.audit, context.alpha.id, nil)

      assert {:ok, %{moved_routes: 0, target: nil}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 nil,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) == nil
      assert agency_ids(context.version) == ["B"]
    end

    test "deletes the agency's record-bound translations and keeps the others", context do
      bound =
        insert_translation(context, %{
          table_name: "agency",
          record_id: context.alpha.id,
          field_name: "agency_name",
          language: "fr"
        })

      other_record =
        insert_translation(context, %{
          table_name: "agency",
          record_id: context.bravo.id,
          field_name: "agency_name",
          language: "fr"
        })

      field_value =
        insert_translation(context, %{
          table_name: "agency",
          record_id: nil,
          field_value: "A",
          field_name: "agency_name",
          language: "de"
        })

      other_table =
        insert_translation(context, %{
          table_name: "stops",
          record_id: context.alpha.id,
          field_name: "stop_name",
          language: "fr"
        })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(context.audit, context.alpha.id, nil)

      assert review.translation_count == 1

      assert {:ok, %{moved_routes: 0, target: nil}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 nil,
                 review.fingerprint
               )

      assert Repo.get(Translation, bound.id) == nil
      assert Repo.get(Translation, other_record.id) != nil
      assert Repo.get(Translation, field_value.id) != nil
      assert Repo.get(Translation, other_table.id) != nil
    end

    test "a route added after the review is stale and moves nothing", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r9",
        agency_id: "A"
      })

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) != nil
      assert route_agency_ids(context.version) == ["A", "A"]
    end

    test "an agency added after the review is stale and nothing changes", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      agency_fixture(context.organization.id, context.version.id, agency_attrs("C", "Charlie"))

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) != nil
      assert agency_ids(context.version) == ["A", "B", "C"]
      assert route_agency_ids(context.version) == ["A"]
    end

    test "a receiving agency deleted after the review is stale and changes nothing", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      agency_fixture(context.organization.id, context.version.id, agency_attrs("C", "Charlie"))

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      # A writer outside FeedSettings removed the receiving agency after the review.
      Repo.delete!(context.bravo)

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      # Charlie keeps two agencies in scope, so the last-agency rule cannot be what
      # refuses: the vanished receiving agency refuses, in `deletion_apply_locked!/4`.
      assert agency_ids(context.version) == ["A", "C"]
      assert route_agency_ids(context.version) == ["A"]
    end

    test "refuses a receiving agency whose own ID is blank", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      # Bravo's row ID is untouched, so the reviewed token still binds this command: only
      # a blank receiving agency can refuse it, and without the guard the move would write
      # a blank reference onto the route.
      force_blank_agency_id!(context.bravo)

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert {:error, :invalid_target} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert Repo.get(Agency, context.alpha.id) != nil
      assert Repo.get(Agency, context.bravo.id) != nil
      assert route_agency_ids(context.version) == ["A"]
    end

    test "the second of two reviews taken before either applied is stale", context do
      # Alpha has no routes and Bravo has five, so both reviews are valid on their own.
      for number <- 1..5 do
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "b#{number}",
          agency_id: "B"
        })
      end

      assert {:ok, delete_alpha} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert {:ok, delete_bravo} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.bravo.id,
                 context.alpha.id
               )

      assert {:ok, %{moved_routes: 0, target: nil}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 delete_alpha.fingerprint
               )

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.bravo.id,
                 context.alpha.id,
                 delete_bravo.fingerprint
               )

      assert agency_ids(context.version) == ["B"]
      assert route_agency_ids(context.version) == ["B", "B", "B", "B", "B"]

      existing = agency_ids(context.version)
      assert Enum.all?(route_agency_ids(context.version), &(&1 in existing))

      # The applied review cannot run a second time either.
      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 delete_alpha.fingerprint
               )

      assert agency_ids(context.version) == ["B"]
    end

    test "a different receiving agency applied with the reviewed token is stale", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      charlie =
        agency_fixture(context.organization.id, context.version.id, agency_attrs("C", "Charlie"))

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      assert {:error, :stale_review} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 charlie.id,
                 review.fingerprint
               )

      assert Repo.get(Agency, context.alpha.id) != nil
      assert route_agency_ids(context.version) == ["A"]

      # The reviewed command still applies.
      assert {:ok, %{moved_routes: 1, target: %Agency{id: target_id}}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert target_id == context.bravo.id
      assert Repo.get(Agency, context.alpha.id) == nil
    end
  end

  describe "delete_agency/4 scope and authority (AC-28)" do
    test "a non-editor is forbidden and an out-of-scope version is not found", context do
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "r1",
        agency_id: "A"
      })

      assert {:ok, review} =
               FeedSettings.review_agency_deletion(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id
               )

      deactivated = user_fixture()
      membership = organization_membership_fixture(deactivated, context.organization)
      deactivate_membership_fixture(membership)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      forbidden = [
        audit_context(context.organization, context.version, deactivated),
        audit_context(context.organization, context.version, viewer),
        %{context.audit | actor_id: Ecto.UUID.generate()},
        %{context.audit | actor_id: "not-a-uuid"}
      ]

      for audit <- forbidden do
        assert {:error, :forbidden} =
                 FeedSettings.review_agency_deletion(
                   audit,
                   context.alpha.id,
                   context.bravo.id
                 )

        assert {:error, :forbidden} =
                 FeedSettings.delete_agency(
                   audit,
                   context.alpha.id,
                   context.bravo.id,
                   review.fingerprint
                 )

        # A malformed id does not change what an unauthorized caller sees.
        assert {:error, :forbidden} =
                 FeedSettings.delete_agency(
                   audit,
                   "not-a-uuid",
                   context.bravo.id,
                   review.fingerprint
                 )
      end

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      out_of_scope = [
        audit_context(context.organization, staging, context.actor),
        %{context.audit | gtfs_version_id: Ecto.UUID.generate()},
        %{context.audit | gtfs_version_id: "not-a-uuid"}
      ]

      for audit <- out_of_scope do
        assert {:error, :not_found} =
                 FeedSettings.review_agency_deletion(
                   audit,
                   context.alpha.id,
                   context.bravo.id
                 )

        assert {:error, :not_found} =
                 FeedSettings.delete_agency(
                   audit,
                   context.alpha.id,
                   context.bravo.id,
                   review.fingerprint
                 )
      end

      # None of the refused commands wrote, so the reviewed command still applies.
      assert agency_ids(context.version) == ["A", "B"]
      assert route_agency_ids(context.version) == ["A"]

      assert {:ok, %{moved_routes: 1, target: %Agency{id: target_id}}} =
               FeedSettings.delete_agency(
                 context.audit,
                 context.alpha.id,
                 context.bravo.id,
                 review.fingerprint
               )

      assert target_id == context.bravo.id
      assert Repo.get(Agency, context.alpha.id) == nil
    end
  end

  describe "delete_agency/4 concurrency (INV-2, INV-3)" do
    test "two reviews taken before either applied produce one writer and one :stale_review" do
      # The loser can only return `:stale_review` after the winner committed if it re-read
      # the version's agency set under the version row lock, so the lock, the re-validation
      # and the fingerprint are all on the path under test.
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture()
        version = gtfs_version_fixture(organization.id)
        first_actor = editor_fixture(organization)
        second_actor = editor_fixture(organization)

        alpha = agency_fixture(organization.id, version.id, agency_attrs("A", "Alpha Transit"))
        bravo = agency_fixture(organization.id, version.id, agency_attrs("B", "Bravo Transit"))

        for number <- 1..5 do
          route_fixture(organization.id, version.id, %{
            route_id: "b#{number}",
            agency_id: "B"
          })
        end

        first_audit = audit_context(organization, version, first_actor)
        second_audit = audit_context(organization, version, second_actor)

        assert {:ok, first_review} =
                 FeedSettings.review_agency_deletion(first_audit, alpha.id, bravo.id)

        assert {:ok, second_review} =
                 FeedSettings.review_agency_deletion(second_audit, bravo.id, alpha.id)

        owner = self()

        winner =
          unboxed_connection(fn ->
            Repo.transaction(fn ->
              result =
                FeedSettings.delete_agency(
                  first_audit,
                  alpha.id,
                  bravo.id,
                  first_review.fingerprint
                )

              send(owner, {:winner_result, self(), result})

              receive do
                :release_winner -> :ok
              end
            end)

            send(owner, {:winner_committed, self()})
          end)

        try do
          assert_receive {:winner_result, ^winner, {:ok, %{moved_routes: 0, target: nil}}},
                         @race_timeout

          loser =
            unboxed_connection(fn ->
              %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(owner, {:loser_backend, self(), backend_pid})

              result =
                FeedSettings.delete_agency(
                  second_audit,
                  bravo.id,
                  alpha.id,
                  second_review.fingerprint
                )

              send(owner, {:loser_result, self(), result})
            end)

          assert_receive {:loser_backend, ^loser, backend_pid}, @race_timeout

          # The loser waits on the version row FOR UPDATE the winner holds.
          assert_postgres_lock_wait!(backend_pid)
          send(winner, :release_winner)

          assert_receive {:loser_result, ^loser, {:error, :stale_review}}, @race_timeout
          assert_receive {:winner_committed, ^winner}, @race_timeout

          stored = agency_ids(version)
          assert stored == ["B"]

          assert Enum.all?(route_agency_ids(version), &(&1 in stored))
        after
          send(winner, :release_winner)
          delete_committed_fixtures(organization.id, [first_actor.id, second_actor.id])
        end
      end)
    end
  end

  defp agency_attrs(agency_id, name) do
    %{
      agency_id: agency_id,
      agency_name: name,
      agency_url: "https://#{String.downcase(agency_id)}.example",
      agency_timezone: "America/Chicago"
    }
  end

  defp insert_fare_attribute(context, attrs) do
    %FareAttribute{}
    |> FareAttribute.changeset(
      Map.merge(
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          price: Decimal.new("2.50"),
          currency_type: "USD",
          payment_method: 0
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_attribution(context, attrs) do
    %Attribution{}
    |> Attribution.changeset(
      Map.merge(
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          organization_name: "Alpha Transit"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  # The import path bypasses the trimming changesets, so a whitespace-only agency_id can
  # only be reproduced with a raw write (R5).
  defp force_blank_agency_id!(agency) do
    {1, _returned} =
      Repo.update_all(from(a in Agency, where: a.id == ^agency.id), set: [agency_id: "   "])

    :ok
  end

  defp insert_translation(context, attrs) do
    %Translation{}
    |> Translation.changeset(
      Map.merge(
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          translation: "Translated"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp stored_agency(version, agency_id) do
    Repo.get_by!(Agency, gtfs_version_id: version.id, agency_id: agency_id)
  end

  defp agency_ids(version) do
    Repo.all(
      from(a in Agency,
        where: a.gtfs_version_id == ^version.id,
        order_by: a.agency_id,
        select: a.agency_id
      )
    )
  end

  defp route_agency_ids(version) do
    Repo.all(
      from(r in Route,
        where: r.gtfs_version_id == ^version.id,
        order_by: r.route_id,
        select: r.agency_id
      )
    )
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

  # The race test commits for real, so its fixtures are deleted by hand instead of being
  # rolled back with the sandbox transaction.
  defp delete_committed_fixtures(organization_id, user_ids) do
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id in ^user_ids))
  end

  defp unboxed_connection(fun) do
    {:ok, pid} =
      Task.Supervisor.start_child(__MODULE__.TaskSupervisor, fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          fun.()
        after
          Sandbox.checkin(Repo)
        end
      end)

    pid
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining \\ 200)

  defp assert_postgres_lock_wait!(_backend_pid, 0) do
    flunk("the losing deletion never blocked on the version row lock")
  end

  defp assert_postgres_lock_wait!(backend_pid, attempts_remaining) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    case rows do
      [["Lock"]] ->
        :ok

      _ ->
        receive do
        after
          10 -> assert_postgres_lock_wait!(backend_pid, attempts_remaining - 1)
        end
    end
  end
end
