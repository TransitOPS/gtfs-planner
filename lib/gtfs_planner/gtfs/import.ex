defmodule GtfsPlanner.Gtfs.Import do
  @moduledoc """
  Context module for importing GTFS data files.

  Handles parsing and importing GTFS data from staged CSV files including:
  - `routes.txt` - Transit routes
  - `calendar.txt` - Service periods
  - `calendar_dates.txt` - Service exceptions
  - `route_patterns.txt` - Route patterns (MBTA extension)
  - `trips.txt` - Trips
  - `levels.txt` - Level/floor definitions for stations
  - `stops.txt` - Stop/station locations and metadata
  - `stop_times.txt` - Stop times for trips
  - `pathways.txt` - Pathways connecting stops within stations
  - `pathway_evolutions.txt` - Scheduled station closures (supported subset)

  All imports are executed within a single database transaction to ensure
  data consistency. Files are processed in dependency order to satisfy
  foreign key constraints.

  Uses batch processing to avoid Erlang atom table exhaustion and memory
  issues with large files. Files are never held in memory as a whole: callers pass
  descriptors of files on disk (see `GtfsPlanner.Gtfs.Import.SourceStorage`) and
  each file is streamed from its path.

  ## Usage

      files = [
        %{filename: "routes.txt", path: "/path/to/routes.source"},
        %{filename: "stops.txt", path: "/path/to/stops.source"},
        %{filename: "pathways.txt", path: "/path/to/pathways.source"}
      ]

      case Import.import_files(org_id, version_id, files, nil, expand_dir: expand_dir) do
        {:ok, %Import.Result{} = result} ->
          # Import successful, topic can be used to subscribe to progress
        {:error, %Import.Failure{} = failure} ->
          # Import failed; `failure` carries the phase, outcome, durable
          # committed counts, certainty, sanitized file/row, and reason code
      end
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Extensions
  alias GtfsPlanner.Gtfs.Import.BatchProcessor
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Import.Failure
  alias GtfsPlanner.Gtfs.Import.ParseError
  alias GtfsPlanner.Gtfs.Import.Result
  alias GtfsPlanner.Gtfs.Import.RowParser
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions

  import Ecto.Query, only: [from: 2]

  require Logger

  @batch_size Application.compile_env(:gtfs_planner, :import_batch_size, 1000)

  @import_specs [
    # Phase 1
    {:agencies, "agency.txt", Gtfs.Agency, &RowParser.agency_row_to_attrs/3, :phase_1},
    {:feed_info, "feed_info.txt", Gtfs.FeedInfo, &RowParser.feed_info_row_to_attrs/3, :phase_1},
    {:levels, "levels.txt", Gtfs.Level, &RowParser.level_row_to_attrs/3, :phase_1},
    {:areas, "areas.txt", Gtfs.Area, &RowParser.area_row_to_attrs/3, :phase_1},
    {:networks, "networks.txt", Gtfs.Network, &RowParser.network_row_to_attrs/3, :phase_1},
    {:fare_media, "fare_media.txt", Gtfs.FareMedia, &RowParser.fare_media_row_to_attrs/3,
     :phase_1},
    {:rider_categories, "rider_categories.txt", Gtfs.RiderCategory,
     &RowParser.rider_category_row_to_attrs/3, :phase_1},
    {:booking_rules, "booking_rules.txt", Gtfs.BookingRule,
     &RowParser.booking_rule_row_to_attrs/3, :phase_1},
    {:locations, "locations.txt", Gtfs.Location, &RowParser.location_row_to_attrs/3, :phase_1},
    {:routes, "routes.txt", Gtfs.Route, &RowParser.route_row_to_attrs/3, :phase_1},
    {:calendars, "calendar.txt", Gtfs.Calendar, &RowParser.calendar_row_to_attrs/3, :phase_1},
    {:calendar_dates, "calendar_dates.txt", Gtfs.CalendarDate,
     &RowParser.calendar_date_row_to_attrs/3, :phase_1},
    {:calendar_attributes, "calendar_attributes.txt", Gtfs.CalendarAttribute,
     &RowParser.calendar_attribute_row_to_attrs/3, :phase_1},
    {:route_patterns, "route_patterns.txt", Gtfs.RoutePattern,
     &RowParser.route_pattern_row_to_attrs/3, :phase_1},
    {:route_networks, "route_networks.txt", Gtfs.RouteNetwork,
     &RowParser.route_network_row_to_attrs/3, :phase_1},
    {:fare_attributes, "fare_attributes.txt", Gtfs.FareAttribute,
     &RowParser.fare_attribute_row_to_attrs/3, :phase_1},
    {:fare_rules, "fare_rules.txt", Gtfs.FareRule, &RowParser.fare_rule_row_to_attrs/3, :phase_1},
    {:fare_products, "fare_products.txt", Gtfs.FareProduct,
     &RowParser.fare_product_row_to_attrs/3, :phase_1},
    {:timeframes, "timeframes.txt", Gtfs.Timeframe, &RowParser.timeframe_row_to_attrs/3,
     :phase_1},
    {:trips, "trips.txt", Gtfs.Trip, &RowParser.trip_row_to_attrs/3, :phase_1},
    {:stops, "stops.txt", Gtfs.Stop, &RowParser.stop_row_to_attrs/3, :phase_1},
    {:pathways, "pathways.txt", Gtfs.Pathway, &RowParser.pathway_row_to_attrs/3, :phase_1},
    # Scheduled closures reference `pathways` and native calendar rows, so the
    # file is registered immediately after `pathways.txt` and before every other
    # dependent file. The entry also fixes the recovery order: `cleanup_schemas/0`
    # reverses the manifest, so closures are deleted before the pathways they
    # reference and the composite pathway foreign key never blocks cleanup.
    {:pathway_evolutions, "pathway_evolutions.txt", Gtfs.PathwayEvolution,
     &RowParser.pathway_evolution_row_to_attrs/3, :phase_1},
    {:transfers, "transfers.txt", Gtfs.Transfer, &RowParser.transfer_row_to_attrs/3, :phase_1},
    {:stop_areas, "stop_areas.txt", Gtfs.StopArea, &RowParser.stop_area_row_to_attrs/3, :phase_1},
    {:frequencies, "frequencies.txt", Gtfs.Frequency, &RowParser.frequency_row_to_attrs/3,
     :phase_1},
    {:attributions, "attributions.txt", Gtfs.Attribution, &RowParser.attribution_row_to_attrs/3,
     :phase_1},
    {:fare_leg_rules, "fare_leg_rules.txt", Gtfs.FareLegRule,
     &RowParser.fare_leg_rule_row_to_attrs/3, :phase_1},
    {:fare_leg_join_rules, "fare_leg_join_rules.txt", Gtfs.FareLegJoinRule,
     &RowParser.fare_leg_join_rule_row_to_attrs/3, :phase_1},
    {:fare_transfer_rules, "fare_transfer_rules.txt", Gtfs.FareTransferRule,
     &RowParser.fare_transfer_rule_row_to_attrs/3, :phase_1},
    {:translations, "translations.txt", Gtfs.Translation, &RowParser.translation_row_to_attrs/3,
     :phase_1},
    # Phase 2
    {:stop_times, "stop_times.txt", Gtfs.StopTime, &RowParser.stop_time_row_to_attrs/3, :phase_2},
    {:shapes, "shapes.txt", Gtfs.Shape, &RowParser.shape_row_to_attrs/3, :phase_2}
  ]

  @filename_to_spec Map.new(@import_specs, fn {_key, filename, _schema, _parser_fun, _phase} =
                                                spec ->
                      {String.downcase(filename), spec}
                    end)
  @phase_1_specs Enum.filter(@import_specs, fn {_k, _f, _s, _p, phase} -> phase == :phase_1 end)
  @phase_2_specs Enum.filter(@import_specs, fn {_k, _f, _s, _p, phase} -> phase == :phase_2 end)
  @file_count_keys Enum.map(@import_specs, fn {key, _f, _s, _p, _phase} -> key end)
  # Bounded integer counters produced by route-pattern derivation. They share the
  # count-key allowlist with the file counts so `Import.Run` accepts them as
  # integers and never as a serialized status string.
  @derivation_count_keys ~w(patterns_created timings_created trips_linked trips_custom)a
  @supported_count_keys @file_count_keys ++ @derivation_count_keys

  # App-owned pattern tables are deleted child-before-parent. `TimedPatternStop`
  # has no organization column and is scoped through its timed-pattern parent.
  @cleanup_pattern_schemas [
    GtfsPlanner.Gtfs.TimedPatternStop,
    GtfsPlanner.Gtfs.TimedPattern,
    GtfsPlanner.Gtfs.RoutePatternStop
  ]

  @doc """
  Imports GTFS data files with optimized transaction handling.

  Small files are processed in a single transaction for atomicity.
  Large files (stop_times) are processed separately with batch-level
  transactions to prevent long-running transactions and connection timeouts.

  Progress is broadcast via PubSub on the returned topic for LiveView consumption.

  ## Parameters

    - `organization_id` - UUID of the organization
    - `gtfs_version_id` - UUID of the GTFS version to associate records with
    - `files` - List of `%{filename: string, path: Path.t()}` descriptors. `filename` is the
      uploaded name and decides the file's category; `path` is the file to read, which must
      stay in place until the import returns because each file is streamed in two passes.
    - `topic` - (optional) PubSub topic for progress updates. If not provided, one will be generated.
    - `opts`
      - `:expand_dir` (required) - a directory dedicated to this import, where `.zip`
        descriptors are expanded one subdirectory per archive. Its extracted files are
        read in place and are not removed here; the caller owns the directory.
      - `:fence` - `{run_id, lease_token}` of the claimed run that owns this
        import. Every write transaction (phase 1, each phase 2 batch, each derivation write and
        the extension transaction) first verifies, under a run-row share lock, that the run is
        `running` under that token with an unexpired lease (INV-4). Without it nothing is verified.

  ## Returns

    - `{:ok, %Import.Result{}}` on success
      - `counts` - map with keys for each file type containing import counts
      - `unrecognized_files` - list of unrecognized filenames
      - `topic` - PubSub topic for progress updates
      - `archive_warnings` - list of `%{filename, reason, detail}` maps for archives that could not be expanded
      - `extensions` - `:not_present` when no extension manifest was supplied, or `:complete` when the extension phase finished fully
    - `{:error, %Import.Failure{}}` on failure, carrying the phase, outcome,
      durable committed counts, count certainty, sanitized file/row, and a fixed
      reason code
    - `{:error, :lease_lost}` when a fenced write found the run handed over; that
      transaction wrote nothing and no later write is attempted

  ## Examples

      iex> files = [%{filename: "routes.txt", path: "/tmp/run/source/routes.source"}]
      iex> import_files(org_id, version_id, files, nil, expand_dir: "/tmp/run/expanded")
      {:ok, %Import.Result{counts: %{routes: 1, stops: 0, ...}, unrecognized_files: [], topic: "import:123456", archive_warnings: [], extensions: :not_present}}
  """
  def import_files(organization_id, gtfs_version_id, files, topic \\ nil, opts \\ []) do
    # Generate a stable progress topic before work begins so the supervised
    # runner can durably attribute an unexpected worker exit to the active phase.
    topic = topic || "import:#{:erlang.unique_integer()}"
    fence = fence_callback(organization_id, Keyword.get(opts, :fence))
    broadcast_phase(topic, :phase_1)

    # Expand any staged .zip archives into the import's private directory; members
    # stay on disk and are streamed from there.
    {files, archive_warnings} = expand_staged_archives(files, Keyword.fetch!(opts, :expand_dir))

    # Categorize files by filename (case-insensitive)
    {categorized, unrecognized_files, extensions} = categorize_files(files)

    with {:ok, counts} <-
           import_phase_1(categorized, organization_id, gtfs_version_id, topic, fence),
         {:ok, counts} <-
           import_phase_2(categorized, counts, organization_id, gtfs_version_id, topic, fence),
         counts = fill_standard_counts(counts),
         {:ok, counts} <-
           maybe_derive_patterns(counts, organization_id, gtfs_version_id, topic, fence),
         _ = broadcast_phase(topic, :extensions),
         {:ok, extensions_status, counts} <-
           import_extensions_phase(organization_id, gtfs_version_id, extensions, counts, fence) do
      {:ok,
       %Result{
         counts: counts,
         unrecognized_files: unrecognized_files,
         topic: topic,
         archive_warnings: archive_warnings,
         extensions: extensions_status
       }}
    end
  end

  # `fence: {run_id, lease_token}` names the claimed run that owns this import. A
  # fenced write transaction calls the callback as its first statement; it locks the
  # run `FOR SHARE` and rolls the transaction back with `:lease_lost` unless the run is
  # still `running` under the token with an unexpired lease, so a superseded worker
  # commits nothing (INV-4). Without a fence, as for direct callers, nothing is checked.
  defp fence_callback(_organization_id, nil), do: nil

  defp fence_callback(organization_id, {run_id, lease_token}) do
    fn -> ImportRuns.assert_owner!(organization_id, run_id, lease_token, ~w(running)) end
  end

  # Phase 1 imports the core files in a single transaction for atomicity, so its
  # counts only become durable after that transaction commits: a Phase 1 failure
  # means every standard count is zero. One fence check at its start covers the
  # non-transactional `insert_batched` calls inside it.
  #
  # Phase 1 replaces `calendars`, `calendar_dates`, `trips` and `pathway_evolutions`,
  # which are the exact rows a reviewed calendar extension binds. After the fence's
  # run lock, the version row is locked `FOR SHARE` before any row this phase writes,
  # so an extension apply holding the same version `FOR UPDATE` cannot interleave a
  # fresh trip or closure set between a review and its apply. A staging or importing
  # scope locks exactly like a published one, so this does not restrict the normal
  # import flow.
  defp import_phase_1(categorized, organization_id, gtfs_version_id, topic, fence) do
    result =
      Repo.transaction(fn ->
        if fence, do: fence.()
        Versions.lock_for_input_write!(organization_id, gtfs_version_id)
        import_phase_1_files(categorized, organization_id, gtfs_version_id, topic)
      end)

    case result do
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> failure(reason, :phase_1, %{})
    end
  end

  # Runs inside the phase 1 transaction: the first rejected file rolls it back.
  defp import_phase_1_files(categorized, organization_id, gtfs_version_id, topic) do
    Enum.reduce_while(@phase_1_specs, %{}, fn {key, _filename, schema, parser_fun, _phase},
                                              counts ->
      case process_file_category(
             categorized[key] || [],
             organization_id,
             gtfs_version_id,
             topic,
             key,
             schema,
             parser_fun
           ) do
        {:ok, count} -> {:cont, Map.put(counts, key, count)}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp import_phase_2(categorized, counts, organization_id, gtfs_version_id, topic, fence) do
    broadcast_phase(topic, :phase_2)

    result =
      Enum.reduce_while(@phase_2_specs, {:ok, counts}, fn
        {key, _filename, schema, parser_fun, _phase}, {:ok, acc_counts} ->
          case process_phase_2_category(
                 categorized[key] || [],
                 organization_id,
                 gtfs_version_id,
                 topic,
                 schema,
                 parser_fun,
                 fence
               ) do
            {:ok, count} ->
              {:cont, {:ok, Map.put(acc_counts, key, count)}}

            {:error, reason, committed} ->
              # Report all earlier committed counts plus this file's durable
              # committed-batch count.
              {:halt, {:error, reason, Map.put(acc_counts, key, committed)}}
          end
      end)

    case result do
      {:ok, counts} -> {:ok, counts}
      {:error, reason, committed} -> failure(reason, :phase_2, committed)
    end
  end

  # The error result for a failed phase. A lost fence is not a reportable failure: the
  # run was handed over, so nothing can close it and the caller only needs to stop.
  defp failure(:lease_lost, _phase, _committed_counts), do: {:error, :lease_lost}

  defp failure(reason, phase, committed_counts),
    do: {:error, build_failure(reason, phase, committed_counts)}

  # Builds a truthful, sanitized failure. Missing standard counts are filled with
  # zero so the durable count map is always complete and bounded. The outcome is
  # `:partial` when any durable rows were committed, otherwise `:failed`.
  defp build_failure(reason, phase, committed_counts) do
    committed_counts = fill_standard_counts(committed_counts)
    outcome = if standard_count_total(committed_counts) > 0, do: :partial, else: :failed

    Failure.from_error(reason,
      phase: phase,
      outcome: outcome,
      committed_counts: committed_counts,
      counts_complete: true
    )
  end

  defp broadcast_phase(topic, phase) do
    Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, topic, {:import_phase, phase})
  end

  defp fill_standard_counts(counts) do
    Enum.reduce(@supported_count_keys, counts, &Map.put_new(&2, &1, 0))
  end

  defp standard_count_total(counts) do
    Enum.reduce(@file_count_keys, 0, fn key, total ->
      case Map.get(counts, key, 0) do
        value when is_integer(value) and value > 0 -> total + value
        _ -> total
      end
    end)
  end

  # Derivation runs after Phase 2 and before extension completion, inside the
  # importer's existing exact-target ownership. An expected route-local failure is
  # non-fatal: the route keeps its bounded error and pending trips for retry. A
  # database failure raises rather than being reported as a clean result. A lost
  # fence stops derivation with `{:error, :lease_lost}`.
  #
  # A feed without imported trips cannot have anything to derive, so the phase is
  # skipped entirely instead of issuing avoidable database work before
  # publication.
  defp maybe_derive_patterns(counts, organization_id, gtfs_version_id, topic, fence) do
    if Map.get(counts, :trips, 0) > 0 do
      broadcast_phase(topic, :derivation)

      with {:ok, summary} <- run_derivation(organization_id, gtfs_version_id, fence) do
        {:ok, Map.merge(counts, summary)}
      end
    else
      {:ok, counts}
    end
  end

  defp run_derivation(organization_id, gtfs_version_id, fence) do
    case Derivation.derive_version(organization_id, gtfs_version_id, {:import, fence}) do
      {:ok, summary} ->
        if summary.routes_failed > 0 do
          Logger.warning(
            "Route pattern derivation failed for #{summary.routes_failed} route(s) in version " <>
              "#{gtfs_version_id}; retry metadata is persisted on those routes"
          )
        end

        {:ok, Map.take(summary, @derivation_count_keys)}

      {:error, :lease_lost} = lost ->
        lost
    end
  end

  # Processes phase 2 files with batch-level transactions.
  # Each batch gets its own transaction to prevent long-running transactions, so
  # committed batches survive a later failure. Returns `{:ok, count}` or
  # `{:error, reason, committed}` where `committed` is the durable row count.
  defp process_phase_2_category(
         files,
         organization_id,
         gtfs_version_id,
         topic,
         schema,
         row_to_attrs_fn,
         fence
       ) do
    insert = fn file, parsed ->
      BatchProcessor.insert_batched_with_transactions(
        Repo,
        schema,
        parsed.events,
        row_to_attrs_fn,
        file
        |> batch_options(parsed, organization_id, gtfs_version_id, topic)
        |> Keyword.put(:fence, fence)
      )
    end

    process_phase_2_files(files, insert)
  end

  defp process_phase_2_files(files, insert) do
    Enum.reduce_while(files, {:ok, 0}, fn file, {:ok, count} ->
      case process_phase_2_file(file, insert) do
        {:ok, inserted} -> {:cont, {:ok, count + inserted}}
        {:error, reason, committed} -> {:halt, {:error, reason, count + committed}}
      end
    end)
  end

  defp process_phase_2_file(file, insert) do
    case CsvParser.stream_file(file.filename, file.path) do
      {:ok, parsed} ->
        case insert.(file, parsed) do
          {:ok, inserted} -> {:ok, inserted}
          {:error, reason, committed} -> {:error, reason, committed}
        end

      # A parser failure happens before any batch is committed for this file.
      {:error, reason} ->
        {:error, reason, 0}
    end
  end

  # Scheduled closures are the one phase-one category whose row function cannot
  # decide the whole contract: a row may parse cleanly and still name a pathway
  # or a service that does not exist in the target scope, or repeat a tuple that
  # is already stored. Those are reference questions, and they need the scoped
  # pathway set, the native calendar set and the version's existing closure
  # tuples, none of which the batch processor's row-function interface carries.
  #
  # So this clause validates the whole category before inserting a single row,
  # then replays the same immutable input events through the unchanged
  # `BatchProcessor.insert_batched/5` interface. The first rejected row ends the
  # category with its own file, source row and bounded code while nothing has
  # been written, and the phase-one transaction still owns publication.
  #
  # The scoped sets are read once for the category, after `pathways.txt`,
  # `calendar.txt` and `calendar_dates.txt` have been inserted in the same
  # transaction, so a closure may reference a pathway or service that this very
  # import created. Duplicate tuples are carried across every file and every
  # batch of the category and reported against the repeating row's own source
  # row, so the recorded row identifies the offender rather than the first
  # occurrence.
  defp process_file_category(
         files,
         organization_id,
         gtfs_version_id,
         topic,
         :pathway_evolutions,
         schema,
         row_to_attrs_fn
       ) do
    with {:ok, parsed_files} <- parse_evolution_files(files),
         :ok <-
           validate_evolution_files(
             parsed_files,
             evolution_reference_state(organization_id, gtfs_version_id),
             row_to_attrs_fn
           ) do
      insert_evolution_files(
        parsed_files,
        organization_id,
        gtfs_version_id,
        topic,
        schema,
        row_to_attrs_fn
      )
    end
  end

  # Processes a category of files using batch insertion
  defp process_file_category(
         files,
         organization_id,
         gtfs_version_id,
         topic,
         _file_type,
         schema,
         row_to_attrs_fn
       ) do
    insert = fn file, parsed ->
      BatchProcessor.insert_batched(
        Repo,
        schema,
        parsed.events,
        row_to_attrs_fn,
        batch_options(file, parsed, organization_id, gtfs_version_id, topic)
      )
    end

    process_category_files(files, insert)
  end

  # Each file is opened once to validate it; the event stream re-reads the staged
  # file on every enumeration, so the validation pass and the insertion pass observe
  # the identical events. A file-level parse failure (header, quoting, encoding)
  # passes through unchanged.
  defp parse_evolution_files(files) do
    files
    |> Enum.reduce_while({:ok, []}, &accumulate_parsed_file/2)
    |> case do
      {:ok, parsed_files} -> {:ok, Enum.reverse(parsed_files)}
      {:error, _reason} = error -> error
    end
  end

  defp accumulate_parsed_file(file, {:ok, acc}) do
    case CsvParser.stream_file(file.filename, file.path) do
      {:ok, parsed} -> {:cont, {:ok, [{file, parsed} | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_evolution_files(parsed_files, state, row_to_attrs_fn) do
    Enum.reduce_while(parsed_files, {:ok, state}, fn {file, parsed}, {:ok, state} ->
      case validate_evolution_events(parsed.events, file.filename, row_to_attrs_fn, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _state} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_evolution_events(events, file_name, row_to_attrs_fn, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case validate_evolution_event(event, file_name, row_to_attrs_fn, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A structural CSV failure keeps its own `ParseError` (with its bounded parser
  # reason) rather than being reported as a rejected row.
  defp validate_evolution_event(
         {:error, %ParseError{} = parse_error},
         _file_name,
         _row_to_attrs_fn,
         _state
       ),
       do: {:error, parse_error}

  defp validate_evolution_event(
         {:ok, row_number, row_map},
         file_name,
         row_to_attrs_fn,
         state
       ) do
    case row_to_attrs_fn.(row_map, state.organization_id, state.gtfs_version_id) do
      {:ok, attrs} -> check_evolution_references(file_name, row_number, attrs, state)
      {:error, reason} -> {:error, evolution_row_error(file_name, row_number, reason)}
    end
  end

  defp check_evolution_references(file_name, row_number, attrs, state) do
    tuple = {attrs.pathway_id, attrs.service_id, attrs.start_time, attrs.end_time}

    cond do
      not MapSet.member?(state.pathway_ids, attrs.pathway_id) ->
        evolution_rejected(file_name, row_number, :evolution_pathway_missing)

      not MapSet.member?(state.service_ids, attrs.service_id) ->
        evolution_rejected(file_name, row_number, :evolution_service_missing)

      MapSet.member?(state.tuples, tuple) ->
        evolution_rejected(file_name, row_number, :evolution_duplicate)

      true ->
        {:ok, %{state | tuples: MapSet.put(state.tuples, tuple)}}
    end
  end

  defp evolution_rejected(file_name, row_number, code) do
    {:error, evolution_row_error(file_name, row_number, {:evolution_rejected, code})}
  end

  # The one shape `Failure` reads a bounded closure code from. The rejected row's
  # values are never part of the term, so no row text can reach the run record.
  defp evolution_row_error(file_name, row_number, reason) do
    %{file: file_name, row: row_number, reason: reason}
  end

  defp evolution_reference_state(organization_id, gtfs_version_id) do
    %{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      pathway_ids: scoped_pathway_ids(organization_id, gtfs_version_id),
      service_ids: PathwayEvolutions.native_service_ids(organization_id, gtfs_version_id),
      tuples: existing_evolution_tuples(organization_id, gtfs_version_id)
    }
  end

  defp scoped_pathway_ids(organization_id, gtfs_version_id) do
    from(p in Pathway,
      where: p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id,
      select: p.pathway_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # The unique closure index covers organization, version and the four reference
  # and window columns, so the in-scope tuples are exactly what a new row would
  # collide with.
  defp existing_evolution_tuples(organization_id, gtfs_version_id) do
    from(e in PathwayEvolution,
      where: e.organization_id == ^organization_id and e.gtfs_version_id == ^gtfs_version_id,
      select: {e.pathway_id, e.service_id, e.start_time, e.end_time}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp insert_evolution_files(
         parsed_files,
         organization_id,
         gtfs_version_id,
         topic,
         schema,
         row_to_attrs_fn
       ) do
    parsed_files
    |> Enum.reduce_while(0, fn {file, parsed}, count ->
      case BatchProcessor.insert_batched(
             Repo,
             schema,
             parsed.events,
             row_to_attrs_fn,
             batch_options(file, parsed, organization_id, gtfs_version_id, topic)
           ) do
        {:ok, inserted} -> {:cont, count + inserted}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> normalize_category_count()
  end

  defp process_category_files(files, insert) do
    files
    |> Enum.reduce_while(0, fn file, count -> process_category_file(file, count, insert) end)
    |> normalize_category_count()
  end

  defp process_category_file(file, count, insert) do
    with {:ok, parsed} <- CsvParser.stream_file(file.filename, file.path),
         {:ok, inserted} <- insert.(file, parsed) do
      {:cont, count + inserted}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_category_count({:error, _} = error), do: error
  defp normalize_category_count(count), do: {:ok, count}

  defp batch_options(file, parsed, organization_id, gtfs_version_id, topic) do
    [
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      file_name: file.filename,
      topic: topic,
      batch_size: @batch_size,
      total_rows: parsed.source_row_count
    ]
  end

  # Categorizes files by filename into file type buckets.
  # Returns {categorized, unrecognized, extensions} where extensions is a map
  # with optional :json (manifest path) and :images (`%{zip_path => path}`) keys
  # for _pathways_extensions data.
  defp categorize_files(files) do
    initial_categorized = Map.new(@file_count_keys, fn key -> {key, []} end)
    initial_acc = {initial_categorized, [], %{}}

    {categorized, unrecognized, extensions} =
      Enum.reduce(files, initial_acc, fn file, {acc, unrecognized_acc, ext_acc} ->
        normalized_filename = normalize_uploaded_filename(file.filename)
        lower = String.downcase(normalized_filename)
        basename = Path.basename(lower)

        cond do
          Map.has_key?(@filename_to_spec, basename) ->
            {key, _filename, _schema, _parser_fun, _phase} =
              Map.fetch!(@filename_to_spec, basename)

            normalized_file = %{file | filename: basename}
            {Map.update!(acc, key, &[normalized_file | &1]), unrecognized_acc, ext_acc}

          basename == "_pathways_extensions.json" ->
            {acc, unrecognized_acc, Map.put(ext_acc, :json, file.path)}

          is_binary(extract_extensions_image_zip_path(normalized_filename)) ->
            image_zip_path = extract_extensions_image_zip_path(normalized_filename)
            images = Map.get(ext_acc, :images, %{})
            images = Map.put(images, image_zip_path, file.path)
            {acc, unrecognized_acc, Map.put(ext_acc, :images, images)}

          true ->
            {acc, [normalized_filename | unrecognized_acc], ext_acc}
        end
      end)

    categorized =
      Map.new(categorized, fn {key, files_list} -> {key, Enum.reverse(files_list)} end)

    {categorized, Enum.reverse(unrecognized), extensions}
  end

  @doc """
  Returns all supported import filenames.
  """
  def supported_filenames do
    Enum.map(@import_specs, fn {_key, filename, _schema, _parser_fun, _phase} -> filename end)
  end

  @doc false
  def import_specs, do: @import_specs

  @doc """
  Returns all supported import count keys.

  The file-backed counts plus the bounded route-pattern derivation counters. The
  derivation counters are plain non-negative integers, so the `Import.Run` count
  allowlist accepts them without a separate status channel.
  """
  def supported_count_keys do
    @supported_count_keys
  end

  @doc """
  Returns the reverse-dependency-ordered list of schema modules that cleanup
  deletes when discarding a failed import target.

  The list shares the same source (`@import_specs`) as `supported_filenames/0`,
  so a supported file can never exist without cleanup ownership (INV-4/INV-5).
  The schemas are returned in reverse import order so that child rows are removed
  before their parents; `GtfsPlanner.Gtfs.StopLevel` (an extension schema not
  backed by a standard GTFS file) and the app-owned pattern tables are prepended
  because their rows must be removed first. The pattern tables are ordered
  child-before-parent: timed-pattern rows, timed patterns, pattern occurrences,
  then the imported `route_patterns` rows later in the reversed list.
  """
  @spec cleanup_schemas() :: [module()]
  def cleanup_schemas do
    schemas = Enum.map(@import_specs, fn {_key, _filename, schema, _parser, _phase} -> schema end)
    [GtfsPlanner.Gtfs.StopLevel | @cleanup_pattern_schemas] ++ Enum.reverse(schemas)
  end

  @max_zip_entries 10_000
  @default_max_zip_uncompressed_bytes 500 * 1024 * 1024
  @default_max_zip_entry_uncompressed_bytes 500 * 1024 * 1024

  @doc false
  def zip_limits do
    max_total_bytes =
      configured_zip_limit(
        :import_max_zip_uncompressed_bytes,
        @default_max_zip_uncompressed_bytes
      )

    max_entry_bytes =
      configured_zip_limit(
        :import_max_zip_entry_uncompressed_bytes,
        min(max_total_bytes, @default_max_zip_entry_uncompressed_bytes)
      )

    %{
      max_entries: @max_zip_entries,
      max_total_bytes: max_total_bytes,
      max_entry_bytes: min(max_entry_bytes, max_total_bytes)
    }
  end

  @doc """
  Expands in-memory `.zip` uploads into `%{filename, content}` entries.

  An adapter over `expand_staged_archives/2` for callers that still hold file
  contents (change review). Each archive is written to a private temporary
  directory, expanded there, read back and removed. Non-zip entries pass through
  unchanged. Full imports do not use it: they expand staged files in the run's
  directory through `expand_staged_archives/2`.

  Returns `{expanded_files, archive_warnings}` where `archive_warnings` is a list
  of `%{filename: String.t(), reason: atom(), detail: String.t()}` maps describing
  archives or members that were rejected.
  """
  def expand_archives(files) do
    root = Path.join(System.tmp_dir!(), "gtfs-import-expand-#{Ecto.UUID.generate()}")

    try do
      staged =
        files
        |> Enum.with_index()
        |> Enum.map(fn {file, index} -> stage_archive(file, root, index) end)

      {expanded, warnings} = expand_staged_archives(staged, Path.join(root, "expanded"))
      {Enum.map(expanded, &read_member/1), warnings}
    after
      File.rm_rf(root)
    end
  end

  defp stage_archive(file, root, index) do
    if zip_file?(file) do
      path = Path.join([root, "archives", "#{index}.zip"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, file.content)
      %{filename: file.filename, path: path}
    else
      file
    end
  end

  defp read_member(%{path: path, filename: filename}),
    do: %{filename: filename, content: File.read!(path)}

  defp read_member(file), do: file

  @doc """
  Expands the `.zip` descriptors in `files` under `dir`, one subdirectory per archive.

  `files` is a list of `%{filename, path}` descriptors. Each zip goes through
  `expand_archive/3` into `dir/<index>`, so same-named members of different archives
  cannot overwrite each other. Other descriptors pass through unchanged.

  Returns `{files, archive_warnings}` with the pass-through descriptors and the
  extracted members in upload order. No file contents are read.
  """
  def expand_staged_archives(files, dir) when is_list(files) and is_binary(dir) do
    limits = zip_limits()

    {files_acc, warnings_acc} =
      files
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {file, index}, {files_acc, warnings_acc} ->
        if zip_file?(file) do
          {members, warnings} =
            expand_archive(file, Path.join(dir, Integer.to_string(index)), limits)

          {Enum.reverse(members, files_acc), Enum.reverse(warnings, warnings_acc)}
        else
          {[file | files_acc], warnings_acc}
        end
      end)

    {Enum.reverse(files_acc), Enum.reverse(warnings_acc)}
  end

  defp zip_file?(file), do: String.ends_with?(String.downcase(file.filename), ".zip")

  @doc """
  Preflights and extracts one staged `.zip` into `dir`.

  `file` is `%{filename, path}`: the upload's name, used in warnings, and the
  archive's path. `preflight_archive/2` runs first, so an archive that is unreadable,
  over a limit or repeats a member name is rejected before `dir` is touched, and only
  the accepted members are extracted. The extracted files' sizes are then checked
  against the same limits; if extraction fails or a size is over, `dir` is removed.
  `dir` must be dedicated to this archive.

  Returns `{members, warnings}`. `members` is a list of `%{filename, path}`:
  `filename` is the member's normalized archive-relative name and `path` the absolute
  extracted file. It is empty when the whole archive is rejected. `warnings` has the
  same shape as in `expand_archives/1`.

  Extraction streams each member to disk, and a member whose header understates its
  size is only caught by the size check afterwards, not bounded while it is written.
  """
  def expand_archive(file, dir, limits) do
    case preflight_archive(file, limits) do
      {:ok, [], warnings} ->
        {[], warnings}

      {:ok, accepted, warnings} ->
        extract_members(file, Path.expand(dir), accepted, limits, warnings)

      {:error, warnings} ->
        {[], warnings}
    end
  end

  defp extract_members(file, dir, accepted, limits, warnings) do
    File.mkdir_p!(dir)

    case unzip_members(file, dir, accepted, limits) do
      {:ok, members} ->
        {members, warnings}

      error ->
        File.rm_rf(dir)
        {[], warnings ++ [extraction_warning(file, limits, error)]}
    end
  end

  defp unzip_members(file, dir, accepted, limits) do
    options = [{:cwd, String.to_charlist(dir)}, {:file_list, accepted}]

    # `:zip` extracts by the name in each member's local header and skips one that
    # climbs above `dir`, even when the directory entry looked safe. A short result
    # means a member was not extracted.
    with {:ok, written} when length(written) == length(accepted) <-
           :zip.unzip(String.to_charlist(file.path), options),
         members = Enum.map(written, &extracted_member(&1, dir)),
         :ok <- ensure_members_within_root(members, dir),
         {:ok, _count, _total} <-
           members
           |> Enum.map(&File.stat!(&1.path).size)
           |> check_zip_entry_sizes_against_limits(limits) do
      {:ok, members}
    else
      {:ok, _written} -> {:error, :member_mismatch}
      error -> error
    end
  end

  defp extracted_member(written, dir) do
    path = List.to_string(written)
    %{filename: path |> Path.relative_to(dir) |> normalize_uploaded_filename(), path: path}
  end

  defp ensure_members_within_root(members, dir) do
    Enum.find_value(members, :ok, fn member ->
      case Extensions.PathSafety.ensure_within_root(dir, member.path) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp extraction_warning(file, limits, {:error, reason, count, total, entry}),
    do: archive_too_large_warning(file, limits, {reason, count, total, entry}, " after expansion")

  defp extraction_warning(file, _limits, {:error, reason}),
    do: unreadable_archive_warning(file, reason, "expand")

  @doc """
  Reads a staged `.zip`'s directory and decides which members to extract, without
  extracting anything.

  Every entry counts toward the entry-count and declared-size limits, including
  ignored and rejected ones. Members whose name is absolute, has a `..` segment (after
  turning `\\` into `/`) or contains a NUL byte are dropped with an `:unsafe_member_path`
  warning, and nested `.zip` members with a `:nested_archive` warning. Directories and
  hidden or system entries are dropped silently.

  Returns `{:ok, accepted, warnings}`, where `accepted` holds the member names to
  extract as the archive spells them, or `{:error, warnings}` when the archive is
  unreadable, over a limit or repeats a member name. The last warning then names the
  reason.
  """
  def preflight_archive(file, limits) do
    case :zip.list_dir(String.to_charlist(file.path)) do
      {:ok, entries} ->
        members =
          for {:zip_file, name, info, _comment, _offset, _comp_size} <- entries,
              do: {name, to_string(name), zip_entry_uncompressed_size(info)}

        classify_members(file, members, limits)

      {:error, reason} ->
        {:error, [unreadable_archive_warning(file, reason, "preflight")]}
    end
  end

  defp classify_members(file, members, limits) do
    {accepted, warnings} =
      Enum.reduce(members, {[], []}, fn {name, string, _size}, {accepted, warnings} ->
        case member_disposition(string) do
          :accept ->
            {[name | accepted], warnings}

          :ignore ->
            {accepted, warnings}

          {:reject, reason, filename} ->
            {accepted, [member_warning(file, reason, filename) | warnings]}
        end
      end)

    sizes = Enum.map(members, fn {_name, _string, size} -> size end)
    warnings = Enum.reverse(warnings)

    case check_zip_entry_sizes_against_limits(sizes, limits) do
      {:ok, _count, _total} ->
        accept_unique_members(file, Enum.reverse(accepted), warnings)

      {:error, reason, count, total, entry} ->
        {:error,
         warnings ++ [archive_too_large_warning(file, limits, {reason, count, total, entry}, "")]}
    end
  end

  defp member_disposition(name) do
    filename = normalize_uploaded_filename(name)

    cond do
      unsafe_member_path?(name) -> {:reject, :unsafe_member_path, name}
      ignore_zip_entry?(filename) -> :ignore
      String.ends_with?(String.downcase(filename), ".zip") -> {:reject, :nested_archive, filename}
      true -> :accept
    end
  end

  defp unsafe_member_path?(name) do
    normalized = String.replace(name, "\\", "/")

    String.starts_with?(normalized, "/") or
      String.match?(normalized, ~r/^[A-Za-z]:/) or
      String.contains?(name, <<0>>) or
      ".." in String.split(normalized, "/")
  end

  # Two members that resolve to one destination would leave a single file standing
  # for both, so the descriptors would no longer describe each member's bytes.
  defp accept_unique_members(file, accepted, warnings) do
    destinations =
      Enum.map(accepted, fn name ->
        name |> to_string() |> normalize_uploaded_filename() |> Path.expand("/")
      end)

    if length(Enum.uniq(destinations)) == length(destinations) do
      {:ok, accepted, warnings}
    else
      {:error, warnings ++ [unreadable_archive_warning(file, :duplicate_members, "preflight")]}
    end
  end

  defp member_warning(file, :unsafe_member_path, filename) do
    Logger.warning("Rejecting unsafe zip member #{inspect(filename)} in archive #{file.filename}")

    %{
      filename: file.filename,
      reason: :unsafe_member_path,
      detail: "unsafe member path rejected: #{inspect(filename)}"
    }
  end

  defp member_warning(file, :nested_archive, filename) do
    Logger.warning("Rejecting nested zip entry #{filename} in archive #{file.filename}")

    %{
      filename: file.filename,
      reason: :nested_archive,
      detail: "nested archive rejected: #{filename}"
    }
  end

  defp archive_too_large_warning(
         file,
         limits,
         {reason, entries_count, total_bytes, entry_bytes},
         phase
       ) do
    Logger.warning(
      "Zip archive #{file.filename} exceeds safety limits#{phase} " <>
        "(reason=#{reason}, entries=#{entries_count}, bytes=#{total_bytes}, " <>
        "entry_bytes=#{entry_bytes}, max_entries=#{limits.max_entries}, " <>
        "max_total_bytes=#{limits.max_total_bytes}, " <>
        "max_entry_bytes=#{limits.max_entry_bytes}), skipping expansion"
    )

    %{
      filename: file.filename,
      reason: :archive_too_large,
      detail:
        "exceeds safety limits (#{reason}: #{entries_count} entries, #{total_bytes} bytes uncompressed)"
    }
  end

  defp unreadable_archive_warning(file, reason, phase) do
    Logger.warning("Failed to #{phase} zip archive #{file.filename}: #{inspect(reason)}")

    %{
      filename: file.filename,
      reason: :unzip_failed,
      detail: "archive could not be read (#{inspect(reason)})"
    }
  end

  @doc false
  def zip_entry_sizes_within_limits?(entry_sizes, limits)
      when is_list(entry_sizes) and is_map(limits) do
    match?({:ok, _, _}, check_zip_entry_sizes_against_limits(entry_sizes, limits))
  end

  defp check_zip_entry_sizes_against_limits(entry_sizes, limits) do
    Enum.reduce_while(entry_sizes, {:ok, 0, 0}, fn entry_bytes, {:ok, count, total} ->
      next_count = count + 1
      next_total = total + entry_bytes

      cond do
        next_count > limits.max_entries ->
          {:halt, {:error, :too_many_entries, next_count, next_total, entry_bytes}}

        entry_bytes > limits.max_entry_bytes ->
          {:halt, {:error, :entry_too_large, next_count, next_total, entry_bytes}}

        next_total > limits.max_total_bytes ->
          {:halt, {:error, :total_too_large, next_count, next_total, entry_bytes}}

        true ->
          {:cont, {:ok, next_count, next_total}}
      end
    end)
  end

  defp zip_entry_uncompressed_size({:file_info, size, _, _, _, _, _, _, _, _, _, _, _, _})
       when is_integer(size) and size >= 0 do
    size
  end

  defp zip_entry_uncompressed_size(_), do: 0

  # The zip limit is a config value; the parse itself is Values.positive_integer/2.
  defp configured_zip_limit(key, default) do
    Values.positive_integer(Application.get_env(:gtfs_planner, key, default), default)
  end

  defp normalize_uploaded_filename(filename) when is_binary(filename) do
    filename
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
    |> String.trim_leading("/")
  end

  defp ignore_zip_entry?(filename) do
    lower = String.downcase(filename)
    basename = Path.basename(lower)

    filename == "" or
      String.ends_with?(filename, "/") or
      String.starts_with?(lower, "__macosx/") or
      String.starts_with?(basename, "._") or
      basename == ".ds_store" or
      basename == "thumbs.db"
  end

  defp extract_extensions_image_zip_path(filename) do
    marker = "_pathways_extensions/"
    lower = String.downcase(filename)

    case :binary.match(lower, marker) do
      {idx, _len} -> binary_part(filename, idx, byte_size(filename) - idx)
      :nomatch -> nil
    end
  end

  # Runs the extensions import phase after standard GTFS phases complete.
  # When no extension manifest is present the phase is absent and counts are
  # returned unchanged. On extension failure the standard counts stay durable and
  # any committed extension counts are threaded back so the overall failure can
  # report exact durable truth (AC-3).
  defp import_extensions_phase(_organization_id, _gtfs_version_id, extensions, counts, _fence)
       when not is_map_key(extensions, :json) do
    {:ok, :not_present, counts}
  end

  defp import_extensions_phase(organization_id, gtfs_version_id, extensions, counts, fence) do
    image_files = Map.get(extensions, :images, %{})

    # The manifest is read here, in the worker, and the images are read one at a time
    # when each is restored, so no staged file travels in a message or process state.
    with {:ok, manifest_json} <- File.read(extensions.json),
         {:ok, ext_counts} <-
           Extensions.Import.import_extensions(
             organization_id,
             gtfs_version_id,
             manifest_json,
             image_files,
             fence: fence
           ) do
      {:ok, :complete, Map.merge(counts, ext_counts)}
    else
      # Unreadable manifest, or decode/reference/DB-transaction failure: no
      # extension writes are durable, but the standard counts already committed
      # remain.
      {:error, reason} ->
        failure(reason, :extensions, counts)

      # Image restoration failed after the extension DB transaction committed:
      # merge the durable extension counts into the standard counts.
      {:error, reason, ext_committed} ->
        failure(reason, :extensions, Map.merge(counts, ext_committed))
    end
  end
end
