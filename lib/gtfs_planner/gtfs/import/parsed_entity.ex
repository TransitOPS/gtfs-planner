defmodule GtfsPlanner.Gtfs.Import.ParsedEntity do
  @moduledoc """
  Represents only a complete reviewed entity source with a unique natural-key
  map, constructed exclusively through `parse/5`. Diagnostics for incomplete
  input live only in `ParseFailure`.
  """

  alias GtfsPlanner.Gtfs.Import.{CsvParser, ParseError, ParseFailure}

  require Logger

  @max_diagnostics 100

  @opaque t :: %__MODULE__{
            entity_type: :level | :stop | :pathway,
            filename: String.t(),
            records_by_key: %{required(String.t()) => map()},
            source_row_count: non_neg_integer()
          }

  defstruct [:entity_type, :filename, :records_by_key, :source_row_count]

  @type result :: :not_uploaded | {:ok, t()} | {:error, ParseFailure.t()}

  @spec parse(
          nil | %{filename: String.t(), content: binary()},
          :level | :stop | :pathway,
          String.t(),
          atom(),
          (map() -> {:ok, map()} | {:error, term()})
        ) :: result()

  def parse(nil, _entity_type, _filename, _natural_key_field, _row_parser), do: :not_uploaded

  def parse(%{filename: filename, content: content}, entity_type, filename, natural_key_field, row_parser) do
    natural_key_header = Atom.to_string(natural_key_field)

    case CsvParser.stream(filename, content) do
      {:error, error} ->
        {:error,
         %ParseFailure{
           entity_type: entity_type,
           filename: filename,
           preview_records_by_key: %{},
           diagnostics: [error],
           total_error_count: 1,
           truncated?: false,
           source_row_count: 0,
           first_error_row: error.row,
           last_error_row: error.row
         }}

      {:ok, %{headers: headers, source_row_count: source_row_count, events: events}} ->
        unless Enum.member?(headers, natural_key_header) do
          error = %ParseError{
            file: filename,
            reason: :missing_natural_key_header,
            metadata: %{header: natural_key_header}
          }

          {:error,
           %ParseFailure{
             entity_type: entity_type,
             filename: filename,
             preview_records_by_key: %{},
             diagnostics: [error],
             total_error_count: 1,
             truncated?: false,
             source_row_count: source_row_count,
             first_error_row: nil,
             last_error_row: nil
           }}
        else
          scan(events, entity_type, filename, natural_key_field, natural_key_header, row_parser, source_row_count)
        end
    end
  end

  defp scan(events, entity_type, filename, natural_key_field, natural_key_header, row_parser, source_row_count) do
    initial = %{
      records_by_key: %{},
      seen_keys: MapSet.new(),
      diagnostics: [],
      total_error_count: 0,
      first_error_row: nil,
      last_error_row: nil,
      preview_records_by_key: %{}
    }

    acc =
      Enum.reduce_while(events, initial, fn event, acc ->
        case process_event(event, entity_type, filename, natural_key_field, natural_key_header, row_parser, acc) do
          {:cont, acc} -> {:cont, acc}
          {:halt, acc} -> {:halt, acc}
        end
      end)

    if acc.total_error_count == 0 do
      {:ok,
       %__MODULE__{
         entity_type: entity_type,
         filename: filename,
         records_by_key: acc.records_by_key,
         source_row_count: source_row_count
       }}
    else
      diagnostics =
        if length(acc.diagnostics) > @max_diagnostics do
          Enum.take(acc.diagnostics, @max_diagnostics)
        else
          Enum.reverse(acc.diagnostics)
        end

      truncated? = acc.total_error_count > @max_diagnostics

      {:error,
       %ParseFailure{
         entity_type: entity_type,
         filename: filename,
         preview_records_by_key: acc.preview_records_by_key,
         diagnostics: diagnostics,
         total_error_count: acc.total_error_count,
         truncated?: truncated?,
         source_row_count: source_row_count,
         first_error_row: acc.first_error_row,
         last_error_row: acc.last_error_row
       }}
    end
  end

  defp process_event({:ok, row, row_map}, entity_type, filename, natural_key_field, _natural_key_header, row_parser, acc) do
        case convert_row(row_map, row_parser, filename, entity_type) do
      {:ok, attrs} ->
        key = Map.get(attrs, natural_key_field)

        cond do
          is_nil(key) or key == "" ->
            add_error(acc, filename, :blank_natural_key, row, %{}, nil)

          MapSet.member?(acc.seen_keys, key) ->
            acc =
              if Map.has_key?(acc.preview_records_by_key, key) do
                acc
              else
                Map.update!(acc, :preview_records_by_key, &Map.put(&1, key, Map.get(acc.records_by_key, key, attrs)))
              end

            add_error(acc, filename, :duplicate_natural_key, row, %{key: key}, nil)

          true ->
            {:cont,
             acc
             |> Map.update!(:records_by_key, &Map.put(&1, key, attrs))
             |> Map.update!(:seen_keys, &MapSet.put(&1, key))}
        end

      {:error, reason} ->
        metadata =
          case reason do
            reason when is_atom(reason) -> %{cause: reason}
            reason when is_binary(reason) and byte_size(reason) <= 64 -> %{cause: reason}
            _ -> %{}
          end

        add_error(acc, filename, :semantic_row, row, metadata, nil)

      :unexpected ->
        add_error(acc, filename, :unexpected_parser_failure, row, %{}, nil)
    end
  end

  defp process_event({:error, error}, _entity_type, _filename, _natural_key_field, _natural_key_header, _row_parser, acc) do
    add_error(acc, error.file, error.reason, error.row, error.metadata, nil)
  end

  defp convert_row(row_map, row_parser, filename, entity_type) do
    try do
      row_parser.(row_map)
    rescue
      kind ->
        log_unexpected(kind, filename, entity_type)
        :unexpected
    catch
      :exit, _ ->
        log_unexpected(:exit, filename, entity_type)
        :unexpected

      thrown ->
        log_unexpected({:throw, thrown}, filename, entity_type)
        :unexpected
    end
  end

  defp log_unexpected(kind, filename, entity_type) do
    class = unexpected_class(kind)

    :ok =
      Logger.warning(fn ->
        "Reviewed entity parser callback failed: filename=#{filename} entity_type=#{entity_type} class=#{class}"
      end)

    :ok
  end

  defp unexpected_class(%{__struct__: mod}), do: inspect(mod)
  defp unexpected_class(kind) when is_atom(kind), do: inspect(kind)
  defp unexpected_class({:throw, _}), do: "throw"
  defp unexpected_class(_), do: "exit"

  defp add_error(acc, file, reason, row, metadata, _extra) do
    error = %ParseError{file: file, row: row, reason: reason, metadata: metadata}
    first_error_row = if is_nil(acc.first_error_row), do: row, else: acc.first_error_row

    diagnostics =
      if length(acc.diagnostics) < @max_diagnostics do
        [error | acc.diagnostics]
      else
        acc.diagnostics
      end

    {:cont,
     acc
     |> Map.put(:diagnostics, diagnostics)
     |> Map.update!(:total_error_count, &(&1 + 1))
     |> Map.put(:first_error_row, first_error_row)
     |> Map.put(:last_error_row, row)}
  end
end
