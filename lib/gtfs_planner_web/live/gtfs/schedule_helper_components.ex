defmodule GtfsPlannerWeb.Gtfs.ScheduleHelperComponents do
  @moduledoc """
  The connection approval card the Schedules page renders beside its helper panel.

  This module decides nothing. It renders values the `RouteSchedulesLive` socket
  already holds: the operator's own approval draft as a native form, the refusal
  the page last returned, and the receipt of the approval the page admitted. The
  buttons raise the events the page handles, so the fields, the digest and the
  limits stay where they are decided.

  Each pair's controls carry their own posted names rather than a nested
  `inputs_for` form. A draft is a plain string-key map with an operator's own
  values in it, so the page can re-render exactly what was typed - including a
  refusal - without a changeset deciding a single field.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.CoreComponents, only: [button: 1, input: 1]

  attr :form, Phoenix.HTML.Form, required: true
  attr :notice, :string, default: nil
  attr :approval, :map, default: nil
  attr :pair_limit, :integer, required: true

  def connection_approval(assigns) do
    ~H"""
    <section id="connection-approval" class="rounded-lg border border-subtle p-4">
      <h2 class="text-base font-semibold">Approve connections to compare</h2>
      <p class="mt-1 text-[13px] text-muted">
        The connection helper reads only what you approve here: one service date, the two routes,
        each side's trip, stop and occurrence, the minimum to compare against, and any candidate
        times you supply. Approving more than {@pair_limit} pairs, or an approval this page
        cannot hold, is refused rather than shortened. It never writes.
      </p>

      <p
        :if={@notice}
        id="connection-approval-notice"
        role="status"
        aria-live="polite"
        class="mt-2 text-[13px] text-muted"
      >
        {@notice}
      </p>

      <dl :if={@approval} id="connection-approval-receipt" class="mt-3 grid gap-1 text-[13px]">
        <dt class="text-muted">Service date</dt>
        <dd id="connection-approval-date">{@approval.service_date}</dd>
        <dt class="text-muted">Approved pairs</dt>
        <dd id="connection-approval-pairs">
          {@approval.pairs} {if @approval.pairs == 1, do: "pair", else: "pairs"}
        </dd>
        <dt class="text-muted">Approved routes</dt>
        <dd id="connection-approval-routes">{Enum.join(@approval.approved_route_ids, ", ")}</dd>
        <dt class="text-muted">Minimums</dt>
        <dd id="connection-approval-minimums">{Enum.join(@approval.minimums, "; ")}</dd>
        <dt class="text-muted">Supplied candidates</dt>
        <dd id="connection-approval-candidates">{@approval.candidates}</dd>
        <dt class="text-muted">Snapshot</dt>
        <dd id="connection-approval-digest" title={@approval.base_digest}>
          {String.slice(@approval.base_digest, 0, 12)}…
        </dd>
        <dt class="text-muted">Conversation</dt>
        <dd id="connection-approval-conversation" title={@approval.conversation_digest}>
          {String.slice(@approval.conversation_digest, 0, 12)}…
        </dd>
      </dl>

      <.form
        for={@form}
        id="connection-approval-form"
        phx-change="connection_validate"
        phx-submit="connection_approve"
        class="mt-3 grid gap-3"
      >
        <.input
          field={@form[:service_date]}
          id="connection-service-date"
          type="date"
          label="Service date"
          help="The one civil date every pair below is compared on."
        />

        <fieldset
          :for={{pair, index} <- Enum.with_index(pairs(@form))}
          id={"connection-pair-#{pair_name(pair, index)}"}
          class="grid gap-2 rounded-lg border border-subtle p-3"
        >
          <legend class="px-1 text-[13px] font-semibold">Connection pair</legend>

          <.input
            name={input_name(@form, index, ["id"])}
            id={"connection-#{pair_name(pair, index)}-id"}
            value={pair_name(pair, index)}
            label="Pair name"
            help="Your own name for this pair. Results are reported under it."
          />

          <div class="grid gap-2 sm:grid-cols-2">
            <.input
              name={input_name(@form, index, ["from", "route_id"])}
              id={"connection-#{pair_name(pair, index)}-from-route"}
              value={endpoint_value(pair, "from", "route_id")}
              label="From route"
            />
            <.input
              name={input_name(@form, index, ["from", "trip_id"])}
              id={"connection-#{pair_name(pair, index)}-from-trip"}
              value={endpoint_value(pair, "from", "trip_id")}
              label="From trip"
            />
            <.input
              name={input_name(@form, index, ["from", "stop_id"])}
              id={"connection-#{pair_name(pair, index)}-from-stop"}
              value={endpoint_value(pair, "from", "stop_id")}
              label="From stop"
            />
            <.input
              name={input_name(@form, index, ["from", "stop_sequence"])}
              id={"connection-#{pair_name(pair, index)}-from-sequence"}
              value={endpoint_value(pair, "from", "stop_sequence")}
              label="From occurrence"
              type="number"
              min="0"
            />
            <.input
              name={input_name(@form, index, ["from", "service_date_offset"])}
              id={"connection-#{pair_name(pair, index)}-from-offset"}
              value={endpoint_value(pair, "from", "service_date_offset")}
              label="From service-date offset"
              type="number"
              min="0"
            />
          </div>

          <div class="grid gap-2 sm:grid-cols-2">
            <.input
              name={input_name(@form, index, ["to", "route_id"])}
              id={"connection-#{pair_name(pair, index)}-to-route"}
              value={endpoint_value(pair, "to", "route_id")}
              label="To route"
            />
            <.input
              name={input_name(@form, index, ["to", "trip_id"])}
              id={"connection-#{pair_name(pair, index)}-to-trip"}
              value={endpoint_value(pair, "to", "trip_id")}
              label="To trip"
            />
            <.input
              name={input_name(@form, index, ["to", "stop_id"])}
              id={"connection-#{pair_name(pair, index)}-to-stop"}
              value={endpoint_value(pair, "to", "stop_id")}
              label="To stop"
            />
            <.input
              name={input_name(@form, index, ["to", "stop_sequence"])}
              id={"connection-#{pair_name(pair, index)}-to-sequence"}
              value={endpoint_value(pair, "to", "stop_sequence")}
              label="To occurrence"
              type="number"
              min="0"
            />
            <.input
              name={input_name(@form, index, ["to", "service_date_offset"])}
              id={"connection-#{pair_name(pair, index)}-to-offset"}
              value={endpoint_value(pair, "to", "service_date_offset")}
              label="To service-date offset"
              type="number"
              min="0"
            />
          </div>

          <.input
            name={input_name(@form, index, ["minimum", "origin"])}
            id={"connection-#{pair_name(pair, index)}-minimum-origin"}
            type="select"
            label="Minimum to compare against"
            value={minimum_value(pair, "origin")}
            options={[
              {"The stored minimum for this pair", "stored"},
              {"A supplied minimum", "supplied"}
            ]}
          />
          <div class="grid gap-2 sm:grid-cols-2">
            <.input
              name={input_name(@form, index, ["minimum", "seconds"])}
              id={"connection-#{pair_name(pair, index)}-minimum-seconds"}
              value={minimum_value(pair, "seconds")}
              label="Supplied minimum in seconds"
              type="number"
              min="0"
            />
            <.input
              name={input_name(@form, index, ["minimum", "approval"])}
              id={"connection-#{pair_name(pair, index)}-minimum-approval"}
              value={minimum_value(pair, "approval")}
              label="Approval for that minimum"
            />
          </div>

          <div class="grid gap-2 sm:grid-cols-2">
            <.input
              name={input_name(@form, index, ["candidate", "arrival"])}
              id={"connection-#{pair_name(pair, index)}-candidate-arrival"}
              value={candidate_value(pair, "arrival")}
              label="Supplied candidate arrival"
              placeholder="09:07"
            />
            <.input
              name={input_name(@form, index, ["candidate", "departure"])}
              id={"connection-#{pair_name(pair, index)}-candidate-departure"}
              value={candidate_value(pair, "departure")}
              label="Supplied candidate departure"
              placeholder="09:07"
            />
          </div>
          <.input
            name={input_name(@form, index, ["candidate", "approval"])}
            id={"connection-#{pair_name(pair, index)}-candidate-approval"}
            value={candidate_value(pair, "approval")}
            label="Approval for those candidate times"
            help="External evidence you hold and approve. It is never a schedule draft."
          />

          <.button
            id={"connection-#{pair_name(pair, index)}-remove"}
            type="button"
            phx-click="connection_pair_remove"
            phx-value-id={pair_name(pair, index)}
            variant="quiet"
          >
            Remove this pair
          </.button>
        </fieldset>

        <div class="flex flex-wrap gap-2">
          <.button
            id="connection-pair-add"
            type="button"
            phx-click="connection_pair_add"
            variant="secondary"
          >
            Add another pair
          </.button>
          <.button id="connection-approve" type="submit" variant="primary">
            Approve for the helper
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  # The draft this form renders: the operator's own pairs, in their own order.
  defp pairs(%Phoenix.HTML.Form{params: %{"pairs" => pairs}}) when is_list(pairs), do: pairs
  defp pairs(%Phoenix.HTML.Form{}), do: []

  # The posted name of one control. The pair's own name is a stable id for its
  # fieldset and its remove button, so a refusal leaves the operator looking at
  # the pair they wrote rather than at the pair that happens to be first.
  defp pair_name(pair, index), do: presence(pair["id"]) || "pair-#{index}"

  defp input_name(%Phoenix.HTML.Form{name: name}, index, path) do
    "#{name}[pairs][#{index}]" <> Enum.map_join(path, fn key -> "[#{key}]" end)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp presence(_value), do: nil

  defp endpoint_value(pair, side, field), do: nested_value(pair, side, field)

  defp minimum_value(pair, field), do: nested_value(pair, "minimum", field)

  defp candidate_value(pair, field), do: nested_value(pair, "candidate", field)

  defp nested_value(pair, group, field) do
    with group when is_map(group) <- pair[group],
         value when not is_nil(value) <- group[field] do
      value
    else
      _other -> ""
    end
  end
end
