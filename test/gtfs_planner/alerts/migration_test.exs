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
