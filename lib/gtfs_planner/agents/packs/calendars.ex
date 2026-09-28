defmodule GtfsPlanner.Agents.Packs.Calendars do
  @moduledoc """
  The Calendars helper pack: bounded, scoped reads over the existing calendar catalog.

  Every read filters by the scope's organization and service version; neither can
  come from a tool argument. `list_calendars` pages the full matching set behind
  one SHA-256 catalog fingerprint, so a caller that has not read every page cannot
  mistake a bounded result for complete discovery: a later page whose catalog
  changed is refused with a restart-discovery error. `get_calendar` explains each
  date of a bounded range. Both reuse `GtfsPlanner.Gtfs` reads and never write.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendar

  @list_limit 50
  @range_limit_days 62

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
  def skill, do: ""

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

  # The prepare tool lands in step 4; the tool stays declared so the model sees
  # the full pack, and a call is a bounded tool error until then.
  def call("prepare_date_change", _args, %Scope{}), do: {:error, "Not available yet."}

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

  defp normalize_query(nil), do: ""
  defp normalize_query(query), do: String.trim(query)
end
