defmodule GtfsPlanner.Agents.Packs.Calendars do
  @moduledoc """
  The Calendars helper pack: bounded, scoped reads and one prepared change over the
  existing calendar catalog.

  Every read filters by the scope's organization and service version; neither can
  come from a tool argument. `list_calendars` pages the full matching set behind
  one SHA-256 catalog fingerprint, so a caller that has not read every page cannot
  mistake a bounded result for complete discovery: a later page whose catalog
  changed is refused with a restart-discovery error. `get_calendar` explains each
  date of a bounded range. `prepare_date_change` validates dates and targets,
  resolves names and fingerprints from one catalog read, and runs the existing
  `GtfsPlanner.Gtfs.review_calendar_change/3`, so it returns the command the
  Calendars list can open in its *Change service on a date* review and writes
  nothing. All three reuse `GtfsPlanner.Gtfs` and never write.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar

  @list_limit 50
  @range_limit_days 62
  @date_limit 366

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
      }
    ]
  end

  @impl true
  def call("list_calendars", args, %Scope{} = scope), do: list_calendars(args, scope)

  def call("get_calendar", args, %Scope{} = scope), do: get_calendar(args, scope)

  def call("prepare_date_change", args, %Scope{} = scope), do: prepare_date_change(args, scope)

  defp list_calendars(args, scope) do
    query = normalize_query(args["query"])
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

  defp read_calendar(service_id, scope, from, to) do
    case Gtfs.get_calendar(scope.organization_id, scope.gtfs_version_id, service_id) do
      {:ok, payload} ->
        {:ok, calendar_result(payload, service_id, from, to)}

      {:error, :not_found} ->
        {:error, "No calendar with service_id " <> service_id <> " in this service version."}
    end
  end

  defp calendar_result(payload, service_id, from, to) do
    exceptions = Map.new(payload.exceptions, &{&1.date, &1.exception_type})
    active_dates = MapSet.new(payload.active_dates)

    %{
      "service_id" => service_id,
      "name" => name(payload, service_id),
      "kind" => Atom.to_string(payload.kind),
      "days" => days(payload.calendar),
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

  defp name(_payload, service_id), do: service_id

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

  defp parse_dates(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      with {:ok, dates} <- parse_each_date(values),
           dates = dates |> Enum.uniq() |> Enum.sort(Date) do
        check_date_count(dates)
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

  defp summary_detail([date]), do: date_label(date)

  defp summary_detail(dates) do
    if consecutive?(dates) do
      "#{range_start(dates)} – #{date_label(List.last(dates))} · #{length(dates)} dates"
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
      Elixir.Calendar.strftime(first, "%a %b %-d")
    else
      date_label(first)
    end
  end

  defp date_label(date), do: Elixir.Calendar.strftime(date, "%a %b %-d, %Y")

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

  defp normalize_query(nil), do: ""
  defp normalize_query(query), do: String.trim(query)
end
