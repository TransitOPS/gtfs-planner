defmodule GtfsPlanner.Repo.Migrations.AddStationLockVersions do
  use Ecto.Migration

  @tables ~w(stops levels pathways stop_levels)a
  @trigger "gtfs_bump_lock_version_trigger"

  def up do
    for table_name <- @tables do
      alter table(table_name, prefix: prefix()) do
        add :lock_version, :integer, null: false, default: 1
      end

      create constraint(table_name, "#{table_name}_lock_version_check",
               check: "lock_version >= 1",
               prefix: prefix()
             )
    end

    execute("""
    CREATE FUNCTION #{qualified_function()}() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.lock_version := OLD.lock_version + 1;
      RETURN NEW;
    END;
    $$
    """)

    for table_name <- @tables do
      execute("""
      CREATE TRIGGER #{@trigger}
      BEFORE UPDATE ON #{qualified_table(table_name)}
      FOR EACH ROW EXECUTE FUNCTION #{qualified_function()}()
      """)
    end
  end

  def down do
    for table_name <- @tables do
      execute("DROP TRIGGER #{@trigger} ON #{qualified_table(table_name)}")
    end

    execute("DROP FUNCTION #{qualified_function()}()")

    for table_name <- @tables do
      drop constraint(table_name, "#{table_name}_lock_version_check", prefix: prefix())

      alter table(table_name, prefix: prefix()) do
        remove :lock_version
      end
    end
  end

  defp qualified_table(table_name) do
    case prefix() do
      nil -> Atom.to_string(table_name)
      schema -> ~s("#{schema}".#{table_name})
    end
  end

  defp qualified_function do
    case prefix() do
      nil -> "gtfs_bump_lock_version"
      schema -> ~s("#{schema}".gtfs_bump_lock_version)
    end
  end
end
