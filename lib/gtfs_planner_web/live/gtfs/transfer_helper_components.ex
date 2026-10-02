defmodule GtfsPlannerWeb.Gtfs.TransferHelperComponents do
  @moduledoc """
  The two panels the transfer helper's native review flow adds to the transfers page.

  This module names no pack command and decides nothing. Both components render
  values the `TransfersLive` socket already holds: the review the server re-read
  from the catalog, and the operator's own draft plus the selection the server
  admitted from it. The buttons they render only raise the events the page handles.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, icon: 1]

  @doc """
  The reviewed change as the reviewer reads it: what the catalog holds now, what
  the reviewed apply would write, and every stored exception the command named as
  protected. A create shows no stored row rather than an empty one.
  """
  attr :review, :map, required: true

  def policy_review_body(assigns) do
    ~H"""
    <div id="transfer-policy-review" class="grid gap-4 text-[13px]">
      <section id="transfer-policy-before" class="rounded-lg border border-subtle p-3">
        <h3 class="font-semibold">Stored now</h3>
        <p :if={is_nil(@review.before)} class="mt-1 text-muted">No stored rule for this direction.</p>
        <dl :if={@review.before} class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
          <dt class="text-muted">From</dt>
          <dd>{@review.before["from_stop_id"]}</dd>
          <dt class="text-muted">To</dt>
          <dd>{@review.before["to_stop_id"]}</dd>
          <dt class="text-muted">Type</dt>
          <dd>{@review.before["transfer_type"]}</dd>
        </dl>
      </section>

      <section id="transfer-policy-after" class="rounded-lg border border-subtle p-3">
        <h3 class="font-semibold">After this change</h3>
        <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
          <dt class="text-muted">From</dt>
          <dd>{@review.after["from_stop_id"]}</dd>
          <dt class="text-muted">To</dt>
          <dd>{@review.after["to_stop_id"]}</dd>
          <dt class="text-muted">Type</dt>
          <dd>{@review.after["transfer_type"]}</dd>
          <dt class="text-muted">Minimum</dt>
          <dd>{policy_time_text(@review.after["min_transfer_time"])}</dd>
        </dl>
      </section>

      <p id="transfer-policy-protected" class="text-muted">
        {length(@review.protected)} protected {if length(@review.protected) == 1,
          do: "rule",
          else: "rules"} will not be changed.
      </p>
    </div>
    """
  end

  @doc """
  What the reviewed proposals did so far: the latest status line and the counts a
  reviewer reads after a partly applied sequence. The page renders it inside the
  review drawer while that is open and on the page itself once it closes.
  """
  attr :status, :string, default: nil
  attr :counts, :map, required: true

  def policy_outcome(assigns) do
    ~H"""
    <div class="grid gap-1 text-[13px] text-muted">
      <p :if={@status} id="transfer-policy-status" role="status">{@status}</p>
      <p id="transfer-policy-counts">{policy_counts_text(@counts)}</p>
    </div>
    """
  end

  @doc "Whether there is an outcome to show: a status line, or any count above zero."
  def policy_outcome?(status, counts),
    do: not is_nil(status) or Enum.any?(counts, fn {_kind, count} -> count > 0 end)

  defp policy_counts_text(counts) do
    "Saved #{counts.saved} · Skipped #{counts.skipped} · Conflicts #{counts.conflict} · Not applied #{counts.not_applied}"
  end

  defp policy_time_text(value) when is_integer(value), do: "#{value} seconds"
  defp policy_time_text(value) when is_binary(value) and value != "", do: "#{value} seconds"
  defp policy_time_text(_empty), do: "None"

  @doc """
  The one control that admits a source: the operator's open draft and the selection
  the server built from it. The selection is shown back as the direction, type and
  time the helper will read, so the reviewer can see the source before asking.
  """
  attr :selections, :list, required: true
  attr :notice, :string, default: nil

  def transfer_policy_source(assigns) do
    ~H"""
    <section id="transfer-policy-source" class="mt-6 rounded-lg border border-subtle p-4">
      <h2 class="text-base font-semibold">Ask the helper about this rule</h2>
      <p class="mt-1 text-[13px] text-muted">
        Each draft you add becomes one selection the helper may read. It proposes changes back here;
        it never writes one.
      </p>
      <p
        :if={@notice}
        id="transfer-policy-source-notice"
        role="status"
        class="mt-2 text-[13px] text-muted"
      >
        {@notice}
      </p>
      <div class="mt-3">
        <.button
          id="transfer-policy-select"
          type="button"
          phx-click="transfer_policy_select"
          variant="secondary"
        >
          <.icon name="hero-sparkles" class="size-4" /> Ask the helper about this draft
        </.button>
      </div>
      <ul :if={@selections != []} id="transfer-policy-selections" class="mt-3 grid gap-2 text-[13px]">
        <li
          :for={selection <- @selections}
          id={"transfer-policy-selection-#{selection["id"]}"}
          class="flex items-center justify-between gap-3"
        >
          <span>
            {selection["from"]["stop_id"]} → {selection["to"]["stop_id"]} · type {selection[
              "transfer_type"
            ]} · {policy_time_text(selection["min_time"]["value"])}
            <span class="text-muted">
              ({length(selection["protected_ids"])} protected rules kept)
            </span>
          </span>
          <.button
            id={"transfer-policy-remove-#{selection["id"]}"}
            type="button"
            phx-click="transfer_policy_remove"
            phx-value-id={selection["id"]}
            variant="quiet"
          >
            Remove
          </.button>
        </li>
      </ul>
      <div :if={@selections != []} class="mt-3">
        <.button
          id="transfer-policy-clear"
          type="button"
          phx-click="transfer_policy_clear"
          variant="quiet"
        >
          Clear selections
        </.button>
      </div>
    </section>
    """
  end
end
