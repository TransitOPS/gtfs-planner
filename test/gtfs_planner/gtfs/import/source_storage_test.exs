defmodule GtfsPlanner.Gtfs.Import.SourceStorageTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.SourceStorage

  @long_ago 1_000_000_000

  setup do
    base = Path.join(System.tmp_dir!(), "import-sources-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)

    File.mkdir_p!(Path.join(base, "uploads"))

    %{
      base: base,
      root: Path.join(base, "root"),
      organization_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate()
    }
  end

  describe "stage/4" do
    test "copies uploads into the run's source directory and describes each file", context do
      stops_content = "stop_id,stop_name\ncentral,Central\n"
      routes_content = "route_id\nr1\n"
      stops = upload(context, "stops.txt", stops_content)
      routes = upload(context, "routes.txt", routes_content)

      assert {:ok, [staged_stops, staged_routes]} = stage(context, [stops, routes])

      assert staged_stops == %{
               filename: "stops.txt",
               path: staged_stops.path,
               size: 34,
               sha256: sha256(stops_content)
             }

      assert staged_routes == %{
               filename: "routes.txt",
               path: staged_routes.path,
               size: 12,
               sha256: sha256(routes_content)
             }

      assert Path.dirname(staged_stops.path) == source_directory(context)
      assert Path.dirname(staged_routes.path) == source_directory(context)
      assert File.read!(staged_stops.path) == stops_content
      assert File.read!(staged_routes.path) == routes_content
    end

    test "leaves the uploaded file in place", context do
      stops = upload(context, "stops.txt", "stop_id\ncentral\n")

      assert {:ok, [_staged]} = stage(context, [stops])

      assert File.read!(stops.path) == "stop_id\ncentral\n"
    end

    test "stores uploads that share a filename as separate files", context do
      first = upload(context, "stops.txt", "first")
      second = upload(context, "stops.txt", "second")

      assert {:ok, [staged_first, staged_second]} = stage(context, [first, second])

      assert staged_first.path != staged_second.path
      assert File.read!(staged_first.path) == "first"
      assert File.read!(staged_second.path) == "second"
    end

    test "rejects a filename that climbs out of the directory and writes nothing", context do
      valid = upload(context, "stops.txt", "stop_id\n")
      traversal = upload(context, "../x.txt", "x")

      assert {:error, :invalid_file} = stage(context, [valid, traversal])

      refute File.exists?(context.root)
    end

    test "rejects a filename longer than 255 bytes and writes nothing", context do
      too_long = upload(context, String.duplicate("a", 252) <> ".txt", "x")

      assert {:error, :invalid_file} = stage(context, [too_long])

      refute File.exists?(context.root)
    end

    test "accepts a filename of exactly 255 bytes", context do
      longest = upload(context, String.duplicate("a", 251) <> ".txt", "x")

      assert {:ok, [staged]} = stage(context, [longest])

      assert byte_size(staged.filename) == 255
    end

    test "rejects an upload whose path is not a readable file and writes nothing", context do
      valid = upload(context, "stops.txt", "stop_id\n")
      missing = %{path: Path.join(context.base, "uploads/missing"), filename: "routes.txt"}

      assert {:error, :invalid_file} = stage(context, [valid, missing])

      refute File.exists?(context.root)
    end

    test "rejects an empty upload list", context do
      assert {:error, :invalid_file} = stage(context, [])
    end

    test "rejects more than 50 uploads and writes nothing", context do
      stops = upload(context, "stops.txt", "stop_id\n")

      assert {:error, :invalid_file} = stage(context, List.duplicate(stops, 51))

      refute File.exists?(context.root)
    end

    test "accepts 50 uploads", context do
      stops = upload(context, "stops.txt", "stop_id\n")

      assert {:ok, staged} = stage(context, List.duplicate(stops, 50))

      assert length(staged) == 50
    end

    test "rejects a file over the 200,000,000-byte upload limit and writes nothing", context do
      oversized = sparse_upload(context, "stop_times.txt", 200_000_001)

      assert {:error, :artifact_capacity_exceeded} =
               stage(context, [oversized], max_run_bytes: 1_000_000_000)

      refute File.exists?(context.root)
    end

    test "rejects uploads that exceed the run capacity and leaves no file", context do
      first = upload(context, "stops.txt", "123")
      second = upload(context, "routes.txt", "456")

      assert {:error, :artifact_capacity_exceeded} =
               stage(context, [first, second], max_run_bytes: 5)

      refute File.exists?(context.root)
    end

    test "accepts uploads that total exactly the run capacity", context do
      first = upload(context, "stops.txt", "123")
      second = upload(context, "routes.txt", "456")

      assert {:ok, [_, _]} = stage(context, [first, second], max_run_bytes: 6)
    end

    test "rejects uploads that exceed the root capacity and keeps existing artifacts",
         context do
      existing = Path.join(context.root, "existing-artifact")
      File.mkdir_p!(context.root)
      File.write!(existing, "1234")
      stops = upload(context, "stops.txt", "x")

      assert {:error, :artifact_capacity_exceeded} =
               stage(context, [stops], max_total_bytes: 4)

      assert File.read!(existing) == "1234"
      refute File.exists?(Path.join(context.root, "import-runs"))
    end

    test "rejects an organization or run id that is not a UUID and writes nothing", context do
      stops = upload(context, "stops.txt", "stop_id\n")

      assert {:error, :invalid_scope} =
               SourceStorage.stage(context.organization_id, "../escape", [stops],
                 root: context.root
               )

      refute File.exists?(context.root)
    end

    test "reports unavailable storage when the root is blank", context do
      stops = upload(context, "stops.txt", "stop_id\n")

      assert {:error, :artifact_storage_unavailable} =
               SourceStorage.stage(context.organization_id, context.run_id, [stops], root: "")
    end
  end

  describe "run_dir/3" do
    test "returns the run directory under the import-runs root", context do
      assert {:ok, directory} =
               SourceStorage.run_dir(context.organization_id, context.run_id, root: context.root)

      assert directory ==
               Path.join([context.root, "import-runs", context.organization_id, context.run_id])
    end

    test "rejects a run id that is not a UUID", context do
      assert {:error, :invalid_scope} =
               SourceStorage.run_dir(context.organization_id, "../escape", root: context.root)
    end
  end

  describe "remove/3" do
    test "deletes the run's directory and keeps other runs' directories", context do
      other_run_id = Ecto.UUID.generate()
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [_]} = stage(context, [stops])
      assert {:ok, [other]} = stage_run(context, other_run_id, [stops])

      assert :ok =
               SourceStorage.remove(context.organization_id, context.run_id, root: context.root)

      refute File.exists?(run_directory(context, context.run_id))
      assert File.exists?(other.path)
    end

    test "succeeds when the run directory is already absent", context do
      assert :ok =
               SourceStorage.remove(context.organization_id, context.run_id, root: context.root)
    end

    test "rejects a run id that is not a UUID", context do
      assert {:error, :invalid_scope} =
               SourceStorage.remove(context.organization_id, "../escape", root: context.root)
    end
  end

  describe "reconcile/2" do
    test "keeps the directory of an active run even when it is older than the grace", context do
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [staged]} = stage(context, [stops])
      File.touch!(run_directory(context, context.run_id), @long_ago)

      assert {:ok, 0} =
               SourceStorage.reconcile([context.run_id],
                 root: context.root,
                 orphan_grace_seconds: 3600
               )

      assert File.exists?(staged.path)
    end

    test "keeps an inactive run's directory younger than the grace", context do
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [staged]} = stage(context, [stops])

      assert {:ok, 0} =
               SourceStorage.reconcile([], root: context.root, orphan_grace_seconds: 3600)

      assert File.exists?(staged.path)
    end

    test "removes an inactive run's directory older than the grace", context do
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [staged]} = stage(context, [stops])
      File.touch!(run_directory(context, context.run_id), @long_ago)

      assert {:ok, 1} =
               SourceStorage.reconcile([], root: context.root, orphan_grace_seconds: 3600)

      refute File.exists?(staged.path)
      refute File.exists?(run_directory(context, context.run_id))
    end

    test "removes only the inactive directory when an active run is also old", context do
      active_run_id = Ecto.UUID.generate()
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [orphan]} = stage(context, [stops])
      assert {:ok, [active]} = stage_run(context, active_run_id, [stops])
      File.touch!(run_directory(context, context.run_id), @long_ago)
      File.touch!(run_directory(context, active_run_id), @long_ago)

      assert {:ok, 1} =
               SourceStorage.reconcile([active_run_id],
                 root: context.root,
                 orphan_grace_seconds: 3600
               )

      refute File.exists?(orphan.path)
      assert File.exists?(active.path)
    end

    test "removes an inactive directory of any age when the grace is zero", context do
      stops = upload(context, "stops.txt", "stop_id\n")
      assert {:ok, [staged]} = stage(context, [stops])

      assert {:ok, 1} =
               SourceStorage.reconcile([], root: context.root, orphan_grace_seconds: 0)

      refute File.exists?(staged.path)
    end

    test "returns zero when nothing has been staged", context do
      assert {:ok, 0} = SourceStorage.reconcile([], root: context.root)
    end
  end

  defp stage(context, uploads, opts \\ []), do: stage_run(context, context.run_id, uploads, opts)

  defp stage_run(context, run_id, uploads, opts \\ []) do
    SourceStorage.stage(
      context.organization_id,
      run_id,
      uploads,
      Keyword.put(opts, :root, context.root)
    )
  end

  defp upload(context, filename, content) do
    path = Path.join([context.base, "uploads", "upload-#{System.unique_integer([:positive])}"])
    File.write!(path, content)
    %{path: path, filename: filename}
  end

  # A sparse file reports its full size without writing the bytes to disk.
  defp sparse_upload(context, filename, size) do
    path = Path.join([context.base, "uploads", "upload-#{System.unique_integer([:positive])}"])
    {:ok, device} = :file.open(path, [:write, :raw, :binary])
    {:ok, _position} = :file.position(device, size - 1)
    :ok = :file.write(device, "x")
    :ok = :file.close(device)
    %{path: path, filename: filename}
  end

  defp run_directory(context, run_id),
    do: Path.join([context.root, "import-runs", context.organization_id, run_id])

  defp source_directory(context), do: Path.join(run_directory(context, context.run_id), "source")

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
