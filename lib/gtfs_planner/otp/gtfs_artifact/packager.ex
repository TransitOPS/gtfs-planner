defmodule GtfsPlanner.Otp.Packager do
  @moduledoc """
  Deterministic GTFS zip packager for OTP materialization.

  Packages root-level `*.txt` files from a staging directory using basename
  sort order, writes the resulting zip to disk, and returns its path and size.
  """

  @spec package_staging_dir(String.t(), String.t()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def package_staging_dir(staging_dir, zip_path)
      when is_binary(staging_dir) and is_binary(zip_path) do
    with {:ok, entries} <- File.ls(staging_dir),
         txt_entries <- entries |> Enum.filter(&String.ends_with?(&1, ".txt")) |> Enum.sort(),
         {:ok, files} <- zip_entries(staging_dir, txt_entries),
         {:ok, {_zip_name, zip_binary}} <- :zip.create(~c"gtfs.zip", files, [:memory]),
         :ok <- File.mkdir_p(Path.dirname(zip_path)),
         :ok <- File.write(zip_path, zip_binary) do
      {:ok, zip_path, byte_size(zip_binary)}
    else
      error -> {:error, error}
    end
  end

  defp zip_entries(_staging_dir, []), do: {:ok, []}

  defp zip_entries(staging_dir, txt_entries) do
    txt_entries
    |> Enum.reduce_while({:ok, []}, fn filename, {:ok, acc} ->
      full_path = Path.join(staging_dir, filename)

      case File.read(full_path) do
        {:ok, file_content} ->
          entry = {String.to_charlist(Path.basename(filename)), file_content}
          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:file_read_failed, filename, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end
end
