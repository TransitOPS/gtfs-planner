defmodule GtfsPlannerWeb.Gtfs.ComparePresentation do
  @moduledoc """
  R6/AC-15: the presentation values one release comparison renders.

  Pure. It reads only the result map it is given — no Repo, no process calls —
  so the same result always produces the same rows, and the page or a test can
  derive them without a database or a running comparison.
  """

  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare

  @day_classes [:weekdays, :saturdays, :sundays]

  @doc """
  One value per date in the comparison window, ascending.

  A date with no groups is `0`. A date whose every group is comparable and
  carries an integer `scheduled_count` is the sum of those groups' deltas; any
  non-comparable group, or a comparable one with an unmeasured count, makes the
  date's value `nil`.
  """
  @spec per_date(map()) :: [%{date: Date.t(), value: integer() | nil}]
  def per_date(%{window: %{from: from, to: to}} = result) do
    groups_by_date = Enum.group_by(result.groups, & &1.date)

    for date <- Date.range(from, to) do
      %{date: date, value: date_value(Map.get(groups_by_date, date, []))}
    end
  end

  @doc """
  The window's per-day-of-week values, in the fixed order weekdays, saturdays,
  sundays.

  A class is emitted only when the window carries at least one date of it, every
  one of those dates has an integer value, and all of them are equal.
  """
  @spec day_classes([%{date: Date.t(), value: integer() | nil}]) :: [
          %{class: :weekdays | :saturdays | :sundays, value: integer()}
        ]
  def day_classes(per_date) do
    by_class = Enum.group_by(per_date, fn %{date: date} -> day_class(Date.day_of_week(date)) end)

    Enum.flat_map(@day_classes, fn class ->
      case Map.get(by_class, class, []) do
        [] -> []
        entries -> class_clause(class, Enum.map(entries, & &1.value))
      end
    end)
  end

  @doc """
  The headline counts: distinct changed routes and compared route pairs.

  A change's route pair is its `:route_ids` `{left, right}`, falling back to
  `{change.route, change.route}` when the change carries no pair.
  """
  @spec conclusion(map()) :: %{changed: non_neg_integer(), compared: non_neg_integer()}
  def conclusion(result) do
    changed =
      result.effective_changes
      |> Enum.map(&change_route_pair/1)
      |> Enum.uniq()
      |> length()

    %{changed: changed, compared: length(Compare.route_pairs(result))}
  end

  @doc """
  One row per `{route, direction_id, kind, delta}` group of effective changes.

  `nil` `kind_filter` keeps every kind; a kind atom keeps only that kind. Rows
  keep the changes' own order, which the engine sorted by `change_order/1`, so a
  row's first appearance is stable.
  """
  @spec route_rows(map(), atom() | nil) :: [map()]
  def route_rows(result, kind_filter) do
    changes =
      result.effective_changes
      |> Enum.filter(&(is_nil(kind_filter) or &1.kind == kind_filter))

    {order, grouped} =
      Enum.reduce(changes, {[], %{}}, fn change, {order, grouped} ->
        key = {change.route, change.direction_id, change.kind, change.delta}

        if Map.has_key?(grouped, key) do
          {order, Map.update!(grouped, key, fn changes -> changes ++ [change] end)}
        else
          {order ++ [key], Map.put(grouped, key, [change])}
        end
      end)

    Enum.map(order, fn {route, direction_id, kind, delta} = key ->
      grouped_changes = Map.fetch!(grouped, key)

      %{
        route: route,
        route_ids: hd(grouped_changes).route_ids,
        direction_id: direction_id,
        kind: kind,
        delta: delta,
        dates: grouped_dates(grouped_changes),
        changes: grouped_changes
      }
    end)
  end

  @doc "How many effective changes carry each kind."
  @spec kind_counts(map()) :: %{atom() => non_neg_integer()}
  def kind_counts(result), do: Enum.frequencies_by(result.effective_changes, & &1.kind)

  defp date_value([]), do: 0

  defp date_value(groups) do
    if Enum.all?(groups, &comparable_group?/1) do
      Enum.reduce(groups, 0, fn group, sum -> sum + group.delta.scheduled_count end)
    else
      nil
    end
  end

  defp comparable_group?(%{comparable?: true, delta: %{scheduled_count: count}})
       when is_integer(count),
       do: true

  defp comparable_group?(_group), do: false

  defp day_class(day) when day in 1..5, do: :weekdays
  defp day_class(6), do: :saturdays
  defp day_class(7), do: :sundays

  defp class_clause(class, values) do
    if Enum.all?(values, &is_integer/1) and length(Enum.uniq(values)) == 1 do
      [%{class: class, value: hd(values)}]
    else
      []
    end
  end

  defp change_route_pair(%{route_ids: %{left: left, right: right}}), do: {left, right}
  defp change_route_pair(%{route: route}), do: {route, route}

  defp grouped_dates(changes) do
    changes
    |> Enum.flat_map(&change_dates/1)
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  defp change_dates(%{dates: dates}) when is_list(dates) and dates != [], do: dates
  defp change_dates(%{date: date}) when not is_nil(date), do: [date]
  defp change_dates(_change), do: []
end
