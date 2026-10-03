defmodule GtfsPlanner.Alerts.MigrationTest do
  @moduledoc """
  Step 1: the alert migrations' table shape, defaults, constraints and foreign
  key actions. Rows are written by table name with explicit ids and timestamps,
  and every uuid is dumped to its 16-byte form because a schemaless insert has
  no field type to do it.

  Each expected constraint violation aborts the sandbox transaction, so every
  `assert_raise` sits in its own test (docs/engineering-standards.md, SQL Sandbox).
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Repo

  describe "service_alerts" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      %{organization: organization, version: version}
    end

    test "inserts a draft with the column defaults", %{
      organization: organization,
      version: version
    } do
      id = insert_alert(organization, version)

      %{rows: [[revision, complete, scope, timing, message, first_date, last_date]]} =
        Repo.query!(
          """
          SELECT revision, complete, scope, timing, message, first_date, last_date
          FROM service_alerts WHERE id = $1
          """,
          [id]
        )

      assert revision == 1
      assert complete == false
      assert scope == %{}
      assert timing == %{}
      assert message == %{}
      assert is_nil(first_date)
      assert is_nil(last_date)
    end

    test "rejects revision 0 with the named check constraint", %{
      organization: organization,
      version: version
    } do
      error =
        assert_raise Postgrex.Error, fn ->
          insert_alert(organization, version, %{revision: 0})
        end

      assert Exception.message(error) =~ "service_alerts_revision_positive"
    end

    test "rejects an alert whose organization does not own the version", %{version: version} do
      other_organization = organization_fixture()

      error =
        assert_raise Postgrex.Error, fn ->
          insert_alert(other_organization, version)
        end

      assert Exception.message(error) =~ "service_alerts_source_version_owner_fkey"
    end

    test "deleting the source gtfs_version retains the alert and clears only the source", %{
      organization: organization,
      version: version
    } do
      id = insert_alert(organization, version)

      Repo.delete_all(from(v in GtfsPlanner.Versions.GtfsVersion, where: v.id == ^version.id))

      assert %{rows: [[organization_id, source_gtfs_version_id, revision]]} =
               Repo.query!(
                 "SELECT organization_id, source_gtfs_version_id, revision FROM service_alerts WHERE id = $1",
                 [id]
               )

      assert Ecto.UUID.load!(organization_id) == organization.id
      assert is_nil(source_gtfs_version_id)
      assert revision == 1
    end

    test "deleting the user leaves created_by_id and updated_by_id NULL", %{
      organization: organization,
      version: version
    } do
      user = user_fixture()
      user_id = Ecto.UUID.dump!(user.id)
      id = insert_alert(organization, version, %{created_by_id: user_id, updated_by_id: user_id})

      Repo.delete_all(from(u in GtfsPlanner.Accounts.User, where: u.id == ^user.id))

      %{rows: [[created_by_id, updated_by_id]]} =
        Repo.query!("SELECT created_by_id, updated_by_id FROM service_alerts WHERE id = $1", [id])

      assert is_nil(created_by_id)
      assert is_nil(updated_by_id)
    end

    test "is queryable by organization, version and last_date", %{
      organization: organization,
      version: version
    } do
      last_date = Date.utc_today()
      id = insert_alert(organization, version, %{last_date: last_date})

      assert %{rows: [[listed_id]]} =
               Repo.query!(
                 """
                 SELECT id FROM service_alerts
                 WHERE organization_id = $1 AND source_gtfs_version_id = $2 AND last_date = $3
                 """,
                 [Ecto.UUID.dump!(organization.id), Ecto.UUID.dump!(version.id), last_date]
               )

      assert listed_id == id
    end
  end

  describe "users.alert_authoring_mode" do
    # The `User` schema carries its own default, so a row written through it would
    # pass without the migration's. The column's catalog entry is what a writer
    # that does not name the column, and every existing user, gets.
    test "the column is NOT NULL and defaults to \"form\"" do
      assert %{rows: [[default, nullable]]} =
               Repo.query!("""
               SELECT column_default, is_nullable FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'users'
                 AND column_name = 'alert_authoring_mode'
               """)

      assert default == "'form'::character varying"
      assert nullable == "NO"
    end
  end

  describe "alert_scripts" do
    setup do
      %{organization: organization_fixture()}
    end

    test "inserts an organization script", %{organization: organization} do
      id = insert_script(organization, "Delay opener")

      %{rows: [[name, position]]} =
        Repo.query!("SELECT name, position FROM alert_scripts WHERE id = $1", [id])

      assert name == "Delay opener"
      assert is_nil(position)
    end

    test "rejects a second script with the same organization and name", %{
      organization: organization
    } do
      insert_script(organization, "Delay opener")

      error =
        assert_raise Postgrex.Error, fn ->
          insert_script(organization, "Delay opener")
        end

      assert Exception.message(error) =~ "alert_scripts_organization_id_name_index"
    end

    test "allows the same script name in another organization", %{organization: organization} do
      insert_script(organization, "Delay opener")

      other = organization_fixture()
      id = insert_script(other, "Delay opener")

      assert %{num_rows: 1} =
               Repo.query!("SELECT id FROM alert_scripts WHERE id = $1", [id])
    end

    test "deleting the organization deletes its scripts", %{organization: organization} do
      id = insert_script(organization, "Delay opener")

      Repo.delete_all(
        from(o in GtfsPlanner.Organizations.Organization, where: o.id == ^organization.id)
      )

      assert count("alert_scripts", id) == 0
    end
  end

  describe "alert_settings" do
    setup do
      %{organization: organization_fixture()}
    end

    test "inserts one settings row per organization", %{organization: organization} do
      id = insert_settings(organization)

      %{rows: [[guidelines, revision]]} =
        Repo.query!("SELECT guidelines, revision FROM alert_settings WHERE id = $1", [id])

      assert is_nil(guidelines)
      assert revision == 1
    end

    test "rejects a second settings row for the same organization", %{organization: organization} do
      insert_settings(organization)

      error =
        assert_raise Postgrex.Error, fn ->
          insert_settings(organization)
        end

      assert Exception.message(error) =~ "alert_settings_organization_id_index"
    end

    test "deleting the organization deletes its settings row", %{organization: organization} do
      id = insert_settings(organization)

      Repo.delete_all(
        from(o in GtfsPlanner.Organizations.Organization, where: o.id == ^organization.id)
      )

      assert count("alert_settings", id) == 0
    end
  end

  defp count(table, id) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE id = $1", [id])
    count
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp insert_alert(organization, version, overrides \\ %{}) do
    id = Ecto.UUID.bingenerate()

    defaults = %{
      id: id,
      organization_id: Ecto.UUID.dump!(organization.id),
      source_gtfs_version_id: Ecto.UUID.dump!(version.id),
      revision: 1,
      complete: false,
      inserted_at: now(),
      updated_at: now()
    }

    Repo.insert_all("service_alerts", [Map.merge(defaults, overrides)])
    id
  end

  defp insert_script(organization, name) do
    id = Ecto.UUID.bingenerate()

    Repo.insert_all("alert_scripts", [
      %{
        id: id,
        organization_id: Ecto.UUID.dump!(organization.id),
        name: name,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp insert_settings(organization) do
    id = Ecto.UUID.bingenerate()

    Repo.insert_all("alert_settings", [
      %{
        id: id,
        organization_id: Ecto.UUID.dump!(organization.id),
        revision: 1,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end
end

defmodule GtfsPlanner.Alerts.ConvertAlertTargetsMigrationTest do
  @moduledoc """
  The migration that stores exact GTFS feed IDs in the private alert selectors and
  capture maps, run for real against an isolated pre-conversion schema.

  `Ecto.Migrator` runs a migration in its own process, which cannot share a
  sandboxed connection, so this module follows the other relational-migration
  tests: it switches the sandbox to auto mode, builds the tables in a throwaway
  schema and removes the schema afterward.

  Every expectation is a literal. The same feed IDs exist in a sibling version and
  in another organization under different row UUIDs, so a conversion that joined
  without the alert's own organization and version would store the wrong ID.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20261003074033_convert_alert_targets_to_gtfs_ids.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.ConvertAlertTargetsToGtfsIds, as: Migration

  # A feed ID that looks like a UUID and is not lower case: it must come out of the
  # conversion byte for byte.
  @uuid_like "ABCDEF00-0000-0000-0000-000000000000"

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    prefix = setup_prefix()

    org = Ecto.UUID.generate()
    other_org = Ecto.UUID.generate()
    version = Ecto.UUID.generate()
    sibling = Ecto.UUID.generate()
    foreign = Ecto.UUID.generate()

    # The same feed IDs live in the sibling version and in another organization,
    # each with its own row UUID.
    ids =
      for {scope, organization, gtfs_version} <- [
            {:own, org, version},
            {:sibling, org, sibling},
            {:foreign, other_org, foreign}
          ],
          into: %{} do
        {scope,
         %{
           route_main:
             insert_row(prefix, "routes", "route_id", organization, gtfs_version, @uuid_like),
           route_12: insert_row(prefix, "routes", "route_id", organization, gtfs_version, "12"),
           stop_a: insert_row(prefix, "stops", "stop_id", organization, gtfs_version, "STOP-A"),
           stop_b: insert_row(prefix, "stops", "stop_id", organization, gtfs_version, "STOP-B"),
           stop_c: insert_row(prefix, "stops", "stop_id", organization, gtfs_version, "STOP-C"),
           trip: insert_row(prefix, "trips", "trip_id", organization, gtfs_version, "T-100")
         }}
      end

    %{prefix: prefix, org: org, version: version, ids: ids}
  end

  describe "up/0" do
    test "stores each feed ID from the alert's own scope and keeps everything else", context do
      %{prefix: prefix, org: org, version: version, ids: %{own: own}} = context

      legacy = insert_alert(prefix, org, version, legacy_scope(own), legacy_capture(own))

      # No target at all: nothing to convert, so the stored digest stays valid.
      system =
        insert_alert(
          prefix,
          org,
          version,
          %{"shape" => "system", "route_ids" => []},
          %{"scope_digest" => "keep", "selectors" => %{"shape" => "system", "routes" => []}}
        )

      # The captured ID answers for a stop that is no longer in the version, and
      # for an alert whose source version is gone.
      gone = Ecto.UUID.generate()

      captured_only =
        insert_alert(
          prefix,
          org,
          nil,
          %{"shape" => "stop_all_routes", "stop_ids" => [gone]},
          %{
            "scope_digest" => "stale",
            "selectors" => %{
              "stops" => [%{"id" => gone, "gtfs_id" => "STOP-GONE", "label" => "Gone"}],
              "unresolved_stops" => []
            }
          }
        )

      publication = insert_publication(prefix, legacy, org)
      before = alert_row(prefix, legacy)
      snapshots_before = snapshots(prefix, publication)

      run(:up, prefix)

      after_up = alert_row(prefix, legacy)

      assert after_up.scope ==
               legacy_scope(own)
               |> Map.merge(%{
                 "route_ids" => [@uuid_like, "12"],
                 "stop_ids" => ["STOP-A"],
                 "route_stop_pairs" => [%{"route_id" => @uuid_like, "stop_id" => "STOP-A"}],
                 "trips" => [
                   %{"trip_id" => "T-100", "service_date" => "2026-10-05", "start_time" => nil},
                   %{
                     "trip_id" => "T-100",
                     "service_date" => "2026-10-05",
                     "start_time" => "25:15:00"
                   }
                 ],
                 "stretch_from_stop_id" => "STOP-B",
                 "stretch_to_stop_id" => "STOP-C"
               })

      selectors = after_up.reference["selectors"]

      assert selectors["routes"] == [
               %{"id" => @uuid_like, "gtfs_id" => @uuid_like, "label" => "Main"},
               %{"id" => "12", "gtfs_id" => "12", "label" => "12"}
             ]

      assert selectors["stops"] == [%{"id" => "STOP-A", "gtfs_id" => "STOP-A", "label" => "A"}]
      assert selectors["unresolved_routes"] == []

      assert [%{"route_id" => @uuid_like, "stop_id" => "STOP-A", "resolved" => true} = pair] =
               selectors["route_stops"]

      assert pair["route_gtfs_id"] == @uuid_like
      assert pair["stop_gtfs_id"] == "STOP-A"

      assert [first, second] = selectors["trips"]
      assert {first["id"], first["gtfs_id"], first["start_time"]} == {"T-100", "T-100", nil}

      assert {second["id"], second["gtfs_id"], second["start_time"]} ==
               {"T-100", "T-100", "25:15:00"}

      assert first["service_date"] == "2026-10-05" and second["service_date"] == "2026-10-05"

      # The agency entry and every server-owned column are untouched; only the
      # digest of the old UUID answer is gone.
      assert selectors["agencies"] == legacy_capture(own)["selectors"]["agencies"]
      assert after_up.reference["timezone"] == "America/New_York"
      refute Map.has_key?(after_up.reference, "scope_digest")

      assert Map.take(after_up, [:revision, :updated_at, :message, :source]) ==
               Map.take(before, [:revision, :updated_at, :message, :source])

      assert alert_row(prefix, system).scope == %{"shape" => "system", "route_ids" => []}
      assert alert_row(prefix, system).reference["scope_digest"] == "keep"

      converted = alert_row(prefix, captured_only)
      assert converted.scope["stop_ids"] == ["STOP-GONE"]

      assert [%{"id" => "STOP-GONE", "gtfs_id" => "STOP-GONE"}] =
               converted.reference["selectors"]["stops"]

      assert snapshots(prefix, publication) == snapshots_before
    end

    test "refuses an unresolved reference and converts nothing", context do
      %{prefix: prefix, org: org, version: version, ids: %{own: own, sibling: sibling}} = context

      healthy = insert_alert(prefix, org, version, legacy_scope(own), legacy_capture(own))
      healthy_before = alert_row(prefix, healthy)

      # An unknown UUID and a UUID that belongs to a sibling version's route are
      # equally unresolved inside this alert's own version.
      unknown = Ecto.UUID.generate()

      broken =
        insert_alert(
          prefix,
          org,
          version,
          %{"shape" => "routes", "route_ids" => [unknown, sibling.route_12]},
          %{}
        )

      error =
        assert_raise Ecto.MigrationError, ~r/could not be converted to GTFS IDs/, fn ->
          run(:up, prefix)
        end

      assert error.message =~ "service_alerts id=#{broken}"
      assert error.message =~ "organization_id=#{org}"
      assert error.message =~ "field=scope.route_ids value=\"#{unknown}\" reason=unresolved"
      assert error.message =~ "value=\"#{sibling.route_12}\" reason=unresolved"
      refute error.message =~ healthy

      assert alert_row(prefix, healthy) == healthy_before
      assert alert_row(prefix, broken).scope["route_ids"] == [unknown, sibling.route_12]
    end

    test "refuses a capture that disagrees with the row it names", context do
      %{prefix: prefix, org: org, version: version, ids: %{own: own}} = context

      healthy = insert_alert(prefix, org, version, legacy_scope(own), legacy_capture(own))
      healthy_before = alert_row(prefix, healthy)

      # The capture says this route is feed ID "99", but its row is "12".
      contradictory =
        insert_alert(
          prefix,
          org,
          version,
          %{"shape" => "routes", "route_ids" => [own.route_12]},
          %{
            "selectors" => %{
              "routes" => [%{"id" => own.route_12, "gtfs_id" => "99", "label" => "99"}]
            }
          }
        )

      error =
        assert_raise Ecto.MigrationError, ~r/could not be converted to GTFS IDs/, fn ->
          run(:up, prefix)
        end

      assert error.message =~ "service_alerts id=#{contradictory}"

      assert error.message =~
               "field=scope.route_ids value=\"#{own.route_12}\" reason=contradictory"

      assert alert_row(prefix, healthy) == healthy_before
    end
  end

  describe "down/0" do
    test "restores the row UUIDs of the alert's own scope", context do
      %{prefix: prefix, org: org, version: version, ids: %{own: own}} = context

      legacy = insert_alert(prefix, org, version, legacy_scope(own), legacy_capture(own))

      run(:up, prefix)
      run(:down, prefix)

      restored = alert_row(prefix, legacy)

      assert restored.scope["route_ids"] == [own.route_main, own.route_12]
      assert restored.scope["stop_ids"] == [own.stop_a]
      assert restored.scope["stretch_to_stop_id"] == own.stop_c
      assert Enum.map(restored.scope["trips"], & &1["trip_id"]) == [own.trip, own.trip]
      assert hd(restored.reference["selectors"]["routes"])["id"] == own.route_main
      assert hd(restored.reference["selectors"]["trips"])["id"] == own.trip
    end

    test "refuses when a scoped row is missing", context do
      %{prefix: prefix, org: org, version: version, ids: %{own: own}} = context

      legacy = insert_alert(prefix, org, version, legacy_scope(own), legacy_capture(own))

      run(:up, prefix)

      SQL.query!(Repo, "DELETE FROM #{q(prefix)}.stops WHERE id = '#{own.stop_c}'", [])

      error =
        assert_raise Ecto.MigrationError, ~r/cannot be restored to row UUIDs/, fn ->
          run(:down, prefix)
        end

      assert error.message =~ "service_alerts id=#{legacy}"
      assert error.message =~ "field=scope.stretch_to_stop_id value=\"STOP-C\""
      assert alert_row(prefix, legacy).scope["route_ids"] == [@uuid_like, "12"]
    end
  end

  defp run(direction, prefix) do
    apply(Migrator, direction, [Repo, @migration_version, Migration, [prefix: prefix, log: false]])
  end

  # An alert as the application wrote it before the conversion: row UUIDs in the
  # scope answer (one in upper case) and in the captured entries.
  defp legacy_scope(ids) do
    %{
      "shape" => "route_stops",
      "mode_route_type" => nil,
      "direction_id" => 0,
      "route_ids" => [String.upcase(ids.route_main), ids.route_12],
      "stop_ids" => [ids.stop_a],
      "route_stop_pairs" => [%{"route_id" => ids.route_main, "stop_id" => ids.stop_a}],
      "trips" => [
        %{"trip_id" => ids.trip, "service_date" => "2026-10-05", "start_time" => nil},
        %{"trip_id" => ids.trip, "service_date" => "2026-10-05", "start_time" => "25:15:00"}
      ],
      "stretch_from_stop_id" => ids.stop_b,
      "stretch_to_stop_id" => ids.stop_c,
      "alternative_stop_id" => nil,
      "alternative_directions" => nil
    }
  end

  defp legacy_capture(ids) do
    %{
      "source_gtfs_version_id" => nil,
      "scope_digest" => "digest-of-the-old-uuid-answer",
      "timezone" => "America/New_York",
      "selectors" => %{
        "shape" => "route_stops",
        "routes" => [
          %{"id" => ids.route_main, "gtfs_id" => @uuid_like, "label" => "Main"},
          %{"id" => ids.route_12, "gtfs_id" => "12", "label" => "12"}
        ],
        "unresolved_routes" => [],
        "stops" => [%{"id" => ids.stop_a, "gtfs_id" => "STOP-A", "label" => "A"}],
        "unresolved_stops" => [],
        "route_stops" => [
          %{
            "route_id" => ids.route_main,
            "route_gtfs_id" => @uuid_like,
            "route_label" => "Main",
            "stop_id" => ids.stop_a,
            "stop_gtfs_id" => "STOP-A",
            "stop_label" => "A",
            "resolved" => true
          }
        ],
        "trips" => [
          %{
            "id" => ids.trip,
            "gtfs_id" => "T-100",
            "service_id" => "WK",
            "service_date" => "2026-10-05",
            "start_time" => nil,
            "label" => "T-100",
            "resolved" => true
          },
          %{
            "id" => ids.trip,
            "gtfs_id" => "T-100",
            "service_id" => "WK",
            "service_date" => "2026-10-05",
            "start_time" => "25:15:00",
            "label" => "T-100",
            "resolved" => true
          }
        ],
        "agencies" => [
          %{"id" => "0c6d2f5e-8f45-4d83-8f4a-1b2a3c4d5e6f", "gtfs_id" => "nyc", "label" => "NYC"}
        ]
      }
    }
  end

  defp q(prefix), do: ~s|"#{prefix}"|

  defp alert_row(prefix, id) do
    %{rows: [[scope, reference, revision, updated_at, message, source]]} =
      SQL.query!(
        Repo,
        """
        SELECT scope, target_reference, revision, updated_at::text, message,
               source_gtfs_version_id::text
        FROM #{q(prefix)}.service_alerts WHERE id = '#{id}'
        """,
        []
      )

    %{
      scope: scope,
      reference: reference,
      revision: revision,
      updated_at: updated_at,
      message: message,
      source: source
    }
  end

  defp snapshots(prefix, id) do
    %{rows: [row]} =
      SQL.query!(
        Repo,
        """
        SELECT desired_snapshot::text, confirmed_snapshot::text
        FROM #{q(prefix)}.alert_publications WHERE id = '#{id}'
        """,
        []
      )

    row
  end

  # The pre-conversion schema, reduced to the columns the migration reads or the
  # conversion must leave alone.
  defp setup_prefix do
    prefix = "test_convert_alert_targets_#{System.unique_integer([:positive])}"
    SQL.query!(Repo, ~s|CREATE SCHEMA "#{prefix}"|, [])

    on_exit(fn -> SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, []) end)

    for {table, column} <- [routes: "route_id", stops: "stop_id", trips: "trip_id"] do
      SQL.query!(
        Repo,
        """
        CREATE TABLE #{q(prefix)}.#{table} (
          id uuid PRIMARY KEY,
          organization_id uuid NOT NULL,
          gtfs_version_id uuid NOT NULL,
          #{column} varchar(255) NOT NULL
        )
        """,
        []
      )
    end

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.service_alerts (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL,
        source_gtfs_version_id uuid,
        revision integer NOT NULL DEFAULT 1,
        scope jsonb NOT NULL DEFAULT '{}',
        target_reference jsonb NOT NULL DEFAULT '{}',
        message jsonb NOT NULL DEFAULT '{}',
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE #{q(prefix)}.alert_publications (
        id uuid PRIMARY KEY,
        alert_id uuid NOT NULL,
        organization_id uuid NOT NULL,
        desired_snapshot jsonb,
        confirmed_snapshot jsonb
      )
      """,
      []
    )

    prefix
  end

  defp insert_row(prefix, table, column, org, version, feed_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.#{table} (id, organization_id, gtfs_version_id, #{column})
      VALUES ('#{id}'::uuid, '#{org}'::uuid, '#{version}'::uuid, $1)
      """,
      [feed_id]
    )

    id
  end

  defp insert_alert(prefix, org, version, scope, reference) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.service_alerts
        (id, organization_id, source_gtfs_version_id, revision, scope, target_reference,
         message, updated_at)
      VALUES ('#{id}'::uuid, '#{org}'::uuid, #{version_sql(version)}, 7, $1::jsonb, $2::jsonb,
              '{"header":"Route 12 detour"}'::jsonb, '2026-10-03 12:34:56.789012')
      """,
      [scope, reference]
    )

    id
  end

  defp version_sql(nil), do: "NULL"
  defp version_sql(version), do: "'#{version}'::uuid"

  # Accepted public intent already holds feed IDs, so the conversion must not
  # touch these bytes.
  defp insert_publication(prefix, alert, org) do
    id = Ecto.UUID.generate()

    snapshot = fn revision ->
      %{
        "public_entity_id" => Ecto.UUID.generate(),
        "accepted_revision" => revision,
        "scope" => %{
          "shape" => "trips",
          "routes" => [@uuid_like],
          "trips" => [
            %{"trip_id" => "T-100", "start_date" => "2026-10-05", "start_time" => "25:15:00"}
          ]
        }
      }
    end

    SQL.query!(
      Repo,
      """
      INSERT INTO #{q(prefix)}.alert_publications
        (id, alert_id, organization_id, desired_snapshot, confirmed_snapshot)
      VALUES ('#{id}'::uuid, '#{alert}'::uuid, '#{org}'::uuid, $1::jsonb, $2::jsonb)
      """,
      [snapshot.(7), snapshot.(6)]
    )

    id
  end
end
