defmodule GtfsPlanner.Otp.Hasher do
  @moduledoc """
  Deterministic SHA256 hashing for OTP GTFS staged exports.

  Hashes staged file content in the provided manifest order and returns a
  lowercase hex digest.
  """

  @spec sha256_for_specs(String.t(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def sha256_for_specs(staging_dir, specs) when is_binary(staging_dir) and is_list(specs) do
    specs
    |> Enum.map(& &1.filename)
    |> sha256_for_filenames(staging_dir)
  end

  @spec sha256_for_filenames([String.t()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256_for_filenames(filenames, staging_dir)
      when is_list(filenames) and is_binary(staging_dir) do
    filenames
    |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn filename, {:ok, acc_hash} ->
      full_path = Path.join(staging_dir, filename)

      case File.read(full_path) do
        {:ok, content} ->
          updated_hash =
            acc_hash
            |> :crypto.hash_update(filename)
            |> :crypto.hash_update(<<0>>)
            |> :crypto.hash_update(content)
            |> :crypto.hash_update(<<0>>)

          {:cont, {:ok, updated_hash}}

        {:error, reason} ->
          {:halt, {:error, {:file_read_failed, filename, reason}}}
      end
    end)
    |> case do
      {:ok, hash_state} ->
        digest =
          hash_state
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, digest}

      error ->
        error
    end
  end
end
