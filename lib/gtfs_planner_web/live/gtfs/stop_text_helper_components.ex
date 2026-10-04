defmodule GtfsPlannerWeb.Gtfs.StopTextHelperComponents do
  @moduledoc """
  Surfaces the stops catalog adds for the stop text helper: the form that turns
  pasted stop IDs, codes and names into an editor-approved set of at most 100
  stops.

  The components present what `StopsLive` holds and decide nothing. The resolution
  comes from `GtfsPlanner.Gtfs.StopSelection`; the page keeps it server-side and
  validates every choice against it, so the radio values here are stop IDs the page
  checks again, never identities it trusts.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Wording

  @basis_labels %{stop_id: "by stop ID", stop_code: "by code", stop_name: "by name"}

  @doc """
  The `Helper stops` section: a heading row that always shows the approved count,
  and a body with the form, the resolution of the last Find and the approved list.

  `resolution` is nil or `%{resolved, ambiguous, unresolved, choices}`; `stop_set`
  is nil or the approved list of `%{uuid, stop_id, stop_name}`.
  """
  attr :open?, :boolean, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil, doc: "the problem with the typed text"
  attr :notice, :string, default: nil, doc: "why the last Approve changed nothing"
  attr :resolution, :map, default: nil
  attr :stop_set, :list, default: nil

  def stop_set_section(assigns) do
    ~H"""
    <section
      id="stop-set-section"
      phx-hook="FormErrorFocus"
      aria-label="Helper stops"
      class="mb-6 rounded-card border border-subtle bg-white"
    >
      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-1 md:px-5">
        <button
          id="stop-set-toggle"
          type="button"
          phx-click="stop_set_toggle"
          aria-expanded={to_string(@open?)}
          aria-controls="stop-set-body"
          class="inline-flex min-h-11 items-center gap-2 text-sm font-[650] text-strong"
        >
          <.icon
            name={if(@open?, do: "hero-chevron-down", else: "hero-chevron-right")}
            class="size-4 text-muted"
          /> Helper stops
        </button>
        <p
          id="stop-set-summary"
          tabindex="-1"
          role="status"
          class="text-[13px] tabular-nums text-default"
        >
          {summary_text(@stop_set)}
        </p>
        <button
          :if={@stop_set}
          id="stop-set-clear"
          type="button"
          phx-click="stop_set_clear"
          class="ml-auto inline-flex min-h-11 items-center text-[13px] font-[650] text-action hover:underline"
        >
          Clear stops
        </button>
      </div>

      <div :if={@open?} id="stop-set-body" class="border-t border-subtle px-4 py-4 md:px-5">
        <div class="grid max-w-[640px] gap-5">
          <.form
            for={@form}
            id="stop-set-form"
            phx-change="stop_set_change"
            phx-submit="stop_set_find"
            class="grid gap-3"
          >
            <.input
              field={@form[:refs]}
              id="stop-set-refs"
              type="textarea"
              label="Stop IDs, codes or names"
              help="One per line, up to 100"
              rows="4"
              errors={if @error, do: [@error], else: []}
              phx-debounce="blur"
              class="w-full textarea font-mono text-[13px]"
            />
            <div>
              <.button
                id="stop-set-find"
                type="submit"
                variant={if(@resolution, do: "secondary", else: "primary")}
                class="min-h-11"
                phx-disable-with="Finding…"
              >
                Find stops
              </.button>
            </div>
          </.form>

          <.resolution :if={@resolution} resolution={@resolution} notice={@notice} />

          <.message
            :if={@notice && is_nil(@resolution)}
            id="stop-set-notice"
            kind="error"
            title={@notice}
            tabindex="-1"
          />

          <section :if={@stop_set} id="stop-set-list-section" aria-labelledby="stop-set-list-heading">
            <h3 id="stop-set-list-heading" class="text-[13px] font-[650] text-default">
              Approved stops
            </h3>
            <ul id="stop-set-list" class="mt-1 divide-y divide-subtle text-sm">
              <li
                :for={stop <- @stop_set}
                data-stop-id={stop.stop_id}
                class="flex min-h-9 flex-wrap items-baseline gap-x-3 py-1.5"
              >
                <span class="font-mono text-[13px] tabular-nums text-default">{stop.stop_id}</span>
                <span class="min-w-0 text-strong">{stop.stop_name}</span>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </section>
    """
  end

  attr :resolution, :map, required: true
  attr :notice, :string, default: nil

  defp resolution(assigns) do
    open = open_choices(assigns.resolution)

    assigns =
      assigns
      |> assign(:open_choices, open)
      |> assign(:selectable, selectable_count(assigns.resolution))

    ~H"""
    <section id="stop-set-resolution" aria-labelledby="stop-set-resolution-heading" class="grid gap-4">
      <h3
        id="stop-set-resolution-heading"
        tabindex="-1"
        class="w-fit max-w-full text-sm font-[650] text-strong"
      >
        {resolution_heading(@resolution)}
      </h3>

      <ul
        :if={@resolution.resolved != []}
        id="stop-set-resolved"
        class="divide-y divide-subtle text-sm"
      >
        <li :for={match <- @resolution.resolved} class="py-2">
          <p class="flex flex-wrap items-baseline gap-x-3">
            <span class="font-mono text-[13px] tabular-nums text-default">{match.stop.stop_id}</span>
            <span class="min-w-0 text-strong">{match.stop.stop_name}</span>
          </p>
          <p class="text-[13px] text-muted">
            Matched {basis_label(match.basis)}: {Enum.join(match.refs, ", ")}
          </p>
        </li>
      </ul>

      <fieldset
        :for={{ambiguity, index} <- Enum.with_index(@resolution.ambiguous)}
        id={"stop-set-ambiguity-#{index}"}
        class="min-w-0 rounded-control border border-control px-4 py-3"
      >
        <legend class="px-1 text-sm font-[650] text-strong">
          “{ambiguity.ref}” matches {ambiguity.candidate_total} stops {basis_label(ambiguity.basis)}
        </legend>
        <p
          :if={ambiguity.candidate_total > length(ambiguity.candidates)}
          class="text-[13px] text-muted"
        >
          Showing {length(ambiguity.candidates)} of {ambiguity.candidate_total}. Use a stop ID to pick another.
        </p>
        <div class="mt-2 grid gap-1">
          <label
            :for={candidate <- ambiguity.candidates}
            class="flex min-h-11 cursor-pointer items-start gap-3 py-1.5"
          >
            <input
              type="radio"
              name={"stop-set-choice-#{index}"}
              id={"stop-set-choice-#{index}-#{candidate.stop_id}"}
              checked={Map.get(@resolution.choices, ambiguity.ref) == candidate.stop_id}
              phx-click="stop_set_choose"
              phx-value-ref={index}
              phx-value-stop={candidate.stop_id}
              class="mt-0.5 size-5 shrink-0 accent-action"
            />
            <span class="min-w-0 text-sm">
              <span class="font-mono text-[13px] tabular-nums text-default">{candidate.stop_id}</span>
              <span class="text-strong">{candidate.stop_name}</span>
              <span class="block text-[13px] text-muted">{candidate_detail(candidate)}</span>
            </span>
          </label>
          <label class="flex min-h-11 cursor-pointer items-center gap-3 py-1.5">
            <input
              type="radio"
              name={"stop-set-choice-#{index}"}
              id={"stop-set-skip-#{index}"}
              checked={Map.get(@resolution.choices, ambiguity.ref) == :skip}
              phx-click="stop_set_skip"
              phx-value-ref={index}
              class="size-5 shrink-0 accent-action"
            />
            <span class="text-sm text-strong">Skip this line</span>
          </label>
        </div>
      </fieldset>

      <.message
        :if={@resolution.unresolved != []}
        id="stop-set-unmatched"
        kind="warning"
        title={Wording.count_noun(length(@resolution.unresolved), "line matched", "lines matched") <> " no stop"}
      >
        <ul class="list-disc pl-5">
          <li :for={line <- @resolution.unresolved}>{line}</li>
        </ul>
      </.message>

      <.message :if={@notice} id="stop-set-notice" kind="error" title={@notice} tabindex="-1" />

      <div class="grid gap-2">
        <div>
          <.button
            id="stop-set-approve"
            type="button"
            phx-click="stop_set_approve"
            phx-disable-with="Approving…"
            disabled={@open_choices > 0 or @selectable == 0}
            aria-describedby={
              if(@open_choices > 0 or @selectable == 0, do: "stop-set-approve-reason")
            }
            class="min-h-11"
          >
            Approve stops
          </.button>
        </div>
        <p :if={@open_choices > 0} id="stop-set-approve-reason" class="text-[13px] text-muted">
          Choose a stop or skip {Wording.count_noun(@open_choices, "line")} first.
        </p>
        <p
          :if={@open_choices == 0 and @selectable == 0}
          id="stop-set-approve-reason"
          class="text-[13px] text-muted"
        >
          No stop is selected.
        </p>
      </div>
    </section>
    """
  end

  defp summary_text(nil), do: "No stops approved"
  defp summary_text(stops), do: Wording.count_noun(length(stops), "stop") <> " approved"

  defp resolution_heading(%{resolved: resolved, ambiguous: ambiguous, unresolved: unresolved}) do
    [
      Wording.count_noun(length(resolved), "stop") <> " found",
      ambiguous != [] && choice_needed(length(ambiguous)),
      unresolved != [] && Wording.count_noun(length(unresolved), "line") <> " not found"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp choice_needed(1), do: "1 line needs a choice"
  defp choice_needed(count), do: "#{count} lines need a choice"

  defp basis_label(basis), do: Map.fetch!(@basis_labels, basis)

  defp candidate_detail(candidate) do
    [
      candidate.stop_code && "Code #{candidate.stop_code}",
      candidate.parent_station && "Parent #{candidate.parent_station}"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "No code or parent station"
      parts -> Enum.join(parts, " · ")
    end
  end

  # Ambiguities the editor has neither chosen from nor skipped.
  defp open_choices(%{ambiguous: ambiguous, choices: choices}) do
    Enum.count(ambiguous, &(not Map.has_key?(choices, &1.ref)))
  end

  # Stops the approval would hold: resolved matches plus chosen candidates.
  defp selectable_count(%{resolved: resolved, choices: choices}) do
    length(resolved) + Enum.count(choices, fn {_ref, choice} -> choice != :skip end)
  end
end
