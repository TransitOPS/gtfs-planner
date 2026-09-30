defmodule GtfsPlannerWeb.Gtfs.LeftOutWording do
  @moduledoc """
  The words every surface uses for the trips import left outside patterns.

  Two pages read the same `Gtfs.left_out_trips/3` rows and must say the same
  thing about them: the route's Patterns tab, which offers the fixes one route
  can have here, and a finished import's result, which reports every route at
  once. Only the wording lives here; each page keeps its own ids, its own
  element and its own links, because they are different actions on different
  pages.

  A reason code this module does not name still gets a row, so a count never
  disappears from either page. The raw code stays in each page's Technical
  details disclosure.
  """

  @doc """
  One row per derivation reason, in the order the reader returned them.

  Each row is `%{code: code, count: count, tone: tone, title: title, body: body,
  action: action | nil}`, where an action is `%{label: label, primary?: boolean,
  target: :group | :schedules}`.
  """
  def rows(left_out) do
    Enum.map(left_out, fn %{reason: reason, trip_count: count} ->
      %{code: code(reason), count: count}
      |> Map.merge(reason_words(code(reason), count))
    end)
  end

  @doc "The trips the rows describe, counted once across every reason."
  def total(rows), do: Enum.reduce(rows, 0, &(&1.count + &2))

  @doc "Whether any row offers the grouping review, the only fix the Patterns tab owns."
  def group_offered?(rows), do: Enum.any?(rows, &match?(%{target: :group}, &1.action))

  @doc "The card's heading for a total of left-out trips."
  def title(1), do: "1 trip isn’t in a pattern"
  def title(total), do: "#{total} trips aren’t in a pattern"

  @doc "The derivation reason as the code both pages disclose."
  def code(nil), do: "unknown"
  def code(reason), do: reason

  @doc "`1 trip`, `2 trips`; a plural that is not `noun <> s` is passed as `many`."
  def plural(1, one, _many), do: "1 #{one}"
  def plural(count, _one, many), do: "#{count} #{many}"

  # Only a trip with no direction can be grouped from a pattern list, so it is
  # the one reason that offers the review.
  defp reason_words("missing_direction", count) do
    %{
      tone: :warning,
      title: "#{plural(count, "trip has", "trips have")} no direction",
      body:
        "Nothing on this route says which way they run, so there is nothing to group them by. " <>
          "We find their stop orders and suggest a direction for each, and nothing changes until you confirm it.",
      action: %{label: "Group #{plural(count, "trip", "trips")}", primary?: true, target: :group}
    }
  end

  defp reason_words(code, count)
       when code in ~w(invalid_chronology invalid_time invalid_attribute) do
    %{
      tone: :error,
      title: "#{plural(count, "trip has", "trips have")} times out of order",
      body:
        "A stop is served before the trip departs, so its times cannot be read in order. " <>
          "Fix the times in the source feed and re-import this version; until then these trips stay as imported.",
      action: %{label: "View trips", primary?: false, target: :schedules}
    }
  end

  defp reason_words("unusable_stops", count) do
    %{
      tone: :error,
      title: "#{plural(count, "trip serves", "trips serve")} a station, not a boarding stop",
      body:
        "A stop on the route is a station, which has no platform to board at. Fix the stop in " <>
          "the source feed and re-import this version; until then this trip stays as imported.",
      action: %{label: "View trip", primary?: false, target: :schedules}
    }
  end

  defp reason_words("missing_times", count) do
    %{
      tone: :error,
      title:
        "#{plural(count, "trip is", "trips are")} missing a time at the first or last stop, or at a timepoint",
      body:
        "Import needs those times before it can read the trip’s running time. Fix them in the " <>
          "source feed and re-import this version; until then these trips stay as imported.",
      action: nil
    }
  end

  defp reason_words(code, count) when code in ~w(scope_mismatch pattern_mismatch) do
    %{
      tone: :error,
      title:
        "#{plural(count, "trip doesn’t", "trips don’t")} match the route pattern it is labelled with",
      body:
        "The feed points these trips at a route pattern for another direction or stop order. " <>
          "Fix the feed and re-import this version; until then these trips stay as imported.",
      action: %{label: "View trips", primary?: false, target: :schedules}
    }
  end

  defp reason_words(_code, count) do
    %{
      tone: :error,
      title: "#{plural(count, "trip wasn’t", "trips weren’t")} grouped into a pattern",
      body:
        "Import could not read enough of #{plural(count, "this trip", "these trips")} to place " <>
          "#{if count == 1, do: "it", else: "them"} in a pattern. Open Technical details for the " <>
          "reason, fix the source feed and re-import this version.",
      action: %{label: "View trips", primary?: false, target: :schedules}
    }
  end
end
