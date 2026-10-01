defmodule GtfsPlanner.Gtfs.Import.ZipExpansionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias GtfsPlanner.Gtfs.Import

  @stops "stop_id,stop_name\ncentral,Central\n"
  @levels "level_id,level_index\nL1,0.0\n"

  setup do
    base = Path.join(System.tmp_dir!(), "zip-expansion-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    uploads = Path.join(base, "uploads")
    File.mkdir_p!(uploads)

    %{base: base, uploads: uploads, dir: Path.join([base, "run", "expanded"])}
  end

  describe "expand_archive/3" do
    test "extracts a feed archive into the directory and describes each member", context do
      archive =
        stage(context, [
          {~c"stops.txt", @stops},
          {~c"feed/levels.txt", @levels}
        ])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert warnings == []

      assert Enum.sort_by(members, & &1.filename) == [
               %{filename: "feed/levels.txt", path: Path.join(context.dir, "feed/levels.txt")},
               %{filename: "stops.txt", path: Path.join(context.dir, "stops.txt")}
             ]

      assert Map.new(members, &{&1.filename, File.read!(&1.path)}) == %{
               "feed/levels.txt" => @levels,
               "stops.txt" => @stops
             }
    end

    test "returns paths, never file contents", context do
      archive = stage(context, [{~c"stops.txt", @stops}])

      {members, _warnings} = Import.expand_archive(archive, context.dir, limits())

      assert members |> Enum.map(&Map.keys/1) |> Enum.uniq() == [[:filename, :path]]
    end

    test "skips hidden and system entries without a warning", context do
      archive =
        stage(context, [
          {~c"stops.txt", @stops},
          {~c"__MACOSX/._stops.txt", "junk"},
          {~c".DS_Store", "junk"}
        ])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert warnings == []
      assert Enum.map(members, & &1.filename) == ["stops.txt"]
      assert files_under(context.dir) == ["stops.txt"]
    end

    test "warns about a member that climbs out of the directory and extracts the others",
         context do
      archive = stage(context, [{~c"../evil.txt", "evil"}, {~c"stops.txt", @stops}])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert warnings == [
               %{
                 filename: "feed.zip",
                 reason: :unsafe_member_path,
                 detail: ~s(unsafe member path rejected: "../evil.txt")
               }
             ]

      assert Enum.map(members, & &1.filename) == ["stops.txt"]
      assert files_under(context.dir) == ["stops.txt"]
      assert Path.wildcard(Path.join(context.base, "**/evil.txt")) == []
    end

    test "warns about a deeply nested climbing member", context do
      archive = stage(context, [{~c"a/b/../../../evil.txt", "evil"}, {~c"stops.txt", @stops}])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert [%{reason: :unsafe_member_path}] = warnings
      assert Enum.map(members, & &1.filename) == ["stops.txt"]
      assert Path.wildcard(Path.join(context.base, "**/evil.txt")) == []
    end

    test "warns about an absolute member and extracts the others", context do
      # :zip.create/3 strips a leading slash, so the member is written under a
      # placeholder name and renamed in the local and central headers.
      binary =
        [{~c"Xabs.txt", "abs"}, {~c"stops.txt", @stops}]
        |> zip_binary()
        |> :binary.replace("Xabs.txt", "/abs.txt", [:global])

      archive = stage_binary(context, binary)

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert warnings == [
               %{
                 filename: "feed.zip",
                 reason: :unsafe_member_path,
                 detail: ~s(unsafe member path rejected: "/abs.txt")
               }
             ]

      assert Enum.map(members, & &1.filename) == ["stops.txt"]
      assert files_under(context.dir) == ["stops.txt"]
      assert Path.wildcard(Path.join(context.base, "**/abs.txt")) == []
    end

    test "warns about a nested archive and does not extract it", context do
      archive = stage(context, [{~c"stops.txt", @stops}, {~c"nested.zip", "nested"}])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert warnings == [
               %{
                 filename: "feed.zip",
                 reason: :nested_archive,
                 detail: "nested archive rejected: nested.zip"
               }
             ]

      assert Enum.map(members, & &1.filename) == ["stops.txt"]
      assert files_under(context.dir) == ["stops.txt"]
    end

    test "rejects an archive whose declared member size is over the per-entry limit before extracting",
         context do
      File.mkdir_p!(context.dir)
      archive = stage(context, [{~c"stops.txt", String.duplicate("a", 20)}])

      {members, warnings} =
        Import.expand_archive(archive, context.dir, limits(max_entry_bytes: 10))

      assert members == []
      assert [%{filename: "feed.zip", reason: :archive_too_large, detail: detail}] = warnings
      assert detail =~ "entry_too_large"
      assert File.ls!(context.dir) == []
    end

    test "rejects an archive whose declared total size is over the limit before extracting",
         context do
      File.mkdir_p!(context.dir)
      archive = stage(context, [{~c"stops.txt", "aaaaaa"}, {~c"routes.txt", "bbbbbb"}])

      {members, warnings} =
        Import.expand_archive(archive, context.dir, limits(max_total_bytes: 10))

      assert members == []
      assert [%{reason: :archive_too_large, detail: detail}] = warnings
      assert detail =~ "total_too_large"
      assert File.ls!(context.dir) == []
    end

    test "rejects an archive with more than 10,000 entries before extracting", context do
      File.mkdir_p!(context.dir)
      entries = Enum.map(1..10_001, fn index -> {~c"f#{index}.txt", "x"} end)
      archive = stage(context, entries)

      {members, warnings} = Import.expand_archive(archive, context.dir, Import.zip_limits())

      assert Import.zip_limits().max_entries == 10_000
      assert members == []
      assert [%{reason: :archive_too_large, detail: detail}] = warnings
      assert detail =~ "too_many_entries"
      assert File.ls!(context.dir) == []
    end

    test "counts ignored and rejected members toward the entry limit", context do
      File.mkdir_p!(context.dir)

      archive =
        stage(context, [
          {~c"stops.txt", @stops},
          {~c"__MACOSX/._stops.txt", "junk"},
          {~c"../evil.txt", "evil"}
        ])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits(max_entries: 2))

      assert members == []

      assert [
               %{reason: :unsafe_member_path},
               %{reason: :archive_too_large, detail: detail}
             ] = warnings

      assert detail =~ "too_many_entries"
      assert File.ls!(context.dir) == []
    end

    test "removes the directory when an extracted file is bigger than its header declared",
         context do
      binary =
        zip_binary([{~c"stops.txt", String.duplicate("a", 20)}])
        |> patch_declared_size(1)

      archive = stage_binary(context, binary)

      {members, warnings} =
        Import.expand_archive(archive, context.dir, limits(max_entry_bytes: 10))

      assert members == []
      assert [%{reason: :archive_too_large, detail: detail}] = warnings
      assert detail =~ "entry_too_large"
      refute File.exists?(context.dir)
    end

    test "rejects an archive that repeats a member name without creating the directory",
         context do
      archive = stage(context, [{~c"stops.txt", "first"}, {~c"stops.txt", "second"}])

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert members == []
      assert [%{reason: :unzip_failed, detail: detail}] = warnings
      assert detail =~ "duplicate_members"
      refute File.exists?(context.dir)
    end

    test "removes the directory when a member's local header names another location", context do
      binary =
        [{~c"stops.txt", @stops}]
        |> zip_binary()
        |> :binary.replace("stops.txt", "../ps.txt")

      archive = stage_binary(context, binary)

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert members == []
      assert [%{reason: :unzip_failed, detail: detail}] = warnings
      assert detail =~ "member_mismatch"
      refute File.exists?(context.dir)
      assert Path.wildcard(Path.join(context.base, "**/ps.txt")) == []
    end

    test "warns that a file that is not a zip could not be read", context do
      archive = stage_binary(context, "not a real zip")

      {members, warnings} = Import.expand_archive(archive, context.dir, limits())

      assert members == []
      assert [%{filename: "feed.zip", reason: :unzip_failed}] = warnings
      refute File.exists?(context.dir)
    end
  end

  describe "preflight_archive/2" do
    test "lists the members to extract as the archive spells them and writes nothing",
         context do
      archive =
        stage(context, [
          {~c"stops.txt", @stops},
          {~c"feed/levels.txt", @levels},
          {~c"__MACOSX/._stops.txt", "junk"}
        ])

      result = Import.preflight_archive(archive, limits())

      assert result == {:ok, [~c"stops.txt", ~c"feed/levels.txt"], []}
      refute File.exists?(context.dir)
    end
  end

  describe "expand_staged_archives/2" do
    test "extracts each archive into its own subdirectory and passes other files through",
         context do
      first = stage(context, [{~c"stops.txt", "first"}], "first.zip")
      second = stage(context, [{~c"stops.txt", "second"}], "second.zip")
      routes = stage_binary(context, "route_id\nr1\n", "routes.txt")

      {files, warnings} = Import.expand_staged_archives([first, routes, second], context.dir)

      assert warnings == []

      assert files == [
               %{filename: "stops.txt", path: Path.join([context.dir, "0", "stops.txt"])},
               routes,
               %{filename: "stops.txt", path: Path.join([context.dir, "2", "stops.txt"])}
             ]

      assert files |> Enum.at(0) |> Map.fetch!(:path) |> File.read!() == "first"
      assert files |> Enum.at(2) |> Map.fetch!(:path) |> File.read!() == "second"
    end

    test "keeps the warnings of a rejected archive and still extracts the others", context do
      bad = stage_binary(context, "not a real zip", "bad.zip")
      good = stage(context, [{~c"stops.txt", @stops}], "good.zip")

      {files, warnings} = Import.expand_staged_archives([bad, good], context.dir)

      assert [%{filename: "bad.zip", reason: :unzip_failed}] = warnings
      assert files == [%{filename: "stops.txt", path: Path.join([context.dir, "1", "stops.txt"])}]
    end
  end

  describe "expand_archives/1" do
    test "returns member contents, passes other files through and rejects an unsafe member" do
      binary = zip_binary([{~c"../evil.txt", "evil"}, {~c"stops.txt", @stops}])
      routes = %{filename: "routes.txt", content: "route_id\nr1\n"}

      {files, warnings} =
        Import.expand_archives([%{filename: "feed.zip", content: binary}, routes])

      assert files == [%{filename: "stops.txt", content: @stops}, routes]
      assert [%{filename: "feed.zip", reason: :unsafe_member_path}] = warnings
    end
  end

  defp limits(overrides \\ []) do
    Map.merge(
      %{max_entries: 10_000, max_total_bytes: 1_000_000, max_entry_bytes: 1_000_000},
      Map.new(overrides)
    )
  end

  defp zip_binary(entries) do
    {:ok, {_name, binary}} = :zip.create(~c"feed.zip", entries, [:memory])
    binary
  end

  defp stage(context, entries, filename \\ "feed.zip") do
    stage_binary(context, zip_binary(entries), filename)
  end

  defp stage_binary(context, binary, filename \\ "feed.zip") do
    path = Path.join(context.uploads, "#{Ecto.UUID.generate()}.source")
    File.write!(path, binary)

    %{filename: filename, path: path}
  end

  # Rewrites the uncompressed size in the first central directory header, the value
  # the preflight trusts.
  defp patch_declared_size(binary, size) do
    {header_offset, _length} = :binary.match(binary, <<0x50, 0x4B, 0x01, 0x02>>)
    size_offset = header_offset + 24
    <<head::binary-size(size_offset), _declared::32, tail::binary>> = binary

    <<head::binary, size::little-32, tail::binary>>
  end

  defp files_under(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end
end
