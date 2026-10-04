defmodule GtfsPlannerWeb.HeadsignHelperLiveHelpers do
  @moduledoc """
  Shared steps for LiveView tests that drive the Headsign helper on the real
  pattern page with the A01 fixture (`GtfsPlanner.HeadsignHelperFixtures`).

  A prepared card is produced by the real session, with only the provider's HTTP
  boundary scripted through `GtfsPlanner.Agents.ScriptedProvider`. The caller's
  test module sets `Req.Test.set_req_test_to_shared/0` and is `async: false`.
  """

  import Ecto.Query
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @endpoint GtfsPlannerWeb.Endpoint

  @pattern_args ~s({"current_text":"Downtown Terminal","new_text":"Central Station"})

  @doc "The rename the A01 scenario prepares: `Downtown Terminal` to `Central Station`."
  def pattern_args, do: @pattern_args

  @doc """
  Opens the A01 pattern page at `query`, asks the helper to prepare a rename with
  `arguments` and returns the view and the prepared card's entry id.
  """
  def prepared_view(conn, version, query, arguments \\ @pattern_args) do
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/routes/R1/patterns/A01-P1#{query}")

    view |> element("#agent-helper-open") |> render_click()

    ScriptedProvider.expect_tool_turn("prepare_headsign_change", arguments, "I prepared it.")

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Rename the headsign."}})

    {view, await_prepared_entry(view)}
  end

  defp await_prepared_entry(view, attempts \\ 100) do
    case Regex.run(~r/id="agent-review-prepared-(\d+)"/, render(view)) do
      [_match, id] ->
        String.to_integer(id)

      nil when attempts > 0 ->
        Process.sleep(50)
        await_prepared_entry(view, attempts - 1)

      nil ->
        flunk("the prepared card never appeared")
    end
  end

  @doc """
  Polls `fun` until it is truthy. The session's events reach the page
  asynchronously, so a result that depends on one is awaited rather than slept for.
  """
  def eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  @doc "The page's socket assigns."
  def assigns(view), do: :sys.get_state(view.pid).socket.assigns

  @doc "Every row a handoff must not write, with update stamps, plus the audit log count."
  def stamps do
    {Repo.all(from(t in Trip, order_by: t.id, select: {t.id, t.updated_at, t.trip_headsign})),
     Repo.all(from(p in RoutePattern, order_by: p.id, select: {p.id, p.updated_at, p.headsign})),
     Repo.all(from(t in TimedPattern, order_by: t.id, select: {t.id, t.updated_at, t.headsign})),
     Repo.aggregate(ChangeLog, :count)}
  end

  def trip_id(a01, name), do: Map.fetch!(a01.trips, name).id

  def stored_headsign(a01, name), do: Repo.get!(Trip, trip_id(a01, name)).trip_headsign

  @doc "The twelve A01 followers' trip UUIDs, sorted."
  def follower_ids(a01) do
    for(index <- 1..12, do: trip_id(a01, "A01-F" <> String.pad_leading("#{index}", 2, "0")))
    |> Enum.sort()
  end
end
