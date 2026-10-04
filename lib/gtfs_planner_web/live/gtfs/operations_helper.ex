defmodule GtfsPlannerWeb.Gtfs.OperationsHelper do
  @moduledoc """
  Host code the Blocks and Runs pages share for their operations helper panel.

  Each page projects its own loaded day (`OperationsAssistance.block_day/2` or
  `run_day/1`) and owns its own refusal wording. This module does the parts that
  are the same on both pages: admitting the projection as the panel's frozen
  copy or dropping it, reading the prepared configuration a card hands back, and
  naming what the copy excluded. Keeping one copy means a refusal or a shape
  check cannot drift between the two pages.

  Both pages keep three assigns this module reads and writes: `:helper_notice`,
  the panel's one-line reason; `:helper_review`, the "Configuration to review"
  summary; and the `AgentPanel`'s own `:agent_context`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.OperationsAssistance
  alias GtfsPlannerWeb.AgentPanel

  @doc """
  Admits a projection as the panel's frozen copy, or drops the copy.

  `pack_id` is the helper this page binds the copy to, and the panel is moved to
  it with `AgentPanel.select_pack/3`, so a page that offers more than one helper
  can hand the panel back to this one with its current copy. `projection` is the
  page's own projection result. Anything other than
  `{:ok, payload}` - a page with no loaded day, a day the projection could not
  describe (`{:error, :unavailable}`) - drops the copy, as does a payload the
  shared owner refuses (too large, not JSON-safe). A dropped copy shows
  `unavailable_notice`, so the panel says it has nothing to answer from rather
  than answering from half a day.

  A copy that differs from the one the panel holds retires the panel's
  conversation, so the configuration summary it opened is cleared with it.
  Republishing the same copy keeps both.
  """
  @spec publish_context(Phoenix.LiveView.Socket.t(), String.t(), term(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def publish_context(socket, pack_id, {:ok, payload}, unavailable_notice) do
    case OperationsAssistance.context(identity(socket), payload) do
      {:ok, context} ->
        socket
        |> clear_review_unless(context == socket.assigns[:agent_context])
        |> AgentPanel.select_pack(pack_id, context)
        |> assign(:helper_notice, nil)

      {:error, _refused} ->
        drop_context(socket, pack_id, unavailable_notice)
    end
  end

  def publish_context(socket, pack_id, _no_projection, unavailable_notice),
    do: drop_context(socket, pack_id, unavailable_notice)

  @doc """
  Drops the frozen copy, so the panel cannot answer about a day the page no
  longer shows, and clears the configuration summary that described it.
  """
  @spec drop_context(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def drop_context(socket, pack_id, notice) do
    socket
    |> assign(:helper_review, nil)
    |> AgentPanel.select_pack(pack_id, Scope.context(identity(socket)))
    |> assign(:helper_notice, notice)
  end

  @doc """
  Clears the configuration summary when the drawer's scope moves off the scope
  the summary describes, so the summary and the scope Preview will run cannot
  disagree. Choosing the described scope again keeps it.
  """
  @spec keep_review_for(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def keep_review_for(%{assigns: %{helper_review: %{mode: mode}}} = socket, scope)
      when mode != scope,
      do: assign(socket, :helper_review, nil)

  def keep_review_for(socket, _scope), do: socket

  @doc """
  Reads the prepared configuration the card's `entry` names.

  `entry_id` is client input: `phx-value-entry` sends the entry number as a
  string. Anything that is not a positive whole number never reaches the
  session. The session hands back the configuration it stored, or nothing, and
  the configuration must name `section` and one of `scopes` and carry the three
  string identities the host re-checks.

  Returns `{:ok, command}` with `mode` as the scope atom, `{:error,
  notices.section}` for another page's configuration, and `{:error,
  notices.missing}` for everything else.
  """
  @spec prepared_command(
          Phoenix.LiveView.Socket.t(),
          term(),
          String.t(),
          [atom()],
          %{missing: String.t(), section: String.t()}
        ) :: {:ok, map()} | {:error, String.t()}
  def prepared_command(socket, entry_id, section, scopes, notices) do
    with {:ok, id} <- read_entry_id(entry_id),
         {:ok, %{command: {:operations_suggestion, command}}} <-
           Agents.prepared(socket.assigns.agent_session, socket.assigns.agent_conversation_id, id),
         {:ok, command} <- read_command(command, section, scopes) do
      {:ok, command}
    else
      :other_section -> {:error, notices.section}
      _refused -> {:error, notices.missing}
    end
  end

  @doc """
  The exclusions a frozen copy records, as `{label, count}` pairs sorted by
  label. The copy holds opaque refs rather than rows, so a count by kind is what
  a reader can act on.
  """
  @spec exclusions(map()) :: [{String.t(), pos_integer()}]
  def exclusions(payload) do
    payload
    |> Map.get("exclusions", [])
    |> Enum.frequencies_by(& &1["kind"])
    |> Enum.map(fn {kind, count} -> {exclusion_label(kind), count} end)
    |> Enum.sort()
  end

  defp clear_review_unless(socket, true), do: socket
  defp clear_review_unless(socket, false), do: assign(socket, :helper_review, nil)

  defp identity(%{assigns: %{current_gtfs_version: version}}), do: {:version, version.id}

  defp read_entry_id(entry_id) when is_binary(entry_id) do
    case Integer.parse(entry_id) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> :error
    end
  end

  defp read_entry_id(entry_id) when is_integer(entry_id) and entry_id > 0, do: {:ok, entry_id}
  defp read_entry_id(_entry_id), do: :error

  # The command is a map the page's own pack wrote. Everything in it is checked
  # for shape before it is used, because a value that arrives as an unexpected
  # term is a refusal rather than a crash on the page.
  defp read_command(
         %{
           section: section,
           day_key: day_key,
           source_digest: source_digest,
           selection_digest: selection_digest,
           mode: mode
         },
         section,
         scopes
       )
       when is_binary(day_key) and is_binary(source_digest) and is_binary(selection_digest) do
    case scope(mode, scopes) do
      nil ->
        :error

      scope ->
        {:ok,
         %{
           day_key: day_key,
           source_digest: source_digest,
           selection_digest: selection_digest,
           mode: scope
         }}
    end
  end

  defp read_command(%{section: other}, section, _scopes) when other != section,
    do: :other_section

  defp read_command(_command, _section, _scopes), do: :error

  # The scope travels through the session as the string the tool schema accepted,
  # and the page addresses it as an atom, so the two are matched by name rather
  # than by identity. Anything else is no scope at all.
  defp scope(value, scopes) when is_binary(value),
    do: Enum.find(scopes, &(Atom.to_string(&1) == value))

  defp scope(value, scopes), do: if(value in scopes, do: value)

  defp exclusion_label("frequency_trip"), do: "repeating trips"
  defp exclusion_label("unplottable"), do: "trips with no plottable times"
  defp exclusion_label("outside_scope"), do: "rows outside the selected scope"
  defp exclusion_label(kind) when is_binary(kind), do: kind
  defp exclusion_label(_kind), do: "other rows"
end
