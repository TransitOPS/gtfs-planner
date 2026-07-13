defmodule GtfsPlanner.Gtfs.StationJournal.PhotoStorageTest do
  use ExUnit.Case, async: false

  alias GtfsPlanner.Gtfs.StationJournal.{PhotoStorage, Scope}

  @scope %Scope{
    organization_id: "e1d9aa70-532d-43e5-bab0-77cce113c923",
    gtfs_version_id: "34247956-83fc-4e80-b0df-78f86972f5f9",
    station_id: "9f7145c0-fd1a-4a82-bc54-0f4a70e147e9",
    station_stop_id: "station/1",
    actor_id: "a709799a-4b37-4af2-aa0a-9d8862da7f46"
  }

  setup do
    previous = Application.get_env(:gtfs_planner, :uploads_path)
    root = Path.join(System.tmp_dir!(), "station_journal_photo_storage_#{System.unique_integer([:positive])}")
    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous),
        do: Application.delete_env(:gtfs_planner, :uploads_path),
        else: Application.put_env(:gtfs_planner, :uploads_path, previous)
    end)

    %{root: root}
  end

  test "stages boundary-valid JPEG and PNG bytes under deterministic trusted paths", %{root: root} do
    jpg = write_upload(root, "capture.jpg", <<0xFF, 0xD8, 1, 2, 0xFF, 0xD9>>)
    png = write_upload(root, "capture.png", <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0, "IEND", 174, 66, 96, 130>>)

    assert {:ok, staged_jpg} = PhotoStorage.stage(@scope, "a1b2c3d4-e5f6-4789-8123-456789abcdef", %{path: jpg})
    assert staged_jpg.content_type == "image/jpeg"
    assert staged_jpg.filename == "a1b2c3d4-e5f6-4789-8123-456789abcdef.jpg"
    assert PhotoStorage.public_path(@scope, staged_jpg) =~ "/field-captures/#{@scope.organization_id}/sid_"
    assert :ok = PhotoStorage.finalize(staged_jpg)
    assert PhotoStorage.final_matches?(staged_jpg)

    assert {:ok, staged_png} = PhotoStorage.stage(@scope, "b1b2c3d4-e5f6-4789-8123-456789abcdef", %{path: png})
    assert staged_png.content_type == "image/png"
    assert staged_png.filename == "b1b2c3d4-e5f6-4789-8123-456789abcdef.png"
    assert :ok = PhotoStorage.discard(staged_png)
  end

  test "rejects empty, truncated, unsupported, and unsafe inputs without a final file", %{root: root} do
    empty = write_upload(root, "empty", <<>>)
    truncated = write_upload(root, "truncated", <<0xFF, 0xD8, 1>>)
    unsupported = write_upload(root, "gif", "GIF89a")

    assert {:error, :empty_file} = PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: empty})
    assert {:error, :invalid_image} = PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: truncated})
    assert {:error, :invalid_image} = PhotoStorage.stage(@scope, Ecto.UUID.generate(), %{path: unsupported})
    assert {:error, :unsafe_path} = PhotoStorage.stage(%{@scope | station_stop_id: nil}, Ecto.UUID.generate(), %{path: unsupported})
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

  defp write_upload(root, filename, bytes) do
    path = Path.join(root, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end
end
