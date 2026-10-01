defmodule GtfsPlanner.Agents.Packs.ServiceQueries do
  @moduledoc """
  The Schedule helper pack: bounded, read-only service-date answers for the route
  the conversation is bound to.

  Every tool takes its organization, service version and route from the scope,
  never from an argument, so a tool can only read the route the person is looking
  at (INV-1). `list_boarding_occurrences` is the discovery step: it lists the
  stops the route's active trips call at on a date, with every `stop_sequence`
  that answers each stop, so a loop's second visit is offered rather than
  guessed. `query_departures` reads the listed departures, the frequency windows
  translated to the boarding occurrence and the trips whose time cannot be read;
  `summarize_service` reports what recorded service the bound route has on a set
  of dates; `compare_service_dates` reports which of those dates keep service.

  Every answer returns the server evidence the panel trusts beside the model's
  result: the exact count, the server-computed facts, the completeness, the
  content digest, the resolved scope and a typed reference to the bound route
  (INV-2). A refusal is a message the model can read and correct; no tool writes
  anything, and none accepts SQL, an organization, a version, a route or a
  filesystem path.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.ServiceQueries

  @source_ref "gtfs_service_queries"

  @skill_path Path.expand("../../../../priv/agents/packs/service_queries/SKILL.md", __DIR__)
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
  def id, do: "service_queries"

  @impl true
  def title, do: "Schedule helper"

  @impl true
  def intro do
    "I can answer service-date questions about the route on this page from the trips and calendars in this service version. I can't change trips, calendars or stops."
  end

  @impl true
  def examples,
    do: [
      "What leaves the first stop after 6pm on Thanksgiving?",
      "Which of these dates does this route run service?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "list_boarding_occurrences",
        description:
          "List the stops this route boards at on a date, with every stop_sequence that answers each stop. Call this before query_departures when you are not sure which occurrence the person means; a stop with more than one sequence needs their choice.",
        activity: "Listed boarding stops",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_date" => %{"type" => "string"},
            "direction_id" => %{"type" => "integer", "minimum" => 0, "maximum" => 1}
          },
          "required" => ["service_date"],
          "additionalProperties" => false
        }
      },
      %{
        name: "query_departures",
        description:
          "List what leaves one stop occurrence of this route on a date after a time of day, for example \"18:00\". \"After\" is strictly later than that time. Frequency windows are reported as windows translated to the boarding stop rather than as separate departures, and trips with no readable time are reported separately and counted nowhere.",
        activity: "Checked departures",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_date" => %{"type" => "string"},
            "stop_id" => %{"type" => "string", "maxLength" => 200},
            "stop_sequence" => %{"type" => "integer", "minimum" => 0},
            "after" => %{"type" => "string", "maxLength" => 8},
            "include_after_midnight" => %{"type" => "boolean"},
            "direction_id" => %{"type" => "integer", "minimum" => 0, "maximum" => 1}
          },
          "required" => ["service_date", "stop_id", "after", "include_after_midnight"],
          "additionalProperties" => false
        }
      },
      %{
        name: "summarize_service",
        description:
          "Report whether this route has recorded service on each of the given dates, using every calendar that runs it. A trip with a missing time still counts as service, and a frequency-based trip is service too. Ask about at most #{ServiceQueries.coverage_limits().dates} dates.",
        activity: "Summarized service dates",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => ServiceQueries.coverage_limits().dates
            }
          },
          "required" => ["dates"],
          "additionalProperties" => false
        }
      },
      %{
        name: "compare_service_dates",
        description:
          "Compare this route's recorded service across the given dates and report which dates keep service and which do not. Use this when the question is about what differs between dates rather than about one date.",
        activity: "Compared service dates",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 2,
              "maxItems" => ServiceQueries.coverage_limits().dates
            }
          },
          "required" => ["dates"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def authorize_context(%Scope{} = scope) do
    case Scope.identity(scope) do
      {:route, _route_id} -> :ok
      _other -> {:error, :unavailable}
    end
  end

  @impl true
  def call("list_boarding_occurrences", args, %Scope{} = scope),
    do: list_boarding_occurrences(args, scope)

  def call("query_departures", args, %Scope{} = scope), do: query_departures(args, scope)

  def call("summarize_service", args, %Scope{} = scope), do: summarize_service(args, scope)

  def call("compare_service_dates", args, %Scope{} = scope),
    do: compare_service_dates(args, scope)

  # -- tools ------------------------------------------------------------------

  defp list_boarding_occurrences(args, scope) do
    with :ok <- query_scope(scope),
         {:ok, service_date} <- parse_date(args["service_date"]),
         {:ok, direction_id} <- parse_direction(args["direction_id"]) do
      answer(
        scope,
        fn selection ->
          ServiceQueries.occurrences(selection, %{
            service_date: service_date,
            direction_id: direction_id
          })
        end,
        fn answer ->
          {
            occurrences_result(answer, service_date),
            # The bound route is already the card's only typed reference, so the
            # facts beside it carry the date and the calendars rather than
            # naming the route a second time.
            evidence(answer, scope, "boarding_occurrences", "Board at", [
              %{label: "Service date", value: Date.to_iso8601(service_date)},
              %{label: "Calendars running", value: list_label(answer.active_service_ids)},
              %{
                label: "Stops with more than one visit",
                value: Integer.to_string(Enum.count(answer.occurrences, & &1.ambiguous?))
              }
            ])
          }
        end
      )
    end
  end

  defp query_departures(args, scope) do
    with :ok <- query_scope(scope),
         {:ok, service_date} <- parse_date(args["service_date"]),
         {:ok, stop_id} <- parse_stop_id(args["stop_id"]),
         {:ok, after_secs} <- parse_after(args["after"]),
         {:ok, include_after_midnight?} <- parse_after_midnight(args["include_after_midnight"]),
         {:ok, direction_id} <- parse_direction(args["direction_id"]) do
      occurrence = %{stop_id: stop_id, stop_sequence: parse_stop_sequence(args["stop_sequence"])}

      answer(
        scope,
        fn selection ->
          ServiceQueries.departures(selection, %{
            service_date: service_date,
            after_secs: after_secs,
            include_after_midnight?: include_after_midnight?,
            direction_id: direction_id,
            occurrence: occurrence
          })
        end,
        fn answer -> departures_result(answer, scope, after_secs, include_after_midnight?) end
      )
    end
  end

  defp summarize_service(args, scope) do
    with :ok <- query_scope(scope),
         {:ok, dates} <- parse_dates(args["dates"]) do
      answer(
        scope,
        fn selection ->
          ServiceQueries.coverage(
            Map.put(selection, :route_id, nil),
            %{dates: dates, route_ids: [gtfs_route_id(selection)]}
          )
        end,
        &coverage_result(&1, scope, dates)
      )
    end
  end

  defp compare_service_dates(args, scope) do
    with :ok <- query_scope(scope),
         {:ok, dates} <- parse_dates(args["dates"]) do
      answer(
        scope,
        fn selection ->
          ServiceQueries.compare_dates(
            Map.put(selection, :route_id, nil),
            %{dates: dates, route_ids: [gtfs_route_id(selection)]}
          )
        end,
        &comparison_result(&1, scope, dates)
      )
    end
  end

  # Every read goes through the domain module inside the already-checked scope.
  # A refusal is one bounded message; the evidence builder only ever sees an
  # `{:ok, answer}`, so a card can never describe a refusal. Each builder returns
  # its result beside its evidence, which this promotes to the `{:ok, result,
  # evidence}` form the `Pack` contract declares.
  defp answer(%Scope{} = scope, query, build) do
    case query.(domain_scope(scope)) do
      {:ok, result} ->
        {result_map, evidence} = build.(result)
        {:ok, result_map, evidence}

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  # A conversation that is not bound to a route has nothing this pack may read,
  # so it is refused here as well as in `authorize_context/1`.
  defp query_scope(%Scope{} = scope) do
    case Scope.identity(scope) do
      {:route, _route_id} -> :ok
      _other -> {:error, "This route is no longer available."}
    end
  end

  # The route UUID comes from the server-held identity and never from an
  # argument, so a tool cannot be pointed at another route.
  defp domain_scope(%Scope{} = scope) do
    {:route, route_id} = Scope.identity(scope)

    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      route_id: route_id
    }
  end

  # The coverage and comparison reads take GTFS route IDs, so the pack resolves
  # the bound route's own ID from the UUID the scope carries. A route the scope
  # no longer resolves never reaches here: `authorize_context/1` and the scope
  # check both refuse first, and an unresolvable route becomes the domain's own
  # `:not_found` refusal rather than another route's data.
  defp gtfs_route_id(selection) do
    case Gtfs.get_route_in_version(
           selection.organization_id,
           selection.gtfs_version_id,
           selection.route_id
         ) do
      {:ok, route} -> route.route_id
      {:error, :not_found} -> ""
    end
  end

  # -- results ----------------------------------------------------------------

  defp occurrences_result(answer, service_date) do
    %{
      "service_date" => Date.to_iso8601(service_date),
      "route_id" => answer.route.route_id,
      "route_state" => Atom.to_string(answer.route.state),
      "active_service_ids" => answer.active_service_ids,
      "occurrences" =>
        Enum.map(answer.occurrences, fn occurrence ->
          %{
            "stop_id" => occurrence.stop_id,
            "stop_name" => occurrence.stop_name,
            "stop_sequences" => occurrence.stop_sequences,
            "trip_count" => occurrence.trip_count,
            "ambiguous" => occurrence.ambiguous?
          }
        end),
      "total" => answer.total,
      "completeness" => Atom.to_string(answer.completeness)
    }
  end

  defp departures_result(answer, %Scope{} = scope, after_secs, include_after_midnight?) do
    result = %{
      "service_date" => Date.to_iso8601(answer.service_date),
      "route_id" => answer.route.route_id,
      "timezone" => answer.timezone,
      "after" => GtfsTime.format(after_secs),
      "include_after_midnight" => include_after_midnight?,
      "occurrence" => answer.occurrence,
      "stop_name" => answer.stop_name,
      "departures" =>
        Enum.map(answer.departures, fn departure ->
          %{
            "trip_id" => departure.trip_id,
            "service_id" => departure.service_id,
            "time" => departure.time
          }
        end),
      "frequency_windows" =>
        Enum.map(answer.frequency_windows, fn window ->
          %{
            "trip_id" => window.trip_id,
            "start" => window.start_time,
            "end" => window.end_time,
            "every_minutes" => div(window.headway_secs, 60),
            "exact_times" => window.exact_times,
            "expanded" => window.expanded?,
            "matching_departures" => window.matching_departures
          }
        end),
      "unknown_times" => Enum.map(answer.unknown_times, &%{"trip_id" => &1.trip_id}),
      "exclusions" =>
        Enum.map(answer.exclusions, fn exclusion ->
          %{"reason" => Atom.to_string(exclusion.reason), "count" => exclusion.count}
        end),
      "active_service_ids" => answer.active_service_ids,
      "total" => answer.total,
      "completeness" => Atom.to_string(answer.completeness)
    }

    facts = [
      %{label: "Service date", value: Date.to_iso8601(answer.service_date)},
      %{label: "Boarding at", value: boarding_label(answer)},
      %{label: "Route time zone", value: answer.timezone},
      %{label: "Frequency windows", value: Integer.to_string(length(answer.frequency_windows))},
      %{
        label: "Trips with no readable time",
        value: Integer.to_string(length(answer.unknown_times))
      },
      %{label: "Calendars running", value: list_label(answer.active_service_ids)}
    ]

    {result,
     evidence(
       answer,
       scope,
       "service_departures",
       "departures after #{GtfsTime.format(after_secs)}",
       facts
     )}
  end

  defp coverage_result(answer, %Scope{} = scope, dates) do
    result = %{
      "dates" => Enum.map(dates, &Date.to_iso8601/1),
      "records" => Enum.map(answer.records, &coverage_row/1),
      "total" => answer.total,
      "completeness" => Atom.to_string(answer.completeness),
      "disclosures" => Enum.map(answer.disclosures, &%{"reason" => Atom.to_string(&1.reason)})
    }

    {result,
     evidence(
       answer,
       scope,
       "service_coverage",
       "recorded service on #{length(dates)} dates",
       coverage_facts(dates, answer.records)
     )}
  end

  defp comparison_result(answer, %Scope{} = scope, dates) do
    result = %{
      "dates" => Enum.map(dates, &Date.to_iso8601/1),
      "comparisons" =>
        Enum.map(answer.comparisons, fn comparison ->
          %{
            "route_id" => comparison.route_id,
            "dates_with_service" => Enum.map(comparison.dates_with_service, &Date.to_iso8601/1),
            "dates_without_service" =>
              Enum.map(comparison.dates_without_service, &Date.to_iso8601/1),
            "undetermined_dates" => Enum.map(comparison.undetermined_dates, &Date.to_iso8601/1),
            "service_ids" => comparison.service_ids
          }
        end),
      "total" => answer.total,
      "completeness" => Atom.to_string(answer.completeness)
    }

    {result,
     evidence(
       answer,
       scope,
       "service_date_comparison",
       "service across #{length(dates)} dates",
       coverage_facts(dates, answer.records)
     )}
  end

  defp coverage_facts(dates, records) do
    [
      %{label: "Dates evaluated", value: Integer.to_string(length(dates))},
      %{label: "Dates with recorded service", value: Integer.to_string(service_count(records))},
      %{label: "Dates without recorded service", value: Integer.to_string(absence_count(records))}
    ]
  end

  defp coverage_row(record) do
    %{
      "route_id" => record.route_id,
      "date" => Date.to_iso8601(record.date),
      "recorded_service" => record.recorded_service?,
      "listed_trip_templates" => record.listed_trip_templates,
      "frequency_templates" => record.frequency_templates,
      "missing_time_templates" => record.missing_time_templates,
      "service_ids" => record.service_ids,
      "alternate_service_ids" => record.alternate_service_ids,
      "route_state" => Atom.to_string(record.route_state),
      "absence_reason" => record.absence_reason && Atom.to_string(record.absence_reason)
    }
  end

  defp service_count(records), do: Enum.count(records, &(&1.recorded_service? == true))

  defp absence_count(records), do: Enum.count(records, &(&1.recorded_service? == false))

  defp boarding_label(%{stop_name: nil, occurrence: %{stop_id: stop_id}}), do: stop_id

  defp boarding_label(%{occurrence: %{stop_sequence: sequence}, stop_name: name}),
    do: "#{name} (occurrence #{sequence})"

  defp list_label([]), do: "None"
  defp list_label(values), do: Enum.join(values, ", ")

  # -- evidence ---------------------------------------------------------------

  # The evidence is built from the same answer the model received, so the card's
  # count cannot disagree with the rows it describes. `total` is the domain's own
  # count: a refusal never reaches this function, and a degraded coverage answer
  # carries `total: nil` so the card shows an undetermined count rather than zero.
  defp evidence(answer, %Scope{} = scope, kind, title, facts) do
    %{
      kind: kind,
      title: title,
      total: answer.total,
      total_label: total_label(kind),
      completeness: answer.completeness,
      completeness_reason: completeness_reason(answer),
      facts: facts,
      source_ref: @source_ref,
      digest: answer.digest,
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: answer |> Map.get(:exclusions, []) |> Enum.map(&exclusion_label/1),
      resources: route_resources(answer)
    }
  end

  # The reads answer different shapes from the same domain: departures and
  # occurrences carry the bound `route`, while coverage and comparison carry the
  # routes they covered as records. Both become typed references here, and a
  # shape that names neither yields no reference rather than a fabricated one.
  defp route_resources(%{route: %{route_id: route_id}}),
    do: [%{kind: "route", id: route_id, label: route_id}]

  defp route_resources(%{records: records}) when is_list(records),
    do:
      records
      |> Enum.map(&%{kind: "route", id: &1.route_id, label: &1.route_id})
      |> Enum.uniq_by(& &1.id)

  defp route_resources(_answer), do: []

  defp total_label("boarding_occurrences"), do: "stops to board at"
  defp total_label("service_departures"), do: "departures"
  defp total_label(_kind), do: "route and date records"

  defp exclusion_label(%{reason: reason, count: count}), do: "#{reason} · #{count}"
  defp exclusion_label(reason) when is_binary(reason), do: reason

  defp completeness_reason(%{completeness: :complete}), do: nil

  defp completeness_reason(answer) do
    answer |> Map.get(:disclosures, []) |> Enum.map_join(" ", & &1.detail)
  end

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # -- refusals ---------------------------------------------------------------

  defp error_message(:not_found), do: "This route is not in this service version."
  defp error_message(:invalid_selection), do: "That question cannot be answered as asked."
  defp error_message(:too_many_dates), do: "Ask about fewer dates at a time."
  defp error_message(:too_many_routes), do: "Ask about fewer routes at a time."

  defp error_message(:too_large),
    do:
      "That route and date has more service than one answer can read. Narrow the stop or the date."

  defp error_message(:occurrence_not_found),
    do: "This route does not board at that stop on that date."

  defp error_message({:ambiguous_occurrence, candidates}) do
    "This route visits that stop more than once. Ask which visit, then pass its stop_sequence. Visits: " <>
      Enum.map_join(candidates, ", ", &"occurrence #{&1.stop_sequence}")
  end

  defp error_message({:unreadable_calendar, service_id}),
    do: "Calendar #{service_id} could not be read, so no complete answer is available."

  defp error_message({:timezone_unavailable, _reason}),
    do: "The route agency's time zone is not usable, so local times cannot be stated."

  defp error_message(_reason), do: "That question could not be answered."

  # -- arguments --------------------------------------------------------------

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "Invalid date: #{value}. Use a date like 2026-11-26."}
    end
  end

  defp parse_date(value),
    do: {:error, "A date is required, like 2026-11-26. Got: #{inspect(value)}."}

  defp parse_dates(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      parse_each_date(values)
    else
      {:error, "Dates must be ISO dates like 2026-11-26."}
    end
  end

  defp parse_dates(_values), do: {:error, "Dates must be a list of ISO dates."}

  defp parse_each_date(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, dates} ->
      case Date.from_iso8601(value) do
        {:ok, date} ->
          {:cont, {:ok, [date | dates]}}

        {:error, _reason} ->
          {:halt, {:error, "Invalid date: #{value}. Use a date like 2026-11-26."}}
      end
    end)
    |> case do
      {:ok, dates} -> {:ok, dates |> Enum.uniq() |> Enum.sort(Date)}
      {:error, _message} = error -> error
    end
  end

  defp parse_stop_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp parse_stop_id(_value), do: {:error, "A stop ID is required."}

  defp parse_stop_sequence(value) when is_integer(value) and value >= 0, do: value
  defp parse_stop_sequence(_value), do: nil

  defp parse_direction(nil), do: {:ok, nil}
  defp parse_direction(value) when value in [0, 1], do: {:ok, value}
  defp parse_direction(_value), do: {:error, "direction_id must be 0 or 1."}

  defp parse_after_midnight(value) when is_boolean(value), do: {:ok, value}

  defp parse_after_midnight(_value),
    do: {:error, "include_after_midnight must be true or false."}

  # "18:00", "18:00:00" and "24:30" all name a service-day boundary, so the
  # pack accepts the two clock forms a person writes and parses them with the
  # same `GtfsTime` the domain orders by.
  defp parse_after(value) when is_binary(value) do
    case GtfsTime.parse(normalize_clock(value)) do
      {:ok, secs} -> {:ok, secs}
      {:error, :invalid_time} -> {:error, "Invalid time: #{value}. Use a time like 18:00."}
    end
  end

  defp parse_after(value),
    do: {:error, "A time of day is required, like 18:00. Got: #{inspect(value)}."}

  defp normalize_clock(value) do
    trimmed = String.trim(value)

    case String.split(trimmed, ":") do
      [hours, minutes] -> "#{hours}:#{minutes}:00"
      _other -> trimmed
    end
  end
end
