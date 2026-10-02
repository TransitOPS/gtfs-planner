defmodule GtfsPlanner.Agents.Packs.Calendars do
  @moduledoc """
  The Calendars helper pack: bounded, scoped reads and one prepared change over the
  existing calendar catalog.

  Every read filters by the scope's organization and service version; neither can
  come from a tool argument. `list_calendars` pages the full matching set behind
  one SHA-256 catalog fingerprint, so a caller that has not read every page cannot
  mistake a bounded result for complete discovery: a later page whose catalog
  changed is refused with a restart-discovery error. `get_calendar` explains each
  date of a bounded range and returns the server evidence for that answer: the
  exact count of dates that run, the window evaluated, the content digest, the
  scope it was read under and a typed reference the panel resolves into the
  calendar page. `prepare_date_change` validates dates and targets,
  resolves names and fingerprints from one catalog read, and runs the existing
  `GtfsPlanner.Gtfs.review_calendar_change/3`, so it returns the command the
  Calendars list can open in its *Change service on a date* review and writes
  nothing. `prepare_calendar_extension` prepares an approved end-date
  extension. It takes no approval argument at all: the approval is an
  editor-entered value the Calendars page copied into the scope's resource
  context, and a request for a different calendar or end date is refused rather
  than prepared for the approved values. Every tool reuses
  `GtfsPlanner.Gtfs` and none writes.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording

  @list_limit 50
  @range_limit_days 62
  @date_limit 366
  @approval_preview_length 120
  @source_ref_service "gtfs_service_queries"

  @weekdays [
    {"Mon", :monday},
    {"Tue", :tuesday},
    {"Wed", :wednesday},
    {"Thu", :thursday},
    {"Fri", :friday},
    {"Sat", :saturday},
    {"Sun", :sunday}
  ]

  @changed_catalog "Calendars changed. Start the search again."
  @source_ref "gtfs_calendars"

  @skill_path Path.expand("../../../../priv/agents/packs/calendars/SKILL.md", __DIR__)
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
  def id, do: "calendars"

  @impl true
  def title, do: "Calendar helper"

  @impl true
  def intro do
    "I can answer questions about calendars in this service version and prepare service date changes for you to review. I can't change routes, trips or stops."
  end

  @impl true
  def examples, do: ["Which calendars run next Monday?", "Run Sunday service on a holiday"]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "list_calendars",
        description:
          "List calendars in this service version, optionally filtered by a case-insensitive substring of the name or service ID. At most 50 calendars are returned per page; keep reading with next_offset and catalog_fingerprint until truncated is false before claiming you have seen every match.",
        activity: "Looked up calendars",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "maxLength" => 100},
            "offset" => %{"type" => "integer", "minimum" => 0},
            "catalog_fingerprint" => %{"type" => "string"}
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_calendar",
        description:
          "Show whether one calendar runs on each date of a range of at most 62 days, with the weekly or exception reason for each date.",
        activity: "Checked a calendar's dates",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_id" => %{"type" => "string"},
            "from" => %{"type" => "string"},
            "to" => %{"type" => "string"}
          },
          "required" => ["service_id", "from", "to"],
          "additionalProperties" => false
        }
      },
      %{
        name: "summarize_calendar_coverage",
        description:
          "Report whether named routes keep recorded service on each of the given dates, using every calendar that runs them. Use service_id to see which other calendars still run a route on a date this calendar does not. At most #{ServiceQueries.coverage_limits().dates} dates and #{ServiceQueries.coverage_limits().routes} routes.",
        activity: "Checked calendar coverage",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_id" => %{"type" => "string", "maxLength" => 200},
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => ServiceQueries.coverage_limits().dates
            },
            "route_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string", "maxLength" => 200},
              "minItems" => 1,
              "maxItems" => ServiceQueries.coverage_limits().routes
            }
          },
          "required" => ["service_id", "dates", "route_ids"],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_calendar_usage",
        description:
          "Report, for the routes that use this calendar, which of the given dates keep recorded service through this calendar and which keep it only through another one. Use this before asking whether a calendar can end; it never proposes a change.",
        activity: "Checked calendar usage",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_id" => %{"type" => "string", "maxLength" => 200},
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => ServiceQueries.coverage_limits().dates
            }
          },
          "required" => ["service_id", "dates"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_date_change",
        description:
          "Prepare a change that stops or runs service on specific dates for review. It saves nothing.",
        activity: "Prepared a date change",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "dates" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "minItems" => 1,
              "maxItems" => 366
            },
            "stop" => %{"type" => "array", "items" => %{"type" => "string"}},
            "run" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["dates", "stop", "run"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_calendar_extension",
        description:
          "Prepare an approved extension of one weekly calendar's end date, listing the dates " <>
            "that newly run, the routes, trips and closures affected and the dates whose holiday " <>
            "policy is still unknown. This works only after the editor entered their approval and " <>
            "the new end date in *Approve a calendar extension* on this page: you cannot supply " <>
            "the approval yourself. It saves nothing; the editor reviews and applies it.",
        activity: "Prepared a calendar extension",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_id" => %{"type" => "string", "maxLength" => 200},
            "end_date" => %{"type" => "string"}
          },
          "required" => ["service_id"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def call("list_calendars", args, %Scope{} = scope), do: list_calendars(args, scope)

  def call("get_calendar", args, %Scope{} = scope), do: get_calendar(args, scope)

  def call("summarize_calendar_coverage", args, %Scope{} = scope),
    do: summarize_calendar_coverage(args, scope)

  def call("get_calendar_usage", args, %Scope{} = scope), do: get_calendar_usage(args, scope)

  def call("prepare_date_change", args, %Scope{} = scope), do: prepare_date_change(args, scope)

  def call("prepare_calendar_extension", args, %Scope{} = scope),
    do: prepare_calendar_extension(args, scope)

  defp list_calendars(args, scope) do
    query = Values.presence(args["query"]) || ""
    offset = args["offset"] || 0
    fingerprint = args["catalog_fingerprint"]

    case Gtfs.load_calendar_catalog(scope.organization_id, scope.gtfs_version_id, []) do
      {:ok, summaries} ->
        page(summaries, query, offset, fingerprint)

      {:error, :not_found} ->
        {:error, "This service version is not available."}

      {:error, :unavailable} ->
        {:error, "Calendars are temporarily unavailable."}
    end
  end

  defp page(summaries, query, offset, fingerprint) do
    matching =
      summaries
      |> Enum.filter(&matches_query?(&1, query))
      |> Enum.sort_by(fn summary ->
        {String.downcase(summary.name || summary.service_id), summary.service_id}
      end)

    catalog_fingerprint = catalog_fingerprint(matching, query)
    total = length(matching)

    with :ok <- check_fingerprint(fingerprint, catalog_fingerprint, offset),
         :ok <- check_offset(offset, total) do
      truncated? = offset + @list_limit < total

      {:ok,
       %{
         "calendars" =>
           matching |> Enum.drop(offset) |> Enum.take(@list_limit) |> Enum.map(&row/1),
         "total" => total,
         "truncated" => truncated?,
         "next_offset" => if(truncated?, do: offset + @list_limit),
         "catalog_fingerprint" => catalog_fingerprint
       }}
    end
  end

  # Later pages must belong to the same catalog the first page was read from.
  # Offset zero starts a fresh discovery and returns the current fingerprint.
  defp check_fingerprint(_fingerprint, _catalog_fingerprint, offset) when offset <= 0, do: :ok

  defp check_fingerprint(fingerprint, catalog_fingerprint, _offset) do
    if fingerprint == catalog_fingerprint, do: :ok, else: {:error, @changed_catalog}
  end

  defp check_offset(offset, total) when offset <= total, do: :ok

  defp check_offset(_offset, _total),
    do: {:error, "Offset is past the end of the matching calendars."}

  defp matches_query?(summary, query) do
    needle = String.downcase(query)

    String.contains?(String.downcase(summary.name || summary.service_id), needle) or
      String.contains?(String.downcase(summary.service_id), needle)
  end

  defp catalog_fingerprint(summaries, query) do
    %{
      "query" => String.downcase(query),
      "calendars" =>
        Enum.map(summaries, &%{"service_id" => &1.service_id, "fingerprint" => &1.fingerprint})
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp row(summary) do
    %{
      "service_id" => summary.service_id,
      "name" => summary.name,
      "kind" => Atom.to_string(summary.kind),
      "days" => days(summary.calendar),
      "first_active_date" => iso_date(summary.first_active_date),
      "last_active_date" => iso_date(summary.last_active_date),
      "trip_count" => summary.trip_count
    }
  end

  defp get_calendar(args, scope) do
    with {:ok, from} <- parse_date("from", args["from"]),
         {:ok, to} <- parse_date("to", args["to"]),
         :ok <- check_order(from, to),
         :ok <- check_range(from, to) do
      read_calendar(args["service_id"], scope, from, to)
    end
  end

  defp parse_date(field, value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, date}

      {:error, _reason} ->
        {:error, "Invalid #{field} date: #{value}. Use a date like 2026-10-12."}
    end
  end

  defp check_order(from, to) do
    if Date.compare(to, from) == :lt do
      {:error, "The end date is before the start date."}
    else
      :ok
    end
  end

  defp check_range(from, to) do
    if Date.diff(to, from) + 1 <= @range_limit_days do
      :ok
    else
      {:error, "The range must be at most #{@range_limit_days} days."}
    end
  end

  # The single-calendar reads (`Gtfs.get_calendar/3`, `Gtfs.fetch_calendar/3`) derive
  # dates and raise on a retained reversed weekly range, which would fail the whole
  # turn. The catalog classifies that range as `coverage_error` instead, so this
  # reads the same summary `prepare_date_change` validates and refuses it with the
  # same message.
  defp read_calendar(service_id, scope, from, to) do
    with {:ok, targets} <- load_targets([service_id], scope) do
      summary = Map.fetch!(targets, service_id)
      result = calendar_result(summary, service_id, from, to)

      {:ok, result, evidence(summary, result, scope, from, to)}
    end
  end

  # The evidence is built from the same catalog summary the result describes, so
  # the card's count cannot disagree with the rows the model read, and the digest
  # covers the exact payload that was returned (INV-2). Nothing here is invented:
  # `source_revision` stays nil until a real native revision exists.
  defp evidence(summary, result, scope, from, to) do
    label = name(summary, result["service_id"])
    running = Enum.count(result["dates"], & &1["runs"])

    %{
      kind: "calendar_dates",
      title: label,
      total: running,
      total_label: "dates run",
      completeness: :complete,
      completeness_reason: nil,
      facts: [
        %{label: "Dates evaluated", value: Integer.to_string(length(result["dates"]))},
        %{label: "Dates that run", value: Integer.to_string(running)},
        %{label: "Weekly days", value: days_label(summary.calendar)},
        %{
          label: "Window",
          value: Date.to_iso8601(from) <> " to " <> Date.to_iso8601(to)
        }
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources: [%{kind: "calendar", id: result["service_id"], label: label}]
    }
  end

  defp digest(result) do
    result
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # -- coverage reads ---------------------------------------------------------

  # The two coverage reads answer the calendar-side questions with the same
  # domain query the Schedule pack uses, so one route/date rule governs both and
  # neither can report a calendar name in place of date evaluation. The
  # Calendar page binds the whole version, so the routes are named explicitly and
  # resolved in scope; a route outside this organization and version is refused
  # rather than described.
  defp summarize_calendar_coverage(args, scope) do
    with {:ok, service_id} <- coverage_service_id(args["service_id"]),
         {:ok, dates} <- coverage_dates(args["dates"]),
         {:ok, route_ids} <- coverage_route_ids(args["route_ids"]) do
      read_coverage(scope, service_id, dates, route_ids, "calendar_coverage", fn _answer ->
        [
          %{label: "Calendar under review", value: service_id},
          %{label: "Routes evaluated", value: Integer.to_string(length(route_ids))},
          %{label: "Dates evaluated", value: Integer.to_string(length(dates))}
        ]
      end)
    end
  end

  # The usage read names the routes the calendar itself is used by, so the person
  # cannot silently widen the question past the routes that would actually be
  # affected. That list is server-derived from the calendar's own trips.
  defp get_calendar_usage(args, scope) do
    with {:ok, service_id} <- coverage_service_id(args["service_id"]),
         {:ok, dates} <- coverage_dates(args["dates"]),
         {:ok, route_ids} <- usage_route_ids(service_id, scope) do
      read_coverage(scope, service_id, dates, route_ids, "calendar_usage", fn _answer ->
        [
          %{label: "Calendar under review", value: service_id},
          %{label: "Routes using this calendar", value: Integer.to_string(length(route_ids))},
          %{label: "Dates evaluated", value: Integer.to_string(length(dates))}
        ]
      end)
    end
  end

  defp usage_route_ids(service_id, scope) do
    case Gtfs.calendar_usage(scope.organization_id, scope.gtfs_version_id, service_id) do
      {:ok, usage} ->
        usage.route_ids |> Enum.sort() |> check_route_limit()

      {:error, :not_found} ->
        {:error, unknown_target_message(service_id)}
    end
  end

  defp check_route_limit(route_ids) do
    if length(route_ids) > ServiceQueries.coverage_limits().routes do
      {:error,
       "This calendar is used by more routes than one answer can cover. Name the routes to check."}
    else
      {:ok, route_ids}
    end
  end

  defp read_coverage(scope, service_id, dates, route_ids, kind, facts) do
    query_scope = %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      route_id: nil
    }

    selection = %{dates: dates, route_ids: route_ids, service_id: service_id}

    case ServiceQueries.coverage(query_scope, selection) do
      {:ok, answer} ->
        {:ok, coverage_result(answer, dates),
         coverage_evidence(answer, scope, kind, facts.(answer))}

      {:error, reason} ->
        {:error, coverage_error(reason)}
    end
  end

  defp coverage_result(answer, dates) do
    %{
      "dates" => Enum.map(dates, &Date.to_iso8601/1),
      "records" =>
        Enum.map(answer.records, fn record ->
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
        end),
      "total" => answer.total,
      "completeness" => Atom.to_string(answer.completeness),
      "disclosures" => Enum.map(answer.disclosures, &%{"reason" => Atom.to_string(&1.reason)})
    }
  end

  defp coverage_evidence(answer, scope, kind, facts) do
    %{
      kind: kind,
      title: coverage_title(kind, facts),
      total: answer.total,
      total_label: "route and date records",
      completeness: answer.completeness,
      completeness_reason: coverage_reason(answer),
      facts: facts,
      source_ref: @source_ref_service,
      digest: answer.digest,
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources: coverage_resources(answer)
    }
  end

  defp coverage_title("calendar_usage", facts),
    do: "Service on #{fact(facts, "Dates evaluated")} dates"

  defp coverage_title(_kind, facts),
    do: "#{fact(facts, "Routes evaluated")} routes over #{fact(facts, "Dates evaluated")} dates"

  defp fact(facts, label) do
    case Enum.find(facts, &(&1.label == label)) do
      %{value: value} -> value
      nil -> "the requested"
    end
  end

  defp coverage_reason(%{completeness: :complete}), do: nil

  defp coverage_reason(answer) do
    Enum.map_join(answer.disclosures, " ", & &1.detail)
  end

  # Each route the answer covers is a typed reference the panel may resolve, and
  # nothing else is: no model-authored name becomes a reference here.
  defp coverage_resources(answer) do
    answer.records
    |> Enum.map(fn record -> %{kind: "route", id: record.route_id, label: record.route_id} end)
    |> Enum.uniq_by(& &1.id)
  end

  defp coverage_service_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp coverage_service_id(_value), do: {:error, "A service_id is required."}

  defp coverage_dates(values) when is_list(values) and values != [] do
    parse_dates(values)
  end

  defp coverage_dates(_values), do: {:error, "Provide at least one date."}

  defp coverage_route_ids(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, "route_ids must be a list of route IDs from this service version."}
    end
  end

  defp coverage_route_ids(_values), do: {:error, "Name at least one route to check."}

  defp coverage_error(:not_found), do: "A named route is not in this service version."
  defp coverage_error(:too_many_dates), do: "Ask about fewer dates at a time."
  defp coverage_error(:too_many_routes), do: "Ask about fewer routes at a time."
  defp coverage_error(:invalid_selection), do: "That question cannot be answered as asked."

  defp coverage_error({:unreadable_calendar, service_id}),
    do: "Calendar #{service_id} could not be read, so no complete answer is available."

  defp coverage_error(_reason), do: "That question could not be answered."

  defp days_label(calendar) do
    case days(calendar) do
      [] -> "None recorded"
      labels -> Enum.join(labels, ", ")
    end
  end

  defp calendar_result(summary, service_id, from, to) do
    exceptions = Map.new(summary.exceptions, &{&1.date, &1.exception_type})
    active_dates = MapSet.new(summary.active_dates)

    %{
      "service_id" => service_id,
      "name" => name(summary, service_id),
      "kind" => Atom.to_string(summary.kind),
      "days" => days(summary.calendar),
      "dates" =>
        for date <- Date.range(from, to) do
          runs = MapSet.member?(active_dates, date)

          %{
            "date" => Date.to_iso8601(date),
            "weekday" => weekday(date),
            "runs" => runs,
            "reason" => reason(Map.get(exceptions, date), runs)
          }
        end
    }
  end

  defp name(%{attributes: %{service_description: description}}, _service_id)
       when is_binary(description),
       do: description

  defp name(_summary, service_id), do: service_id

  # An exception on the date is the explicit reason; otherwise the weekly
  # baseline answers the question.
  defp reason(1, _runs), do: "added"
  defp reason(2, _runs), do: "removed"
  defp reason(nil, true), do: "weekly"
  defp reason(nil, false), do: "not_scheduled"

  defp days(nil), do: []

  defp days(%Calendar{} = calendar) do
    for {label, field} <- @weekdays, Map.get(calendar, field) == 1, do: label
  end

  defp weekday(date) do
    {label, _field} = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    label
  end

  defp iso_date(nil), do: nil
  defp iso_date(%Date{} = date), do: Date.to_iso8601(date)

  # -- prepare_date_change ---------------------------------------------------

  # The prepared change reuses the drawer's own reviewed path: this function
  # validates the selection, then `Gtfs.review_calendar_change/3` loads exactly the
  # target fingerprints under its shared version lock and writes nothing. The
  # fingerprint map covers each target once and no other calendar, which is the
  # exact key set that review requires.
  defp prepare_date_change(args, scope) do
    with {:ok, dates} <- parse_dates(args["dates"]),
         {:ok, stop} <- service_ids("stop", args["stop"]),
         {:ok, run} <- service_ids("run", args["run"]),
         :ok <- check_targets(stop, run),
         {:ok, targets} <- load_targets(stop ++ run, scope) do
      command = {:date_change, dates, stop, run}
      fingerprints = Map.new(stop ++ run, &{&1, Map.fetch!(targets, &1).fingerprint})

      case Gtfs.review_calendar_change(command, fingerprints, Scope.audit_context(scope)) do
        {:ok, review} ->
          {:prepared, %{summary: summary(command, targets), command: command},
           result(command, targets, review.warnings)}

        {:error, reason} ->
          {:error, prepare_error(reason)}
      end
    end
  end

  # -- prepare_calendar_extension -------------------------------------------

  # The approval is not an argument and never comes from the model. The editor
  # entered it in this page's own form, the page copied the validated approval,
  # service ID and end date into the scope's resource context, and
  # `Scope.authorized_context/1` has already resolved that calendar inside the
  # current organization and version before this tool runs. A model paraphrase,
  # a pasted approval or an imported GTFS field therefore cannot establish one
  # (AC-13), and the prepared command carries the approval the editor typed.
  defp prepare_calendar_extension(args, scope) do
    with {:ok, approved} <- approved_extension(scope),
         :ok <- check_approved_target(args["service_id"], approved),
         {:ok, end_date} <- check_approved_end_date(args["end_date"], approved),
         {:ok, targets} <- load_targets([approved.service_id], scope) do
      command =
        {:save, approved.service_id, %{end_date: end_date, approval_text: approved.approval_text}}

      fingerprints = %{
        approved.service_id => Map.fetch!(targets, approved.service_id).fingerprint
      }

      case Gtfs.review_calendar_change(command, fingerprints, Scope.audit_context(scope)) do
        {:ok, %{extension: extension}} when not is_nil(extension) ->
          {:prepared, extension_summary(command, targets, extension, approved),
           extension_result(extension, targets, approved),
           extension_evidence(extension, scope, targets, approved)}

        {:ok, _review} ->
          {:error, "That approval did not produce a reviewable extension."}

        {:error, reason} ->
          {:error, prepare_error(reason)}
      end
    end
  end

  defp approved_extension(scope) do
    case Scope.approved_extension(scope) do
      nil ->
        {:error,
         "No calendar extension has been approved on this page. Ask the editor to enter their " <>
           "approval and the new end date in Approve a calendar extension first."}

      approved ->
        {:ok, approved}
    end
  end

  # Naming the approved calendar keeps the model answerable for its choice, but a
  # different calendar or a different end date is refused instead of quietly
  # prepared for the values the editor approved.
  defp check_approved_target(service_id, approved) do
    if service_id == approved.service_id do
      :ok
    else
      {:error,
       "The approved extension is for calendar " <>
         approved.service_id <>
         ". The editor has to approve that calendar before you can prepare it."}
    end
  end

  defp check_approved_end_date(nil, approved), do: {:ok, approved.end_date}

  defp check_approved_end_date(value, approved) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} when date == approved.end_date ->
        {:ok, date}

      _other ->
        {:error,
         "The approved extension ends on " <>
           Date.to_iso8601(approved.end_date) <>
           ". The editor has to approve that end date before you can prepare it."}
    end
  end

  # The saved command carries only the new end date and the approval. Every other
  # weekly and metadata value is omitted, so the native save retains the stored
  # calendar and all of its existing exceptions exactly as they are (AC-14).
  defp extension_summary(command, targets, extension, approved) do
    target = Map.fetch!(targets, command_service_id(command))

    %{
      summary: %{
        title: "Extend #{target_name(target.service_id, targets)}",
        detail:
          Wording.weekday_date_with_year(extension.previous_end_date) <>
            " → " <> Wording.weekday_date_with_year(extension.requested_end_date),
        lines: [
          "Approved by the editor · #{approval_label(approved.approval_text)}",
          "Newly active dates · #{Wording.count_noun(extension.newly_active_date_count, "date")}",
          "Routes affected · #{Wording.count_noun(length(extension.routes), "route")}",
          "Trips affected · #{Wording.count_noun(length(extension.trip_identities), "trip")}",
          "Closures affected · #{Wording.count_noun(length(extension.closure_consequences), "closure")}",
          "Retained exceptions · #{Wording.count_noun(length(extension.retained_exceptions), "exception")}",
          "Unresolved dates · #{Wording.count_noun(length(extension.unresolved_dates), "date")}"
        ]
      },
      command: command
    }
  end

  defp extension_result(extension, targets, approved) do
    %{
      "service_id" => extension.service_id,
      "name" => target_name(extension.service_id, targets),
      "approval" => approved.approval_text,
      "previous_end_date" => Date.to_iso8601(extension.previous_end_date),
      "requested_end_date" => Date.to_iso8601(extension.requested_end_date),
      "added_days" => extension.added_days,
      "newly_active_dates" => Enum.map(extension.newly_active_dates, &Date.to_iso8601/1),
      "newly_active_date_count" => extension.newly_active_date_count,
      "routes" =>
        Enum.map(extension.routes, &%{"route_id" => &1.route_id, "trip_count" => &1.trip_count}),
      "trips" => Enum.map(extension.trip_identities, &%{"trip_id" => &1.trip_id}),
      "closures" => Enum.map(extension.closure_consequences, &%{"pathway_id" => &1.pathway_id}),
      "retained_exceptions" =>
        Enum.map(
          extension.retained_exceptions,
          &%{
            "date" => Date.to_iso8601(&1.date),
            "exception_type" => &1.exception_type
          }
        ),
      "unresolved_dates" => Enum.map(extension.unresolved_dates, &Date.to_iso8601/1),
      "holiday_policy" => Atom.to_string(extension.holiday_policy)
    }
  end

  # The card's counts come from the same review the native page regenerates for
  # Apply, so the assistant's summary and the reviewer's dialog cannot disagree,
  # and the digest covers the exact impact that was described (INV-2).
  defp extension_evidence(extension, scope, targets, approved) do
    result = extension_result(extension, targets, approved)

    %{
      kind: "calendar_extension",
      title: "Extension of #{target_name(extension.service_id, targets)}",
      total: extension.newly_active_date_count,
      total_label: "dates newly in service",
      completeness: :complete,
      completeness_reason: nil,
      facts: [
        %{label: "Approval", value: approval_label(approved.approval_text)},
        %{
          label: "End date",
          value:
            Wording.weekday_date_with_year(extension.previous_end_date) <>
              " → " <> Wording.weekday_date_with_year(extension.requested_end_date)
        },
        %{label: "Routes", value: Integer.to_string(length(extension.routes))},
        %{label: "Trips", value: Integer.to_string(length(extension.trip_identities))},
        %{label: "Closures", value: Integer.to_string(length(extension.closure_consequences))},
        %{
          label: "Retained exceptions",
          value: Integer.to_string(length(extension.retained_exceptions))
        },
        %{
          label: "Future holiday policy",
          value:
            "#{length(extension.unresolved_dates)} newly active dates have no recorded exception"
        }
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources: [
        %{
          kind: "calendar",
          id: extension.service_id,
          label: target_name(extension.service_id, targets)
        }
      ]
    }
  end

  defp command_service_id({:save, service_id, _attrs}), do: service_id

  defp approval_label(text) do
    if String.length(text) > @approval_preview_length do
      String.slice(text, 0, @approval_preview_length - 1) <> "…"
    else
      text
    end
  end

  defp parse_dates(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      case parse_each_date(values) do
        {:ok, dates} -> dates |> Enum.uniq() |> Enum.sort(Date) |> check_date_count()
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Dates must be ISO dates like 2026-10-12."}
    end
  end

  defp parse_dates(_values), do: {:error, "Dates must be a list of ISO dates."}

  defp parse_each_date(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, dates} ->
      case Date.from_iso8601(value) do
        {:ok, date} ->
          {:cont, {:ok, [date | dates]}}

        {:error, _reason} ->
          {:halt, {:error, "Invalid date: #{value}. Use a date like 2026-10-12."}}
      end
    end)
  end

  defp check_date_count([]), do: {:error, "Provide at least one date."}

  defp check_date_count(dates) when length(dates) > @date_limit,
    do: {:error, "Use at most #{@date_limit} dates."}

  defp check_date_count(dates), do: {:ok, dates}

  defp service_ids(field, values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, service_id_message(field)}
    end
  end

  defp service_ids(field, _values), do: {:error, service_id_message(field)}

  defp service_id_message(field), do: "Argument #{field} must be a list of service IDs."

  defp check_targets([], []), do: {:error, "Provide at least one calendar to stop or run."}

  defp check_targets(stop, run) do
    case Enum.find(stop, &(&1 in run)) do
      nil -> :ok
      service_id -> {:error, "A calendar cannot be both stopped and run: " <> service_id <> "."}
    end
  end

  defp load_targets(service_ids, scope) do
    case Gtfs.load_calendar_catalog(scope.organization_id, scope.gtfs_version_id, []) do
      {:ok, summaries} -> index_targets(service_ids, summaries)
      {:error, :not_found} -> {:error, "This service version is not available."}
      {:error, :unavailable} -> {:error, "Calendars are temporarily unavailable."}
    end
  end

  defp index_targets(service_ids, summaries) do
    targets = Map.new(summaries, &{&1.service_id, &1})

    case Enum.find(service_ids, &(not Map.has_key?(targets, &1))) do
      nil -> check_ranges(service_ids, targets)
      service_id -> {:error, unknown_target_message(service_id)}
    end
  end

  defp unknown_target_message(service_id),
    do: "No calendar with service_id " <> service_id <> " in this service version."

  # A retained weekly range the date evaluator refuses is not reviewable (the live
  # drawer filters those rows out of its own selection), so refuse it with a bounded
  # message instead of letting the review raise inside the calling task.
  defp check_ranges(service_ids, targets) do
    case Enum.find(service_ids, &(Map.get(Map.fetch!(targets, &1), :coverage_error) != nil)) do
      nil -> {:ok, targets}
      service_id -> {:error, invalid_range_message(service_id)}
    end
  end

  defp invalid_range_message(service_id) do
    "The calendar " <>
      service_id <> " has an invalid weekly range. Fix it on the Calendars page first."
  end

  defp summary(command, targets) do
    {:date_change, dates, stop, run} = command

    %{
      title: summary_title(stop, run),
      detail: summary_detail(dates),
      lines: summary_lines(stop, :stop, targets) ++ summary_lines(run, :run, targets)
    }
  end

  defp summary_title(_stop, []), do: "Stop service"
  defp summary_title([], _run), do: "Run service"
  defp summary_title(_stop, _run), do: "Change service"

  defp summary_detail([date]), do: Wording.weekday_date_with_year(date)

  defp summary_detail(dates) do
    if consecutive?(dates) do
      "#{range_start(dates)} – #{Wording.weekday_date_with_year(List.last(dates))} · #{length(dates)} dates"
    else
      "#{length(dates)} dates"
    end
  end

  # Dates are unique and sorted, so one gap makes the span longer than the count.
  defp consecutive?(dates),
    do: Date.diff(List.last(dates), List.first(dates)) == length(dates) - 1

  defp range_start(dates) do
    first = List.first(dates)

    if first.year == List.last(dates).year do
      Wording.weekday_date(first)
    else
      Wording.weekday_date_with_year(first)
    end
  end

  defp summary_lines(service_ids, action, targets) do
    service_ids
    |> Enum.sort_by(&{String.downcase(target_name(&1, targets)), &1})
    |> Enum.map(&"#{action_label(action)} · #{target_name(&1, targets)}")
  end

  defp action_label(:stop), do: "Stop"
  defp action_label(:run), do: "Run"

  defp target_name(service_id, targets), do: Map.fetch!(targets, service_id).name || service_id

  defp result(command, targets, review_warnings) do
    {:date_change, dates, stop, run} = command

    %{
      "calendars" =>
        target_rows(dates, stop, :stop, targets) ++ target_rows(dates, run, :run, targets),
      "warnings" => selected_warnings(dates, review_warnings)
    }
  end

  defp target_rows(dates, service_ids, action, targets) do
    Enum.map(service_ids, fn service_id ->
      %{
        "service_id" => service_id,
        "name" => target_name(service_id, targets),
        "action" => Atom.to_string(action),
        "changing_dates" => changing_dates(dates, action, targets, service_id)
      }
    end)
  end

  # A selected date changes service only when the calendar does not already hold
  # the wanted effective state that day: removing service from a day the calendar
  # does not run, or running a day it already runs, changes no date.
  defp changing_dates(dates, :stop, targets, service_id) do
    active = active_dates(targets, service_id)
    Enum.count(dates, &MapSet.member?(active, &1))
  end

  defp changing_dates(dates, :run, targets, service_id) do
    active = active_dates(targets, service_id)
    Enum.count(dates, &(not MapSet.member?(active, &1)))
  end

  defp active_dates(targets, service_id) do
    targets |> Map.fetch!(service_id) |> Map.get(:active_dates) |> MapSet.new()
  end

  # The review reports the projected state of every target, including exceptions
  # the selection never touches, so only warnings dated inside the selection and
  # the calendar-level no-service warning reach the model. The order is stable, so
  # one selection always produces one result shape.
  defp selected_warnings(dates, review_warnings) do
    selected = MapSet.new(dates)

    review_warnings
    |> Enum.filter(fn warning ->
      warning.reason == :no_service or MapSet.member?(selected, Map.get(warning, :date))
    end)
    |> Enum.sort_by(fn warning -> {warning.service_id, warning_date(warning)} end)
    |> Enum.map(&stringify_warning/1)
  end

  defp warning_date(warning) do
    case Map.get(warning, :date) do
      %Date{} = date -> {1, Date.to_iso8601(date)}
      _none -> {0, ""}
    end
  end

  defp stringify_warning(warning) do
    Map.new(warning, fn
      {key, %Date{} = date} -> {Atom.to_string(key), Date.to_iso8601(date)}
      {key, value} when is_atom(value) -> {Atom.to_string(key), Atom.to_string(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp prepare_error(:forbidden), do: "Access to calendars changed."
  defp prepare_error(:not_found), do: "This service version is not available."
  defp prepare_error(:unavailable), do: "Calendars are temporarily unavailable."
  defp prepare_error(:stale_review), do: "These calendars changed in another session. Try again."
  defp prepare_error(_reason), do: "This change could not be prepared."
end
