defmodule GtfsPlannerWeb.Gtfs.ScheduleHelperComponents do
  @moduledoc """
  The connection approval card the Schedules page renders beside its helper panel.

  This module decides nothing. It renders values the `RouteSchedulesLive` socket
  already holds: the operator's own approval draft as a native form, the refusal
  the page last returned, the receipt of the approval the page admitted, and the
  official connection comparison the helper's server evidence carries. The buttons
  raise the events the page handles, so the fields, the digest and the limits stay
  where they are decided.

  The comparison card reads the evidence the session delivered - never the model's
  prose and never a number recomputed here - and every value on it is the server's
  own: both sides of each connection, the seconds available, the margin each side
  leaves against the stated minimum, the difference between them, and the minimum's
  own provenance. A pair the version cannot answer exactly is listed with its
  reason rather than dropped, so the totals above the rows always describe every
  approved pair (CR-4).

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
            variant="quiet"
          >
            Add another pair
          </.button>
          <.button id="connection-approve" type="submit" variant="secondary">
            Approve for the helper
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  @doc """
  Renders the official connection comparison beside the helper panel.

  `evidence` is the `connection_comparison` evidence the session delivered, or
  `nil` before any comparison has settled. `status` is the panel's own
  conversation status and `approved?` says whether an approval is still admitted,
  so the empty, pending and stopped states each name what to do next instead of
  leaving a blank region.
  """
  attr :evidence, :map, default: nil
  attr :status, :atom, required: true
  attr :approved?, :boolean, required: true

  def connection_results(assigns) do
    assigns =
      assigns
      |> assign(:facts, Map.get(assigns.evidence || %{}, :facts, []))
      |> assign(:rows, Map.get(assigns.evidence || %{}, :rows, []))
      |> assign(:exclusions, Map.get(assigns.evidence || %{}, :exclusions, []))
      |> assign(
        :complete?,
        assigns.evidence != nil and assigns.evidence.completeness == :complete
      )

    ~H"""
    <section
      id="connection-comparison-results"
      aria-labelledby="connection-comparison-results-title"
      class="mb-4 min-w-0 rounded-lg border border-subtle p-4"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 id="connection-comparison-results-title" class="text-base font-semibold">
          Connection comparison
        </h2>
        <span
          :if={@evidence}
          id="connection-comparison-completeness"
          class={["badge badge-sm", if(@complete?, do: "badge-info", else: "badge-warning")]}
        >
          {if @complete?, do: "Complete", else: "Incomplete"}
        </span>
      </div>

      <p
        id="connection-comparison-status"
        role="status"
        aria-live="polite"
        class="mt-1 text-[13px] text-muted"
      >
        {results_status(assigns)}
      </p>

      <div :if={@evidence}>
        <p id="connection-comparison-total" class="mt-2 text-[13px] font-semibold">
          {@evidence.total} {@evidence.total_label}
        </p>
        <p
          :if={not @complete? and @evidence.completeness_reason}
          id="connection-comparison-incomplete"
          class="mt-1 text-[13px] text-muted"
        >
          {@evidence.completeness_reason}
        </p>

        <dl id="connection-comparison-totals" class="mt-2 grid gap-1 text-[13px]">
          <%= for fact <- @facts do %>
            <div class="flex flex-col gap-0.5 sm:flex-row sm:flex-wrap sm:items-baseline sm:justify-between sm:gap-2">
              <dt class="text-muted">{fact.label}</dt>
              <dd class="font-semibold [overflow-wrap:anywhere]">{fact.value}</dd>
            </div>
          <% end %>
        </dl>

        <ol id="connection-comparison-rows" class="mt-3 grid gap-3">
          <li
            :for={row <- @rows}
            id={"connection-comparison-row-#{row.id}"}
            class="min-w-0 rounded-lg border border-subtle p-3"
          >
            <div class="flex flex-col gap-0.5 sm:flex-row sm:flex-wrap sm:items-baseline sm:justify-between sm:gap-2">
              <p class="text-[13px] font-semibold [overflow-wrap:anywhere]">{row.id}</p>
              <p
                id={"connection-comparison-row-#{row.id}-status"}
                class="text-[13px] font-semibold"
              >
                {status_label(row.status)}
              </p>
            </div>

            <p
              :if={row.reason}
              id={"connection-comparison-row-#{row.id}-reason"}
              class="mt-1 text-[13px] text-muted"
            >
              {reason_text(row.reason)}
            </p>

            <dl class="mt-1.5 grid gap-1 text-[13px]">
              <div :if={row.current} class="flex flex-wrap items-baseline justify-between gap-2">
                <dt class="text-muted">Now</dt>
                <dd
                  id={"connection-comparison-row-#{row.id}-current"}
                  class="font-semibold [overflow-wrap:anywhere]"
                >
                  {side_text(row.current)}
                </dd>
              </div>
              <div :if={row.candidate} class="flex flex-wrap items-baseline justify-between gap-2">
                <dt class="text-muted">Supplied candidate</dt>
                <dd
                  id={"connection-comparison-row-#{row.id}-candidate"}
                  class="font-semibold [overflow-wrap:anywhere]"
                >
                  {side_text(row.candidate)}
                </dd>
              </div>
              <div
                :if={not is_nil(row.delta_seconds)}
                class="flex flex-wrap items-baseline justify-between gap-2"
              >
                <dt class="text-muted">Change</dt>
                <dd
                  id={"connection-comparison-row-#{row.id}-delta"}
                  class="font-semibold [overflow-wrap:anywhere]"
                >
                  {signed(row.delta_seconds)} s
                </dd>
              </div>
              <div class="flex flex-col gap-0.5 sm:flex-row sm:flex-wrap sm:items-baseline sm:justify-between sm:gap-2">
                <dt class="text-muted">Minimum</dt>
                <dd
                  id={"connection-comparison-row-#{row.id}-minimum"}
                  class="font-semibold [overflow-wrap:anywhere]"
                >
                  {minimum_text(row.minimum)}
                </dd>
              </div>
            </dl>
          </li>
        </ol>

        <ul
          :if={@exclusions != []}
          id="connection-comparison-exclusions"
          class="mt-3 grid gap-1 text-[13px] text-muted"
        >
          <li :for={exclusion <- @exclusions}>Not listed · {exclusion}</li>
        </ul>

        <p id="connection-comparison-source" class="mt-3 text-[13px] text-muted">
          Source · {@evidence.source_ref} · digest {short_digest(@evidence.digest)}
        </p>
        <p class="mt-1 text-[13px] text-muted">
          Every number here was read from this service version in one snapshot. The helper's
          reply below is its explanation of them, not a guarantee.
        </p>
      </div>
    </section>
    """
  end

  # Evidence arrives from the session with its own keys on each row and the
  # string keys the tool result was serialized with inside it, so the helpers
  # below read the nested value by string key.

  # The draft this form renders: the operator's own pairs, in their own order.
  defp pairs(%Phoenix.HTML.Form{params: %{"pairs" => pairs}}) when is_list(pairs), do: pairs
  defp pairs(%Phoenix.HTML.Form{}), do: []

  # Each state names what a reader can do next rather than leaving the region
  # blank or implying that a comparison exists when none has settled.
  defp results_status(%{evidence: nil, status: :working}),
    do: "Comparing the connections you approved…"

  defp results_status(%{evidence: nil, status: status})
       when status in [:forbidden, :unavailable, :ended, :limit, :allowance_exhausted],
       do:
         "The connection helper stopped, so nothing is compared here. Your approved inputs are unchanged."

  defp results_status(%{evidence: nil, approved?: true}),
    do:
      "No comparison yet. Ask the connection helper whether the approved connections can be made."

  defp results_status(%{evidence: nil, approved?: false}),
    do:
      "Nothing is approved on this page. Approve the connections above, then ask the connection helper to compare them."

  defp results_status(%{evidence: %{}, approved?: false}),
    do:
      "This comparison belongs to an approval this page no longer holds. Approve the connections again to read a current one."

  defp results_status(%{evidence: %{}}), do: nil

  defp status_label("comparable"), do: "Comparable"
  defp status_label("unresolved"), do: "Unresolved"
  defp status_label("not_applicable"), do: "Not applicable"
  defp status_label("prohibited"), do: "Prohibited"
  defp status_label(status), do: status

  defp side_text(side) do
    "#{side["arrival"]} → #{side["departure"]} · #{side["available_seconds"]} s available · margin #{signed(side["margin_seconds"])} s"
  end

  # The minimum is named with the evidence that states it: this version's own
  # stored rule with its type, or the operator's supplied approval, which never
  # stands in for a prohibition or a conflict. Session evidence arrives as JSON,
  # so every key here is a string.
  defp minimum_text(%{
         "origin" => "stored",
         "status" => "resolved",
         "seconds" => seconds,
         "provenance" => provenance
       }) do
    case Map.get(provenance, "transfer_type") do
      nil -> "Stored minimum #{seconds} s from this version's own rule"
      type -> "Stored minimum #{seconds} s from this version's best-ranked type #{type} rule"
    end
  end

  defp minimum_text(%{"origin" => "supplied", "status" => "resolved", "supplied" => supplied}) do
    "Supplied minimum #{supplied["seconds"]} s, approved as “#{supplied["approval"]}”"
  end

  defp minimum_text(%{"status" => "prohibited", "provenance" => provenance}),
    do: "This version prohibits the transfer (#{Map.get(provenance, "reason")})"

  defp minimum_text(%{"status" => "conflicting", "provenance" => provenance}),
    do: "Two best-ranked stored rules disagree (#{Map.get(provenance, "reason")})"

  defp minimum_text(%{"status" => "absent"}),
    do: "This version states no minimum for this pair"

  defp minimum_text(%{"origin" => "supplied"}),
    do: "A supplied minimum was approved, but this version's stored policy decides this pair"

  defp minimum_text(_minimum), do: "No minimum could be read for this pair"

  defp reason_text("no_stated_minimum"),
    do: "Not compared: this version states no minimum for this pair (no_stated_minimum)."

  defp reason_text("missing_candidate_evidence"),
    do:
      "Not compared: no candidate times were supplied for this pair (missing_candidate_evidence)."

  defp reason_text("mixed_date_offset_basis"),
    do:
      "Not compared: the two ends fall on different service dates, so no exact subtraction is safe (mixed_date_offset_basis)."

  defp reason_text("mixed_timezones"),
    do:
      "Not compared: the two ends are in different agency time zones, so no exact subtraction is safe (mixed_timezones)."

  defp reason_text("frequency_template"),
    do:
      "Not compared: one end is a frequency template rather than one exact departure (frequency_template)."

  defp reason_text("unknown_candidate_time"),
    do: "Not compared: a supplied candidate clock could not be read (unknown_candidate_time)."

  defp reason_text("unreadable_calendar"),
    do:
      "Not compared: this version's calendar for one end could not be read (unreadable_calendar)."

  defp reason_text("conflicting_best_rules"),
    do: "Not compared: two best-ranked stored rules disagree (conflicting_best_rules)."

  defp reason_text("inactive_route"),
    do: "Not applicable on this date: the route does not run (inactive_route)."

  defp reason_text("no_recorded_service"),
    do: "Not applicable on this date: no service is recorded (no_recorded_service)."

  defp reason_text(reason), do: "Not compared: #{reason}."

  # A negative number is written with the sign the server computed, so a reader
  # never has to infer one from the surrounding words.
  defp signed(seconds) when seconds < 0, do: "-#{abs(seconds)}"
  defp signed(seconds), do: Integer.to_string(seconds)

  defp short_digest(digest) when is_binary(digest), do: String.slice(digest, 0, 12) <> "…"
  defp short_digest(_digest), do: "unavailable"

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
