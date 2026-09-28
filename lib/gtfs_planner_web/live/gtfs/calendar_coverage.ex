defmodule GtfsPlannerWeb.Gtfs.CalendarCoverage do
  @moduledoc """
  Pure presentation geometry for the Calendars coverage axis.

  `project/2` turns one calendar screen read into one axis shared by every row:
  month ticks, the today marker, the version-wide gap bands and, per row, the
  overview bars or the near-view day cells. Only placement lives here. The exact
  effective dates stay on the screen (`active_dates`, `periods`, `exceptions`), so a
  clipped axis never limits a domain date set (INV-5) and the exact-details surface
  reads real dates instead of reconstructing them from bins.

  ## Ranges

    * `:whole` covers the feed's first to last active month. A history longer than 24
      months opens on the disclosed window from twelve months before today through the
      feed's last month, and `clipped?` reports that the axis is narrower than the feed.
    * `:all` is the same month-aligned span without that window.
    * `:near` is the 105 inclusive days from the Monday two weeks before today.

  ## Marks

  An overview mark covers one or more days with one `type`:

    * `:service` - inside the row's regular service periods,
    * `:added` - a date the row adds outside a weekly baseline; a specific-dates
      calendar's own dates are its regular service, not additions,
    * `:removed` - a `ServiceDates` holiday, a short run of removed expected days,
    * `:break` - inside a `ServiceDates` break of three or more removed expected days.

  Overview marks are quantized to at most 512 bins per row and adjacent bins holding the
  same kind counts merge, so a repeated uniform pattern costs one bar. A compressed bin
  that holds more than one kind is `mixed?: true` and reads as an approximation; the
  exact dates behind it remain on the screen. The near range
  instead returns one day cell per served, added or removed day, at most 105 of them.
  A day the row does not serve produces no mark, so the axis background shows through.

  ## Geometry

  `left`/`width` on marks, `position` on ticks and `today_position` are fractions of
  the axis width, so a caller only formats percentages. `gap_bands` carry the screen's
  version-wide service gaps clipped to the axis, and `today_position` is the centre of
  today's day cell or `nil` when today is outside the axis.
  """

  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates

  @max_bins 512
  @near_days 105
  @long_history_months 24
  @weeks_back 2
  @week_days 7
  @removed_exception 2

  @type range :: :whole | :near | :all
  @type mark_type :: :service | :added | :removed | :break
  @type kind_counts :: %{optional(mark_type()) => pos_integer()}

  @type mark :: %{
          first_date: Date.t(),
          last_date: Date.t(),
          left: float(),
          width: float(),
          type: mark_type(),
          mixed?: boolean()
        }

  @type bin :: %{
          first_index: non_neg_integer(),
          last_index: non_neg_integer(),
          type: mark_type(),
          mixed?: boolean(),
          counts: kind_counts()
        }

  @type tick :: %{date: Date.t(), position: float(), line?: boolean(), year?: boolean()}
  @type gap_band :: %{first_date: Date.t(), last_date: Date.t(), left: float(), width: float()}
  @type row :: %{marks: [mark()], offscreen: :before | :after | nil}
  @type window :: %{first_date: Date.t(), last_date: Date.t()}
  @type gap :: %{first_date: Date.t(), last_date: Date.t()}

  @type projection :: %{
          first_date: Date.t() | nil,
          last_date: Date.t() | nil,
          ticks: [tick()],
          today_position: float() | nil,
          clipped?: boolean(),
          gap_bands: [gap_band()],
          rows: %{optional(String.t()) => row()}
        }

  @type day_sets :: %{
          dates_only?: boolean(),
          extra: MapSet.t(Date.t()),
          holidays: MapSet.t(Date.t()),
          break_days: MapSet.t(Date.t()),
          periods: [ServiceDates.interval()],
          active: MapSet.t(Date.t()),
          removed: MapSet.t(Date.t())
        }

  @doc """
  Projects one calendar screen read onto the shared coverage axis.

  `range` is `:whole`, `:near` or `:all`. An axis is only created for a feed with at
  least one evaluated date; an all-empty feed returns no axis and empty rows instead
  of dividing by a zero span. Projecting a screen reads nothing and writes nothing.
  """
  @spec project(Calendars.screen(), range()) :: projection()
  def project(screen, range) when range in [:whole, :near, :all] do
    case axis(screen, range) do
      nil -> empty_projection(screen)
      window -> projection(screen, range, window)
    end
  end

  defp empty_projection(screen) do
    %{
      first_date: nil,
      last_date: nil,
      ticks: [],
      today_position: nil,
      clipped?: false,
      gap_bands: [],
      rows: Map.new(screen.rows, &{&1.service_id, %{marks: [], offscreen: nil}})
    }
  end

  defp projection(screen, range, window) do
    span = span(window)

    %{
      first_date: window.first_date,
      last_date: window.last_date,
      ticks: ticks(window, span),
      today_position: today_position(screen.today, window, span),
      clipped?: clipped?(screen.horizon, window),
      gap_bands: gap_bands(screen.gaps, window, span),
      rows: Map.new(screen.rows, &{&1.service_id, project_row(&1, range, window, span)})
    }
  end

  # -- axis -------------------------------------------------------------------

  # A feed with no evaluated date has no axis to share, so every range reports the
  # empty projection rather than dividing by a zero span.
  defp axis(%{horizon: nil}, _range), do: nil

  defp axis(%{today: today}, :near) do
    first_date = today |> monday() |> Date.add(-@weeks_back * @week_days)

    %{first_date: first_date, last_date: Date.add(first_date, @near_days - 1)}
  end

  defp axis(%{today: today, horizon: horizon}, range) do
    first_date = Date.beginning_of_month(horizon.first_date)
    last_date = Date.end_of_month(horizon.last_date)
    recent_start = Date.new!(today.year - 1, today.month, 1)

    # Only `:whole` discloses the recent window, and only when the feed really starts
    # earlier, so a feed that is already recent or future-dated keeps its own bounds.
    recent? =
      range == :whole and long_history?(first_date, last_date) and
        Date.compare(recent_start, first_date) == :gt

    %{first_date: if(recent?, do: recent_start, else: first_date), last_date: last_date}
  end

  @doc """
  Reports whether the feed's own month-aligned span is long enough for `:whole` to
  disclose a recent window instead of every year.

  The list surface reads this to decide whether `:all` has years to restore, so the
  24-month rule stays here rather than being restated in a template.
  """
  @spec long_history?(Calendars.screen()) :: boolean()
  def long_history?(%{horizon: nil}), do: false

  def long_history?(%{horizon: horizon}) do
    long_history?(
      Date.beginning_of_month(horizon.first_date),
      Date.end_of_month(horizon.last_date)
    )
  end

  defp long_history?(first_date, last_date) do
    months = (last_date.year - first_date.year) * 12 + (last_date.month - first_date.month) + 1

    months > @long_history_months
  end

  defp monday(date), do: Date.add(date, -(Date.day_of_week(date) - 1))

  defp span(%{first_date: first_date, last_date: last_date}),
    do: Date.diff(last_date, first_date) + 1

  defp index(date, %{first_date: first_date}), do: Date.diff(date, first_date)

  defp earlier(left, right), do: if(Date.compare(left, right) == :gt, do: right, else: left)
  defp later(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)

  defp in_window?(date, window) do
    Date.compare(date, window.first_date) != :lt and Date.compare(date, window.last_date) != :gt
  end

  defp clipped?(horizon, window) do
    Date.compare(window.first_date, Date.beginning_of_month(horizon.first_date)) == :gt or
      Date.compare(window.last_date, Date.end_of_month(horizon.last_date)) == :lt
  end

  defp today_position(today, window, span) do
    if in_window?(today, window) do
      (index(today, window) + 0.5) / span
    else
      nil
    end
  end

  # -- ticks and gap bands ----------------------------------------------------

  # A window starting mid-month names its first month without a month line; that is the
  # near range, whose window begins on a Monday rather than a month boundary.
  defp ticks(%{first_date: first_date} = window, span) do
    if first_date.day == 1 do
      month_ticks(first_date, window, span)
    else
      [tick(first_date, window, span, false) | month_ticks(next_month(first_date), window, span)]
    end
  end

  defp month_ticks(date, %{last_date: last_date} = window, span) do
    if Date.compare(date, last_date) == :gt do
      []
    else
      [tick(date, window, span, true) | month_ticks(next_month(date), window, span)]
    end
  end

  defp tick(date, window, span, line?) do
    %{date: date, position: index(date, window) / span, line?: line?, year?: date.month == 1}
  end

  defp next_month(date) do
    if date.month == 12 do
      Date.new!(date.year + 1, 1, 1)
    else
      Date.new!(date.year, date.month + 1, 1)
    end
  end

  defp gap_bands(nil, _window, _span), do: []

  defp gap_bands(gaps, window, span) do
    gaps
    |> Enum.flat_map(&clip(&1, window))
    |> Enum.map(fn gap ->
      {left, width} = geometry(index(gap.first_date, window), index(gap.last_date, window), span)
      Map.merge(gap, %{left: left, width: width})
    end)
  end

  defp clip(gap, window) do
    first_date = later(gap.first_date, window.first_date)
    last_date = earlier(gap.last_date, window.last_date)

    if Date.compare(first_date, last_date) == :gt do
      []
    else
      [%{first_date: first_date, last_date: last_date}]
    end
  end

  # -- rows -------------------------------------------------------------------

  defp project_row(row, range, window, span) do
    %{marks: marks(row, range, window, span), offscreen: offscreen(row, window)}
  end

  defp offscreen(%{first_active_date: first_active, last_active_date: last_active}, window) do
    cond do
      before?(last_active, window.first_date) -> :before
      after?(first_active, window.last_date) -> :after
      true -> nil
    end
  end

  defp before?(%Date{} = last_active, %Date{} = first_date),
    do: Date.compare(last_active, first_date) == :lt

  defp before?(_last_active, _first_date), do: false

  defp after?(%Date{} = first_active, %Date{} = last_date),
    do: Date.compare(first_active, last_date) == :gt

  defp after?(_first_active, _last_date), do: false

  # The near range draws exact day cells; every overview range draws quantized bars.
  defp marks(row, :near, window, span), do: near_marks(row, window, span)
  defp marks(row, _overview, window, span), do: overview_marks(row, window, span)

  defp near_marks(row, window, span) do
    sets = day_sets(row)

    day_indexes(span)
    |> Enum.flat_map(fn index ->
      case near_kind(Date.add(window.first_date, index), sets) do
        nil -> []
        kind -> [to_mark(day_bin(index, kind), window, span)]
      end
    end)
  end

  # One pass over the axis counts the kinds each bin holds. Period and break lists are
  # scanned linearly per day, so a row with hundreds of breaks costs days x intervals;
  # step 21's measurement would surface that before a cursor over sorted intervals is
  # worth the extra code.
  defp overview_marks(row, window, span) do
    sets = day_sets(row)
    bin_width = bin_width(span)

    day_indexes(span)
    |> Enum.reduce(%{}, fn index, bins ->
      case overview_kind(Date.add(window.first_date, index), sets) do
        nil -> bins
        kind -> Map.update(bins, div(index, bin_width), %{kind => 1}, &count_kind(&1, kind))
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {bin, counts} -> to_bin(bin, counts, bin_width, span) end)
    |> merge_bins()
    |> Enum.map(&to_mark(&1, window, span))
  end

  defp day_indexes(span), do: 0..(span - 1)

  defp day_bin(index, kind) do
    %{first_index: index, last_index: index, type: kind, mixed?: false, counts: %{kind => 1}}
  end

  defp count_kind(counts, kind), do: Map.update(counts, kind, 1, &(&1 + 1))

  defp bin_width(span), do: max(1, div(span + @max_bins - 1, @max_bins))

  defp to_bin(bin, counts, bin_width, span) do
    first_index = bin * bin_width
    {type, mixed?} = bin_kind(counts)

    %{
      first_index: first_index,
      last_index: min(first_index + bin_width - 1, span - 1),
      type: type,
      mixed?: mixed?,
      counts: counts
    }
  end

  # A bin holding more than one kind cannot claim exact coverage, so it is `mixed?`.
  # The dominant kind supplies its type, with a fixed tie-break order for determinism.
  defp bin_kind(counts) do
    [{type, _count} | _rest] =
      Enum.sort_by(counts, fn {kind, count} -> {-count, kind_rank(kind)} end)

    {type, map_size(counts) > 1}
  end

  defp kind_rank(:service), do: 0
  defp kind_rank(:added), do: 1
  defp kind_rank(:removed), do: 2
  defp kind_rank(:break), do: 3

  defp merge_bins(bins), do: bins |> Enum.reduce([], &merge_bin/2) |> Enum.reverse()

  defp merge_bin(bin, []), do: [bin]

  # Adjacent bins holding the same kind counts describe the same compressed pattern, so
  # they become one bar; the counts already determine the type and the `mixed?` state.
  # Only empty bins are dropped before this, so a day no row serves separates bars. The
  # bin ceiling holds either way, because merging only removes marks.
  defp merge_bin(bin, [previous | rest] = bins) do
    if previous.counts == bin.counts and previous.last_index + 1 == bin.first_index do
      [%{previous | last_index: bin.last_index} | rest]
    else
      [bin | bins]
    end
  end

  defp to_mark(bin, window, span) do
    {left, width} = geometry(bin.first_index, bin.last_index, span)

    %{
      first_date: Date.add(window.first_date, bin.first_index),
      last_date: Date.add(window.first_date, bin.last_index),
      left: left,
      width: width,
      type: bin.type,
      mixed?: bin.mixed?
    }
  end

  defp geometry(first_index, last_index, span),
    do: {first_index / span, (last_index - first_index + 1) / span}

  # -- day kinds --------------------------------------------------------------

  defp day_sets(row) do
    periods = row.periods

    %{
      dates_only?: row.kind == :dates_only,
      extra: MapSet.new(periods.extra_days),
      holidays: MapSet.new(periods.holidays),
      break_days:
        MapSet.new(Enum.flat_map(periods.breaks, &Date.range(&1.first_date, &1.last_date))),
      periods: periods.periods,
      active: MapSet.new(row.active_dates),
      removed: expected_removals(row)
    }
  end

  # Overview periods span whole weeks, so an expected off weekday inside a period stays
  # part of the row's regular service bar; the near range classifies the day exactly.
  defp overview_kind(date, sets) do
    cond do
      MapSet.member?(sets.extra, date) -> extra_kind(sets)
      MapSet.member?(sets.holidays, date) -> :removed
      MapSet.member?(sets.break_days, date) -> :break
      in_periods?(sets.periods, date) -> :service
      true -> nil
    end
  end

  defp near_kind(date, sets) do
    cond do
      MapSet.member?(sets.extra, date) -> extra_kind(sets)
      MapSet.member?(sets.active, date) -> :service
      MapSet.member?(sets.removed, date) -> :removed
      true -> nil
    end
  end

  # A specific-dates calendar's own dates are its regular service, not additions to a
  # weekly baseline it does not have.
  defp extra_kind(%{dates_only?: true}), do: :service
  defp extra_kind(%{dates_only?: false}), do: :added

  defp in_periods?(periods, date) do
    Enum.any?(periods, fn period ->
      Date.compare(date, period.first_date) != :lt and Date.compare(date, period.last_date) != :gt
    end)
  end

  # `ServiceDates` reports the two removals that never had an expected service day: a
  # removal on an off weekday inside the range and a removal outside the weekly range.
  # Neither is a day off, so no mark claims one.
  defp expected_removals(row) do
    noops = row.warnings |> Enum.filter(&noop_removal?/1) |> MapSet.new(& &1.date)

    row.exceptions
    |> Enum.filter(&(&1.exception_type == @removed_exception))
    |> MapSet.new(& &1.date)
    |> MapSet.difference(noops)
  end

  defp noop_removal?(%{reason: :removal_on_nonservice_day}), do: true
  defp noop_removal?(%{reason: :outside_range, exception: :removed}), do: true
  defp noop_removal?(_warning), do: false
end
