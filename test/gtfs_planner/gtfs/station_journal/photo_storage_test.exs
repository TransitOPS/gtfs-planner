defmodule GtfsPlanner.Gtfs.StationJournal.PhotoStorageTest do
  use GtfsPlanner.DataCase, async: false

  import ExUnit.CaptureLog
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.StationJournal.{PhotoStorage, Scope}
  alias GtfsPlanner.Repo

  @max_bytes 25 * 1024 * 1024
  @jpeg <<0xFF, 0xD8, "journal-photo", 0xFF, 0xD9>>

  @scope %Scope{
    organization_id: "e1d9aa70-532d-43e5-bab0-77cce113c923",
    gtfs_version_id: "34247956-83fc-4e80-b0df-78f86972f5f9",
    station_id: "9f7145c0-fd1a-4a82-bc54-0f4a70e147e9",
    station_stop_id: "station/1",
    actor_id: "a709799a-4b37-4af2-aa0a-9d8862da7f46"
  }

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)

    root =
      Path.join(
        System.tmp_dir!(),
        "station_journal_photo_storage_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous)
    end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, version.id,
        stop_id: "station_#{System.unique_integer([:positive])}",
        location_type: 1
      )

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_id: station.id,
      station_stop_id: station.stop_id,
      actor_id: Ecto.UUID.generate()
    }

    entry =
      Repo.insert!(%JournalEntry{
        id: Ecto.UUID.generate(),
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        author_id: scope.actor_id,
        target_type: "station",
        captured_at: ~U[2026-07-13 10:00:00.000000Z]
      })

    %{root: root, scope: scope, entry: entry}
  end

  test "stages boundary-valid JPEG and PNG bytes under deterministic trusted paths", %{root: root} do
    jpg = write_upload(root, "capture.jpg", <<0xFF, 0xD8, 1, 2, 0xFF, 0xD9>>)

    png =
      write_upload(
        root,
        "capture.png",
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0, "IEND", 174, 66, 96, 130>>
      )

    assert {:ok, staged_jpg} =
             PhotoStorage.stage(@scope, "a1b2c3d4-e5f6-4789-8123-456789abcdef", %{path: jpg})

    assert staged_jpg.content_type == "image/jpeg"
    assert staged_jpg.filename == "a1b2c3d4-e5f6-4789-8123-456789abcdef.jpg"

    assert PhotoStorage.public_path(@scope, staged_jpg) =~
             "/field-captures/#{@scope.organization_id}/sid_"

    assert :ok = PhotoStorage.finalize(staged_jpg)
    assert PhotoStorage.final_matches?(staged_jpg)

    assert {:ok, staged_png} =
             PhotoStorage.stage(@scope, "b1b2c3d4-e5f6-4789-8123-456789abcdef", %{path: png})

    assert staged_png.content_type == "image/png"
    assert staged_png.filename == "b1b2c3d4-e5f6-4789-8123-456789abcdef.png"
    assert :ok = PhotoStorage.discard(staged_png)
  end

  test "rejects empty, truncated, unsupported, and unsafe inputs without a final file", %{
    root: root
  } do
    empty = write_upload(root, "empty", <<>>)
    truncated = write_upload(root, "truncated", <<0xFF, 0xD8, 1>>)
    unsupported = write_upload(root, "gif", "GIF89a")

    assert {:error, :empty_file} =
             PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: empty})

    assert {:error, :invalid_image} =
             PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: truncated})

    assert {:error, :invalid_image} =
             PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: unsupported})

    assert {:error, :unsafe_path} =
             PhotoStorage.stage(%{@scope | station_stop_id: nil}, Ecto.UUID.generate(), %{
               path: unsupported
             })

    assert [] == Path.wildcard(Path.join([root, "field-captures", "**", "*.jpg"]))
    assert [] == Path.wildcard(Path.join([root, "field-captures", "**", "*.png"]))
  end

  test "inspects a final artifact by digest and detects a corrupt replacement", %{root: root} do
    upload = write_upload(root, "capture.jpg", <<0xFF, 0xD8, 1, 2, 0xFF, 0xD9>>)
    assert {:ok, staged} = PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: upload})
    assert :ok = PhotoStorage.finalize(staged)
    assert PhotoStorage.final_matches?(staged)
    assert :ok = File.write(staged.final_path, "wrong bytes")
    refute PhotoStorage.final_matches?(staged)
  end

  test "accepts exactly 25 MiB and rejects one byte more", %{root: root} do
    exact = write_sparse_jpeg(root, "exact.jpg", @max_bytes)
    oversized = write_sparse_jpeg(root, "oversized.jpg", @max_bytes + 1)

    assert {:ok, staged} = PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: exact})
    assert staged.byte_size == @max_bytes
    assert :ok = PhotoStorage.discard(staged)

    assert {:error, :payload_too_large} =
             PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: oversized})

    assert [] == Path.wildcard(Path.join([root, "field-captures", "**", "*.tmp"]))
  end

  test "cleans the current and stale temporary files after metadata validation failure",
       context do
    photo_id = Ecto.UUID.generate()
    stale_path = stale_temp_path(context.root, context.scope, photo_id)
    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale")

    upload = upload(context.root, "mismatch.jpg", @jpeg)

    assert {:error, :validation_error} =
             Gtfs.create_journal_photo(
               context.scope,
               photo_attrs(photo_id, context.entry.id, %{"content_type" => "image/png"}),
               upload
             )

    assert [] == temporary_files(context.root, context.scope, photo_id)
    refute Repo.get(JournalPhoto, photo_id)
  end

  test "temporary-file/no-row retry creates the row and removes stale same-id files", context do
    photo_id = Ecto.UUID.generate()
    stale_path = stale_temp_path(context.root, context.scope, photo_id)
    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale")

    assert {:ok, %JournalPhoto{id: ^photo_id}} = create_photo(context, photo_id, @jpeg)
    assert [] == temporary_files(context.root, context.scope, photo_id)
    assert File.read!(final_path(context.root, context.scope, photo_id)) == @jpeg
  end

  test "final-file/no-row retry adopts matching bytes and cleans temporary files", context do
    photo_id = Ecto.UUID.generate()
    source = write_upload(context.root, "orphan.jpg", @jpeg)
    assert {:ok, staged} = PhotoStorage.stage(context.scope, photo_id, %{path: source})
    assert :ok = PhotoStorage.finalize(staged)
    refute Repo.get(JournalPhoto, photo_id)

    log =
      capture_log(fn ->
        assert {:ok, %JournalPhoto{id: ^photo_id}} = create_photo(context, photo_id, @jpeg)
      end)

    assert log =~ "orphan_adopted"
    refute log =~ "journal-photo"
    assert [] == temporary_files(context.root, context.scope, photo_id)
    assert File.read!(staged.final_path) == @jpeg
  end

  test "row/no-file retry restores the missing materialization", context do
    photo_id = Ecto.UUID.generate()
    assert {:ok, photo} = create_photo(context, photo_id, @jpeg)
    path = final_path(context.root, context.scope, photo_id)
    File.rm!(path)

    log =
      capture_log(fn ->
        assert {:ok, ^photo} = create_photo(context, photo_id, @jpeg)
      end)

    assert log =~ "file_repaired"
    assert File.read!(path) == @jpeg
    assert [] == temporary_files(context.root, context.scope, photo_id)
  end

  test "row/correct-file retry returns the original row and removes stale temporary files",
       context do
    photo_id = Ecto.UUID.generate()
    assert {:ok, photo} = create_photo(context, photo_id, @jpeg)
    stale_path = stale_temp_path(context.root, context.scope, photo_id)
    File.write!(stale_path, "stale")

    assert {:ok, ^photo} = create_photo(context, photo_id, @jpeg)
    assert Repo.aggregate(JournalPhoto, :count, :id) == 1
    assert File.read!(final_path(context.root, context.scope, photo_id)) == @jpeg
    assert [] == temporary_files(context.root, context.scope, photo_id)
  end

  test "row/wrong-file retry repairs from bytes matching the authoritative row", context do
    photo_id = Ecto.UUID.generate()
    assert {:ok, photo} = create_photo(context, photo_id, @jpeg)
    path = final_path(context.root, context.scope, photo_id)
    File.write!(path, <<0xFF, 0xD8, "corrupt", 0xFF, 0xD9>>)

    log =
      capture_log(fn ->
        assert {:ok, ^photo} = create_photo(context, photo_id, @jpeg)
      end)

    assert log =~ "file_repaired"
    refute log =~ "journal-photo"
    assert File.read!(path) == @jpeg
    assert [] == temporary_files(context.root, context.scope, photo_id)
  end

  test "different bytes for an existing row return a conflict without leaking bytes", context do
    photo_id = Ecto.UUID.generate()
    assert {:ok, photo} = create_photo(context, photo_id, @jpeg)
    changed = <<0xFF, 0xD8, "private-changed-bytes", 0xFF, 0xD9>>

    log =
      capture_log(fn ->
        assert {:error, :id_conflict} = create_photo(context, photo_id, changed)
      end)

    assert log =~ "id_conflict"
    refute log =~ "private-changed-bytes"
    assert Repo.get!(JournalPhoto, photo_id) == photo
    assert File.read!(final_path(context.root, context.scope, photo_id)) == @jpeg
    assert [] == temporary_files(context.root, context.scope, photo_id)
  end

  defp write_upload(root, filename, bytes) do
    path = Path.join(root, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  defp write_sparse_jpeg(root, filename, size) do
    path = Path.join(root, filename)

    {:ok, :ok} =
      File.open(path, [:write, :binary], fn file ->
        :ok = IO.binwrite(file, <<0xFF, 0xD8>>)
        {:ok, _position} = :file.position(file, {:bof, size - 2})
        IO.binwrite(file, <<0xFF, 0xD9>>)
      end)

    path
  end

  defp create_photo(context, photo_id, bytes) do
    Gtfs.create_journal_photo(
      context.scope,
      photo_attrs(photo_id, context.entry.id),
      upload(context.root, "#{photo_id}.jpg", bytes)
    )
  end

  defp photo_attrs(photo_id, entry_id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => photo_id,
        "journal_entry_id" => entry_id,
        "captured_at" => "2026-07-13T10:00:00Z"
      },
      overrides
    )
  end

  defp upload(root, filename, bytes) do
    %{
      path: write_upload(root, "#{System.unique_integer([:positive])}-#{filename}", bytes),
      filename: filename,
      content_type: nil
    }
  end

  defp final_path(root, scope, photo_id) do
    Path.join([
      root,
      "field-captures",
      scope.organization_id,
      PathSafety.stop_storage_dir(scope.station_stop_id),
      "#{photo_id}.jpg"
    ])
  end

  defp stale_temp_path(root, scope, photo_id) do
    final_path(root, scope, photo_id)
    |> Path.rootname()
    |> Kernel.<>(".#{photo_id}.stale.tmp")
  end

  defp temporary_files(root, scope, photo_id) do
    final_path(root, scope, photo_id)
    |> Path.dirname()
    |> Path.join("#{photo_id}.*.tmp")
    |> Path.wildcard()
  end
end
