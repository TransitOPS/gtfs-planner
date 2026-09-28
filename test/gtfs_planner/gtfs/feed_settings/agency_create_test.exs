defmodule GtfsPlanner.Gtfs.FeedSettings.AgencyCreateTest do
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
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  @valid_attrs %{
    "agency_name" => "Metro Transit",
    "agency_url" => "https://metro.example",
    "agency_timezone" => "America/Chicago"
  }
  @url_message "must be a full web address starting with https:// or http://"
  @timezone_message "must be a valid timezone, such as America/New_York"
  @race_timeout 10_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "create_agency/2 first-agency zone (R2)" do
    test "the first agency is stored with its submitted zone", context do
      assert {:ok, %Agency{} = agency} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert agency.agency_id == "metro_transit"
      assert agency.agency_timezone == "America/Chicago"

      assert agency.organization_id == context.organization.id
      assert agency.gtfs_version_id == context.version.id
      assert agency_count(context.version) == 1
    end

    test "an invalid submitted zone returns a changeset error and writes nothing", context do
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})

      attrs = Map.put(@valid_attrs, "agency_timezone", "Not/a_zone")

      assert {:error, %Ecto.Changeset{} = changeset} =
               FeedSettings.create_agency(context.audit, attrs)

      assert errors_on(changeset)[:agency_timezone] == [@timezone_message]
      assert agency_count(context.version) == 0
      assert Repo.get!(Route, route.id).agency_id == nil
    end
  end

  describe "create_agency/2 later-agency zone (R2)" do
    test "a later agency ignores the submitted zone and takes the version zone", context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "MTA",
        agency_name: "Metropolitan Transit",
        agency_timezone: "America/New_York"
      })

      attrs = Map.put(@valid_attrs, "agency_timezone", "Asia/Tokyo")

      assert {:ok, %Agency{} = agency} =
               FeedSettings.create_agency(context.audit, attrs)

      assert agency.agency_timezone == "America/New_York"
      assert agency.agency_id == "metro_transit"
    end

    test "a conflicting or invalid version zone returns :timezone_unresolved with no write",
         context do
      conflict_version = context.version

      agency_fixture(context.organization.id, conflict_version.id, %{
        agency_id: "NY",
        agency_timezone: "America/New_York"
      })

      agency_fixture(context.organization.id, conflict_version.id, %{
        agency_id: "CHI",
        agency_timezone: "America/Chicago"
      })

      invalid_version = gtfs_version_fixture(context.organization.id)

      agency_fixture(context.organization.id, invalid_version.id, %{
        agency_id: "BAD",
        agency_timezone: "Not/a_zone"
      })

      assert {:error, :timezone_unresolved} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert {:error, :timezone_unresolved} =
               FeedSettings.create_agency(
                 audit_context(context.organization, invalid_version, context.actor),
                 @valid_attrs
               )

      assert agency_count(conflict_version) == 2
      assert agency_count(invalid_version) == 1
    end
  end

  describe "create_agency/2 agency IDs (R1)" do
    test "a taken slug gets the next free suffix", context do
      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert {:ok, %Agency{agency_id: "metro_transit_2"}} =
               FeedSettings.create_agency(
                 context.audit,
                 Map.put(@valid_attrs, "agency_url", "https://metro2.example")
               )

      assert agency_count(context.version) == 2
    end

    test "a name that slugifies to empty gets the default id", context do
      attrs = Map.put(@valid_attrs, "agency_name", "東京")

      assert {:ok, %Agency{agency_id: "agency"}} =
               FeedSettings.create_agency(context.audit, attrs)

      assert {:ok, %Agency{agency_id: "agency_2"}} =
               FeedSettings.create_agency(
                 context.audit,
                 Map.put(attrs, "agency_url", "https://tokyo2.example")
               )
    end

    test "a route reference takes the suffix before the new agency does", context do
      # Two distinct dangling references mean the slug rule applies, not adoption. The
      # slug collides with the route reference, so the new agency steps past it.
      for agency_id <- ["metro_transit", "other_line"] do
        route_fixture(context.organization.id, context.version.id, %{agency_id: agency_id})
      end

      assert {:ok, %Agency{agency_id: "metro_transit_2"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      rows = FeedSettings.list_agencies(context.organization.id, context.version.id)
      assert Enum.map(rows, & &1.agency.agency_id) == ["metro_transit_2"]
    end

    test "a fare and an attribution reference also reserve the candidate", context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "downtown",
        agency_name: "Downtown Transit",
        agency_timezone: "America/New_York"
      })

      route_fixture(context.organization.id, context.version.id, %{agency_id: "metro_transit"})
      fare_attribute!(context.organization, context.version, "metro_transit_2")
      attribution!(context.organization, context.version, "metro_transit_3")

      assert {:ok, %Agency{agency_id: "metro_transit_4"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)
    end

    test "the only referenced route id is adopted and its routes stay untouched", context do
      routes =
        for _index <- 1..3 do
          route_fixture(context.organization.id, context.version.id, %{agency_id: "MTA"})
        end

      before = Enum.map(routes, &Repo.get!(Route, &1.id))

      assert {:ok, %Agency{agency_id: "MTA"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert Enum.map(routes, &Repo.get!(Route, &1.id)) == before
    end

    test "a whitespace-only route reference is not adopted as the new agency id", context do
      # Route.changeset/2 trims, so only a raw write produces the padded rows the import
      # path can leave behind.
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})
      force_agency_id!(Route, route.id, "   ")

      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      # Blank under `btrim`, so the reference is not adopted as the agency id; the first
      # agency claims the route instead.
      assert Repo.get!(Route, route.id).agency_id == "metro_transit"
    end

    test "more than one route reference falls back to the slug", context do
      routes =
        for agency_id <- ["A", "B", nil] do
          route_fixture(context.organization.id, context.version.id, %{agency_id: agency_id})
        end

      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert Enum.all?(routes, &(Repo.get!(Route, &1.id).agency_id == "metro_transit"))
    end
  end

  describe "create_agency/2 backfills (R6)" do
    test "the first agency claims blank routes and leaves matching ones alone", context do
      blank = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})

      matching =
        route_fixture(context.organization.id, context.version.id, %{agency_id: "metro_transit"})

      matching_before = Repo.get!(Route, matching.id)

      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert Repo.get!(Route, blank.id).agency_id == "metro_transit"
      assert Repo.get!(Route, matching.id) == matching_before
    end

    test "the second agency fills blank routes and fares and leaves attributions blank",
         context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "NCT",
        agency_name: "North County Transit",
        agency_timezone: "America/New_York"
      })

      routes =
        for _index <- 1..2 do
          route_fixture(context.organization.id, context.version.id, %{agency_id: nil})
        end

      fare = fare_attribute!(context.organization, context.version, nil)
      attribution = attribution!(context.organization, context.version, nil)

      attrs = Map.put(@valid_attrs, "agency_name", "Other Transit")

      assert {:ok, %Agency{agency_id: "other_transit"}} =
               FeedSettings.create_agency(context.audit, attrs)

      assert Enum.all?(routes, &(Repo.get!(Route, &1.id).agency_id == "NCT"))
      assert Repo.get!(FareAttribute, fare.id).agency_id == "NCT"
      assert Repo.get!(Attribution, attribution.id).agency_id == nil
    end

    test "the second agency fills whitespace-only route and fare references", context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "NCT",
        agency_name: "North County Transit",
        agency_timezone: "America/New_York"
      })

      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})
      force_agency_id!(Route, route.id, "   ")

      fare = fare_attribute!(context.organization, context.version, nil)
      force_agency_id!(FareAttribute, fare.id, "   ")

      assert {:ok, %Agency{agency_id: "other_transit"}} =
               FeedSettings.create_agency(
                 context.audit,
                 Map.put(@valid_attrs, "agency_name", "Other Transit")
               )

      # Blank under `btrim` is the blank the second agency owns, even though neither
      # reference is nil or the empty string.
      assert Repo.get!(Route, route.id).agency_id == "NCT"
      assert Repo.get!(FareAttribute, fare.id).agency_id == "NCT"
    end

    test "blank references are not filled once the version already has two agencies", context do
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "NCT",
        agency_name: "North County Transit",
        agency_timezone: "America/New_York"
      })

      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "MTA",
        agency_name: "Metropolitan Transit",
        agency_timezone: "America/New_York"
      })

      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})

      assert {:ok, %Agency{agency_id: "other_transit"}} =
               FeedSettings.create_agency(
                 context.audit,
                 Map.put(@valid_attrs, "agency_name", "Other Transit")
               )

      assert Repo.get!(Route, route.id).agency_id == nil
    end

    test "another version's and organization's references are ignored", context do
      other_version = gtfs_version_fixture(context.organization.id)
      agency_fixture(context.organization.id, other_version.id, %{agency_id: "metro_transit"})

      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      agency_fixture(other_organization.id, foreign_version.id, %{agency_id: "metro_transit_2"})
      foreign_route = route_fixture(other_organization.id, foreign_version.id, %{agency_id: nil})

      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert Repo.get!(Route, foreign_route.id).agency_id == nil
    end
  end

  describe "create_agency/2 atomicity" do
    test "a refused insert rolls the backfill back and the version stays usable", context do
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})

      attrs = Map.put(@valid_attrs, "agency_url", "www.example.com")

      assert {:error, %Ecto.Changeset{} = changeset} =
               FeedSettings.create_agency(context.audit, attrs)

      assert errors_on(changeset)[:agency_url] == [@url_message]

      # The backfill runs before the insert, so this asserts the transaction boundary:
      # the route is untouched and no agency row exists.
      assert agency_count(context.version) == 0
      assert Repo.get!(Route, route.id).agency_id == nil

      # The prior state is still usable: a valid retry assigns the same route.
      assert {:ok, %Agency{agency_id: "metro_transit"}} =
               FeedSettings.create_agency(context.audit, @valid_attrs)

      assert Repo.get!(Route, route.id).agency_id == "metro_transit"
    end
  end

  describe "create_agency/2 scope and authority (R10)" do
    test "a deactivated or non-editor membership is forbidden and backfills nothing", context do
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})

      deactivated = user_fixture()
      membership = organization_membership_fixture(deactivated, context.organization)
      deactivate_membership_fixture(membership)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      for actor <- [deactivated, viewer] do
        assert {:error, :forbidden} =
                 FeedSettings.create_agency(
                   audit_context(context.organization, context.version, actor),
                   @valid_attrs
                 )
      end

      assert {:error, :forbidden} =
               FeedSettings.create_agency(
                 %{context.audit | actor_id: Ecto.UUID.generate()},
                 @valid_attrs
               )

      assert agency_count(context.version) == 0
      assert Repo.get!(Route, route.id).agency_id == nil
    end

    test "a foreign, unpublished, random or malformed version returns :not_found", context do
      route = route_fixture(context.organization.id, context.version.id, %{agency_id: nil})
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      for version <- [other_version, staging, %{id: Ecto.UUID.generate()}, %{id: "not-a-uuid"}] do
        assert {:error, :not_found} =
                 FeedSettings.create_agency(
                   audit_context(context.organization, version, context.actor),
                   @valid_attrs
                 )
      end

      assert agency_count(context.version) == 0
      assert Repo.get!(Route, route.id).agency_id == nil
    end
  end

  describe "create_agency/2 concurrency (INV-2)" do
    test "two writers serialize on the version row and take distinct ids" do
      start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

      Sandbox.unboxed_run(Repo, fn ->
        organization = organization_fixture()
        version = gtfs_version_fixture(organization.id)
        actor = editor_fixture(organization)
        second_actor = editor_fixture(organization)
        owner = self()
        audit = audit_context(organization, version, actor)
        second_audit = audit_context(organization, version, second_actor)
        winner_attrs = @valid_attrs
        loser_attrs = Map.put(@valid_attrs, "agency_timezone", "Asia/Tokyo")

        winner =
          unboxed_connection(fn ->
            Repo.transaction(fn ->
              result = FeedSettings.create_agency(audit, winner_attrs)
              send(owner, {:winner_result, self(), result})

              receive do
                :release_winner -> :ok
              end
            end)

            send(owner, {:winner_committed, self()})
          end)

        try do
          assert_receive {:winner_result, ^winner, {:ok, %Agency{agency_id: "metro_transit"}}},
                         @race_timeout

          loser =
            unboxed_connection(fn ->
              %Postgrex.Result{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(owner, {:loser_backend, self(), backend_pid})

              result = FeedSettings.create_agency(second_audit, loser_attrs)
              send(owner, {:loser_result, self(), result})
            end)

          assert_receive {:loser_backend, ^loser, backend_pid}, @race_timeout

          # The loser is waiting on the winner's `gtfs_versions` FOR UPDATE lock; only
          # releasing the winner lets it read the newly committed agency.
          assert_postgres_lock_wait!(backend_pid)
          send(winner, :release_winner)

          assert_receive {:loser_result, ^loser,
                          {:ok,
                           %Agency{
                             agency_id: "metro_transit_2",
                             agency_timezone: "America/Chicago"
                           }}},
                         @race_timeout

          assert_receive {:winner_committed, ^winner}, @race_timeout

          rows = FeedSettings.list_agencies(organization.id, version.id)
          assert Enum.map(rows, & &1.agency.agency_id) == ["metro_transit", "metro_transit_2"]
        after
          send(winner, :release_winner)
          delete_committed_fixtures(organization.id, [actor.id, second_actor.id])
        end
      end)
    end
  end

  describe "change_agency/2" do
    test "returns a validated editor changeset without casting scope or id" do
      changeset = FeedSettings.change_agency(%Agency{}, @valid_attrs)

      assert changeset.valid?
      assert changeset.changes.agency_name == "Metro Transit"

      invalid =
        FeedSettings.change_agency(
          %Agency{},
          Map.put(@valid_attrs, "agency_url", "www.example.com")
        )

      refute invalid.valid?
      assert errors_on(invalid)[:agency_url] == [@url_message]

      scoped =
        FeedSettings.change_agency(
          %Agency{},
          Map.merge(@valid_attrs, %{
            "agency_id" => "HACK",
            "organization_id" => Ecto.UUID.generate()
          })
        )

      refute Map.has_key?(scoped.changes, :agency_id)
      refute Map.has_key?(scoped.changes, :organization_id)
    end
  end

  defp agency_count(version) do
    Repo.aggregate(
      from(a in Agency, where: a.gtfs_version_id == ^version.id),
      :count
    )
  end

  defp fare_attribute!(organization, version, agency_id) do
    %FareAttribute{}
    |> FareAttribute.changeset(%{
      fare_id: "fare_#{System.unique_integer([:positive])}",
      price: Decimal.new("2.50"),
      currency_type: "USD",
      payment_method: 0,
      agency_id: agency_id,
      organization_id: organization.id,
      gtfs_version_id: version.id
    })
    |> Repo.insert!()
  end

  defp attribution!(organization, version, agency_id) do
    %Attribution{}
    |> Attribution.changeset(%{
      attribution_id: "attr_#{System.unique_integer([:positive])}",
      organization_name: "Metro",
      agency_id: agency_id,
      organization_id: organization.id,
      gtfs_version_id: version.id
    })
    |> Repo.insert!()
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

  # The changesets trim every string field, so an import's padded or whitespace-only
  # agency reference can only be reproduced with a raw write.
  defp force_agency_id!(schema, id, agency_id) do
    {1, _returned} =
      Repo.update_all(from(row in schema, where: row.id == ^id), set: [agency_id: agency_id])
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
    flunk("the losing create never blocked on the version row lock")
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
