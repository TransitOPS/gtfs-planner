defmodule GtfsPlanner.Agents.Prompt do
  @moduledoc """
  Builds the system message for one capability pack and one scope.

  The message carries the pack's compile-time skill body plus the two server
  facts the model cannot derive from the conversation: the agency-local date
  with its resolved display timezone, and the service version name. It carries
  no organization, version or user identifier, so nothing the model sees can
  name the tenant it came from.
  """

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.DisplayClock

  @doc """
  Returns the chat `system` message for `pack` in `scope`.

  The content is the pack's `skill/0` body, a blank line, and the local date,
  service version name and section title.
  """
  @spec system(module(), Scope.t()) :: %{String.t() => String.t()}
  def system(pack, %Scope{} = scope) do
    today = DisplayClock.today(scope.organization_id, scope.gtfs_version_id)

    facts = [
      "Today is #{Date.to_iso8601(today.date)}, #{Calendar.strftime(today.date, "%A, %B %-d, %Y")} (#{today.timezone}), in the agency's local time.",
      "Service version: #{scope.version_name}.",
      "Section: #{pack.title()}."
    ]

    %{"role" => "system", "content" => pack.skill() <> "\n\n" <> Enum.join(facts, "\n")}
  end
end
