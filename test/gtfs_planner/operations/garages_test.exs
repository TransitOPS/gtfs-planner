defmodule GtfsPlanner.Operations.GaragesTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Garage

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "list_garages/1" do
    test "isolates organizations and orders by name" do
      organization = organization_fixture()
      other = organization_fixture()

      garage_fixture(organization.id, %{"name" => "Beta Depot"})
      garage_fixture(organization.id, %{"name" => "Alpha Yard"})
      garage_fixture(other.id, %{"name" => "Foreign Garage"})

      assert Enum.map(Operations.list_garages(organization.id), & &1.name) == [
               "Alpha Yard",
               "Beta Depot"
             ]

      assert Enum.map(Operations.list_garages(other.id), & &1.name) == ["Foreign Garage"]
    end

    test "exposes a zero vehicle_count before vehicles exist" do
      organization = organization_fixture()
      garage_fixture(organization.id)

      assert [%Garage{vehicle_count: 0}] = Operations.list_garages(organization.id)
    end
  end

  describe "get_garage/2" do
    test "returns the organization's garage" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)

      assert %Garage{id: id} = Operations.get_garage(organization.id, garage.id)
      assert id == garage.id
    end

    test "treats an unknown or malformed id as missing" do
      organization = organization_fixture()

      assert Operations.get_garage(organization.id, Ecto.UUID.generate()) == nil
      assert Operations.get_garage(organization.id, "not-a-uuid") == nil
    end

    test "returns nil for another organization's garage" do
      organization = organization_fixture()
      other = organization_fixture()
      garage = garage_fixture(other.id)

      assert Operations.get_garage(organization.id, garage.id) == nil
    end
  end

  describe "create_garage/3" do
    test "persists only the caller's organization and records the acting user" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor(organization.id)

      attrs =
        Map.merge(valid_garage_attrs(), %{
          "organization_id" => other.id,
          "updated_by_id" => Ecto.UUID.generate()
        })

      assert {:ok, garage} = Operations.create_garage(organization.id, actor, attrs)
      assert garage.organization_id == organization.id
      assert garage.updated_by_id == actor.id
      assert garage.name == attrs["name"]
      assert garage.garage_id == attrs["garage_id"]

      assert Repo.get(Garage, garage.id).organization_id == organization.id
      assert Operations.list_garages(other.id) == []
    end

    test "records the acting user even when params omit actor fields" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)

      assert {:ok, garage} =
               Operations.create_garage(organization.id, actor, valid_garage_attrs())

      assert garage.updated_by_id == actor.id
    end

    test "requires a name, garage_id, latitude and longitude" do
      organization = organization_fixture()

      assert {:error, changeset} =
               Operations.create_garage(organization.id, operations_actor(organization.id), %{})

      errors = errors_on(changeset)
      assert errors.name
      assert errors.garage_id
      assert errors.lat
      assert errors.lon
    end

    test "rejects a garage_id outside the allowed character set" do
      organization = organization_fixture()

      assert {:error, changeset} =
               Operations.create_garage(
                 organization.id,
                 operations_actor(organization.id),
                 valid_garage_attrs(%{"garage_id" => "bad id!"})
               )

      assert %{garage_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects out-of-range coordinates" do
      organization = organization_fixture()

      assert {:error, lat_changeset} =
               Operations.create_garage(
                 organization.id,
                 operations_actor(organization.id),
                 valid_garage_attrs(%{"lat" => "91"})
               )

      assert %{lat: [_ | _]} = errors_on(lat_changeset)

      assert {:error, lon_changeset} =
               Operations.create_garage(
                 organization.id,
                 operations_actor(organization.id),
                 valid_garage_attrs(%{"lon" => "-181"})
               )

      assert %{lon: [_ | _]} = errors_on(lon_changeset)
    end

    test "a duplicate garage_id returns a changeset error from the unique index" do
      organization = organization_fixture()
      existing = garage_fixture(organization.id, %{"garage_id" => "garage_shared"})

      assert {:error, changeset} =
               Operations.create_garage(
                 organization.id,
                 operations_actor(organization.id),
                 valid_garage_attrs(%{"garage_id" => "garage_shared"})
               )

      assert %{garage_id: [_ | _]} = errors_on(changeset)
      assert [%Garage{id: id}] = Operations.list_garages(organization.id)
      assert id == existing.id
    end

    test "allows the same garage_id in a different organization" do
      organization = organization_fixture()
      other = organization_fixture()

      garage_fixture(organization.id, %{"garage_id" => "garage_shared"})

      assert {:ok, garage} =
               Operations.create_garage(
                 other.id,
                 operations_actor(other.id),
                 valid_garage_attrs(%{"garage_id" => "garage_shared"})
               )

      assert garage.organization_id == other.id
    end
  end

  describe "update_garage/4" do
    test "renaming keeps the garage ID and UUID" do
      organization = organization_fixture()
      actor = operations_actor(organization.id)
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main"})

      assert {:ok, updated} =
               Operations.update_garage(organization.id, actor, garage.id, %{
                 "name" => "Main Depot"
               })

      assert updated.id == garage.id
      assert updated.garage_id == "garage_main"
      assert updated.name == "Main Depot"
      assert updated.updated_by_id == actor.id
    end

    test "changing the garage ID keeps the UUID" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main"})

      assert {:ok, updated} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 garage.id,
                 %{"garage_id" => "garage_depot"}
               )

      assert updated.id == garage.id
      assert updated.garage_id == "garage_depot"
      assert Repo.get(Garage, garage.id).garage_id == "garage_depot"
    end

    test "refuses an ID already used in the organization and changes nothing" do
      organization = organization_fixture()
      garage_fixture(organization.id, %{"garage_id" => "garage_first"})
      second = garage_fixture(organization.id, %{"garage_id" => "garage_second"})

      assert {:error, changeset} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 second.id,
                 %{"garage_id" => "garage_first"}
               )

      assert %{garage_id: [_ | _]} = errors_on(changeset)
      assert Repo.get(Garage, second.id).garage_id == "garage_second"
    end

    test "a foreign, unknown or malformed garage is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = garage_fixture(other.id, %{"name" => "Foreign Garage"})

      assert {:error, :not_found} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 foreign.id,
                 %{
                   "name" => "Hijacked"
                 }
               )

      assert Repo.get(Garage, foreign.id).name == "Foreign Garage"

      assert {:error, :not_found} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 Ecto.UUID.generate(),
                 %{
                   "name" => "Missing"
                 }
               )

      assert {:error, :not_found} =
               Operations.update_garage(
                 organization.id,
                 operations_actor(organization.id),
                 "not-a-uuid",
                 %{
                   "name" => "Missing"
                 }
               )
    end

    test "params cannot set organization_id or updated_by_id" do
      organization = organization_fixture()
      other = organization_fixture()
      actor = operations_actor(organization.id)
      garage = garage_fixture(organization.id)

      assert {:ok, updated} =
               Operations.update_garage(organization.id, actor, garage.id, %{
                 "name" => "Renamed",
                 "organization_id" => other.id,
                 "updated_by_id" => Ecto.UUID.generate()
               })

      assert updated.organization_id == organization.id
      assert updated.updated_by_id == actor.id
    end
  end

  describe "delete_garage/3" do
    test "deletes a garage in the organization" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)

      assert {:ok, %Garage{id: id}} =
               Operations.delete_garage(
                 organization.id,
                 operations_actor(organization.id),
                 garage.id
               )

      assert id == garage.id
      assert Repo.get(Garage, garage.id) == nil
    end

    test "a foreign, unknown or malformed garage is not found and changes nothing" do
      organization = organization_fixture()
      other = organization_fixture()
      foreign = garage_fixture(other.id)

      assert {:error, :not_found} =
               Operations.delete_garage(
                 organization.id,
                 operations_actor(organization.id),
                 foreign.id
               )

      assert Repo.get(Garage, foreign.id)

      assert {:error, :not_found} =
               Operations.delete_garage(
                 organization.id,
                 operations_actor(organization.id),
                 Ecto.UUID.generate()
               )

      assert {:error, :not_found} =
               Operations.delete_garage(
                 organization.id,
                 operations_actor(organization.id),
                 "not-a-uuid"
               )
    end
  end

  describe "change_garage/2" do
    test "returns a changeset that ignores tenant and actor params" do
      organization = organization_fixture()
      other = organization_fixture()
      garage = garage_fixture(organization.id)

      changeset =
        Operations.change_garage(garage, %{
          "name" => "Renamed",
          "organization_id" => other.id,
          "updated_by_id" => Ecto.UUID.generate()
        })

      assert changeset.changes.name == "Renamed"
      refute Map.has_key?(changeset.changes, :organization_id)
      refute Map.has_key?(changeset.changes, :updated_by_id)
    end
  end

  describe "default_garage_id/1" do
    test "slugs a name and prefixes it with garage_" do
      assert Operations.default_garage_id("Main Garage") == "garage_main_garage"
      assert Operations.default_garage_id("  East   Depot  ") == "garage_east_depot"
    end

    test "returns an empty string for a blank or missing name" do
      assert Operations.default_garage_id("") == ""
      assert Operations.default_garage_id("   ") == ""
      assert Operations.default_garage_id(nil) == ""
    end
  end

  describe "garage_stop_id_conflicts/3" do
    test "returns exact, case-sensitive matches with the stop name" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      matching = garage_fixture(organization.id, %{"garage_id" => "garage_main"})
      different_case = garage_fixture(organization.id, %{"garage_id" => "garage_East"})
      unrelated = garage_fixture(organization.id, %{"garage_id" => "garage_west"})

      stop_fixture(organization.id, version.id, %{
        stop_id: "garage_main",
        stop_name: "Main Garage Stop"
      })

      stop_fixture(organization.id, version.id, %{stop_id: "garage_east", stop_name: "East Stop"})

      assert Operations.garage_stop_id_conflicts(organization.id, version.id, [
               different_case,
               unrelated,
               matching
             ]) == [
               %{
                 garage_id: "garage_main",
                 garage_name: matching.name,
                 stop_name: "Main Garage Stop"
               }
             ]
    end

    test "orders conflicts by garage ID" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      beta = garage_fixture(organization.id, %{"garage_id" => "garage_b"})
      alpha = garage_fixture(organization.id, %{"garage_id" => "garage_a"})

      stop_fixture(organization.id, version.id, %{stop_id: "garage_b", stop_name: "B"})
      stop_fixture(organization.id, version.id, %{stop_id: "garage_a", stop_name: "A"})

      assert Enum.map(
               Operations.garage_stop_id_conflicts(organization.id, version.id, [beta, alpha]),
               & &1.garage_id
             ) == ["garage_a", "garage_b"]
    end

    test "ignores other versions and other organizations" do
      organization = organization_fixture()
      other = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      sibling_version = gtfs_version_fixture(organization.id)
      foreign_version = gtfs_version_fixture(other.id)

      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main"})
      foreign_garage = garage_fixture(other.id, %{"garage_id" => "garage_foreign"})

      stop_fixture(organization.id, sibling_version.id, %{
        stop_id: "garage_main",
        stop_name: "Other Version"
      })

      stop_fixture(other.id, foreign_version.id, %{
        stop_id: "garage_foreign",
        stop_name: "Other Organization"
      })

      assert Operations.garage_stop_id_conflicts(organization.id, version.id, [garage]) == []

      assert Operations.garage_stop_id_conflicts(organization.id, version.id, [foreign_garage]) ==
               []
    end

    test "returns no conflicts for an empty list or a malformed version" do
      organization = organization_fixture()
      garage = garage_fixture(organization.id)

      assert Operations.garage_stop_id_conflicts(organization.id, Ecto.UUID.generate(), []) == []

      assert Operations.garage_stop_id_conflicts(organization.id, "not-a-uuid", [garage]) == []
    end
  end

  defp valid_garage_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "garage_id" => "garage_#{System.unique_integer([:positive])}",
      "name" => "Garage #{System.unique_integer([:positive])}",
      "address" => nil,
      "lat" => "40.7128",
      "lon" => "-74.0060"
    })
  end
