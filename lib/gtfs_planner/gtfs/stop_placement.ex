defmodule GtfsPlanner.Gtfs.StopPlacement do
  @moduledoc """
  The judgements an editor makes about where a stop sits, as pure functions.

  Placing a stop on a map raises questions that have no single right answer,
  only defensible ones: is this a second copy of the stop I just placed, is it on
  the wrong side of the street, is it so far from the line that the shape is
  wrong rather than the stop. Each of those is a threshold, and the thresholds
  live here and nowhere else (INV-3), so that "why does the editor warn at 5 m
  and not at 6" has one answer.

  Every function takes points as `{lon, lat}`, the order the map hook sends
  coordinates in. Callers holding a `{lat, lon}` pair convert at the edge rather
  than relying on this module to guess.

  The geometry works in a local metre grid around the point being measured,
  because projecting a whole city onto a sphere is not needed to answer "is this
  3 m off the line". Over the tens of metres a stop can be from a line, an
  equirectangular projection is accurate to well under a centimetre.
  """

  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  # Metres per degree of latitude, at the equator. Longitude is scaled by the
  # cosine of the latitude, which is what makes a local grid roughly square.
  @metres_per_degree 111_320.0

  # Two stops closer than this are the same stop placed twice. Five metres is
  # about one doorway: close enough that a rider could not tell which stop the
  # vehicle stopped at.
  @duplicate_metres 5.0

  # A stop further than this from another is its own place. Thirty metres is far
  # enough to be a different doorway, close enough to be worth a look when an
  # editor is reviewing a feed.
  @nearby_metres 30.0

  # A stop further than this from every serving line is off the shape.
  @off_line_metres 100.0

  # A stop at least this far from a line is not on the kerb. Measured across a
  # northbound line, so a rider on the far pavement is on the wrong side.
  @wrong_side_metres 3.0

  # How far a stop may be moved and still be called a correction rather than
  # something a person must review. Eight metres is about a kerbside reposition;
  # past it, the editor's intent is unclear.
  @correction_metres 8.0

  # Past this, a move changes where the stop serves. Being told "yes, move it
  # that far" is not a reason to accept moving a stop four hundred metres.
  @far_metres 100.0

  @type point :: {float(), float()}
  @type line :: [point()]
  @type role :: :shape | :connector
  @type classification :: :duplicate | :nearby | :distinct
  @type warning :: :wrong_side | :middle_of_street | :off_line
  @type move_band :: :correction | :review | :far
  @type travel_direction :: :northbound | :southbound | :eastbound | :westbound

  # The shapes `version_checks/1` reads. They are the `StopsMap` row maps, named
  # here rather than referenced as `StopsMap.stop_row()`: `StopsMap` calls into
  # this module at runtime, so a compile-time typespec reference back to it would
  # close a cycle. The fields this function actually reads are `:id`, `:stop_id`,
  # `:point`, `:location_type`, `:parent_station`, `:served?` and `:pattern_ids`,
  # and `:pattern_id`, `:source` and `:points` on a line.
  @type checked_stop :: map()
  @type checked_line :: map()

  # One thing an editor should be told about a point they just placed. The
  # shape is the same as `version_checks/1`'s findings, because the panel
  # renders both: a `dom_id` to address the row, a `kind` to style and test it,
  # copy an editor can act on, an `action` and whatever that action needs. The
  # action never carries a point — it names a stop or a line, and the caller
  # re-derives the point from what the server holds (INV-4).
  @type finding :: %{
          required(:kind) => atom(),
          required(:dom_id) => String.t(),
          required(:title) => String.t(),
          required(:text) => String.t(),
          required(:action) => nil | :open_duplicate | :move_across,
          required(:action_key) => String.t() | nil,
          required(:action_label) => String.t() | nil,
          required(:stop_id) => String.t() | nil,
          required(:line) => map() | nil
        }

  # How close a shape has to be for the panel to say which routes pass here.
  # A route a block away does not serve a stop on this street corner, and a
  # panel that named it would be offering a pattern the stop is not on.
  @passing_metres 30.0

  # The width of one bucket in the duplicate scan, in metres. A cell has to be
  # wider than the duplicate threshold or a pair either side of a boundary would
  # be missed, and narrow enough that the scan is not quadratic over a whole
  # city. Ten metres against a five-metre threshold leaves room on both sides.
  @cell_metres 10.0

  @doc """
  How far apart two stops are, in metres.
  """
  @spec distance(point(), point()) :: float()
  def distance({lon1, lat1}, {lon2, lat2}),
    do: Helpers.haversine(lat1, lon1, lat2, lon2)

  @doc """
  Whether two stops are the same stop placed twice, nearby, or distinct places.

  Judged only between stops, never against a shape: two stops 4 m apart are the
  same stop twice whatever the route does, and two stops 40 m apart are two
  stops however many lines run between them.
  """
  @spec classify(point(), point()) :: classification()
  def classify(a, b) do
    metres = distance(a, b)

    cond do
      metres < @duplicate_metres -> :duplicate
      metres <= @nearby_metres -> :nearby
      true -> :distinct
    end
  end

  @doc """
  Classifies two stops that share a parent station.

  Two child stops of one station are different levels or different platforms by
  construction, however close their pins are, so the answer is `:distinct` and
  the distance is returned for a diagram that wants to flag the overlap. Being
  this close is how a diagram stops being readable, but it is a diagram problem
  rather than a duplicate data problem.
  """
  @spec classify_shared_station(point(), point()) :: {classification(), float()}
  def classify_shared_station(a, b), do: {:distinct, distance(a, b)}

  @doc """
  How far a point sits from a line, and which side of it.

  Returns `{metres, :west | :east | :on}`. The side is relative to the direction
  the line runs: a point west of a northbound line is the far pavement from a
  vehicle travelling that way, and the same point east of a southbound line is
  the far pavement too. A point on the line is `:on` rather than a zero with an
  arbitrary side, so callers can tell "on the kerb" from "on the centreline".
  """
  @spec offset_m(point(), line()) :: {float(), :west | :east | :on}
  def offset_m(_point, []), do: {:infinity, :on}
  def offset_m(_point, [_only]), do: {:infinity, :on}

  def offset_m({lon, lat}, line) when is_list(line) do
    line
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&segment_offset({lon, lat}, &1))
    |> Enum.min_by(fn {metres, _side} -> metres end, fn -> {:infinity, :on} end)
  end

  defp segment_offset({lon, lat}, [{lon1, lat1}, {lon2, lat2}]) do
    # One frame, origin at the segment's first point: the point sits at (x, y)
    # and the segment runs from (0, 0) to (x2, y2).
    {x, y} = local({lon, lat}, {lon1, lat1})
    {x2, y2} = local({lon2, lat2}, {lon1, lat1})

    {foot_x, foot_y} = closest_point(x, y, x2, y2)

    east_offset = x - foot_x
    north_offset = y - foot_y

    {:math.sqrt(east_offset * east_offset + north_offset * north_offset),
     side_of(east_offset, y2)}
  end

  # The nearest point on the segment, clamped to its ends. A point beyond the
  # last vertex is measured to that vertex, not to the infinite line the segment
  # would extend along, so a stop past the end of a shape is as far away as the
  # shape's end really is.
  defp closest_point(x, y, x2, y2) do
    length_squared = x2 * x2 + y2 * y2

    if length_squared == 0.0 do
      {0.0, 0.0}
    else
      t = (x * x2 + y * y2) / length_squared

      cond do
        t <= 0.0 -> {0.0, 0.0}
        t >= 1.0 -> {x2, y2}
        true -> {t * x2, t * y2}
      end
    end
  end

  # Which side of the line the point falls on, relative to the direction the line
  # runs. A line running north serves its east kerb, so a point west of it is on
  # the far pavement; a line running south serves its west kerb, so the same east
  # offset is now the far side. `y2` is the line's northward extent, so its sign
  # is the direction of travel for any line that is not running east-west.
  # A line with no northward extent runs east-west, so a point on it has no side.
  defp side_of(_east_offset, y2) when abs(y2) < @metres_per_degree * 0.000001, do: :on

  defp side_of(east_offset, y2) when y2 > 0 do
    if east_offset < 0.0, do: :west, else: :east
  end

  defp side_of(east_offset, _y2) do
    if east_offset > 0.0, do: :west, else: :east
  end

  # Local metres east and north of the segment's first point.
  defp local({lon, lat}, {lon_ref, lat_ref}) do
    {(lon - lon_ref) * @metres_per_degree * :math.cos(:math.pi() * lat_ref / 180),
     (lat - lat_ref) * @metres_per_degree}
  end

  @doc """
  A point reflected across a line, for the editor's "put it on this side" action.

  Reflects in the line itself, so a point 8 m east of a northbound line comes
  back 8 m west of it, on the kerb the vehicle actually serves. A point already
  on the line reflects to itself. An empty or single-point line returns the
  point unchanged, because there is nothing to reflect in.
  """
  @spec across_street(point(), line()) :: point()
  def across_street(point, []), do: point
  def across_street(point, [_only]), do: point

  def across_street({lon, lat}, line) do
    {lon1, lat1} = hd(line)
    {lon2, lat2} = List.last(line)

    # One frame, origin at the line's first point: the line runs from (0, 0) to
    # (x2, y2) and the point sits at (x, y).
    {x, y} = local({lon, lat}, {lon1, lat1})
    {x2, y2} = local({lon2, lat2}, {lon1, lat1})

    dx = x2
    dy = y2
    length_squared = dx * dx + dy * dy

    if length_squared == 0.0 do
      {lon, lat}
    else
      # The point's projection onto the line, then the same distance again on
      # the far side of it.
      t = (x * dx + y * dy) / length_squared
      foot_x = t * dx
      foot_y = t * dy

      unproject({2 * foot_x - x, 2 * foot_y - y}, {lon1, lat1})
    end
  end

  defp unproject({x, y}, {lon_ref, lat_ref}) do
    {lon_ref + x / (@metres_per_degree * :math.cos(:math.pi() * lat_ref / 180)),
     lat_ref + y / @metres_per_degree}
  end

  @doc """
  The warning a point on a line deserves, or nil.

  A `:shape` line is where the vehicle actually runs, so a stop on the wrong side
  of one is a real error: riders on that pavement wait for the wrong direction. A
  `:connector` line joins two shapes and describes no roadside at all, so the
  same distances produce no side warning — only `:off_line`, which is a
  statement about distance and so means the same thing for either role.
  """
  @spec warn(point(), line(), role()) :: warning() | nil
  def warn(_point, [], _role), do: nil

  def warn(point, line, :connector), do: off_line(point, line)

  def warn(point, line, :shape) do
    {metres, side} = offset_m(point, line)

    cond do
      metres > @off_line_metres -> :off_line
      side == :west and metres > @wrong_side_metres -> :wrong_side
      # On the served side but nearer the centreline than the kerb: right side
      # of the road, wrong place in it. The band is the same three metres the
      # wrong-side rule uses, so the two partition the kerbside cleanly.
      metres <= @wrong_side_metres -> :middle_of_street
      true -> nil
    end
  end

  defp off_line(point, line) do
    case offset_m(point, line) do
      {metres, _side} when metres > @off_line_metres -> :off_line
      _ -> nil
    end
  end

  @doc """
  How much a proposed move should worry the editor.

  A stop nothing serves can be moved as far as the editor likes: there is no
  schedule to contradict, so the move is a correction whatever its size. A stop
  that is served has riders and a timetable attached to where it is, so moving it
  is a `:review` past the correction band and `:far` past a hundred metres,
  however confident the editor is.
  """
  @spec move_band(float(), boolean()) :: move_band()
  def move_band(_metres, false), do: :correction
  def move_band(metres, true) when metres > @far_metres, do: :far
  def move_band(metres, true) when metres > @correction_metres, do: :review
  def move_band(_metres, _served), do: :correction

  @doc """
  Thins a polyline to the points that carry its shape, by Douglas-Peucker.

  A shape point exists because the road turned. Points within `tolerance_m` of
  the straight line between the points that survive are noise at street zoom
  and are dropped; the ones that carry a real deviation are kept. The distance
  is metres, measured the same way as every other judgement here, so the
  tolerance an editor can see on the map is the tolerance this applies.

  The first and last point are always kept. A line that lost either would be
  drawn short, and a shape's endpoints are frequently the only place a route
  turns — dropping the last one shortens the drawn route to the previous street.
  A line of fewer than three points is already minimal and is returned as it is.
  """
  @spec simplify([point()], float()) :: [point()]
  def simplify([], _tolerance_m), do: []

  def simplify([only], _tolerance_m), do: [only]

  def simplify([first, second], _tolerance_m), do: [first, second]

  def simplify([first | _rest] = line, tolerance_m) do
    last = List.last(line)
    inner = Enum.drop(line, 1) |> Enum.drop(-1)

    # Douglas-Peucker: if nothing between the endpoints strays further from the
    # chord than the tolerance, they are the whole line. Otherwise keep the
    # point that strays furthest and recurse on each side of it, taking the
    # *slice* of the line between the two bounding points so no point is ever
    # measured against a chord it is not between.
    apex = Enum.max_by(inner, &deviation(&1, first, last), fn -> nil end)

    cond do
      is_nil(apex) ->
        [first, last]

      deviation(apex, first, last) <= tolerance_m ->
        [first, last]

      true ->
        # The apex is the one point that must survive both halves and sits in
        # neither slice, so it is stitched between them. Neither slice contains
        # it and neither slice's endpoints are dropped, so the line's first and
        # last point come through untouched.
        index = Enum.find_index(line, &(&1 == apex))
        {before, [_apex | after_apex]} = Enum.split(line, index)

        simplify(before, tolerance_m) ++ [apex] ++ simplify(after_apex, tolerance_m)
    end
  end

  # How far a point sits from the straight line between the line's two
  # endpoints, in metres. `offset_m/2` is exactly that measurement on a
  # two-point line, so this is the same geometry every other function here
  # uses rather than a second projection of the same question.
  defp deviation(point, first, last), do: offset_m(point, [first, last]) |> elem(0)

  @doc """
  Which way a line runs, in the word a stop's description uses.

  The comparison is made in the same local metre grid every other measurement
  here uses, so the axis a line is "mostly" running along is the axis a reader
  would call it running along, rather than an artefact of how wide a degree of
  longitude is at this latitude. A line with no extent answers `nil`: there is
  no direction to name, and "Northbound" for a stopped line is a lie.
  """
  @spec travel_direction(line()) :: travel_direction() | nil
  def travel_direction([]), do: nil
  def travel_direction([_only]), do: nil

  def travel_direction([first | _rest] = line) do
    {east, north} = local(List.last(line), first)

    cond do
      abs(north) >= abs(east) and north > 0 -> :northbound
      abs(north) >= abs(east) -> :southbound
      east > 0 -> :eastbound
      true -> :westbound
    end
  end

  @doc """
  Every placement problem a point an editor just dropped deserves, in the order
  the editor meets them.

  Takes the same `StopsMap.load/2` model `version_checks/1` takes and answers
  with a list of findings, each already carrying its copy, its DOM id and the
  action it offers:

    * `:middle_of_street` — the point is within `@wrong_side_metres` of a shape's
      centreline, so it is on the right side of the road and in the wrong place
      in it. Nothing else is said: a point in the middle of the street is not
      also a duplicate.
    * `:duplicate` — a stop within `@duplicate_metres` that shares no station,
      with "Open …" naming that stop.
    * `:wrong_side` — the point is on the far pavement of a shape it can reach,
      with "Move it across the street"; the reflection is the server's to make.
    * `:nearby` — the two next stops out to `@nearby_metres`, in one line.
    * `:passing` — which routes run past on the served side, and the promise
      that the stop can be added to one of them; or the absence of any.

  `:duplicate` and `:wrong_side` are suppressed for a point in the middle of the
  street, because both of them are about which kerb the stop is on and the
  middle of the street is on neither. A stop in the middle of a road with a
  duplicate 4 m away is told to move to the kerb first, and is told about the
  duplicate next.

  The actions carry a stop ID and a line rather than a point, so the caller
  cannot be talked into moving the draft somewhere the server would not have
  put it.
  """
  @spec warnings(point(), %{
          required(:stops) => [checked_stop()],
          required(:lines) => [checked_line()],
          required(:routes) => map()
        }) :: [finding()]
  def warnings(point, model) do
    shapes = Enum.filter(model.lines || [], &(&1.source == :shape))
    middle? = Enum.any?(shapes, &(warn(point, &1.points, :shape) == :middle_of_street))

    middle_finding(middle?) ++
      duplicate_finding(point, model, middle?) ++
      wrong_side_finding(point, model, shapes, middle?) ++
      nearby_finding(point, model, middle?) ++
      passing_finding(point, model, shapes, middle?)
  end

  defp middle_finding(true) do
    [
      %{
        kind: :middle_of_street,
        dom_id: "add-warning-middle",
        title: "This is the middle of the street",
        text:
          "Drag the pin to the curb where riders wait. The side decides which buses can use it.",
        action: nil,
        action_key: nil,
        action_label: nil,
        stop_id: nil,
        line: nil
      }
    ]
  end

  defp middle_finding(false), do: []

  defp duplicate_finding(point, model, middle?) do
    if middle? do
      []
    else
      case nearest_stops(point, model.stops, @duplicate_metres, 1) do
        [{stop, _metres}] ->
          [
            %{
              kind: :duplicate,
              dom_id: "add-warning-duplicate-#{dom_id(stop.stop_id)}",
              title:
                "#{stop_label(stop)} is #{format_distance(distance(point, stop.point))} away",
              text:
                "#{presence(stop.desc)}ID #{stop.stop_id}. If riders wait at the same sign, use that stop instead of adding another.",
              action: :open_duplicate,
              action_key: stop.stop_id,
              action_label: "Open #{stop_label(stop)}",
              stop_id: stop.stop_id,
              line: nil
            }
          ]

        _none ->
          []
      end
    end
  end

  defp wrong_side_finding(point, model, shapes, middle?) do
    if middle? do
      []
    else
      case Enum.find(shapes, &(warn(point, &1.points, :shape) == :wrong_side)) do
        nil ->
          []

        line ->
          [
            %{
              kind: :wrong_side,
              dom_id: "add-warning-wrong-side-#{dom_id(line.pattern_id)}",
              title: "Buses pass on the far side of the street",
              text:
                "#{route_label(model, line)} runs #{direction_phrase(line.points)} here, so riders board from the other curb.",
              action: :move_across,
              action_key: line.pattern_id,
              action_label: "Move it across the street",
              stop_id: nil,
              line: line
            }
          ]
      end
    end
  end

  defp nearby_finding(point, model, middle?),
    do: if(middle?, do: [], else: nearby_names_finding(point, model))

  defp nearby_names_finding(point, model) do
    case nearest_stops(point, model.stops, @nearby_metres, 3) do
      [] ->
        []

      nearby ->
        names = Enum.map_join(nearby, "; ", &nearby_label/1)

        [
          %{
            kind: :nearby,
            dom_id: "add-warning-nearby",
            title: "Nearby",
            text: "#{names}.",
            action: nil,
            action_key: nil,
            action_label: nil,
            stop_id: nil,
            line: nil
          }
        ]
    end
  end

  defp nearby_label({stop, metres}),
    do: "#{stop_label(stop)}#{desc_suffix(stop)} (#{format_distance(metres)})"

  defp passing_finding(point, model, shapes, middle?),
    do: if(middle?, do: [], else: passing_lines_finding(point, model, shapes))

  defp passing_lines_finding(point, model, shapes) do
    case passing_lines(point, shapes) do
      [] -> [no_pattern_finding()]
      lines -> [passing_finding_row(model, lines)]
    end
  end

  defp no_pattern_finding do
    %{
      kind: :no_pattern,
      dom_id: "add-warning-no-pattern",
      title: "No pattern passes here yet",
      text: "The stop can still be added to one later.",
      action: nil,
      action_key: nil,
      action_label: nil,
      stop_id: nil,
      line: nil
    }
  end

  defp passing_finding_row(model, lines) do
    names = lines |> Enum.map(&route_label(model, &1)) |> Enum.uniq()

    text =
      case names do
        [one] ->
          "#{one} passes on this side. You can add the stop to it after creating it."

        many ->
          "#{length(many)} patterns pass on this side: #{Enum.join(many, ", ")}. You can add the stop to them after creating it."
      end

    %{
      kind: :passing,
      dom_id: "add-warning-passing",
      title: "Routes on this side",
      text: text,
      action: nil,
      action_key: nil,
      action_label: nil,
      stop_id: nil,
      line: nil
    }
  end

  # The shapes close enough to serve this point, on the kerb a vehicle on them
  # actually stops at. `:west` is the far pavement for a shape's own direction
  # of travel, and a point in the middle of the road is not on a kerb at all —
  # which is why the caller has already answered that case.
  defp passing_lines(point, shapes) do
    Enum.filter(shapes, fn line ->
      {metres, side} = offset_m(point, line.points)
      metres <= @passing_metres and side in [:east, :on]
    end)
  end

  # The stops nearest this point, each with its distance. Stations are skipped
  # because a station is a container for bays rather than a place riders wait,
  # and this list is read as places. A bay is not skipped: a bay three metres
  # from a new stop is the same sign, and the same-station exemption
  # `version_checks/1` takes does not apply, because a draft belongs to no
  # station.
  defp nearest_stops(point, stops, max_metres, limit) do
    stops
    |> Enum.filter(fn stop ->
      is_map(stop) and not is_nil(stop.point) and stop.location_type == 0
    end)
    |> Enum.map(fn stop -> {stop, distance(point, stop.point)} end)
    |> Enum.filter(fn {_stop, metres} -> metres <= max_metres end)
    |> Enum.sort_by(fn {_stop, metres} -> metres end)
    |> Enum.take(limit)
  end

  defp desc_suffix(%{desc: nil}), do: nil
  defp desc_suffix(%{desc: desc}), do: ", #{String.downcase(desc)}"

  defp presence(nil), do: ""
  defp presence(""), do: ""
  defp presence(text), do: "#{text}, "

  # A row's DOM id is its key with everything that is not a letter, a digit or a
  # dash replaced. GTFS stop IDs are free text, so `A|B` in an element id reads
  # as a CSS combinator in every selector that names it.
  defp dom_id(value), do: String.replace(to_string(value), ~r/[^A-Za-z0-9]+/, "-")

  defp stop_label(stop), do: "#{stop.name || stop.stop_id}"

  defp route_label(model, line) do
    case Map.get(model.routes || %{}, line.route_id) do
      %{short_name: short} when is_binary(short) and short != "" -> "Route #{short}"
      %{long_name: long} when is_binary(long) and long != "" -> long
      _other -> "Its pattern"
    end
  end

  defp direction_phrase(points) do
    case travel_direction(points) do
      nil -> "along this street"
      direction -> to_string(direction)
    end
  end

  @doc """
  How far apart two places are, in the units a reader of a stop list uses.

  Feet to the nearest five under a thousand of them, and miles with two decimals
  beyond. "1.5 m" is not a distance an editor can act on at a kerb; "5 ft" is
  the coarsest one they can, and past a thousand feet a decimal is noise.
  """
  @spec format_distance(float()) :: String.t()
  def format_distance(metres) do
    feet = metres / 0.3048

    if feet < 1000 do
      "#{round(feet / 5) * 5} ft"
    else
      "#{Float.round(metres / 1609.344, 2)} mi"
    end
  end

  @doc """
  Which way the nearest line a point is on the served kerb of runs, for a
  stop's description.
  """
  @spec kerb_direction(point(), [checked_line()]) :: travel_direction() | nil
  def kerb_direction(point, lines) do
    shapes = Enum.filter(lines || [], &(&1.source == :shape))

    case passing_lines(point, shapes) do
      [] -> nil
      [line | _rest] -> travel_direction(line.points)
    end
  end

  @doc """
  Where a placed point is, in the one sentence the panel puts above its fields.

  Production has coordinates and no street names, so the sentence is made of the
  two things the loaded model does know: which line runs past this point, and
  which side of it the point is on. A point with no shape within
  `@passing_metres` says so rather than naming a line it is nowhere near.

  Returns `%{text:, route:, direction:, side:, metres:}`, and the caller renders
  `text`. `direction` is what a description would say ("Northbound") and is nil
  where `text` is already the whole answer.
  """
  @spec describe_point(point(), %{
          required(:lines) => [checked_line()],
          required(:routes) => map()
        }) :: %{
          text: String.t(),
          route: String.t() | nil,
          direction: travel_direction() | nil,
          side: atom() | nil,
          metres: float() | nil
        }
  def describe_point(point, model) do
    shapes = Enum.filter(model.lines || [], &(&1.source == :shape))

    nearest =
      shapes
      |> Enum.map(fn line -> {line, offset_m(point, line.points)} end)
      |> Enum.filter(fn {_line, {metres, _side}} -> metres <= @passing_metres end)
      |> Enum.min_by(fn {_line, {metres, _side}} -> metres end, fn -> nil end)

    case nearest do
      nil ->
        %{
          text:
            "About #{format_distance(distance_to_nearest_stop(point, model))} from the nearest stop.",
          route: nil,
          direction: nil,
          side: nil,
          metres: nil
        }

      {line, {metres, side}} ->
        route = route_label(model, line)

        %{
          text: "#{side_phrase(side, route)}, #{format_distance(metres)} from it.",
          route: route,
          direction: travel_direction(line.points),
          side: side,
          metres: metres
        }
    end
  end

  defp side_phrase(:on, route), do: "On the #{route} line"
  defp side_phrase(:east, route), do: "East side of the #{route} line"
  defp side_phrase(:west, route), do: "West side of the #{route} line"

  # The fallback sentence needs a distance it can name, and "from nothing" is
  # not one. The model's own stops are the only landmarks it holds; with no
  # located stop at all the sentence says that instead of inventing a number.
  defp distance_to_nearest_stop(point, model) do
    case nearest_stops(point, Map.get(model, :stops, []), 1_000_000.0, 1) do
      [{_stop, metres}] -> metres
      [] -> 0.0
    end
  end

  @doc """
  The three placement problems a whole version has, for the map's checks list.

  Takes the `StopsMap.load/2` model and answers with

      %{duplicates: [{stop, stop, metres}],
        wrong_side: [{stop, line}],
        not_served: [stop]}

  which is what step 26's disclosure renders: a pair of stops an editor has to
  call different, a stop waiting on the far pavement from the vehicle that
  serves it, and a stop nothing serves at all.

  The duplicate scan is bucketed into a grid of `@cell_metres` cells around the
  centre of the version, so its cost grows with the stops actually near each
  other rather than with the square of the feed. Two stops within five metres
  can only be in the same or an adjacent cell, so scanning each stop against its
  own and eight neighbouring cells finds every pair and no others. Each pair is
  listed once, ordered as `load/2` ordered the stops, so the list is stable
  between two reads of the same version.

  Same-station siblings and pairs of stations are skipped. Two bays of one
  station are different places by construction — that is `classify_shared_station/2`
  in the single-stop case — and two stations 3 m apart are two stations, which
  is what stop IDs exist to express.

  A wrong-side entry pairs the stop with the *first* of its own `:shape` lines
  that puts it on the far pavement, rather than with all of them. The editor's
  action is "look at this stop", and a stop on the wrong side of four
  directional patterns is one row, not four. `:connector` lines are never
  considered: they describe no roadside, so a stop beside one is not on the
  wrong side of anything.

  Not-served stops are the ones `served?` is false for with `location_type` 0.
  An unserved *station* is not listed: a station with no children served is a
  container awaiting platforms, not a stop riders are standing at.
  """
  @spec version_checks(%{stops: [checked_stop()], lines: [checked_line()]}) :: %{
          duplicates: [{checked_stop(), checked_stop(), float()}],
          wrong_side: [{checked_stop(), checked_line()}],
          not_served: [checked_stop()]
        }
  def version_checks(%{stops: stops, lines: lines}) do
    %{
      duplicates: duplicate_pairs(stops),
      wrong_side: wrong_side_stops(stops, lines),
      not_served: not_served_stops(stops)
    }
  end

  defp duplicate_pairs(stops) do
    located = Enum.filter(stops, & &1.point)
    grid = build_grid(located)

    located
    |> Enum.with_index()
    |> Enum.flat_map(fn {stop, index} ->
      stop
      |> later_neighbours(grid, index)
      |> Enum.flat_map(&duplicate_pair(stop, &1))
    end)
  end

  # The candidate pairs this stop contributes: each other stop in its own and the
  # eight surrounding cells that comes after it in the list. The ordering is what
  # makes every pair appear exactly once rather than twice.
  defp later_neighbours(stop, grid, index) do
    stop
    |> neighbour_candidates(grid)
    |> Enum.filter(fn {_other, other_index} -> other_index > index end)
    |> Enum.map(fn {other, _other_index} -> other end)
  end

  # The pair a stop makes with one candidate, or nothing if they are not two
  # places that could be the same one, or are further apart than the threshold.
  defp duplicate_pair(stop, other) do
    if comparable?(stop, other) do
      metres = distance(stop.point, other.point)

      if metres <= @duplicate_metres, do: [{stop, other, metres}], else: []
    else
      []
    end
  end

  # Stops in the same cell as `stop` and in the eight around it, each with the
  # index it holds in the caller's list. The index is what makes every pair
  # appear exactly once: each stop only keeps candidates that come after it.
  defp neighbour_candidates(stop, grid) do
    {cell_x, cell_y} = cell_of(stop.point)

    for dx <- -1..1,
        dy <- -1..1,
        {other, index} <- Map.get(grid, {cell_x + dx, cell_y + dy}, []),
        do: {other, index}
  end

  defp build_grid(located) do
    Enum.group_by(Enum.with_index(located), fn {stop, _index} -> cell_of(stop.point) end)
  end

  # The cell a point falls in, on a metre grid whose origin is lon/lat 0,0.
  # Cells are compared relative to the same origin for every point, so a pair in
  # adjacent cells is in adjacent cells on the same grid; bucketing around the
  # version's centre instead would only change which cells exist, not which are
  # neighbours.
  defp cell_of({lon, lat}) do
    {floor(lon * @metres_per_degree * :math.cos(:math.pi() * lat / 180) / @cell_metres),
     floor(lat * @metres_per_degree / @cell_metres)}
  end

  # Two stops are comparable when they are genuinely two places that could be the
  # same one. Sharing a station means they are siblings, and either one being a
  # station means they are a station and something, never a duplicated pair.
  defp comparable?(stop, other) do
    not same_station?(stop, other) and not station?(stop) and not station?(other)
  end

  defp same_station?(stop, other) do
    not is_nil(stop.parent_station) and stop.parent_station == other.parent_station
  end

  defp station?(stop), do: stop.location_type == 1

  # One row per stop, not per offending line: a bidirectional pattern pair puts
  # a stop on the wrong side of one direction only, and an editor's action is
  # "look at this stop" rather than "look at this stop four times".
  defp wrong_side_stops(stops, lines) do
    shapes = Enum.filter(lines, &(&1.source == :shape))

    for stop <- stops,
        stop.served?,
        not is_nil(stop.point),
        line = Enum.find(own_shape_lines(stop, shapes), wrong_side_for?(stop)),
        do: {stop, line}
  end

  defp wrong_side_for?(stop), do: &(warn(stop.point, &1.points, :shape) == :wrong_side)

  defp own_shape_lines(stop, shapes) do
    Enum.filter(shapes, &(&1.pattern_id in (stop.pattern_ids || [])))
  end

  defp not_served_stops(stops) do
    Enum.filter(stops, &(&1.served? == false and &1.location_type == 0))
  end
end
