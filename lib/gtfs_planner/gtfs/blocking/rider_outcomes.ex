defmodule GtfsPlanner.Gtfs.Blocking.RiderOutcomes do
  @moduledoc """
  The rider-facing copy of one in-seat connection: its hints, what each trip
  planner will tell a rider, the footnote under that table, the pickup/drop-off
  warning and the text a refused save explains itself with.

  The module holds the copy and nothing else, so a claim about a consumer is
  written once and rendered from one place (CR-3). The copy is corrected against
  each publisher's published behaviour rather than guessed: Google Maps ignores
  transfer types 4 and 5 and decides from the block, the stops and the routes;
  OpenTripPlanner infers a stay-seated link from the block within 200 m and adds
  one for a type 4 record with no distance or time check, dropping that record
  where drop-off or pickup is not allowed; Transit reads types 4, 5 and
  `block_id` alike, so it follows the choice without distinguishing it.

  `hints/1` returns neutral facts in a fixed order — the route change, the
  turnback, the wait, the distance — and never a verdict, because the editor
  decides and the hints only say what the data shows. `rows/2` returns one
  `{app, title, detail}` map per planner, Google Maps first because it is the one
  that ignores the setting, and `:conflict` reads as `:none` because a pair of
  disagreeing records has no single rider outcome until it is resolved.

  The module is pure: it reads the connection it is given and calls no
  repository, clock, file or network.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.InSeat

  # A wait worth a hint: Transit's converter treats waits over 10 minutes as
  # must re-board, so a gap above it is a fact the editor is unlikely to know.
  @wait_hint_secs 600

  @type setting :: :none | :stay | :reboard | :conflict

  @typedoc """
  What the copy is written about: the two trips of one connection, the gap
  between them and whether the pair is a turnback.

  `turnback?` is the caller's own fact — the connection grouping already decides
  it — so this module never re-derives it and the two can never disagree.
  """
  @type connection :: %{
          from: Checks.trip_row(),
          to: Checks.trip_row(),
          gap: Checks.gap(),
          turnback?: boolean()
        }

  @typedoc "One hint: its kind, which is also the order the drawer lists them in."
  @type hint :: %{kind: :route_change | :turnback | :wait | :distance, text: String.t()}

  @typedoc "One planner's row of the rider table."
  @type row :: %{app: String.t(), title: String.t(), detail: String.t()}

  @doc """
  Returns the connection's hints, in the order route change, turnback, wait,
  distance.

  A route change is a fact about the two routes, whatever the handoff, and it
  names the handoff the way the editor reads it: the same stop, another stop of
  the same station, a stop a walkable distance away, or another stop. A turnback
  is added when the caller's `turnback?` says the one route's two directions meet
  here, a wait when the gap is over ten minutes, and a distance when the vehicle
  moves empty between two stops whose distance is known.

  A headsign the version does not carry is left out of the sentence rather than
  read as a blank, so the hint still names the route and the handoff.
  """
  @spec hints(connection()) :: [hint()]
  def hints(connection) do
    Enum.flat_map(
      [
        route_change_hint(connection),
        turnback_hint(connection),
        wait_hint(connection),
        distance_hint(connection)
      ],
      & &1
    )
  end

  @doc """
  Returns one row per trip planner — Google Maps, OpenTripPlanner, the Transit
  app — for the given choice.

  Google's row depends only on the handoff and the routes, never on the choice,
  because Google ignores the setting. OpenTripPlanner's row follows the choice:
  `:stay` adds a link wherever it is not dropped for a forbidden pickup or
  drop-off, `:reboard` removes the link it would infer, and `:none` reports what
  it infers from the block. The Transit app's row reports whether it follows the
  choice or decides for itself. A `:conflict` pair reads as `:none`.
  """
  @spec rows(connection(), setting()) :: [row()]
  def rows(connection, setting) do
    [
      %{app: "Google Maps", title: google_title(connection), detail: google_detail(connection)},
      %{
        app: "OpenTripPlanner",
        title: otp_title(connection, choice(setting)),
        detail: otp_detail(connection, choice(setting))
      }
    ] ++ [transit_row(choice(setting))]
  end

  @doc """
  Returns the line under the rider table.

  It names the behaviour the table cannot show: Transit propagates a delay from
  the block or from either record, so the choice does not change what riders see
  there, and OneBusAway reads the block rather than the record.
  """
  @spec footnote() :: String.t()
  def footnote do
    "Transit can carry delays into the next trip from the block or from either record. " <>
      "OneBusAway shows \"Continues as\" from the block and ignores this setting."
  end

  @doc """
  Returns why OpenTripPlanner would drop a type 4 record at this handoff, or nil.

  A record is dropped silently where the arriving trip does not allow drop-off at
  its last stop or the departing trip does not allow pickup at its first one, so
  the drawer names the trip and the stop rather than only the effect.
  """
  @spec pickup_problem(connection()) :: String.t() | nil
  def pickup_problem(%{from: from, to: to}) do
    cond do
      to.first_pickup_type == 1 ->
        "Trip #{to.trip_id} doesn't allow pickup at its first stop, #{stop_name(to.first_stop)}."

      from.last_drop_off_type == 1 ->
        "Trip #{from.trip_id} doesn't allow drop-off at its last stop, " <>
          "#{stop_name(from.last_stop)}."

      true ->
        nil
    end
  end

  @doc """
  Returns what a refused save or a stale record tells the editor.

  A not-next failure joins one sentence per day type, naming the trip that runs
  next where the day type has one — the trip a rider would be put on instead —
  and the day type's own label and date count, so the reason links to the right
  day type. The other reasons are one fixed sentence each. `:matches` has no text
  because it is never a refusal.
  """
  @spec refusal_text(InSeat.state()) :: String.t() | nil
  def refusal_text(:matches), do: nil
  def refusal_text({:stale, {:not_next, failures}}), do: not_next_text(failures)
  def refusal_text({:unconfirmed, :coupling}), do: coupling_text()
  def refusal_text({:unconfirmed, :untimed}), do: untimed_text()
  def refusal_text({:unconfirmed, :next_service_day}), do: next_service_day_text()
  def refusal_text({:stale, :no_block}), do: "A trip has no block."
  def refusal_text({:stale, :no_shared_date}), do: "The trips share no date."
  def refusal_text({:stale, :trip_missing}), do: "A trip isn't in this version."
  def refusal_text({:stale, :stops_changed}), do: "The record's stops changed."

  # --- hints ------------------------------------------------------------

  defp route_change_hint(%{from: from, to: to} = connection) do
    if from.route_id == to.route_id do
      []
    else
      [
        hint(
          :route_change,
          "Continues as Route #{to.route_id}#{toward(to)} #{handoff_phrase(connection.gap.handoff)} " <>
            "after #{wait_minutes(connection.gap)} min."
        )
      ]
    end
  end

  defp turnback_hint(%{from: from, to: to, turnback?: true}) do
    [
      hint(
        :turnback,
        "Route #{from.route_id} turns back here#{towardward(to)}. Google offers staying on within " <>
          "one route only for loop routes. Transit's converter treats a next trip that retraces " <>
          "this one as must re-board, unless both ends are within 500 m."
      )
    ]
  end

  defp turnback_hint(_connection), do: []

  defp wait_hint(%{gap: %{gap_secs: gap_secs} = gap}) do
    if gap_secs > @wait_hint_secs do
      [
        hint(
          :wait,
          "The vehicle waits #{wait_minutes(gap)} min. Transit's converter treats waits over " <>
            "10 min as must re-board and over 20 min as unlinked. OpenTripPlanner has no wait " <>
            "limit."
        )
      ]
    else
      []
    end
  end

  # Only a known distance is a fact; `{:moves, nil}` says the coordinates are
  # missing, which the rider table already reports as an unknown.
  defp distance_hint(%{gap: %{handoff: {:moves, meters}}}) when is_integer(meters) do
    [
      hint(
        :distance,
        "Stops are #{meters} m apart; the vehicle moves empty between them. OpenTripPlanner " <>
          "infers staying on only within 200 m but honours \"Riders stay on board\" at any " <>
          "distance. Transit's converter says re-board beyond 500 m."
      )
    ]
  end

  defp distance_hint(_connection), do: []

  defp hint(kind, text), do: %{kind: kind, text: text}

  # A headsign the version does not carry leaves the sentence naming the route
  # and the handoff alone rather than reading as a blank after "to".
  defp toward(to), do: headsign_phrase(to, " to ")
  defp towardward(to), do: headsign_phrase(to, " toward ")

  defp headsign_phrase(to, prefix) do
    case presence(to.trip_headsign) do
      nil -> ""
      headsign -> prefix <> headsign
    end
  end

  defp handoff_phrase(:same_stop), do: "from the same stop"
  defp handoff_phrase(:same_station), do: "from another stop in the same station"

  defp handoff_phrase({:nearby, meters}) when is_integer(meters),
    do: "from a stop #{meters} m away"

  defp handoff_phrase({:moves, _meters}), do: "from another stop"

  defp wait_minutes(%{gap_secs: gap_secs}), do: div(gap_secs, 60)

  # --- rider table ------------------------------------------------------

  defp google_title(%{from: from, to: to, gap: gap}) do
    cond do
      not close?(gap.handoff) -> "Unknown"
      from.route_id != to.route_id -> "Shows one continuous ride"
      true -> "Only if Route #{to.route_id} is a loop"
    end
  end

  defp google_detail(%{from: from, to: to, gap: gap}) do
    cond do
      not close?(gap.handoff) ->
        "Google needs the same or a physically close stop and publishes no distance. " <>
          "It ignores this setting."

      from.route_id != to.route_id ->
        "Tells riders to stay on the vehicle, from the shared block. Google Maps ignores " <>
          "this setting."

      true ->
        "Google offers staying on within one route only for loop routes. It ignores this setting."
    end
  end

  # A stay the record forbids is the one row where OTP shows no link, so the
  # title follows the same problem the detail names.
  defp otp_title(connection, :stay) do
    if pickup_problem(connection), do: "No stay-on link", else: "Stay on board"
  end

  defp otp_title(_connection, :reboard), do: "No stay-on link"

  # Not stated: OTP infers the link itself, and its only test is the 200 m
  # default, so a move is a link it will not make and a move with no coordinates
  # is one it cannot judge.
  defp otp_title(%{gap: %{handoff: {:moves, nil}}}, :none), do: "Unknown"
  defp otp_title(%{gap: %{handoff: {:moves, _meters}}}, :none), do: "No stay-on link"
  defp otp_title(_connection, :none), do: "Stay on board"

  defp otp_detail(connection, :stay) do
    case pickup_problem(connection) do
      nil ->
        "Shows \"Stay on board at #{stop_name(connection.to.first_stop)}\" and counts no " <>
          "transfer, with no distance or time check."

      problem ->
        "OpenTripPlanner drops this record. #{problem}"
    end
  end

  defp otp_detail(_connection, :reboard) do
    "Removes the link it would infer. Shows an ordinary transfer if it offers one."
  end

  defp otp_detail(%{gap: %{handoff: {:moves, nil}}}, :none) do
    "Stop coordinates are missing, so the distance is unknown."
  end

  defp otp_detail(%{gap: %{handoff: {:moves, _meters}}}, :none) do
    "Stops are more than 200 m apart (OpenTripPlanner's default)."
  end

  defp otp_detail(_connection, :none) do
    "Inferred from the block: stops within 200 m (OpenTripPlanner's default), whatever the wait."
  end

  defp transit_row(:stay) do
    %{app: "Transit app", title: "Stay on board", detail: "Follows this setting."}
  end

  defp transit_row(:reboard) do
    %{app: "Transit app", title: "Get off and board again", detail: "Follows this setting."}
  end

  defp transit_row(:none) do
    %{
      app: "Transit app",
      title: "Decides from the block",
      detail: "Uses its own wait, distance and turnback rules."
    }
  end

  # A conflict is two records that disagree, so until it is resolved the only
  # outcome a rider can be shown is the one neither record writes.
  defp choice(:conflict), do: :none
  defp choice(setting), do: setting

  # Google needs the same or a physically close stop; a move is neither, and a
  # move whose distance is unknown is the same answer as one that is too long.
  defp close?(:same_stop), do: true
  defp close?(:same_station), do: true
  defp close?({:nearby, _meters}), do: true
  defp close?({:moves, _meters}), do: false

  # --- refusals ---------------------------------------------------------

  defp not_next_text(failures) do
    Enum.map_join(failures, " ", &not_next_sentence/1)
  end

  defp not_next_sentence(%{label: label, date_count: date_count, next_trip_id: nil}) do
    "On #{label}, #{date_count} dates, these trips aren't consecutive on one vehicle."
  end

  defp not_next_sentence(%{label: label, date_count: date_count, next_trip_id: next_trip_id}) do
    "On #{label}, #{date_count} dates, trip #{next_trip_id} runs next on this vehicle, so these " <>
      "trips aren't one vehicle on every date they share."
  end

  defp coupling_text do
    "The second trip starts before the first one ends, so they can't be one vehicle in sequence."
  end

  defp untimed_text,
    do: "A trip has missing or repeating times, so this connection can't be checked."

  defp next_service_day_text do
    "The second trip runs on the next service day, which this view can't set."
  end

  defp stop_name(nil), do: "an unnamed stop"

  defp stop_name(stop_ref) do
    presence(stop_ref.name) || presence(stop_ref.parent_name) || presence(stop_ref.stop_id) ||
      "an unnamed stop"
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
