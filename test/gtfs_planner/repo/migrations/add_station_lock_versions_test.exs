defmodule GtfsPlanner.Repo.Migrations.AddStationLockVersionsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop, StopLevel}

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    %{organization: organization, version: version}
  end

  test "a direct insert uses revision one and Ecto returns the trigger's new revision", context do
    stop_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(Stop, [
               %{
                 id: stop_id,
                 stop_id: "revision-stop",
                 stop_name: "Original",
                 organization_id: context.organization.id,
                 gtfs_version_id: context.version.id,
                 inserted_at: now,
                 updated_at: now
               }
             ])

    stop = Repo.get!(Stop, stop_id)
    assert stop.lock_version == 1

    assert {:ok, updated} =
             stop
             |> Stop.changeset(%{stop_name: "Changed"})
             |> Repo.update()

    assert updated.lock_version == 2
    assert Repo.get!(Stop, stop_id).lock_version == 2
  end

  test "bulk updates increment every pathway once", context do
    from_stop = stop_fixture(context.organization.id, context.version.id)
    to_stop = stop_fixture(context.organization.id, context.version.id)

    pathways =
      for _ <- 1..3 do
        pathway_fixture(
          context.organization.id,
          context.version.id,
          from_stop.stop_id,
          to_stop.stop_id
        )
      end

    ids = Enum.map(pathways, & &1.id)
    assert Enum.all?(pathways, &(&1.lock_version == 1))

    assert {3, nil} =
             Pathway
             |> where([pathway], pathway.id in ^ids)
             |> Repo.update_all(set: [traversal_time: 90])

    assert Pathway
           |> where([pathway], pathway.id in ^ids)
           |> Repo.all()
           |> Enum.map(& &1.lock_version)
           |> Enum.sort() == [2, 2, 2]
  end

  test "raw SQL increments a stop level revision", context do
    stop = stop_fixture(context.organization.id, context.version.id, %{location_type: 1})
    level = level_fixture(context.organization.id, context.version.id)
    stop_level_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(StopLevel, [
               %{
                 id: stop_level_id,
                 stop_id: stop.stop_id,
                 level_id: level.level_id,
                 organization_id: context.organization.id,
                 gtfs_version_id: context.version.id,
                 inserted_at: now,
                 updated_at: now
               }
             ])

    assert Repo.get!(StopLevel, stop_level_id).lock_version == 1

    assert %{num_rows: 1} =
             Repo.query!("UPDATE stop_levels SET diagram_filename = $1 WHERE id = $2", [
               "diagram.png",
               Ecto.UUID.dump!(stop_level_id)
             ])

    assert %{lock_version: 2, diagram_filename: "diagram.png"} =
             Repo.get!(StopLevel, stop_level_id)
  end

  test "explicit revision assignment cannot bypass the trigger", context do
    level = level_fixture(context.organization.id, context.version.id)
    assert level.lock_version == 1

    assert %{num_rows: 1} =
             Repo.query!("UPDATE levels SET lock_version = 99 WHERE id = $1", [
               Ecto.UUID.dump!(level.id)
             ])

    assert Repo.get!(Level, level.id).lock_version == 2
  end

  test "the database rejects revision zero on insert", context do
    id = Ecto.UUID.generate()

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO levels
              (id, level_id, level_index, organization_id, gtfs_version_id,
               lock_version, inserted_at, updated_at)
            VALUES ($1, 'invalid-revision', 0, $2, $3, 0, now(), now())
            """,
            [
              Ecto.UUID.dump!(id),
              Ecto.UUID.dump!(context.organization.id),
              Ecto.UUID.dump!(context.version.id)
            ]
          )
        end)
      end

    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == "levels_lock_version_check"
    assert is_nil(Repo.get(Level, id))
  end

  test "station changesets ignore submitted revisions" do
    for schema <- [Stop, Level, Pathway, StopLevel] do
      changeset = schema.changeset(struct(schema), %{lock_version: 99})
      assert is_nil(Ecto.Changeset.get_change(changeset, :lock_version))
      assert Ecto.Changeset.get_field(changeset, :lock_version) == 1
    end
  end
end
