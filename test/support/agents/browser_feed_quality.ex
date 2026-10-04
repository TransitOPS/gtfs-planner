defmodule GtfsPlanner.Agents.BrowserFeedQuality do
  @moduledoc """
  The feed-quality facts shared by the seeded feed and the OpenRouter stand-in,
  so a browser journey and the rows it reads cannot disagree.

  `test/support/browser_seed.exs` builds the `Browser Feed Quality Version` and
  its one completed MobilityData report from these values, and
  `GtfsPlanner.Agents.BrowserOpenRouter` answers about the same run and the same
  stop. The scripted calls name no run, because a real model is never shown a
  run id: the Result page's attached run is the default the pack reads.

    * the stored report is a historical wrapper: its own length is 1 while the
      embedded upstream `totalNotices` is 170 and only three samples are
      retained, so a card that shows the retained count as the total fails;
    * `FQ-CENTRAL` is the version's own stop, so one sample resolves to current
      navigation while the missing and row-only samples stay unmapped;
    * the version is backdated, so it never becomes the organization's current
      version and the other browser journeys keep their own page.
  """

  @version_name "Browser Feed Quality Version"
  @run_id "f1f1f1f1-0000-4000-8000-000000000001"
  @stop_id "FQ-CENTRAL"

  @doc "The seeded version's name, as the version panel shows it."
  def version_name, do: @version_name

  @doc "The complete run whose report the journeys read."
  def run_id, do: @run_id

  @doc "The one current stop a retained sample names."
  def stop_id, do: @stop_id

  @doc "Whether a journey message belongs to this scenario."
  def question?(content) do
    Regex.match?(
      ~r/feed quality|last check|validation findings|duplicate key|prepare the pathways|review options/i,
      content
    )
  end

  @doc "The next tool call for a user message."
  def user_reply(content) do
    cond do
      content =~ ~r/duplicate key/i ->
        {:explain_notice, %{"code" => "duplicate_key"}}

      content =~ ~r/prepare the pathways|review options/i ->
        {:prepare_export_options, %{"export_type" => "pathways"}}

      true ->
        {:list_validation_findings, %{}}
    end
  end

  @doc """
  The sentence after one tool result.

  The findings sentence deliberately states the retained sample count as if it
  were the total in one clause and the true total in another, so the journey
  proves the server card, not the prose, carries the exact 170.
  """
  def tool_reply(name) do
    case name do
      "list_validation_findings" ->
        "There are three retained samples, and the stored total is 170 findings."

      "explain_notice" ->
        "That code names a field the seeded feed requires."

      "prepare_export_options" ->
        "I prepared the Pathways selection for Review options."

      _other ->
        "I can read this version's findings and export readiness."
    end
  end
end
