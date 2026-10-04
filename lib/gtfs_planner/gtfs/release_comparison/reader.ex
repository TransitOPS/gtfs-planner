defmodule GtfsPlanner.Gtfs.ReleaseComparison.Reader do
  @moduledoc """
  Reads the allowlisted CSV members of one claimed native full-main export
  artifact into memory, without persisting anything.

  The claim is the only source of the path, the recorded size and the recorded
  digest. The bytes are consumed through bounded 65,536-byte reads and refused
  as soon as they would exceed `min(recorded size, #{div(150 * 1024 * 1024, 1_048_576)}MiB)`,
  so a replaced oversized file is never fully retained. The assembled binary is
  then rehashed and its size checked against both the claim and the artifact
  identity from step 1; the rows returned are parsed from that same binary, so
  the reported digest always describes the bytes the evidence came from.

  Admission happens on the central directory before extraction. Only unique
  exact root names of the service allowlist are selected; unsafe member paths
  and repeated allowlisted names refuse the whole archive, every entry counts
  toward the existing `GtfsPlanner.Gtfs.Import.zip_limits/0` entry cap, and the
  declared uncompressed size of the selected members is capped at
  #{div(20 * 1024 * 1024, 1_048_576)}MiB. After `:zip.unzip/2` the extracted names
  and their actual sizes must still match the admitted metadata, so a member
  whose header understates its size refuses instead of being parsed.

  `agency.txt`, `routes.txt`, `stops.txt`, `trips.txt` and `stop_times.txt` are
  required, and at least one of `calendar.txt` or `calendar_dates.txt` must be
  present; an artifact without any calendar table is not an empty service, it
  is a refusal. Members outside the allowlist, such as shapes or extensions, are
  ignored and never enter the result.

  No extracted file is written, no import is invoked and no uploaded source is
  accepted: the only caller is the native comparison start in step 7, which owns
  the claim.
  """

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.CsvParser

  @read_chunk_bytes 65_536
  @max_compressed_bytes 150 * 1024 * 1024
  @max_selected_bytes 20 * 1024 * 1024
  @max_rows 100_000

  @required_tables ~w(agency.txt routes.txt stops.txt trips.txt stop_times.txt)
  @calendar_tables ~w(calendar.txt calendar_dates.txt)
  @allowlist @required_tables ++ @calendar_tables ++ ~w(frequencies.txt feed_info.txt)

  @typedoc "One claimed artifact, as returned by `GtfsPlanner.Gtfs.ExportRuns.claim_download/4`."
  @type claim :: %{
          required(:path) => String.t(),
          required(:size) => non_neg_integer(),
          required(:sha256) => String.t(),
          required(:claim_id) => DateTime.t()
        }

  @typedoc "One parsed row with its physical CSV row number, which begins at 2."
  @type row :: %{required(:row) => pos_integer(), required(:fields) => map()}

  @spec read(claim(), map()) ::
          {:ok, %{required(:tables) => %{String.t() => [row()]}, required(:identity) => map()}}
          | {:error, :unavailable | :unsupported_size | :invalid_archive | :malformed_csv}
  def read(claim, identity) when is_map(claim) and is_map(identity) do
    with {:ok, bytes} <- read_bytes(claim),
         :ok <- verify_consumed(bytes, claim, identity),
         {:ok, selected} <- admit(bytes),
         {:ok, contents} <- extract(bytes, selected),
         {:ok, tables} <- parse_tables(contents) do
      {:ok, %{tables: tables, identity: identity}}
    end
  end

  def read(_claim, _identity), do: {:error, :unavailable}

  # Bounded consumption: the refusal happens before the offending chunk is
  # retained, so an artifact replaced with a much larger file costs one chunk.
  defp read_bytes(%{path: path, size: size})
       when is_binary(path) and is_integer(size) and size >= 0 do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          read_chunks(device, min(size, @max_compressed_bytes), 0, [])
        after
          File.close(device)
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp read_bytes(_claim), do: {:error, :unavailable}

  defp read_chunks(device, limit, total, acc) do
    case IO.binread(device, @read_chunk_bytes) do
      :eof ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, _reason} ->
        {:error, :unavailable}

      chunk ->
        if total + byte_size(chunk) > limit do
          {:error, :unsupported_size}
        else
          read_chunks(device, limit, total + byte_size(chunk), [chunk | acc])
        end
    end
  end

  # The digest must describe exactly the bytes that will be parsed, and both
  # recorded shapes must agree with each other.
  defp verify_consumed(bytes, %{size: size, sha256: sha256}, identity) do
    if byte_size(bytes) == size and sha256(bytes) == sha256 and
         Map.get(identity, :size) == size and Map.get(identity, :sha256) == sha256 do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp admit(bytes) do
    case :zip.list_dir(bytes) do
      {:ok, entries} -> admit_entries(entries)
      {:error, _reason} -> {:error, :invalid_archive}
    end
  end

  defp admit_entries(entries) do
    described = entries |> Enum.map(&describe/1) |> Enum.reject(&is_nil/1)

    if length(described) > Import.zip_limits().max_entries do
      {:error, :unsupported_size}
    else
      selected = Enum.filter(described, & &1.allowlisted)

      cond do
        Enum.any?(described, & &1.unsafe) ->
          {:error, :invalid_archive}

        selected != Enum.uniq_by(selected, & &1.name) ->
          {:error, :invalid_archive}

        not covers_required_tables?(selected) ->
          {:error, :invalid_archive}

        Enum.sum(Enum.map(selected, & &1.size)) > @max_selected_bytes ->
          {:error, :unsupported_size}

        true ->
          {:ok, selected}
      end
    end
  end

  defp describe({:zip_file, name, info, _comment, _offset, _compressed_size}) do
    string = to_string(name)

    %{
      name: string,
      size: uncompressed_size(info),
      # An allowlist name is exact and at the archive root, so a nested
      # `feed/routes.txt` is ignored rather than compared.
      allowlisted: string in @allowlist,
      unsafe: unsafe_path?(string)
    }
  end

  defp describe({:zip_dir, name}) do
    string = to_string(name)

    %{name: string, size: 0, allowlisted: false, unsafe: unsafe_path?(string)}
  end

  # The archive comment carries no member and is not one of the entries the
  # entry cap or the selection may consider.
  defp describe({:zip_comment, _comment}), do: nil

  defp unsafe_path?(name) do
    normalized = String.replace(name, "\\", "/")

    String.starts_with?(normalized, "/") or String.match?(normalized, ~r/^[A-Za-z]:/) or
      String.contains?(name, <<0>>) or ".." in String.split(normalized, "/")
  end

  defp covers_required_tables?(selected) do
    names = MapSet.new(selected, & &1.name)

    Enum.all?(@required_tables, &MapSet.member?(names, &1)) and
      Enum.any?(@calendar_tables, &MapSet.member?(names, &1))
  end

  defp uncompressed_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _})
       when is_integer(size) and size >= 0,
       do: size

  defp uncompressed_size(_info), do: 0

  defp extract(bytes, selected) do
    names = Enum.map(selected, &String.to_charlist(&1.name))

    case :zip.unzip(bytes, [:memory, {:file_list, names}]) do
      {:ok, extracted} -> check_extracted(extracted, selected)
      {:error, _reason} -> {:error, :invalid_archive}
    end
  end

  # A member whose header understates its size, or a selection `:zip` did not
  # honour, refuses the artifact instead of being parsed as truncated evidence.
  defp check_extracted(extracted, selected) do
    contents = Map.new(extracted, fn {name, content} -> {to_string(name), content} end)

    if MapSet.new(Map.keys(contents)) == MapSet.new(Enum.map(selected, & &1.name)) and
         Enum.all?(selected, &(byte_size(Map.fetch!(contents, &1.name)) == &1.size)) do
      {:ok, contents}
    else
      {:error, :invalid_archive}
    end
  end

  defp parse_tables(contents) do
    result =
      Enum.reduce_while(
        contents |> Map.keys() |> Enum.sort(),
        {:ok, 0, %{}},
        fn name, {:ok, count, tables} ->
          case parse_table(name, Map.fetch!(contents, name), count) do
            {:ok, count, rows} -> {:cont, {:ok, count, Map.put(tables, name, rows)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      )

    case result do
      {:ok, _count, tables} -> {:ok, tables}
      {:error, _reason} = error -> error
    end
  end

  # A structural CSV fault is a malformed artifact, not a partially parsed table.
  defp parse_table(name, content, count) do
    case CsvParser.stream(name, content) do
      {:ok, parsed} -> collect_rows(parsed.events, count)
      {:error, _parse_error} -> {:error, :malformed_csv}
    end
  end

  # The row cap covers the whole artifact, not one table, and a refusal is
  # never a truncated success.
  defp collect_rows(events, count) do
    case take_rows(events, count, []) do
      {:ok, count, acc} -> {:ok, count, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp take_rows(events, count, acc) do
    Enum.reduce_while(events, {:ok, count, acc}, fn
      {:ok, row, fields}, {:ok, count, acc} ->
        if count + 1 > @max_rows do
          {:halt, {:error, :unsupported_size}}
        else
          {:cont, {:ok, count + 1, [row_entry(row, fields) | acc]}}
        end

      {:error, _parse_error}, _acc ->
        {:halt, {:error, :malformed_csv}}
    end)
  end

  defp row_entry(row, fields), do: %{row: row, fields: fields}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
