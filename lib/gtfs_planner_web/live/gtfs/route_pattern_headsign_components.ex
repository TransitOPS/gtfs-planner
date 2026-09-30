defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents do
  @moduledoc """
  Headsign surfaces for the pattern editor: the usage line under the Details and
  Running-times headsign fields, the inline update box that replaces it while a
  value is edited, and the non-blocking wording warnings.

  The components present what they are given: the usage map from
  `GtfsPlanner.Gtfs.RoutePatterns.headsign_usage/3`, the staged selection the
  LiveView derives from it, and the lint atoms from
  `GtfsPlanner.Gtfs.Headsigns.lint/2`. They decide nothing about saving. Copy,
  hierarchy and states follow the headsign propagation prototype
  (`.specs/20-headsign-propagation/references/headsign-propagation-prototype.html`).
  """

  use GtfsPlannerWeb, :html

  alias GtfsPlanner.Gtfs.Headsigns

  @doc """
  Renders how trips use a scope's headsign: "Used by N trips · M show a
  different headsign", the likely-typo chip, the **Review M trips** button and
  the empty, all-matching, shielded-timing and timings-carry variants.

  `usage` is the map `RoutePatterns.headsign_usage/3` returns; `scope_label`
  names the scope in the no-trips line ("pattern" or "timing").
  """
  attr :usage, :map,
    required: true,
    doc:
      "the usage map from Gtfs.headsign_usage/3: scope, default, total, same, differ, shielded, timings_carry, groups"

  attr :id, :string, default: "headsign-usage"

  attr :scope_label, :string,
    default: "pattern",
    doc: ~s{"pattern" or "timing", for the no-trips line}

  def usage_line(assigns) do
    usage = assigns.usage

    carries = usage.timings_carry

    assigns =
      assigns
      |> assign(:typos, typo_count(usage))
      |> assign(:carry_trip_count, carries |> Enum.map(& &1.trip_count) |> Enum.sum())
      |> assign(:carry_values, carries |> Enum.map(& &1.headsign) |> Enum.uniq())
      |> assign(:carry_last, length(carries) - 1)
      |> assign(
        :all_match_copy,
        if(Headsigns.normalize(usage.default),
          do: "all show this headsign",
          else: "all show no headsign"
        )
      )
      |> assign(:scope_value, scope_value(usage.scope))

    ~H"""
    <div
      :if={@usage.timings_carry != []}
      id={@id}
      class="mt-2 rounded-card bg-info-bg px-3 py-2.5 text-[13px] text-default"
    >
      <p>
        <.icon name="hero-information-circle" class="mr-1 inline size-4 align-[-3px] text-muted" />
        Timings set the headsign here:
        <%= for {carry, index} <- Enum.with_index(@usage.timings_carry) do %>
          {carry.name} shows <span class="font-[650] text-strong">{carry.headsign}</span>{if index <
                                                                                               @carry_last,
                                                                                             do: ", "}
        <% end %>
        ({@carry_trip_count} {if(@carry_trip_count == 1, do: "trip", else: "trips")}).
        <%= if @usage.total > 0 do %>
          {@usage.total} {if(@usage.total == 1, do: "trip", else: "trips")} on no timing {if(
            @usage.total == 1,
            do: "follows",
            else: "follow"
          )} this field.
        <% end %>
      </p>
      <button
        :if={length(@carry_values) == 1}
        type="button"
        id={"#{@id}-lift"}
        phx-click="use_timings_headsign"
        phx-value-value={hd(@carry_values)}
        class="mt-2 inline-flex min-h-11 items-center justify-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        Use {hd(@carry_values)} for this pattern
      </button>
    </div>
    <p
      :if={@usage.timings_carry == [] and @usage.total == 0}
      id={@id}
      class="mt-2 text-[13px] text-muted"
    >
      No trips use this {@scope_label} yet. Trips you add get this headsign.
    </p>
    <div
      :if={@usage.timings_carry == [] and @usage.total > 0}
      id={@id}
      class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-default"
    >
      <.icon name="hero-truck" class="size-4 text-muted" />
      <span>
        Used by
        <strong class="font-[650] tabular-nums text-strong">{plural(@usage.total, "trip")}</strong>
        <span aria-hidden="true" class="text-muted">·</span>
        <%= if @usage.differ == 0 do %>
          {@all_match_copy}
        <% else %>
          <strong class="font-[650] tabular-nums text-strong">{@usage.differ}</strong>
          {if(@usage.differ == 1, do: "shows", else: "show")} a different headsign
        <% end %>
        <span :if={@usage.shielded != []}>
          <span aria-hidden="true" class="text-muted">·</span>
          {plural(length(@usage.shielded), "timing")}
          {if(length(@usage.shielded) == 1, do: "sets its own", else: "set their own")}
        </span>
      </span>
      <span
        :if={@typos > 0}
        class="inline-flex max-w-full items-center gap-1.5 whitespace-nowrap rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] leading-normal text-warning-fg"
      >
        <.icon name="hero-exclamation-triangle" class="size-3.5" />
        {@typos} likely {if(@typos == 1, do: "typo", else: "typos")}
      </span>
      <button
        :if={@usage.differ > 0}
        type="button"
        id={"#{@id}-review"}
        phx-click="open_headsign_review"
        phx-value-mode="exceptions"
        phx-value-scope={@scope_value}
        class="inline-flex min-h-11 items-center gap-1 px-1 font-[650] text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
      >
        Review {plural(@usage.differ, "trip")} <.icon name="hero-chevron-right" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders the inline update box that replaces the usage line while a headsign
  value is edited: the "Also update N trips" checkbox over the stay-as-they-are
  lines and **Review trips**.

  `id` is the base id: with `id: "headsign-update"`, the box renders
  `headsign-update-box`, the checkbox `headsign-update-toggle` and the review
  link `headsign-update-review`. `from` is the scope's old effective
  default and `to` the edited value (nil when clearing); `followers` counts the
  trips that show `from`, `selected_follow` the ones currently selected,
  `extra` the trips added in the review, and `others` the differing trips left
  alone. `shielded` lists `%{name: string, headsign: string, trip_count:
  integer}` for the timings that keep their own headsign.
  """
  attr :id, :string, default: "headsign-update"
  attr :from, :string, default: nil, doc: "the scope's old effective default, or nil"
  attr :to, :string, default: nil, doc: "the edited value, or nil when clearing"
  attr :followers, :integer, required: true, doc: "trips that show the old default"

  attr :selected_follow, :integer,
    required: true,
    doc: "followers currently selected for the update"

  attr :extra, :integer, required: true, doc: "trips added to the selection in the review"
  attr :others, :integer, required: true, doc: "differing trips that stay as they are"

  attr :shielded, :list,
    default: [],
    doc: "%{name:, headsign:, trip_count:} per timing with its own headsign"

  attr :update?, :boolean, required: true

  def update_box(assigns) do
    assigns =
      assigns
      |> assign(:from, Headsigns.normalize(assigns.from))
      |> assign(:to, Headsigns.normalize(assigns.to))
      |> assign(:label?, update_label?(assigns))
      |> assign(:partial?, assigns.selected_follow < assigns.followers)

    ~H"""
    <div
      id={"#{@id}-box"}
      class={[
        "mt-3 rounded-card border px-3 py-2",
        @update? && "border-action bg-selection/50",
        !@update? && "border-control"
      ]}
    >
      <%= if @label? do %>
        <label class="flex min-h-11 cursor-pointer items-center gap-3 text-sm" for={"#{@id}-toggle"}>
          <input
            id={"#{@id}-toggle"}
            type="checkbox"
            phx-click="toggle_headsign_update"
            checked={@update?}
            class="size-5 shrink-0 cursor-pointer accent-action"
          />
          <span class="font-[650] text-strong">
            <%= cond do %>
              <% is_nil(@to) -> %>
                Also clear the headsign on {maybe_partial(@partial?, @selected_follow)}{plural(
                  @followers,
                  "trip"
                )} that {if(@followers == 1, do: "shows", else: "show")}
                <.headsign_value value={@from} />
              <% is_nil(@from) -> %>
                Also give {maybe_partial(@partial?, @selected_follow)}{plural(@followers, "trip")} with no headsign
                this headsign
              <% true -> %>
                Also update {maybe_partial(@partial?, @selected_follow)}{plural(@followers, "trip")} that {if(
                  @followers == 1,
                  do: "shows",
                  else: "show"
                )} <.headsign_value value={@from} />
            <% end %>
          </span>
        </label>
      <% else %>
        <p class="py-2 text-sm text-strong">
          No trips show <.headsign_value value={@from} /> now.
        </p>
      <% end %>
      <div class="-mt-1 flex flex-wrap items-center gap-x-1 pl-8 text-[13px] text-default">
        <span class="inline-flex flex-wrap items-center gap-x-1">
          <%= if @update? or not @label? do %>
            <span :if={@extra > 0}>Plus {plural(@extra, "trip")} you added in the review.</span>
            <span :if={@others > 0}>
              {plural(@others, "trip")} with a different headsign {if(@others == 1,
                do: "stays",
                else: "stay"
              )} as {if(@others == 1, do: "it is", else: "they are")}.
            </span>
            <span :for={shield <- @shielded}>
              {shield.name} sets its own headsign, <span class="font-[650] text-strong">{shield.headsign}</span>; its {plural(
                shield.trip_count,
                "trip"
              )}
              {if(shield.trip_count == 1, do: "is", else: "are")} not changed.
            </span>
            <span :if={is_nil(@to)}>
              Trip planner apps then show those trips with the last stop’s name.
            </span>
          <% else %>
            <span>
              Only trips you add get
              <.headsign_value value={@to} />. {plural(@followers, "trip")} keep
              <.headsign_value value={@from} /> and will count as different.
            </span>
          <% end %>
        </span>
        <button
          type="button"
          id={"#{@id}-review"}
          phx-click="open_headsign_review"
          phx-value-mode="change"
          class="inline-flex min-h-11 items-center gap-1 px-1 text-[13px] font-[650] text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          Review trips <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders the non-blocking wording warnings for an edited headsign value: one
  warning note per lint atom from `Headsigns.lint/2`. `value` is the edited
  value (for the all-caps suggestion and the length count), `sibling` the
  `%{name:, headsign:}` of the pattern whose headsign matches except for case,
  and `route` the route short name. Nothing renders while there is no warning.
  """
  attr :warnings, :list, required: true, doc: "lint atoms from Headsigns.lint/2"
  attr :id, :string, default: "headsign-warnings"
  attr :value, :string, default: nil
  attr :sibling, :map, default: nil, doc: "%{name:, headsign:} of the case-equal sibling pattern"
  attr :route, :string, default: nil, doc: "the route short name"

  def wording_warnings(assigns) do
    assigns = assign(assigns, :notes, warning_notes(assigns))

    ~H"""
    <div :if={@notes != []} id={@id}>
      <p
        :for={note <- @notes}
        class="mt-2 flex gap-2 rounded-card bg-warning-bg px-3 py-2 text-[13px] text-warning-fg"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" /> {note}
      </p>
    </div>
    """
  end

  @doc false
  attr :value, :string, required: true

  # A headsign value as riders see it; blank reads words, never an empty quote.
  def headsign_value(assigns) do
    assigns = assign(assigns, :present?, is_binary(Headsigns.normalize(assigns.value)))

    ~H"""
    <span :if={@present?} class="font-[650] text-strong">{@value}</span>
    <span :if={not @present?} class="italic text-muted">No headsign</span>
    """
  end

  # The chip counts the trips in the differing groups the shared Headsigns rule
  # marks as likely typos; the read model already applied that rule per trip.
  defp typo_count(%{groups: groups}) do
    Enum.reduce(groups, 0, fn
      %{likely_typo: true, trips: trips}, count -> count + length(trips)
      _group, count -> count
    end)
  end

  defp scope_value(:pattern), do: "pattern"
  defp scope_value({:timing, timing_id}), do: to_string(timing_id)

  # The checkbox shows when the update reaches at least one trip; without any
  # the box only explains that nothing existing changes.
  defp update_label?(%{followers: followers, extra: extra}), do: followers > 0 or extra > 0

  defp maybe_partial(false, _selected_follow), do: ""
  defp maybe_partial(true, selected_follow), do: "#{selected_follow} of "

  defp warning_notes(%{warnings: warnings} = assigns) do
    value = Headsigns.normalize(assigns.value) || ""

    Enum.map(warnings, fn
      :leading_to ->
        "Leave out “To”. Trip planner apps add their own “to” or arrow."

      :all_caps ->
        "Use mixed case, as vehicle signs and apps do: “#{titlecased(value)}”, not “#{value}”."

      :route_name ->
        "Leave out the route name. Apps already show Route #{assigns.route} beside the headsign."

      :sibling_case ->
        "#{assigns.sibling.name} uses “#{assigns.sibling.headsign}”. Match its capitals so riders see one destination."

      :long ->
        "#{String.length(value)} characters. Vehicle signs and phone screens may cut off headsigns longer than about 30."
    end)
  end

  # The suggestion the prototype offers for an all-caps value: without a
  # leading "To"/"Towards", lowercased, then capitalized per word.
  defp titlecased(value) do
    value
    |> String.replace(~r/^(to|towards)\s+/i, "")
    |> String.downcase()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"
end
