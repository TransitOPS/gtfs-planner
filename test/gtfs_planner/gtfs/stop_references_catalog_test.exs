defmodule GtfsPlanner.Gtfs.StopReferencesCatalogTest do
  @moduledoc """
  The independent oracle for `StopReferences`: the expected column set comes from
  `information_schema`, not from the module.

  Two directions are checked. Every catalog column that matches the name rules or
  is a foreign key onto `stops.id` must appear in `StopReferences.all/0` or in
  `excluded/0` with a reason, so a new stop-referencing column cannot be added
  without being classified. And every `all/0` entry must name a column that really
  exists, so the list cannot drift into describing a table that is not there.
  """

  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Repo

  # A column could hold a stop reference by name if it is text-like or an array
  # and its name says so. A UUID column only counts when a real foreign key ties
  # it to stops.id, which the second query finds. `hub_stop_ids` is listed
  # explicitly because it holds stop IDs without the substring `stop_id`.
  @name_match_columns_sql """
  select table_name, column_name
  from information_schema.columns
  where table_schema = 'public'
    and (
      column_name like '%stop_id'
      or column_name in ('parent_station', 'from_ref', 'to_ref', 'record_id', 'hub_stop_ids')
    )
    and (
      data_type in ('character varying', 'text', 'ARRAY')
      or udt_name = '_varchar'
      or udt_name = '_text'
    )
  order by table_name, column_name
  """

  @foreign_key_columns_sql """
  select tc.table_name, kcu.column_name
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on tc.constraint_name = kcu.constraint_name
     and tc.constraint_schema = kcu.constraint_schema
  join information_schema.constraint_column_usage ccu
    on ccu.constraint_name = tc.constraint_name
     and ccu.constraint_schema = tc.constraint_schema
  where tc.constraint_type = 'FOREIGN KEY'
    and tc.table_schema = 'public'
    and ccu.table_schema = 'public'
    and ccu.table_name = 'stops'
    and ccu.column_name = 'id'
  order by 1, 2
  """

  defp pairs(sql) do
    {:ok, %{rows: rows}} = Repo.query(sql)
    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  defp name_matched, do: pairs(@name_match_columns_sql)
  defp foreign_keyed, do: pairs(@foreign_key_columns_sql)

  defp classified_pairs do
    StopReferences.all()
    |> Enum.map(&{&1.table, Atom.to_string(&1.column)})
    |> MapSet.new()
  end

  defp excluded_pairs do
    StopReferences.excluded()
    |> Enum.map(fn {table, column, _reason} -> {table, column} end)
    |> MapSet.new()
  end

  describe "completeness" do
    test "every name-matched catalog column is classified" do
      classified = classified_pairs()

      excluded = excluded_pairs()

      unclassified =
        name_matched()
        |> Enum.reject(fn pair ->
          MapSet.member?(classified, pair) or MapSet.member?(excluded, pair)
        end)

      assert unclassified == [],
             """
             These columns match the stop-reference name rules but appear in neither \
             StopReferences.all/0 nor StopReferences.excluded/0. Classify each one, or \
             add it to excluded/0 with the reason it is not a stop reference.

             #{inspect(unclassified)}
             """
    end

    test "every foreign key onto stops.id is classified" do
      classified = classified_pairs()

      excluded = excluded_pairs()

      unclassified =
        foreign_keyed()
        |> Enum.reject(fn pair ->
          MapSet.member?(classified, pair) or MapSet.member?(excluded, pair)
        end)

      assert unclassified == [],
             """
             These columns are foreign keys onto stops.id but appear in neither \
             StopReferences.all/0 nor StopReferences.excluded/0.

             #{inspect(unclassified)}
             """
    end

    test "every name-matched column is accounted for exactly once" do
      all = MapSet.new(Enum.map(StopReferences.all(), &{&1.table, Atom.to_string(&1.column)}))
      excluded = excluded_pairs()

      # `stops.stop_id` matches the name rule and is excluded. No other catalog
      # pair may be both listed and excluded.
      both = MapSet.intersection(all, excluded)

      assert MapSet.to_list(both) == [],
             "these pairs are both listed and excluded: #{inspect(MapSet.to_list(both))}"
    end
  end

  describe "soundness" do
    test "every all/0 entry names a column the catalog knows" do
      catalog = MapSet.new(name_matched() ++ foreign_keyed())

      unknown =
        StopReferences.all()
        |> Enum.reject(&MapSet.member?(catalog, {&1.table, Atom.to_string(&1.column)}))
        |> Enum.map(&{&1.table, Atom.to_string(&1.column)})

      assert unknown == [],
             """
             StopReferences.all/0 names columns the catalog does not report, either \
             because the column or the table does not exist, or because it is neither a \
             name match nor a foreign key onto stops.id.

             #{inspect(unknown)}
             """
    end

    test "every all/0 entry has a blocking or descriptive kind" do
      for ref <- StopReferences.all() do
        assert ref.kind in [:blocking, :descriptive],
               "#{ref.key} has kind #{inspect(ref.kind)}"
      end
    end

    test "every all/0 entry has a replace rule the replace command understands" do
      for ref <- StopReferences.all() do
        assert ref.replace in StopReferences.valid_replace_rules(),
               "#{ref.key} has replace rule #{inspect(ref.replace)}"
      end
    end

    test "every all/0 entry has a via the query builder understands" do
      for ref <- StopReferences.all() do
        assert ref.via in [:string, :array, :fk_uuid],
               "#{ref.key} has via #{inspect(ref.via)}"
      end
    end

    test "every key is unique, including across tables that share a schema" do
      keys = Enum.map(StopReferences.all(), & &1.key)

      duplicates = keys -- Enum.uniq(keys)

      assert duplicates == [], "duplicate keys: #{inspect(duplicates)}"
    end

    test "every entry names its own schema module and table" do
      for ref <- StopReferences.all() do
        assert is_atom(ref.schema), "#{ref.key} has no schema module"
        assert is_binary(ref.table), "#{ref.key} has no table name"
        assert is_atom(ref.column), "#{ref.key} has no column"
        assert is_binary(ref.label) and ref.label != "", "#{ref.key} has no label"
      end
    end

    test "fetch/1 finds every entry by key" do
      for ref <- StopReferences.all() do
        assert StopReferences.fetch(ref.key) == ref
      end

      assert StopReferences.fetch(:not_a_key) == nil
    end

    test "every all/0 entry with a collision key has one that is a real unique index" do
      for ref <- StopReferences.all(), ref.collision_key do
        # A table can carry several unique indexes — `relief_points` has both
        # its own and the primary key — so the entry must match *one* of them.
        # The index is written on the scope columns too; the entry carries only
        # what the scoped query does not already supply.
        scope = Enum.map([:organization_id, :gtfs_version_id], &Atom.to_string/1)

        matched =
          ref.table
          |> unique_indexes()
          |> Enum.any?(fn columns ->
            # `attname` comes back as text, so both sides are compared as
            # strings rather than converting a database value into an atom.
            Enum.sort(columns -- scope) ==
              Enum.sort(Enum.map(ref.collision_key, &Atom.to_string/1))
          end)

        assert matched,
               "#{ref.key} collision key #{inspect(ref.collision_key)} matches none of " <>
                 "#{ref.table}'s unique indexes #{inspect(unique_indexes(ref.table))}"
      end
    end

    test "every table that a rewrite can collide on declares a collision key" do
      # The other direction. A `:rewrite_keep_existing` or `:rekey_segments` ref
      # with no key would let `replace_stop/4` write straight into a unique
      # violation, so each one must either name its key or be genuinely unique.
      for ref <- StopReferences.all(),
          ref.replace in [:rewrite_keep_existing, :rekey_segments],
          ref.collision_key == nil do
        indexes = unique_indexes(ref.table)

        # A table whose only unique index is the primary key cannot collide on
        # a rewritten column; anything else has to declare one.
        assert indexes == [["id"]],
               "#{ref.key} can collide on #{ref.table} but declares no collision key"
      end
    end

    test "the schema module's table matches the entry's table" do
      for ref <- StopReferences.all() do
        assert ref.schema.__schema__(:source) == ref.table,
               "#{ref.key} names module #{inspect(ref.schema)} but table #{ref.table}"
      end
    end
  end

  describe "the fk_uuid entries" do
    test "are all blocking and refused by replace" do
      for ref <- StopReferences.all(), ref.via == :fk_uuid do
        assert ref.kind == :blocking, "#{ref.key} is a cascade row and must block a delete"
        assert ref.replace == :refuse, "#{ref.key} must refuse a replace"
      end
    end

    test "cover every real foreign key onto stops.id" do
      real = MapSet.new(foreign_keyed())

      covered =
        StopReferences.all()
        |> Enum.filter(&(&1.via == :fk_uuid))
        |> Enum.map(&{&1.table, Atom.to_string(&1.column)})
        |> MapSet.new()

      missing = real |> MapSet.difference(covered) |> MapSet.to_list()

      assert missing == [],
             "these foreign keys onto stops.id are not covered: #{inspect(missing)}"
    end

    test "a dormant ref names a column the schema still lacks" do
      # If `levels.parent_station_id` is ever added, this entry must move into
      # `all/0` so a delete refuses on it. This test is what says so.
      for ref <- StopReferences.dormant_refs() do
        pair = {ref.table, Atom.to_string(ref.column)}

        refute MapSet.member?(classified_pairs(), pair),
               "#{ref.key} is listed as dormant but is also in all/0"

        refute MapSet.member?(MapSet.new(name_matched() ++ foreign_keyed()), pair),
               """
               #{ref.table}.#{ref.column} now exists in the schema but its entry is still                dormant. Move it into StopReferences.all/0 so a delete refuses on it.
               """
      end
    end
  end

  describe "excluded/0" do
    test "each entry carries a reason" do
      for {table, column, reason} <- StopReferences.excluded() do
        assert is_binary(reason) and reason != "", "#{table}.#{column} has no reason"
      end
    end

    test "names only columns the catalog knows" do
      # `excluded/0` may name a column the name rules do not reach
      # (`change_logs.entity_external_id`), so this checks the column exists at all
      # rather than that the stop-reference query returned it.
      for {table, column, _reason} <- StopReferences.excluded() do
        {:ok, %{num_rows: count}} =
          Repo.query(
            "select count(*) from information_schema.columns " <>
              "where table_schema = 'public' and table_name = $1 and column_name = $2",
            [table, column]
          )

        assert count == 1, "excluded/0 names #{table}.#{column}, which does not exist"
      end
    end
  end

  # Each of a table's unique indexes, as a list of column names, read from the
  # live database rather than from the migrations — so a later migration that
  # changes an index is caught here instead of at a replace. Expression indexes
  # carry 0 in `indkey` and are dropped: no column name describes them.
  defp unique_indexes(table) do
    %{rows: rows} =
      Repo.query!(
        """
        select i.indexrelid::regclass::text, array_agg(a.attname order by a.attname)
        from pg_index i
        join pg_class c on c.oid = i.indrelid
        join pg_attribute a on a.attrelid = c.oid and a.attnum = any(i.indkey)
        where c.relname = $1 and i.indisunique
        group by i.indexrelid
        """,
        [table]
      )

    Enum.map(rows, fn [_name, columns] -> List.wrap(columns) end)
  end
end
