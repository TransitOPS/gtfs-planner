defmodule GtfsPlanner.Agents.Packs.Timetables do
  @moduledoc """
  The Timetables helper pack: read the reviewed source and prepare one native
  batch of it.

  Every tool reads the source the Paste page already accepted and attached to
  this conversation's resource context. The pack never receives that source as
  an argument: `read_timetable_source` and `inspect_timetable_scope` take no
  arguments at all, and the only selectors `prepare_timetable_input` accepts are
  source row positions, one `service_id`, the reviewed `direction_id` and
  `pattern_id`, and optional native cell corrections. Identity — organization,
  version, route — comes from the scope `Scope.authorized_context/1` and
  `Pack.authorize_context/1` already resolved, so a model cannot name a foreign
  calendar, pattern, trip or occurrence and reach preparation (AC-6, AC-15).

  The preparation is a proposal, never a save. `prepare_timetable_input`
  projects the selected rows of exactly one calendar through
  `GtfsPlanner.Gtfs.TimetableSource.native_input/3`, checks the requested
  direction and pattern against the route's own loaded paste scope and against
  the direction and pattern the editor reviewed for those rows, and runs the
  existing `GtfsPlanner.Gtfs.prepare_timetable_paste/5`. It returns the tagged
  `{:timetable_input, …}` command the Paste host re-prepares and reviews through
  the native controls, with the native review's own fingerprint beside it. There
  is no apply tool here, and nothing in this module writes (CR-2, INV-2).

  `compare_approved_timetable` answers from the same server report the Paste page
  shows: it takes no arguments either, rebuilds the accepted source from the
  admitted snapshot through `TimetableSource.from_payload/1` and runs
  `TimetableComparison.compare/2` on the identity `Scope.authorized_context/1`
  already resolved. Its bounded summary, its totals and its evidence card are
  that report's own values, so a model's sentence can neither restate a total
  nor invent a link (AC-13, AC-15, INV-3).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.TimetableComparison
  alias GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser
  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken
  alias GtfsPlanner.Gtfs.TimetableSource

  @snapshot_kind "gtfs_timetable_source"
  @source_ref "gtfs_timetable_source"
  @paste_source_ref "gtfs_timetable_paste"

  @max_rows 500
  @max_corrections 500
  @max_clock_length 32
  @max_id_length 255
  @text_preview_length 4_000

  @no_source "No accepted timetable source is attached to this page yet."

  # A tool result is bounded, so the summary it hands the model is bounded too:
  # the totals stay exact and the witness examples are explicitly a sample.
  @summary_witnesses 20

  # The report's own category vocabulary, in the order the panel reads it.
  @comparison_categories [:matched, :missing, :extra, :time_mismatch, :date_mismatch]

  @skill_path Path.expand("../../../../priv/agents/packs/timetables/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: "timetables"

  @impl true
  def title, do: "Timetable helper"

  @impl true
  def intro do
    "I can read the timetable source you reviewed on this page and prepare a batch of it " <>
      "for you to review and save. I cannot save anything myself."
  end

  @impl true
  def examples do
    [
      "What does this source say about Friday service?",
      "Prepare the weekday rows for this calendar"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "read_timetable_source",
        description:
          "Read the timetable source the editor reviewed and accepted on this page: its label, " <>
            "notes, effective interval, date policy, copied text and every source row with its " <>
            "resolved calendar, pattern, feed trip, dates and stop clocks. It takes no arguments.",
        activity: "Read the timetable source",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "inspect_timetable_scope",
        description:
          "List the native options this route offers for the calendars the attached source " <>
            "names: the calendar name, the direction, each pattern's id, name, stop occurrences " <>
            "and recorded trips. It takes no arguments, so it can only ever describe this route " <>
            "in this service version.",
        activity: "Checked the native paste options",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_timetable_input",
        description:
          "Prepare one native batch of the source for the editor to review and save. Name the " <>
            "source row positions to include, the one service_id they belong to, and the " <>
            "direction_id and pattern_id the review resolved for them. One call is one calendar: " <>
            "rows from two calendars are refused, so a second calendar is a second call and a " <>
            "second confirmation. corrections optionally proposes a different reading for a " <>
            "pasted cell (source_row_id, source_col, clock); it only reaches the native draft " <>
            "the editor reviews, and never edits the accepted source. It saves nothing.",
        activity: "Prepared a timetable batch",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "row_ids" => %{
              "type" => "array",
              "items" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_rows},
              "minItems" => 1,
              "maxItems" => @max_rows
            },
            "service_id" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => @max_id_length
            },
            "pattern_id" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_id_length},
            "direction_id" => %{"type" => "integer", "minimum" => 0, "maximum" => 1},
            "corrections" => %{
              "type" => "array",
              "maxItems" => @max_corrections,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "source_row_id" => %{"type" => "integer", "minimum" => 1},
                  "source_col" => %{"type" => "integer", "minimum" => 0},
                  "clock" => %{
                    "type" => "string",
                    "minLength" => 1,
                    "maxLength" => @max_clock_length
                  }
                },
                "required" => ["source_row_id", "source_col", "clock"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["row_ids", "service_id", "pattern_id", "direction_id"],
          "additionalProperties" => false
        }
      },
      %{
        name: "compare_approved_timetable",
        description:
          "Compare the accepted timetable source with this route's current feed over the " <>
            "interval and pattern the source was reviewed against. It takes no arguments and " <>
            "compares the whole accepted source, never a narrower subset, because a subset " <>
            "cannot speak for the whole. The answer carries the server's exact totals per " <>
            "category with their units, whether the computation was complete, and the first " <>
            "examples of each category. It reads only: a difference is not fixed by it, and a " <>
            "clean comparison certifies nothing about the agency's approval of the sheet.",
        activity: "Compared the accepted timetable with the feed",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      }
    ]
  end

  @doc """
  The pack's own precondition: an accepted timetable source on a route page.

  It runs before the provider request, every tool, a delivered result and a
  prepared lookup, so a conversation without an accepted source sends no
  request, reads no route and prepares nothing. The refusal is the single
  `{:error, :unavailable}` every other absent resource produces.
  """
  @impl true
  def authorize_context(%Scope{} = scope) do
    case attached_source(scope) do
      {:ok, _source} -> :ok
      :error -> {:error, :unavailable}
    end
  end

  @impl true
  def call("read_timetable_source", _args, %Scope{} = scope), do: read_timetable_source(scope)

  def call("inspect_timetable_scope", _args, %Scope{} = scope), do: inspect_timetable_scope(scope)

  def call("prepare_timetable_input", args, %Scope{} = scope),
    do: prepare_timetable_input(args, scope)

  def call("compare_approved_timetable", _args, %Scope{} = scope),
    do: compare_approved_timetable(scope)

  # -- compare_approved_timetable --------------------------------------------

  # Read-only, provider-independent and argument-free. The source comes from the
  # admitted snapshot, the identity from the scope `Dispatch` already authorized,
  # and every number from `TimetableComparison.compare/2`, so this tool and the
  # Paste page's own Compare control cannot disagree (AC-13, AC-15).
  defp compare_approved_timetable(scope) do
    with {:ok, attached} <- require_source(scope),
         {:ok, source} <- TimetableSource.from_payload(attached.payload),
         {:ok, route_uuid} <- route_identity(scope),
         {:ok, comparison_scope} <- comparison_scope(scope, route_uuid),
         {:ok, report} <- TimetableComparison.compare(comparison_scope, source) do
      result = comparison_result(report)
      {:ok, result, comparison_evidence(report, result, attached, scope)}
    else
      {:error, :invalid_snapshot} ->
        {:error, "The attached source could not be read back for comparison."}

      {:error, :not_found} ->
        {:error, "That route is not in this service version."}

      {:error, :forbidden} ->
        {:error, "Your access to this service version has changed."}

      {:error, :invalid_selection} ->
        {:error, "This source's interval or mapping is not a comparison scope."}

      {:error, {:incomplete, reason}} ->
        {:error, "This comparison was not computed: " <> incomplete_reason(reason)}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp comparison_scope(%Scope{} = scope, route_uuid) do
    {:ok,
     %{
       organization_id: scope.organization_id,
       gtfs_version_id: scope.gtfs_version_id,
       actor_id: scope.user_id,
       route_id: route_uuid
     }}
  end

  defp incomplete_reason({:too_many_dates, count}),
    do:
      "it covers #{count} dates, over the #{TimetableComparison.limits().dates} this comparison reads."

  defp incomplete_reason({:too_many_trips, count}),
    do:
      "the route has #{count} trips in scope, over the #{TimetableComparison.limits().trips} this comparison reads."

  defp incomplete_reason({:too_many_stop_times, count}),
    do:
      "the route has #{count} stop times in scope, over the #{TimetableComparison.limits().stop_times} this comparison reads."

  defp incomplete_reason({:too_many_frequencies, count}),
    do: "the route has #{count} frequency windows in scope, which this comparison does not read."

  defp incomplete_reason(_reason), do: "the reviewed scope is larger than this comparison reads."

  # The totals are the report's own exact numbers beside the report's own units;
  # the examples are the first of each category's bounded sample, and the flag
  # says so, so a bounded answer is never read as a whole one.
  defp comparison_result(report) do
    %{
      "source_digest" => report.source_digest,
      "feed_digest" => report.feed_digest,
      "interval" => comparison_interval(report.interval),
      "comparison_scope" => comparison_scope_result(report.comparison_scope),
      "computation" => Atom.to_string(report.computation),
      "clean" => report.clean?,
      "totals" =>
        Map.new(report.totals, fn {category, total} ->
          {Atom.to_string(category), %{"total" => total, "unit" => report.units[category]}}
        end),
      "categories" => Enum.map(@comparison_categories, &category_examples(report, &1)),
      "unresolved" => Enum.map(report.unresolved, &to_string/1),
      "exclusions" => Enum.map(report.exclusions, &to_string/1)
    }
  end

  defp comparison_interval({first, last}),
    do: "#{Date.to_iso8601(first)} to #{Date.to_iso8601(last)}"

  defp comparison_scope_result(scope) do
    %{
      "route_id" => scope.route_id,
      "direction_ids" => scope.direction_ids,
      "pattern_ids" => scope.pattern_ids,
      "source_rows" => scope.source_rows,
      "feed_trips" => scope.feed_trips
    }
  end

  defp category_examples(report, category) do
    retained = get_in(report, [:witnesses, category]) || []
    total = Map.get(report.totals, category, 0)

    %{
      "category" => Atom.to_string(category),
      "unit" => report.units[category],
      "total" => total,
      "retained_examples" => length(retained),
      "examples" => Enum.map(Enum.take(retained, @summary_witnesses), &witness_result/1),
      "examples_truncated" => length(retained) > @summary_witnesses
    }
  end

  defp witness_result(witness) do
    %{
      "date" => Date.to_iso8601(witness.date),
      "source_row_id" => witness.source_row_id,
      "trip_id" => witness.trip_id,
      "stop_sequence" => witness.stop_sequence,
      "event" => witness.event && Atom.to_string(witness.event),
      "source_clock" => witness.source_clock,
      "feed_clock" => witness.feed_clock,
      "reason" => to_string(witness.reason)
    }
  end

  # The card's headline is the report's own difference count; its completeness is
  # the report's own `computation`, and its links are the existing typed route
  # reference the panel already renders, never a URL a model could have written
  # (AC-15, INV-3).
  defp comparison_evidence(report, result, attached, scope) do
    differences =
      [:missing, :extra, :time_mismatch, :date_mismatch]
      |> Enum.map(&Map.get(report.totals, &1, 0))
      |> Enum.sum()

    %{
      kind: "timetable_comparison",
      title: source_label(attached),
      total: differences,
      total_label: "differences against the current feed",
      completeness: if(report.computation == :complete, do: :complete, else: :incomplete),
      completeness_reason: comparison_incomplete_reason(report),
      facts: [
        %{label: "Effective interval", value: result["interval"]},
        %{label: "Matched trip-date pairs", value: Integer.to_string(report.totals.matched)},
        %{label: "Missing trip-date pairs", value: Integer.to_string(report.totals.missing)},
        %{label: "Extra trip-date pairs", value: Integer.to_string(report.totals.extra)},
        %{label: "Time mismatches", value: Integer.to_string(report.totals.time_mismatch)},
        %{label: "Date mismatches", value: Integer.to_string(report.totals.date_mismatch)},
        %{label: "Unresolved items", value: Integer.to_string(length(report.unresolved))},
        %{label: "Feed digest", value: report.feed_digest}
      ],
      source_ref: @source_ref,
      digest: report.source_digest,
      source_revision: nil,
      scope: scope_of(scope),
      exclusions: Enum.map(result["exclusions"], &to_string/1),
      resources: [%{kind: "route", id: result["comparison_scope"]["route_id"], label: nil}]
    }
  end

  defp comparison_incomplete_reason(%{computation: :complete} = report) do
    if report.clean? do
      nil
    else
      "This comparison is complete, but it still reports differences or unresolved items."
    end
  end

  defp comparison_incomplete_reason(%{unresolved: unresolved}) when unresolved != [],
    do: "#{length(unresolved)} unresolved item(s) mean this comparison cannot read clean."

  defp comparison_incomplete_reason(_report),
    do: "The reviewed scope could not be computed in full, so nothing here reads as a match."

  # -- read_timetable_source ------------------------------------------------

  # The answer is the payload the host admitted, not a retelling of it: the
  # copied text, the reviewed interval and date rules, and every resolved row.
  # The evidence card's count and digest come from that same payload, so the
  # panel's total cannot disagree with the rows the model read (INV-2).
  defp read_timetable_source(scope) do
    with {:ok, source} <- require_source(scope) do
      result = source_result(source)
      {:ok, result, source_evidence(source, result, scope)}
    end
  end

  defp source_result(source) do
    %{
      "label" => source.label,
      "revision" => source.payload["revision"],
      "notes" => source.payload["notes"],
      "accepted?" => true,
      "digest" => source.digest,
      "interval" => source.payload["interval"],
      "date_rules" => source.payload["date_rules"],
      "text" => text_preview(source.text),
      "text_truncated" => byte_size(source.text) > @text_preview_length,
      "rows" => source.payload["rows"],
      "row_count" => length(source.rows),
      "unresolved" => source.payload["unresolved"] || [],
      "exclusions" => source.payload["exclusions"] || []
    }
  end

  # The copied text is the reviewed source, so it is never silently shortened: a
  # preview over the limit says so, and the native paste keeps the whole text.
  defp text_preview(text) when byte_size(text) > @text_preview_length,
    do: binary_part(text, 0, @text_preview_length)

  defp text_preview(text), do: text

  defp source_evidence(source, result, scope) do
    unresolved = length(result["unresolved"])

    %{
      kind: "timetable_source",
      title: source_label(source),
      total: result["row_count"],
      total_label: "source rows",
      completeness: if(unresolved == 0, do: :complete, else: :incomplete),
      completeness_reason: unresolved_reason(unresolved),
      facts: [
        %{label: "Effective interval", value: interval_from(result)},
        %{label: "Date policy", value: policy_from(result)},
        %{label: "Unresolved items", value: Integer.to_string(unresolved)},
        %{label: "Source digest", value: result["digest"]}
      ],
      source_ref: @source_ref,
      digest: result["digest"],
      source_revision: nil,
      scope: scope_of(scope),
      exclusions: Enum.map(result["exclusions"], &to_string/1),
      resources: []
    }
  end

  defp interval_from(%{"interval" => %{"first_date" => first, "last_date" => last}}),
    do: first <> " to " <> last

  defp interval_from(_result), do: "unavailable"

  defp policy_from(%{"date_rules" => %{"policy" => policy} = rules}) when is_binary(policy) do
    extras =
      [
        weekday_label(rules["weekdays"]),
        count_label("school dates", rules["school_dates"]),
        count_label("added dates", rules["added_dates"]),
        count_label("removed dates", rules["removed_dates"])
      ]
      |> Enum.reject(&is_nil/1)

    case extras do
      [] -> policy
      labels -> policy <> " (" <> Enum.join(labels, ", ") <> ")"
    end
  end

  defp policy_from(_result), do: "unavailable"

  defp weekday_label(weekdays) when is_list(weekdays) and weekdays != [],
    do: "weekdays " <> Enum.map_join(weekdays, ",", &to_string/1)

  defp weekday_label(_weekdays), do: nil

  defp count_label(_label, dates) when dates in [nil, []], do: nil
  defp count_label(label, dates) when is_list(dates), do: "#{length(dates)} #{label}"

  defp unresolved_reason(0), do: nil

  defp unresolved_reason(count),
    do: "#{count} unresolved item(s) remain on this source; the editor has not resolved them."

  # -- inspect_timetable_scope ----------------------------------------------

  # The native options come from the route's own paste scope, one read per
  # calendar the accepted source names. A calendar this route does not run, or
  # one from another organization or version, resolves to nothing and is named
  # as unavailable rather than described from the payload.
  defp inspect_timetable_scope(scope) do
    with {:ok, source} <- require_source(scope),
         {:ok, route_uuid} <- route_identity(scope),
         {:ok, route} <- native_route(scope, route_uuid) do
      case calendar_ids(source) do
        [] ->
          {:error, "This source has no resolved rows, so there are no native options to inspect."}

        service_ids ->
          options = Enum.map(service_ids, &scope_option(&1, route, scope))
          {:ok, %{"route_id" => route.route_id, "calendars" => options}}
      end
    end
  end

  defp scope_option(service_id, route, scope) do
    case native_scope(scope, route, %{"service_id" => service_id}) do
      {:ok, native} ->
        %{
          "service_id" => service_id,
          "available" => true,
          "calendar_name" => native.calendar && native.calendar.name,
          "direction_id" => native.direction_id,
          "pattern_id" => native.pattern_id,
          "trip_count" => length(native.trips),
          "patterns" => Enum.map(native.patterns, &pattern_option(&1, native))
        }

      {:error, _reason} ->
        %{
          "service_id" => service_id,
          "available" => false,
          "reason" => "This route does not run that calendar in this service version."
        }
    end
  end

  defp pattern_option(pattern, native) do
    %{
      "pattern_id" => pattern.id,
      "route_pattern_id" => pattern.route_pattern_id,
      "name" => pattern.name,
      "headsign" => pattern.headsign,
      "trip_count" => pattern.timings |> Enum.map(& &1.trip_count) |> Enum.sum(),
      "occurrences" =>
        Enum.map(pattern.occurrences, fn occurrence ->
          %{
            "position" => occurrence.position,
            "stop_id" => occurrence.stop_id,
            "stop_name" => get_in(native.stops, [occurrence.stop_id, :stop_name])
          }
        end)
    }
  end

  # -- prepare_timetable_input ----------------------------------------------

  # The whole path is server-side: the accepted source comes from the admitted
  # snapshot, the selectors are checked against the route's own loaded paste
  # scope, the batch is projected by `TimetableSource.native_input/3` (which
  # refuses unknown rows and mixed calendars itself) and the resolved review
  # comes from the production `prepare_timetable_paste/5`. Nothing is written
  # and no argument can widen the scope (AC-6, FH-3).
  defp prepare_timetable_input(args, scope) do
    with {:ok, source} <- require_source(scope),
         {:ok, route_uuid} <- route_identity(scope),
         {:ok, route} <- native_route(scope, route_uuid),
         {:ok, row_ids} <- selected_row_ids(args["row_ids"]),
         {:ok, service_id} <- identifier("service_id", args["service_id"]),
         {:ok, pattern_id} <- identifier("pattern_id", args["pattern_id"]),
         {:ok, direction_id} <- direction(args["direction_id"]),
         :ok <- check_rows_exist(source, row_ids),
         {:ok, native} <- native_scope(scope, route, %{"service_id" => service_id}),
         :ok <- check_calendar(native, service_id),
         :ok <- check_direction(native, direction_id),
         :ok <- check_pattern(native, pattern_id),
         :ok <- check_reviewed_selection(source, native, row_ids),
         {:ok, input} <- project_input(source, row_ids, service_id),
         {:ok, input, applied} <- apply_corrections(input, args["corrections"], source, row_ids) do
      prepared(%{
        native: native,
        input: input,
        applied: applied,
        source: source,
        row_ids: row_ids,
        service_id: service_id,
        direction_id: direction_id,
        route: route,
        scope: scope
      })
    end
  end

  defp prepared(context) do
    %{
      native: native,
      input: input,
      applied: applied,
      source: source,
      row_ids: row_ids,
      service_id: service_id,
      direction_id: direction_id,
      route: route,
      scope: scope
    } = context

    scope_params = %{
      "service_id" => service_id,
      "direction_id" => direction_id,
      "pattern_id" => native.pattern_id
    }

    case Gtfs.prepare_timetable_paste(
           scope.organization_id,
           scope.gtfs_version_id,
           route.route_id,
           scope_params,
           input
         ) do
      {:ok, %{review: %{plan: plan} = review}} when is_map(plan) ->
        # The command is the tagged value the Paste host re-prepares and reviews
        # through the native controls, and it names the exact source digest it
        # was built from, so a source that changed since can never be applied
        # from this proposal (AC-6, AC-7).
        command =
          {:timetable_input,
           %{
             source_digest: source.digest,
             row_ids: row_ids,
             scope_params: %{
               service_id: service_id,
               direction_id: direction_id,
               pattern_id: native.pattern_id
             },
             input: input,
             fingerprint: review.fingerprint
           }}

        result =
          prepare_result(source, native, review, row_ids, service_id, applied, input)

        {:prepared, %{summary: prepare_summary(native, review, result), command: command}, result,
         prepare_evidence(native, review, result, source, route, scope)}

      {:ok, %{review: review}} when is_map(review) ->
        {:error, unmatched_columns_message(review)}

      {:ok, %{review: nil}} ->
        {:error, "The native review found no timetable to prepare from this source."}

      {:error, reason} ->
        {:error, prepare_error(reason)}
    end
  end

  # A scope-only prepare: the same production call the Paste page makes before
  # anything is pasted, so the calendar, direction and pattern a selector may
  # name are resolved from the route itself, never from an argument list.
  defp native_scope(scope, route, scope_params) do
    case Gtfs.prepare_timetable_paste(
           scope.organization_id,
           scope.gtfs_version_id,
           route.route_id,
           scope_params,
           %{"text" => ""}
         ) do
      {:ok, %{scope: native}} ->
        {:ok, native}

      {:error, _reason} ->
        {:error, "That calendar does not run on this route in this service version."}
    end
  end

  # `Schedules.load_paste_scope/5` falls back to the calendar with the most trips
  # on the route when it is asked for one that is not there, so the resolved
  # calendar is compared with the requested one: a calendar this route does not
  # run is refused instead of being prepared against its neighbour.
  defp check_calendar(native, service_id) do
    if native.calendar && native.calendar.service_id == service_id do
      :ok
    else
      {:error, "Calendar #{service_id} does not run on this route in this service version."}
    end
  end

  defp check_direction(native, direction_id) do
    if native.direction_id == direction_id do
      :ok
    else
      {:error,
       "This route has no direction #{direction_id} with recorded service on that calendar. " <>
         "Call inspect_timetable_scope for the directions it has."}
    end
  end

  # The pattern is compared against the route's own loaded pattern, by UUID or
  # natural ID, so a pattern from another route, direction or version never
  # resolves and a model-supplied ID cannot substitute for the reviewed one.
  defp check_pattern(native, pattern_id) do
    if pattern_id in pattern_identifiers(native, native.pattern_id) do
      :ok
    else
      {:error,
       "Pattern #{pattern_id} is not a pattern of this route in that direction. " <>
         "Call inspect_timetable_scope for the patterns it has."}
    end
  end

  defp pattern_identifiers(native, pattern_id) do
    case Enum.find(native.patterns, &(&1.id == pattern_id)) do
      nil -> [pattern_id]
      pattern -> [pattern.id, pattern.route_pattern_id]
    end
  end

  # The reviewed mapping recorded which direction and pattern each source row
  # resolved to. A batch resolved against another pattern would paste the same
  # text against the wrong stops, so a disagreement is refused rather than
  # prepared (AC-6).
  defp check_reviewed_selection(source, native, row_ids) do
    selected = Enum.filter(source.rows, &(&1["source_row_id"] in row_ids))
    accepted = Enum.map(pattern_identifiers(native, native.pattern_id), &to_string/1)

    cond do
      Enum.any?(selected, &(to_string(&1["direction_id"]) != to_string(native.direction_id))) ->
        {:error, "Those source rows were reviewed against another direction of this route."}

      Enum.any?(selected, &(not reviewed_pattern?(accepted, &1["pattern_id"]))) ->
        {:error, "Those source rows were reviewed against another pattern of this route."}

      true ->
        :ok
    end
  end

  defp reviewed_pattern?(_accepted, nil), do: false
  defp reviewed_pattern?(accepted, pattern_id), do: to_string(pattern_id) in accepted

  defp project_input(source, row_ids, service_id) do
    case TimetableSource.native_input(native_source(source), row_ids, service_id) do
      {:ok, %{input: input}} ->
        {:ok, input}

      {:error, :empty_selection} ->
        {:error, "Name at least one source row to prepare."}

      {:error, :unknown_row} ->
        {:error, "One of those rows is not in the attached source."}

      {:error, :mixed_calendars} ->
        {:error,
         "Those rows belong to more than one calendar. Prepare one calendar per call, so each " <>
           "batch gets its own confirmation."}

      {:error, _reason} ->
        {:error, "Those rows could not be projected into a native batch."}
    end
  end

  # A correction is a proposal for a new native draft: it is checked against the
  # pasted grid's own bounds and the native clock grammar, and it never edits the
  # accepted source. A reading the grammar cannot make exact — an unrecognized
  # cell or an ambiguous 12-hour hour — is left to the editor in native review
  # rather than guessed here (AC-12).
  defp apply_corrections(input, nil, _source, _row_ids), do: {:ok, input, []}

  defp apply_corrections(input, corrections, source, row_ids) do
    with {:ok, grid} <- source_grid(source) do
      reduce_corrections(input, corrections, grid, source, row_ids, [])
    end
  end

  defp reduce_corrections(input, [], _grid, _source, _row_ids, applied),
    do: {:ok, merge_corrections(input, Enum.reverse(applied)), Enum.reverse(applied)}

  defp reduce_corrections(input, [correction | rest], grid, source, row_ids, applied) do
    with {:ok, row_id} <- correction_row(correction, row_ids),
         {:ok, col} <- correction_column(correction, grid, source, row_id),
         {:ok, clock} <- correction_clock(correction) do
      if Enum.any?(applied, &(&1.row_id == row_id and &1.col == col)) do
        {:error, "Two corrections name the same cell. Correct one cell per call."}
      else
        reduce_corrections(
          input,
          rest,
          grid,
          source,
          row_ids,
          [%{row_id: row_id, col: col, clock: clock} | applied]
        )
      end
    end
  end

  defp correction_row(%{"source_row_id" => row_id}, row_ids) when is_integer(row_id) do
    if row_id in row_ids do
      {:ok, row_id}
    else
      {:error, "A correction names source row #{row_id}, which is not in this batch."}
    end
  end

  defp correction_row(_correction, _row_ids),
    do: {:error, "A correction needs a source_row_id that is in this batch."}

  defp correction_column(%{"source_col" => col}, grid, source, row_id) when is_integer(col) do
    with {:ok, cells} <- grid_row(grid, source, row_id) do
      if col < length(cells) do
        {:ok, col}
      else
        {:error, "Column #{col} is not a column of the pasted source."}
      end
    end
  end

  defp correction_column(_correction, _grid, _source, _row_id),
    do: {:error, "A correction needs a source_col that is a pasted column."}

  defp correction_clock(%{"clock" => clock}) when is_binary(clock) do
    case TimeToken.classify(clock) do
      {:time, _secs, kind} when kind in [:h24, :h12] ->
        {:ok, String.trim(clock)}

      :not_served ->
        {:ok, String.trim(clock)}

      {:time, _secs, :ambiguous} ->
        {:error,
         "Clock #{String.trim(clock)} is ambiguous on a 12-hour reading. Leave that cell for the " <>
           "editor to decide in the native review."}

      _unreadable ->
        {:error,
         "Clock #{String.trim(clock)} is not a time this timetable can read. Leave that cell for " <>
           "the editor to decide in the native review."}
    end
  end

  defp correction_clock(_correction),
    do: {:error, "A correction needs a clock such as 06:05 or 6:05p."}

  # Source rows are numbered from the first pasted data row, exactly as the
  # native decision grid numbers them, so a correction lands on the cell the
  # editor sees at that row and column.
  defp grid_row(grid, source, row_id) do
    index = if source.header?, do: row_id, else: row_id - 1

    case Enum.at(grid, index) do
      cells when is_list(cells) -> {:ok, cells}
      _other -> {:error, "Source row #{row_id} is not a row of the pasted source."}
    end
  end

  # The parsed grid is only needed to bound a correction to a real pasted cell,
  # and it comes from the same parser the native review reads the text with.
  defp source_grid(source) do
    case ClipboardParser.parse(source.text, transpose: source.layout == :stops_in_rows) do
      {:ok, %{grid: grid}} when is_list(grid) -> {:ok, grid}
      _other -> {:error, "The pasted source could not be read to check that correction."}
    end
  end

  # Corrections ride the native `decisions` map the row review already reads,
  # keyed exactly as the editor's own correction control keys it: the source
  # row number, then the pasted column and the clock to read there.
  defp merge_corrections(input, applied) do
    decisions =
      Enum.reduce(applied, input.decisions, fn correction, decisions ->
        Map.update(
          decisions,
          correction.row_id,
          %{"cells" => %{correction.col => correction.clock}},
          fn row -> put_in(row, ["cells", correction.col], correction.clock) end
        )
      end)

    %{input | decisions: decisions}
  end

  defp prepare_result(source, native, review, row_ids, service_id, applied, input) do
    counts = review.plan.counts

    %{
      "source_digest" => source.digest,
      "service_id" => service_id,
      "calendar_name" => native.calendar && native.calendar.name,
      "direction_id" => native.direction_id,
      "pattern_id" => native.pattern_id,
      "mode" => Atom.to_string(input.mode),
      "rows" =>
        Enum.map(Enum.filter(source.rows, &(&1["source_row_id"] in row_ids)), fn row ->
          %{
            "source_row_id" => row["source_row_id"],
            "feed_trip_id" => row["feed_trip_id"],
            "dates" => length(row["dates"] || [])
          }
        end),
      "row_count" => length(row_ids),
      "rows_left_out" => length(source.rows) - length(row_ids),
      "corrections" => Enum.map(applied, &correction_result/1),
      "counts" => Map.new(counts, fn {key, value} -> {Atom.to_string(key), value} end),
      "needs_decision" => counts.needs_decision,
      "refusal" => refusal_label(review.plan.refusal),
      "warnings" => Enum.map(review.plan.warnings, &inspect/1),
      "fingerprint" => review.fingerprint
    }
  end

  defp correction_result(%{row_id: row_id, col: col, clock: clock}) do
    %{"source_row_id" => row_id, "source_col" => col, "clock" => clock}
  end

  defp refusal_label(nil), do: nil
  defp refusal_label(refusal), do: inspect(refusal)

  # The card's counts are the native plan's own counts, computed by the same
  # `Plan.build/6` the editor's own review runs, and the digest is the native
  # review fingerprint: nothing here restates a number the paste page would not
  # show (INV-2, AC-15).
  defp prepare_evidence(native, review, result, source, route, scope) do
    counts = review.plan.counts
    incomplete? = counts.needs_decision > 0 or not is_nil(review.plan.refusal)

    %{
      kind: "timetable_batch",
      title: result["service_id"],
      total: counts.add + counts.change,
      total_label: "trips to add or change",
      completeness: if(incomplete?, do: :incomplete, else: :complete),
      completeness_reason: incompleteness_reason(counts, review.plan.refusal),
      facts: [
        %{label: "Service calendar", value: result["service_id"]},
        %{label: "Direction", value: Integer.to_string(native.direction_id)},
        %{label: "Pattern", value: native.pattern_id},
        %{label: "Source rows in this batch", value: Integer.to_string(result["row_count"])},
        %{label: "Source rows left out", value: Integer.to_string(result["rows_left_out"])},
        %{label: "Proposed corrections", value: Integer.to_string(length(result["corrections"]))},
        %{label: "Source digest", value: source.digest}
      ],
      source_ref: @paste_source_ref,
      digest: review.fingerprint,
      source_revision: nil,
      scope: scope_of(scope),
      exclusions: exclusions_for(result),
      resources:
        calendar_resource(result["service_id"], result["calendar_name"]) ++
          [%{kind: "route", id: route.route_id, label: route_label(route)}]
    }
  end

  defp incompleteness_reason(counts, refusal) do
    []
    |> add_reason(
      counts.needs_decision > 0,
      "#{counts.needs_decision} pasted row(s) still need an editor decision"
    )
    |> add_reason(not is_nil(refusal), "the native plan refused this batch")
    |> blank_to_nil()
  end

  defp blank_to_nil([]), do: nil
  defp blank_to_nil(reasons), do: Enum.join(reasons, " ")

  defp add_reason(reasons, true, reason), do: reasons ++ [reason]
  defp add_reason(reasons, false, _reason), do: reasons

  defp exclusions_for(result) do
    []
    |> add_reason(
      result["rows_left_out"] > 0,
      "#{result["rows_left_out"]} source row(s) are not in this batch"
    )
    |> add_reason(
      result["needs_decision"] > 0,
      "#{result["needs_decision"]} pasted row(s) need an editor decision"
    )
    |> add_reason(not is_nil(result["refusal"]), "the native plan refused this batch")
  end

  defp prepare_summary(native, review, result) do
    counts = review.plan.counts

    %{
      title: "Prepare #{result["service_id"]}",
      detail:
        "Direction #{native.direction_id} · pattern #{native.pattern_id} · " <>
          "#{result["row_count"]} of #{result["row_count"] + result["rows_left_out"]} source rows",
      lines: [
        "Trips to add · #{counts.add}",
        "Trips to change · #{counts.change}",
        "Trips unchanged · #{counts.unchanged}",
        "Source rows left for another batch · #{result["rows_left_out"]}",
        "Rows needing a decision · #{counts.needs_decision}",
        "Proposed corrections · #{length(result["corrections"])}",
        "Saved only when the editor reviews and applies this batch"
      ]
    }
  end

  defp unmatched_columns_message(review) do
    issues = Enum.map_join(review.column_issues || [], " ", &inspect/1)

    "The native review could not match the pasted columns to this pattern yet" <>
      if(issues == "", do: ".", else: ": " <> issues <> ".") <>
      " The editor resolves that in the native review before anything is saved."
  end

  defp prepare_error(:not_found), do: "That route or calendar is not in this service version."
  defp prepare_error(:no_times), do: "The pasted source has no readable times."

  defp prepare_error({:too_large, _bytes}),
    do: "The pasted source is too large for the native review."

  defp prepare_error({:too_many_rows, _rows}),
    do: "The pasted source has too many rows for the native review."

  defp prepare_error({:too_many_columns, _columns}),
    do: "The pasted source has too many columns for the native review."

  defp prepare_error({:unclosed_quote, _column}), do: "The pasted source has an unclosed quote."
  defp prepare_error(:empty), do: "The pasted source is empty."
  defp prepare_error(_reason), do: "That batch could not be prepared from this source."

  # -- the attached source --------------------------------------------------

  # The accepted source is the admitted snapshot, read only after
  # `Scope.authorized_context/1` re-verified its envelope and digest. The kind is
  # this pack's own, so another pack's snapshot is simply no source here.
  defp require_source(scope) do
    case attached_source(scope) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, @no_source}
    end
  end

  defp attached_source(%Scope{} = scope) do
    with %{kind: @snapshot_kind, payload: payload} when is_map(payload) <-
           Scope.source_snapshot(scope),
         true <- Map.get(payload, "accepted?") == true,
         true <- is_binary(Map.get(payload, "digest")),
         {:ok, rows} <- source_rows(payload),
         {:ok, text} <- source_text(payload),
         {:ok, layout} <- source_layout(payload) do
      {:ok,
       %{
         payload: payload,
         digest: Map.get(payload, "digest"),
         label: Map.get(payload, "label") || "",
         text: text,
         layout: layout,
         header?: Map.get(payload, "header?") != false,
         rows: rows
       }}
    else
      _other -> :error
    end
  end

  defp source_rows(payload) do
    case Map.get(payload, "rows") do
      rows when is_list(rows) ->
        if Enum.all?(rows, &is_integer(Map.get(&1, "source_row_id"))),
          do: {:ok, rows},
          else: :error

      _other ->
        :error
    end
  end

  defp source_text(payload) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> {:ok, text}
      _other -> :error
    end
  end

  defp source_layout(payload) do
    case Map.get(payload, "layout") do
      "trips_in_rows" -> {:ok, :trips_in_rows}
      "stops_in_rows" -> {:ok, :stops_in_rows}
      "auto" -> {:ok, :auto}
      _other -> :error
    end
  end

  # `native_input/3` reads the source's own text, layout and header flag and the
  # selected rows' positions. It is the same projection the host uses, so the
  # prepared draft and the editor's review parse one grid.
  defp native_source(source) do
    %{
      raw_text: source.text,
      layout: source.layout,
      header?: source.header?,
      rows:
        Enum.map(source.rows, fn row ->
          %{source_row_id: row["source_row_id"], service_id: row["service_id"]}
        end)
    }
  end

  # -- arguments ------------------------------------------------------------

  defp selected_row_ids(row_ids) when is_list(row_ids) do
    cond do
      row_ids == [] ->
        {:error, "Name at least one source row to prepare."}

      not Enum.all?(row_ids, &is_integer/1) ->
        {:error, "row_ids must be the source row positions read from the source."}

      Enum.uniq(row_ids) != row_ids ->
        {:error, "row_ids must not repeat a source row."}

      true ->
        {:ok, Enum.sort(row_ids)}
    end
  end

  defp selected_row_ids(_row_ids),
    do: {:error, "row_ids must be a list of source row positions."}

  defp identifier(_field, value) when is_binary(value) do
    if String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, "A nonblank identifier is required."}
    end
  end

  defp identifier(field, _value),
    do: {:error, "Argument #{field} must be a nonblank string."}

  defp direction(value) when value in [0, 1], do: {:ok, value}

  defp direction(_value),
    do: {:error, "Argument direction_id must be 0 or 1 for the direction the review resolved."}

  defp check_rows_exist(source, row_ids) do
    known = MapSet.new(source.rows, & &1["source_row_id"])

    case Enum.reject(row_ids, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      [row_id | _rest] ->
        {:error, "Source row #{row_id} is not in the attached source."}
    end
  end

  defp calendar_ids(source) do
    source.rows
    |> Enum.map(& &1["service_id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp route_identity(scope) do
    case Scope.identity(scope) do
      {:route, route_id} -> {:ok, route_id}
      _other -> {:error, "This helper only works on a route's Paste page."}
    end
  end

  # The scope's identity is the route's own UUID, which `Scope.authorized_context/1`
  # has already resolved inside this organization and version. The native paste
  # scope is loaded by the route's GTFS id, so the authorized route is read back
  # once and every later call uses that: no tool argument can name either value
  # (AC-2, AC-15).
  defp native_route(scope, route_uuid) do
    case Gtfs.get_route_in_version(scope.organization_id, scope.gtfs_version_id, route_uuid) do
      {:ok, route} -> {:ok, route}
      {:error, :not_found} -> {:error, "That route is not in this service version."}
    end
  end

  # -- labels and evidence links --------------------------------------------

  defp source_label(%{label: label}) when is_binary(label) and label != "", do: label
  defp source_label(_source), do: "Reviewed timetable source"

  defp scope_of(scope) do
    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      identity: identity_label(scope)
    }
  end

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  defp route_label(route) do
    route.route_short_name || route.route_long_name || route.route_id
  end

  defp calendar_resource(service_id, name) when is_binary(service_id) do
    [%{kind: "calendar", id: service_id, label: name || service_id}]
  end

  defp calendar_resource(_service_id, _name), do: []
end
