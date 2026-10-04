defmodule GtfsPlannerWeb.StopTextHelperLiveHelpers do
  @moduledoc """
  Shared steps for LiveView tests that drive the Stop text helper on the real stops
  catalog: approve a set through the page's own form, open the helper and have the
  real session prepare a batch with only the provider's HTTP boundary scripted.

  The caller's test module sets `Req.Test.set_req_test_to_shared/0` and is
  `async: false`, and its context carries `conn`, `version` and `stops`.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @endpoint GtfsPlannerWeb.Endpoint

  @doc "Writes `changes` to `stop` the way an import or another editor's session would."
  def set_stop(stop, changes),
    do: Repo.update_all(from(s in Stop, where: s.id == ^stop.id), set: changes)

  @doc "The page's own approval: Find stops with `text`, then Approve stops."
  def approve(view, text) do
    view |> form("#stop-set-form", stop_set: %{refs: text}) |> render_submit()
    view |> element("#stop-set-approve") |> render_click()
  end

  @doc """
  Opens the catalog, approves `S410`, `S411` and `S412`, opens the helper and has the
  session prepare `rows`; returns the view and the prepared card's entry ID.
  """
  def prepared_view(context, rows) do
    {:ok, view, _html} = live(context.conn, "/gtfs/#{context.version.id}/stops")
    view |> element("#stop-set-toggle") |> render_click()
    approve(view, "S410\nS411\nS412")
    view |> element("#agent-helper-open") |> render_click()

    ScriptedProvider.expect_tool_turn(
      "prepare_stop_metadata_changes",
      Jason.encode!(%{"rows" => rows}),
      "I prepared the changes."
    )

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Rename these stops."}})

    {view, await_entry(view)}
  end

  defp await_entry(view, attempts \\ 100) do
    case Regex.run(~r/id="agent-review-prepared-(\d+)"/, render(view)) do
      [_match, id] ->
        String.to_integer(id)

      nil when attempts > 0 ->
        Process.sleep(50)
        await_entry(view, attempts - 1)

      nil ->
        flunk("the prepared card never appeared")
    end
  end
end