end

defmodule GtfsPlanner.Operations.GaragesMigrationTest do
  # The garages migration is exercised against real DDL in a unique disposable
  # PostgreSQL schema dropped on exit, so no retained development database is
  # ever rolled back.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../priv/repo/migrations/*_create_garages.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one create_garages migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreateGarages, as: Migration

  @now ~U[2026-09-27 00:00:00.000000Z]

  describe "create_garages migration" do
    test "up, down and up again touches only the garages table and preserves unrelated rows" do
      schema = setup_prefix()
      _organization_id = insert_organization(schema, "Retained Org")

      assert organization_names(schema) == ["Retained Org"]

      migrate_up(schema)
      assert table_exists?(schema, "garages")
      assert "garages_organization_id_garage_id_index" in index_names(schema, "garages")
      assert organization_names(schema) == ["Retained Org"]

      migrate_down(schema)
      refute table_exists?(schema, "garages")
      assert organization_names(schema) == ["Retained Org"]

      migrate_up(schema)
      assert table_exists?(schema, "garages")
      assert organization_names(schema) == ["Retained Org"]
    end

    test "enforces the (organization_id, garage_id) unique index" do
      schema = setup_prefix()
      organization_id = insert_organization(schema, "Org")
      migrate_up(schema)

      assert :ok = insert_garage(schema, organization_id, "garage_shared")

      assert_raise Postgrex.Error, fn ->
        insert_garage(schema, organization_id, "garage_shared")
      end

      other_organization_id = insert_organization(schema, "Other Org")
      assert :ok = insert_garage(schema, other_organization_id, "garage_shared")
    end
  end

  defp setup_prefix do
    schema = "test_garages_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY,
        name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(),
        updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    schema
  end

  defp insert_organization(schema, name) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [Ecto.UUID.dump!(id), name]
    )

    id
  end

  defp insert_garage(schema, organization_id, garage_id) do
    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".garages
        (id, organization_id, garage_id, name, lat, lon, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 40.0, -74.0, $5, $5)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(organization_id),
        garage_id,
        "Garage",
        @now
      ]
    )

    :ok
  end

  defp organization_names(schema) do
    %{rows: rows} =
      SQL.query!(Repo, ~s|SELECT name FROM "#{schema}".organizations ORDER BY name|, [])

    List.flatten(rows)
  end

  defp table_exists?(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = $1 AND table_name = $2
        """,
        [schema, table]
      )

    rows != []
  end

  defp index_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes
        WHERE schemaname = $1 AND tablename = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp migrate_up(schema) do
    Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)
  end

  defp migrate_down(schema) do
    Ecto.Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)
  end
end
