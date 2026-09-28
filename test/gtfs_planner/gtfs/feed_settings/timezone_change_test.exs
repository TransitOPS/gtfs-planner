defmodule GtfsPlanner.Gtfs.FeedSettings.TimezoneChangeTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @race_timeout 10_000
  @missing_zone String.duplicate("0", 64)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    new_york =
      agency_fixture(organization.id, version.id, %{
        agency_id: "MTA",
        agency_name: "Metropolitan Transit",
        agency_url: "https://mta.example",
        agency_timezone: "America/New_York"
      })

    chicago =
      agency_fixture(organization.id, version.id, %{
        agency_id: "CTA",
        agency_name: "Chicago Transit",
        agency_url: "https://cta.example",
        agency_timezone: "America/Chicago"
      })

    for _route <- 1..2, do: route_fixture(organization.id, version.id, %{agency_id: "MTA"})
    route_fixture(organization.id, version.id, %{agency_id: "CTA"})

    %{
      organization: organization,
      version: version,
      actor: actor,
      new_york: new_york,
      chicago: chicago,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "review_timezone_change/2 (R3, INV-3)" do
    test "trims the chosen zone and reports every agency's current zone and route count",
         context do
      assert {:ok, review} =
               FeedSettings.review_timezone_change(context.audit, " America/Chicago ")

      assert review.zone == "America/Chicago"
      assert review.fingerprint =~ ~r/\A[0-9a-f]{64}\z/

      rows = Map.new(review.agencies, &{&1.agency_id, &1})
      assert Enum.sort(Map.keys(rows)) == ["CTA", "MTA"]

      assert %{
               id: chicago_id,
               agency_name: "Chicago Transit",
               from: "America/Chicago",
               route_count: 1
             } = rows["CTA"]

      assert chicago_id == context.chicago.id

      assert %{
               id: new_york_id,
               agency_name: "Metropolitan Transit",
               from: "America/New_York",
               route_count: 2
             } = rows["MTA"]

      assert new_york_id == context.new_york.id

      # The token binds the reviewed zone: another zone reviews to another token.
      assert {:ok, denver} = FeedSettings.review_timezone_change(context.audit, "America/Denver")
      assert denver.zone == "America/Denver"
      refute denver.fingerprint == review.fingerprint

      # Reviewing the same unchanged version again returns the same token.
      assert {:ok, again} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")
      assert again.fingerprint == review.fingerprint
      assert again.agencies == review.agencies
    end

    test "refuses a zone the timezone catalog does not hold exactly", context do
      for zone <- ["Not/a_zone", "", "   ", nil] do
        assert {:error, :invalid_timezone} =
                 FeedSettings.review_timezone_change(context.audit, zone)

        assert {:error, :invalid_timezone} =
                 FeedSettings.apply_timezone_change(context.audit, zone, @missing_zone)
      end

      assert agency_count(context.version) == 2
      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"

      assert stored_agency(context.version, "CTA").updated_at == context.chicago.updated_at
    end

    test "refuses a version that has no agencies", context do
      empty_version = gtfs_version_fixture(context.organization.id)
      audit = audit_context(context.organization, empty_version, context.actor)

      assert {:error, :no_agencies} =
               FeedSettings.review_timezone_change(audit, "America/Chicago")
    end

    test "a non-editor is forbidden and an out-of-scope version is not found", context do
      deactivated = user_fixture()
      membership = organization_membership_fixture(deactivated, context.organization)
      deactivate_membership_fixture(membership)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      other_version = gtfs_version_fixture(context.organization.id)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "St"})

      forbidden = [
        audit_context(context.organization, context.version, deactivated),
        audit_context(context.organization, context.version, viewer),
        %{context.audit | actor_id: Ecto.UUID.generate()},
        %{context.audit | actor_id: "not-a-uuid"}
      ]

      for audit <- forbidden do
        assert {:error, :forbidden} =
                 FeedSettings.review_timezone_change(audit, "America/Chicago")
      end

      not_found = [
        audit_context(context.organization, staging, context.actor),
        %{context.audit | gtfs_version_id: Ecto.UUID.generate()},
        %{context.audit | gtfs_version_id: "not-a-uuid"}
      ]

      for audit <- not_found do
        assert {:error, :not_found} =
                 FeedSettings.review_timezone_change(audit, "America/Chicago")
      end

      # A published sibling version is in scope and holds no agency of its own, so the
      # review never reports the other version's agencies.
      assert {:error, :no_agencies} =
               FeedSettings.review_timezone_change(
                 audit_context(context.organization, other_version, context.actor),
                 "America/Chicago"
               )

      assert agency_count(context.version) == 2
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
    end
  end

  describe "apply_timezone_change/3 (R3, CR-7)" do
    test "rewrites every agency of the version and resolves the new zone", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      new_york = stored_agency(context.version, "MTA")
      chicago = stored_agency(context.version, "CTA")

      assert new_york.agency_timezone == "America/Chicago"
      assert chicago.agency_timezone == "America/Chicago"

      # One statement moved the whole set, so both rows carry the apply's timestamp.
      assert new_york.updated_at == chicago.updated_at
      assert DateTime.compare(new_york.updated_at, context.new_york.updated_at) == :gt
      assert DateTime.compare(chicago.updated_at, context.chicago.updated_at) == :gt

      assert %{timezone: "America/Chicago", fallback?: false} =
               DisplayClock.resolve_zone(context.organization.id, context.version.id)

      assert agency_count(context.version) == 2
    end

    test "leaves stop times, frequencies and calendars byte-identical", context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "S1"})
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: "MTA"})

      trip =
        trip_fixture(context.organization.id, context.version.id, route.route_id, %{
          trip_id: "T1"
        })

      stop_time =
        stop_time_fixture(
          context.organization.id,
          context.version.id,
          trip.trip_id,
          stop.stop_id,
          %{
            arrival_time: "08:15:00",
            departure_time: "08:16:30"
          }
        )

      frequency =
        frequency_fixture(context.organization.id, context.version.id, trip.trip_id, %{
          start_time: "09:00:00",
          end_time: "12:30:00",
          headway_secs: 900
        })

      calendar =
        calendar_fixture(context.organization.id, context.version.id, %{service_id: "WKDY"})

      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      stored_time = Repo.get!(StopTime, stop_time.id)
      assert stored_time.arrival_time == "08:15:00"
      assert stored_time.departure_time == "08:16:30"
      assert stored_time == stop_time

      stored_frequency = Repo.get!(Frequency, frequency.id)
      assert stored_frequency.start_time == "09:00:00"
      assert stored_frequency.end_time == "12:30:00"
      assert stored_frequency.headway_secs == 900
      assert stored_frequency == frequency

      assert Repo.get!(Calendar, calendar.id) == calendar
    end

    test "an agency added after the review is stale and no zone changes", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      _added =
        agency_fixture(context.organization.id, context.version.id, %{
          agency_id: "PACE",
          agency_name: "Pace Suburban",
          agency_url: "https://pace.example",
          agency_timezone: "America/Chicago"
        })

      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      assert agency_count(context.version) == 3
      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
      assert stored_agency(context.version, "CTA").updated_at == context.chicago.updated_at
      assert stored_agency(context.version, "PACE").agency_timezone == "America/Chicago"
    end

    test "a different zone applied with the reviewed fingerprint is stale", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Denver",
                 review.fingerprint
               )

      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "CTA").agency_timezone == "America/Chicago"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
    end

    test "a fingerprint no review issued is stale and writes nothing", context do
      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 @missing_zone
               )

      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
      assert stored_agency(context.version, "CTA").updated_at == context.chicago.updated_at
    end

    test "an agency rezoned after the review is stale and leaves the set alone", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      # A writer outside FeedSettings rezoned one agency after the review. The token binds
      # the reviewed zones, so the reviewed command no longer matches the version.
      context.chicago
      |> Ecto.Changeset.change(agency_timezone: "America/Denver")
      |> Repo.update!()

      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      assert stored_agency(context.version, "CTA").agency_timezone == "America/Denver"
      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
    end
  end

  describe "apply_timezone_change/3 repeated apply (INV-3)" do
    test "an already-applied review is stale and writes nothing a second time", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      applied_new_york = stored_agency(context.version, "MTA")
      applied_chicago = stored_agency(context.version, "CTA")

      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )

      assert stored_agency(context.version, "MTA").updated_at == applied_new_york.updated_at
      assert stored_agency(context.version, "CTA").updated_at == applied_chicago.updated_at
      assert stored_agency(context.version, "MTA").agency_timezone == "America/Chicago"
      assert agency_count(context.version) == 2
    end

    test "re-applying a review whose zone is already stored adds no row and no zone",
         context do
      solo_version = gtfs_version_fixture(context.organization.id)

      solo =
        agency_fixture(context.organization.id, solo_version.id, %{
          agency_id: "SOLO",
          agency_name: "Solo Transit",
          agency_url: "https://solo.example",
          agency_timezone: "America/Chicago"
        })

      audit = audit_context(context.organization, solo_version, context.actor)
      assert {:ok, review} = FeedSettings.review_timezone_change(audit, "America/Chicago")

      assert {:ok, 1} =
               FeedSettings.apply_timezone_change(audit, "America/Chicago", review.fingerprint)

      assert {:ok, 1} =
               FeedSettings.apply_timezone_change(audit, "America/Chicago", review.fingerprint)

      assert stored_agency(solo_version, "SOLO").agency_timezone == "America/Chicago"
      assert stored_agency(solo_version, "SOLO").id == solo.id
      assert agency_count(solo_version) == 1
    end

    test "a second editor who reviews after the first apply applies the new zone", context do
      second_actor = editor_fixture(context.organization)
      second_audit = audit_context(context.organization, context.version, second_actor)

      assert {:ok, first} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 first.fingerprint
               )

      assert {:ok, second} = FeedSettings.review_timezone_change(second_audit, "America/Denver")
      refute second.fingerprint == first.fingerprint

      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 second_audit,
                 "America/Denver",
                 second.fingerprint
               )

      assert stored_agency(context.version, "MTA").agency_timezone == "America/Denver"
      assert stored_agency(context.version, "CTA").agency_timezone == "America/Denver"
    end
  end

  describe "apply_timezone_change/3 scope and authority (AC-28)" do
    test "a deactivated, non-editor or unknown actor is forbidden and writes nothing", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

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
                 FeedSettings.apply_timezone_change(
                   audit,
                   "America/Chicago",
                   review.fingerprint
                 )
      end

      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
      assert stored_agency(context.version, "CTA").updated_at == context.chicago.updated_at

      # The refused applies wrote nothing, so the reviewed token still applies.
      assert {:ok, 2} =
               FeedSettings.apply_timezone_change(
                 context.audit,
                 "America/Chicago",
                 review.fingerprint
               )
    end

    test "an out-of-scope version is not found and writes nothing", context do
      assert {:ok, review} = FeedSettings.review_timezone_change(context.audit, "America/Chicago")

      other_version = gtfs_version_fixture(context.organization.id)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "St"})

      out_of_scope = [
        audit_context(context.organization, staging, context.actor),
        %{context.audit | gtfs_version_id: Ecto.UUID.generate()},
        %{context.audit | gtfs_version_id: "not-a-uuid"}
      ]

      for audit <- out_of_scope do
        assert {:error, :not_found} =
                 FeedSettings.apply_timezone_change(
                   audit,
                   "America/Chicago",
                   review.fingerprint
                 )
      end

      # A published sibling version is in scope but holds no agency, so this version's
      # review cannot rewrite it and its own agency set stays empty.
      assert {:error, :stale_review} =
               FeedSettings.apply_timezone_change(
                 audit_context(context.organization, other_version, context.actor),
                 "America/Chicago",
                 review.fingerprint
               )

      assert stored_agency(context.version, "MTA").agency_timezone == "America/New_York"
      assert stored_agency(context.version, "CTA").agency_timezone == "America/Chicago"
      assert stored_agency(context.version, "MTA").updated_at == context.new_york.updated_at
      assert agency_count(other_version) == 0
    end
  end

  describe "apply_timezone_change/3 concurrency (INV-2, INV-3)" do
    test "two editors applying different reviewed zones produce one writer and one :stale_review" do
      # The loser can only return `:stale_review` if it recomputed its token after the
      # winner committed, so the version-row FOR UPDATE, the fingerprint recomputation and
      # the write are all on the path under test.
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture()
        version = gtfs_version_fixture(organization.id)
        first_actor = editor_fixture(organization)
        second_actor = editor_fixture(organization)

        for {agency_id, name, zone} <- [
              {"MTA", "Metropolitan Transit", "America/New_York"},
              {"CTA", "Chicago Transit", "America/Chicago"}
            ] do
          agency_fixture(organization.id, version.id, %{
            agency_id: agency_id,
            agency_name: name,
            agency_url: "https://#{String.downcase(agency_id)}.example",
            agency_timezone: zone
          })
        end

        first_audit = audit_context(organization, version, first_actor)
        second_audit = audit_context(organization, version, second_actor)

        assert {:ok, first_review} =
                 FeedSettings.review_timezone_change(first_audit, "America/Chicago")

        assert {:ok, second_review} =
                 FeedSettings.review_timezone_change(second_audit, "America/Denver")

        refute first_review.fingerprint == second_review.fingerprint

        owner = self()

        winner =
          unboxed_connection(fn ->
            Repo.transaction(fn ->
              result =
                FeedSettings.apply_timezone_change(
                  first_audit,
                  "America/Chicago",
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
          assert_receive {:winner_result, ^winner, {:ok, 2}}, @race_timeout

          loser =
            unboxed_connection(fn ->
              %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(owner, {:loser_backend, self(), backend_pid})

              result =
                FeedSettings.apply_timezone_change(
                  second_audit,
                  "America/Denver",
                  second_review.fingerprint
                )

              send(owner, {:loser_result, self(), result})
            end)

          assert_receive {:loser_backend, ^loser, backend_pid}, @race_timeout

          # The loser is waiting on the version row FOR UPDATE the winner holds.
          assert_postgres_lock_wait!(backend_pid)
          send(winner, :release_winner)

          assert_receive {:loser_result, ^loser, {:error, :stale_review}}, @race_timeout
          assert_receive {:winner_committed, ^winner}, @race_timeout

          stored =
            Repo.all(
              from(a in Agency, where: a.gtfs_version_id == ^version.id, order_by: a.agency_id)
            )

          assert Enum.map(stored, &{&1.agency_id, &1.agency_timezone}) == [
                   {"CTA", "America/Chicago"},
                   {"MTA", "America/Chicago"}
                 ]
        after
          send(winner, :release_winner)
          delete_committed_fixtures(organization.id, [first_actor.id, second_actor.id])
        end
      end)
    end
  end

  defp stored_agency(version, agency_id) do
    Repo.get_by!(Agency, gtfs_version_id: version.id, agency_id: agency_id)
  end

  defp agency_count(version) do
    Repo.aggregate(from(a in Agency, where: a.gtfs_version_id == ^version.id), :count)
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
    flunk("the losing apply never blocked on the version row lock")
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
