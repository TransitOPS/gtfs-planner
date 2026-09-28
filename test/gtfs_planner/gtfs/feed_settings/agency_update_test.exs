defmodule GtfsPlanner.Gtfs.FeedSettings.AgencyUpdateTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @url_message "must be a full web address starting with https:// or http://"
  @race_timeout 10_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    agency =
      agency_fixture(organization.id, version.id, %{
        agency_id: "MTA",
        agency_name: "Metropolitan Transit",
        agency_url: "https://mta.example",
        agency_timezone: "America/New_York"
      })

    %{
      organization: organization,
      version: version,
      actor: actor,
      agency: agency,
      token: agency.updated_at,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "update_agency/4 editable fields (R9)" do
    test "the loaded token persists every editable field", context do
      attrs = %{
        "agency_name" => "Metropolitan Transportation Authority",
        "agency_url" => "https://new.mta.example",
        "agency_lang" => "en",
        "agency_email" => "data@mta.example",
        "agency_fare_url" => "https://mta.example/fares"
      }

      assert {:ok, %Agency{} = updated} =
               FeedSettings.update_agency(context.audit, context.agency.id, attrs, context.token)

      assert updated.id == context.agency.id
      assert updated.agency_name == "Metropolitan Transportation Authority"

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_name == "Metropolitan Transportation Authority"
      assert stored.agency_url == "https://new.mta.example"
      assert stored.agency_lang == "en"
      assert stored.agency_email == "data@mta.example"
      assert stored.agency_fare_url == "https://mta.example/fares"
      assert DateTime.compare(stored.updated_at, context.token) == :gt
    end

    test "a formatted phone number is stored exactly as submitted", context do
      attrs = %{"agency_phone" => "(212) 555-RIDE"}

      assert {:ok, %Agency{agency_phone: "(212) 555-RIDE"}} =
               FeedSettings.update_agency(context.audit, context.agency.id, attrs, context.token)

      assert Repo.get!(Agency, context.agency.id).agency_phone == "(212) 555-RIDE"
    end

    test "an imported schemeless url does not block an unrelated edit", context do
      imported =
        agency_fixture(context.organization.id, context.version.id, %{
          agency_id: "IMP",
          agency_name: "Imported Transit",
          agency_url: "www.example.com",
          agency_timezone: "America/New_York"
        })

      assert {:ok, %Agency{} = updated} =
               FeedSettings.update_agency(
                 context.audit,
                 imported.id,
                 %{"agency_phone" => "555-0100"},
                 imported.updated_at
               )

      assert updated.agency_phone == "555-0100"
      assert updated.agency_url == "www.example.com"
      assert Repo.get!(Agency, imported.id).agency_url == "www.example.com"
    end

    test "a newly submitted schemeless url is refused and keeps the stored row", context do
      assert {:error, %Ecto.Changeset{} = changeset} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_url" => "www.example.com"},
                 context.token
               )

      assert errors_on(changeset)[:agency_url] == [@url_message]

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_url == "https://mta.example"
      assert stored.updated_at == context.token
    end
  end

  describe "update_agency/4 immutable columns (R9)" do
    test "agency_id, agency_timezone and the scope in the attrs are ignored", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      attrs = %{
        "agency_name" => "Renamed Transit",
        "agency_id" => "HACK",
        "agency_timezone" => "Asia/Tokyo",
        "organization_id" => other_organization.id,
        "gtfs_version_id" => other_version.id
      }

      assert {:ok, %Agency{} = updated} =
               FeedSettings.update_agency(context.audit, context.agency.id, attrs, context.token)

      assert updated.agency_name == "Renamed Transit"
      assert updated.agency_timezone == "America/New_York"

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_id == "MTA"
      assert stored.agency_timezone == "America/New_York"
      assert stored.organization_id == context.organization.id
      assert stored.gtfs_version_id == context.version.id

      assert Repo.aggregate(
               from(a in Agency, where: a.organization_id == ^other_organization.id),
               :count
             ) == 0
    end
  end

  describe "update_agency/4 staleness (R8)" do
    test "a token older than the stored row returns :stale and writes nothing", context do
      stale_token = DateTime.add(context.token, -1, :second)

      assert {:error, :stale} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "Rewrite"},
                 stale_token
               )

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_name == "Metropolitan Transit"
      assert stored.updated_at == context.token
    end

    test "a token the row never carried returns :stale with no write", context do
      future_token = DateTime.add(context.token, 60, :second)

      assert {:error, :stale} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "Rewrite"},
                 future_token
               )

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_name == "Metropolitan Transit"
      assert stored.updated_at == context.token
    end

    test "a save loaded before another editor's save loses instead of overwriting", context do
      assert {:ok, %Agency{agency_name: "First Save"}} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "First Save"},
                 context.token
               )

      assert {:error, :stale} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "Second Save"},
                 context.token
               )

      assert Repo.get!(Agency, context.agency.id).agency_name == "First Save"

      # The losing save wrote nothing at all, so the freshly loaded token still applies.
      loaded = Repo.get!(Agency, context.agency.id)

      assert {:ok, %Agency{agency_name: "Second Save"}} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "Second Save"},
                 loaded.updated_at
               )
    end
  end

  describe "update_agency/4 scope and authority (R10, AC-28)" do
    test "a foreign, other-version or malformed agency id returns :not_found", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      foreign =
        agency_fixture(other_organization.id, other_version.id, %{
          agency_id: "OTHER",
          agency_name: "Other Transit",
          agency_url: "https://other.example",
          agency_timezone: "America/New_York"
        })

      second_version = gtfs_version_fixture(context.organization.id)

      same_org_other_version =
        agency_fixture(context.organization.id, second_version.id, %{
          agency_id: "MTA",
          agency_name: "Same Organization Other Version",
          agency_url: "https://second.example",
          agency_timezone: "America/New_York"
        })

      attrs = %{"agency_name" => "Hijacked"}

      for id <- [foreign.id, same_org_other_version.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} =
                 FeedSettings.update_agency(context.audit, id, attrs, context.token)
      end

      assert Repo.get!(Agency, foreign.id).agency_name == "Other Transit"

      assert Repo.get!(Agency, same_org_other_version.id).agency_name ==
               "Same Organization Other Version"

      assert Repo.get!(Agency, context.agency.id).agency_name == "Metropolitan Transit"
      assert Repo.get!(Agency, context.agency.id).updated_at == context.token
    end

    test "a foreign, unpublished, random or malformed scope returns :not_found", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      for version <- [other_version, staging, %{id: Ecto.UUID.generate()}, %{id: "not-a-uuid"}] do
        assert {:error, :not_found} =
                 FeedSettings.update_agency(
                   audit_context(context.organization, version, context.actor),
                   context.agency.id,
                   %{"agency_name" => "Hijacked"},
                   context.token
                 )
      end

      assert Repo.get!(Agency, context.agency.id).updated_at == context.token
    end

    test "a deactivated, non-editor or unknown actor is forbidden and writes nothing", context do
      deactivated = user_fixture()
      membership = organization_membership_fixture(deactivated, context.organization)
      deactivate_membership_fixture(membership)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      attrs = %{"agency_name" => "Hijacked"}

      for actor <- [deactivated, viewer] do
        assert {:error, :forbidden} =
                 FeedSettings.update_agency(
                   audit_context(context.organization, context.version, actor),
                   context.agency.id,
                   attrs,
                   context.token
                 )
      end

      assert {:error, :forbidden} =
               FeedSettings.update_agency(
                 %{context.audit | actor_id: Ecto.UUID.generate()},
                 context.agency.id,
                 attrs,
                 context.token
               )

      assert {:error, :forbidden} =
               FeedSettings.update_agency(
                 %{context.audit | actor_id: "not-a-uuid"},
                 context.agency.id,
                 attrs,
                 context.token
               )

      stored = Repo.get!(Agency, context.agency.id)
      assert stored.agency_name == "Metropolitan Transit"
      assert stored.updated_at == context.token

      # Nothing was written, so the refused saves did not rotate the token.
      assert {:ok, %Agency{agency_name: "Later Save"}} =
               FeedSettings.update_agency(
                 context.audit,
                 context.agency.id,
                 %{"agency_name" => "Later Save"},
                 context.token
               )
    end
  end

  describe "update_agency/4 concurrency (INV-2)" do
    test "two writers racing one agency produce one winner and one :stale loser" do
      # The second writer loads the same token as the first and saves while the first
      # writer's transaction still holds the agency row lock. It can only return `:stale`
      # if its locked read observes the first writer's committed, newer `updated_at`,
      # so the row lock and the token comparison are both on the path under test.
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture()
        version = gtfs_version_fixture(organization.id)
        first_actor = editor_fixture(organization)
        second_actor = editor_fixture(organization)

        agency =
          agency_fixture(organization.id, version.id, %{
            agency_id: "MTA",
            agency_name: "Metropolitan Transit",
            agency_url: "https://mta.example",
            agency_timezone: "America/New_York"
          })

        token = agency.updated_at
        owner = self()
        first_audit = audit_context(organization, version, first_actor)
        second_audit = audit_context(organization, version, second_actor)

        winner =
          unboxed_connection(fn ->
            Repo.transaction(fn ->
              result =
                FeedSettings.update_agency(
                  first_audit,
                  agency.id,
                  %{"agency_name" => "Winner Transit"},
                  token
                )

              send(owner, {:winner_result, self(), result})

              receive do
                :release_winner -> :ok
              end
            end)

            send(owner, {:winner_committed, self()})
          end)

        try do
          assert_receive {:winner_result, ^winner, {:ok, %Agency{agency_name: "Winner Transit"}}},
                         @race_timeout

          loser =
            unboxed_connection(fn ->
              %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(owner, {:loser_backend, self(), backend_pid})

              result =
                FeedSettings.update_agency(
                  second_audit,
                  agency.id,
                  %{"agency_name" => "Loser Transit"},
                  token
                )

              send(owner, {:loser_result, self(), result})
            end)

          assert_receive {:loser_backend, ^loser, backend_pid}, @race_timeout

          # The loser is waiting on the winner's agency row FOR UPDATE lock, taken after
          # the shared version lock both writers hold.
          assert_postgres_lock_wait!(backend_pid)
          send(winner, :release_winner)

          assert_receive {:loser_result, ^loser, {:error, :stale}}, @race_timeout
          assert_receive {:winner_committed, ^winner}, @race_timeout

          stored = Repo.get!(Agency, agency.id)
          assert stored.agency_name == "Winner Transit"
          assert DateTime.compare(stored.updated_at, token) == :gt
          assert agency_count(version) == 1
        after
          send(winner, :release_winner)
          delete_committed_fixtures(organization.id, [first_actor.id, second_actor.id])
        end
      end)
    end
  end

  defp agency_count(version) do
    Repo.aggregate(
      from(a in Agency, where: a.gtfs_version_id == ^version.id),
      :count
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
    flunk("the losing update never blocked on the agency row lock")
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
