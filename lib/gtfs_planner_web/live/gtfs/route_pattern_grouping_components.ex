defmodule GtfsPlannerWeb.Gtfs.RoutePatternGroupingComponents do
  @moduledoc """
  The grouping review `RoutePatternLive` renders for `:index` with
  `?review=group`: one card per groupable stop order among a route's left-out
  trips, the sticky footer that groups them, and the states a review can be in
  besides the ordinary one.

  The cards draw what `Gtfs.preview_left_out/2` already decided — the direction
  suggestion and its reason, the target, the timing names and the distances from
  the target's saved map line. Nothing here recomputes a suggestion: the review
  opens the preview read-only and the apply confirms against the same groups, so
  a card cannot promise one thing and write another.

  `card_id/1`, `direction_id/2` and `target_id/1` are the one place a group's key
  becomes a DOM id. The key is the supplied pattern id joined to a SHA-256 of the
  stop order, so it carries a `:` and 64 hex characters that no CSS selector can
  name; these keep the hash, which is unique per stop order and stable across
  loads.
  """
  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [route_header: 1]

  alias GtfsPlanner.Wording

  @doc """
  The DOM id of one group's card.

  The group's key ends in the SHA-256 of its stop order, so its last path segment
  identifies the stop order uniquely and carries nothing a selector reads as
  syntax.
  """
  def card_id(key) when is_binary(key), do: "grouping-card-#{dom_segment(key)}"

  @doc "The DOM id of one direction radio of one group."
  def direction_id(key, direction), do: "grouping-direction-#{dom_segment(key)}-#{direction}"

  @doc "The DOM id of one group's target chooser."
  def target_id(key), do: "grouping-target-#{dom_segment(key)}"

  @doc "The DOM id of the card's id suffix, for the reason and distance lists."
  def reason_id(key), do: "grouping-reason-#{dom_segment(key)}"

  def distances_id(key), do: "grouping-distances-#{dom_segment(key)}"

  def missing_id(key), do: "grouping-missing-#{dom_segment(key)}"

  attr :route, :map, required: true
  attr :version, :map, required: true
  attr :preview, :map, required: true, doc: "the `Gtfs.preview_left_out/2` map"
  attr :selections, :map, required: true, doc: "the review's selections, keyed by group key"
  attr :state, :atom, required: true, values: [:ready, :stale, :missing, :failed]
  attr :missing_key, :string, default: nil
  attr :failed_reason, :string, default: nil
  attr :editable?, :boolean, required: true

  def page(assigns) do
    groups = assigns.preview.groups

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:trip_total, Enum.reduce(groups, 0, &(&1.trip_count + &2)))
      |> assign(:card_count, length(groups))
      |> assign(:blocked_total, blocked_trips(assigns.preview.blocked))
      |> assign(:lists_path, lists_path(assigns.version, assigns.route))

    ~H"""
    <div id="grouping-review" class="ds-page">
      <.route_header
        route={@route}
        gtfs_version_id={@version.id}
        active_tab={:patterns}
        trip_count={@trip_total}
      />

      <section aria-labelledby="grouping-title" class="pt-5">
        <.link
          id="grouping-back"
          patch={@lists_path}
          class="-ml-2 inline-flex min-h-11 items-center gap-1 rounded-control px-2 text-sm font-[650] text-muted no-underline hover:bg-canvas hover:text-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          <.icon name="hero-chevron-left" class="size-4" /> Back to patterns
        </.link>

        <h2
          id="grouping-title"
          tabindex="-1"
          class="mt-1 font-display text-[26px] font-semibold leading-tight tracking-[-0.025em] text-strong sm:text-[30px]"
        >
          Group {Wording.count_noun(@trip_total, "trip")} into patterns
        </h2>
        <p class="mt-1.5 max-w-[86ch] text-[15px] leading-relaxed text-default">
          These trips have no direction, so import left them out. We found {@card_count} stop
          order{if(@card_count == 1, do: "", else: "s")} among them and filled in everything we
          could. Check each group’s direction, then group them.
        </p>

        <div class="mt-4 grid gap-4">
          <.message
            :if={@state == :stale}
            id="grouping-stale"
            kind="warning"
            title="These trips changed since you opened this review"
          >
            Nothing has been changed. Your direction choices are kept where their groups still
            exist — group again to apply what is there now.
          </.message>

          <.message
            :if={@state == :missing}
            id="grouping-missing"
            kind="error"
            title="Choose a direction for every group first"
          >
            Nothing has been changed. The card below still has no direction.
          </.message>

          <.message
            :if={@state == :failed}
            id="grouping-failed"
            kind="error"
            title="Grouping didn’t finish. Nothing was changed."
          >
            Your direction choices are kept. Try again in a moment.
            <p
              :if={@failed_reason}
              id="grouping-failed-reason"
              class="mt-2 font-mono text-[12px] [overflow-wrap:anywhere]"
            >
              {@failed_reason}
            </p>
          </.message>
        </div>

        <form id="grouping-form" phx-change="grouping_change" phx-submit="grouping_submit">
          <div class="mt-5 grid gap-4">
            <.group_card
              :for={group <- @groups}
              group={group}
              selection={Map.get(@selections, group.key, %{})}
              missing?={@state == :missing and @missing_key == group.key}
              editable?={@editable?}
            />

            <p
              :if={@preview.blocked != []}
              id="grouping-blocked"
              class="flex items-start gap-2 text-[13px] text-muted"
            >
              <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />
              <span>
                Not offered here: {Wording.count_noun(@blocked_total, "trip")} with other problems ({blocked_reasons(
                  @preview.blocked
                )}).
                They stay as imported until the source feed is fixed and re-imported, and are offered
                here automatically once they can be grouped.
              </span>
            </p>
          </div>

          <.footer trip_total={@trip_total} lists_path={@lists_path} editable?={@editable?} />
        </form>
      </section>
    </div>
    """
  end

  attr :group, :map, required: true, doc: "one `Gtfs.preview_left_out/2` group card"
  attr :selection, :map, required: true, doc: "this group's own selections"
  attr :missing?, :boolean, required: true
  attr :editable?, :boolean, required: true
  # One stop order's card: what the trips are, the direction question with the
  # suggestion and its reason, the target it joins or creates, the timing names
  # derivation will give it, and each stop's distance from a saved map line.
  #
  # The card's fields are one form named for the group, so a change round trip
  # arrives as `%{"grouping" => %{group_key => %{"direction_id" => ...}}}` and one
  # map holds every group's answer.
  defp group_card(assigns) do
    %{group: group, selection: selection} = assigns
    chosen = chosen_direction(group, selection)
    target = chosen_target(group, chosen, selection)

    # The chooser's value comes from the form, so the target the headline names
    # is written into it; otherwise the browser would show and send "new".
    field =
      group_form(group.key, if(target, do: Map.put(selection, "target", target), else: selection))

    assigns =
      assigns
      |> assign(:key, group.key)
      |> assign(:field, field)
      |> assign(:chosen, chosen)
      |> assign(:target, target)

    ~H"""
    <article
      id={card_id(@key)}
      tabindex="-1"
      aria-labelledby={"#{card_id(@key)}-title"}
      aria-invalid={@missing? && "true"}
      class={[
        "rounded-card border bg-white",
        (@missing? && "border-error-line") || "border-subtle"
      ]}
    >
      <header class="flex flex-wrap items-start gap-x-4 gap-y-2 px-5 pb-3 pt-4">
        <div class="min-w-0 flex-1 basis-[280px]">
          <p class="text-[13px] text-muted">
            {Wording.count_noun(@group.trip_count, "trip")} · {group_label(@group)}
          </p>
          <h3
            id={"#{card_id(@key)}-title"}
            data-stop-range
            class="mt-0.5 font-display text-[18px] font-semibold leading-snug tracking-[-0.01em] text-strong"
          >
            {stop_range(@group.stop_names)}
          </h3>
          <p class="text-[13px] text-muted">
            {length(@group.stop_names)} stops · imported line {shape_label(@group.shapes)}
          </p>
        </div>
      </header>

      <div class="grid gap-4 px-5 pb-5">
        <fieldset disabled={not @editable?} id={"#{card_id(@key)}-direction"}>
          <legend class="text-sm font-[650] text-strong">{legend_for(@group)}</legend>
          <div class="mt-2 grid gap-3 sm:grid-cols-2">
            <.direction_option
              :for={direction <- [0, 1]}
              group={@group}
              direction={direction}
              name={@field[:direction_id].name}
              checked={@chosen == direction}
            />
          </div>
          <p id={reason_id(@key)} class="mt-2 flex items-start gap-2 text-[13px] text-default">
            <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0 text-info-fg" />
            <span>
              <span class="font-[650] text-strong">{suggestion_heading(@group)}</span>
              {suggestion_reason(@group)}
            </span>
          </p>
          <p
            :if={@missing?}
            id={missing_id(@key)}
            class="mt-2 flex items-center gap-2 text-sm font-[650] text-error-fg"
          >
            <.icon name="hero-exclamation-triangle" class="size-4" />
            Choose Direction 0 or Direction 1 for this group.
          </p>
        </fieldset>

        <div class="rounded-card bg-canvas px-4 py-3">
          <p class="text-sm text-strong">{target_headline(@group, @chosen, @target)}</p>
          <dl class="mt-1.5 divide-y divide-subtle">
            <.detail term="Stops">
              {length(@group.stop_names)}, {stop_range(@group.stop_names)} in the same order.
            </.detail>
            <.detail term="Running times">{timing_label(@group)}</.detail>
            <.detail term="Map line">{map_line_label(@group)}</.detail>
            <.detail
              :if={length(@group.candidates) > 1 and @chosen == @group.direction_id}
              term="Joins"
            >
              <.input
                field={@field[:target]}
                id={target_id(@key)}
                type="select"
                options={target_options(@group)}
                class="select select-sm min-h-11 w-full"
              />
            </.detail>
            <.detail term="Direction">{direction_summary(@chosen)}</.detail>
          </dl>
        </div>

        <ul
          :if={@group.stop_distances_m}
          id={distances_id(@key)}
          class="grid gap-1 text-[13px] text-muted"
        >
          <li :for={{name, meters} <- distance_rows(@group)}>
            <span class="font-[650] text-default">{name}</span>
            {round(meters)} m from the target’s saved map line
          </li>
        </ul>
      </div>
    </article>
    """
  end

  attr :group, :map, required: true
  attr :direction, :integer, required: true
  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  # The radio cards are the ones the alignment editor already draws for its scope
  # question, so a direction reads the way an apply scope does.
  defp direction_option(assigns) do
    assigns = assign(assigns, :id, direction_id(assigns.group.key, assigns.direction))

    ~H"""
    <label
      for={@id}
      class="flex min-h-[64px] cursor-pointer items-start gap-3 rounded-card border border-control bg-white px-4 py-3 text-sm hover:bg-canvas has-[:checked]:border-action has-[:checked]:bg-selection has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
    >
      <input
        type="radio"
        id={@id}
        name={@name}
        value={@direction}
        checked={@checked}
        class="mt-0.5 size-5 shrink-0 accent-action focus-visible:outline-0"
      />
      <span class="min-w-0 flex-1">
        <span class="flex items-center gap-2">
          <span class="text-sm font-bold text-strong">Direction {@direction}</span>
          <span
            :if={suggested_direction(@group) == @direction}
            id={"#{@id}-suggested"}
            class="rounded-control bg-info-bg px-2 py-0.5 text-[12px] font-[650] text-info-fg"
          >
            Suggested
          </span>
        </span>
        <span class="mt-0.5 block text-[13px] text-default">{direction_hint(@direction)}</span>
      </span>
    </label>
    """
  end

  attr :term, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="grid gap-x-4 gap-y-0.5 py-1.5 sm:grid-cols-[112px_minmax(0,1fr)]">
      <dt class="text-[13px] font-[650] text-default">{@term}</dt>
      <dd class="text-[13px] text-default">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :trip_total, :integer, required: true
  attr :lists_path, :string, required: true
  attr :editable?, :boolean, required: true
  # The bar that stays with the operator while the cards scroll: what grouping
  # will do, the one primary action, and the way out that writes nothing.
  defp footer(assigns) do
    ~H"""
    <div
      id="grouping-footer"
      class="sticky bottom-0 z-20 mt-6 flex flex-wrap items-center gap-x-6 gap-y-3 border-t border-subtle bg-white/95 px-1 py-3 shadow-[0_-8px_24px_#0a13300d] backdrop-blur"
    >
      <div class="min-w-0 flex-1 basis-[420px]">
        <p class="text-sm text-default">
          <strong class="font-[650] text-strong">
            {Wording.count_noun(@trip_total, "trip")} get a direction, which is exported.
          </strong>
          Trip times don’t change.
        </p>
        <p class="text-[13px] text-muted">Nothing changes until you group.</p>
      </div>
      <div class="flex flex-wrap items-center gap-3">
        <.link
          id="grouping-cancel"
          patch={@lists_path}
          phx-click="grouping_cancel"
          class="btn btn-outline min-h-11"
        >
          Keep trips as they are
        </.link>
        <button
          id="grouping-submit"
          type="submit"
          disabled={not @editable?}
          phx-disable-with="Grouping…"
          class="btn btn-primary min-h-11 disabled:cursor-progress disabled:hover:bg-action"
        >
          Group {Wording.count_noun(@trip_total, "trip")}
        </button>
      </div>
    </div>
    """
  end

  # --- card data -------------------------------------------------------------
  defp lists_path(version, route),
    do: ~p"/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  defp dom_segment(key) when is_binary(key), do: key |> String.split(":") |> List.last()
  # One form per group, named `grouping[<group key>]`, so the whole review is a
  # single `grouping` map on the way back. `Phoenix.HTML.Form` does not nest, so
  # the nesting is expressed in the name rather than in a second form.
  defp group_form(key, selection),
    do: to_form(selection, as: "grouping[#{key}]")

  # A group's trips carry no direction and no single supplied pattern id of their
  # own, so the card names the two things that identify it: how many trips, and
  # which imported pattern they arrived under.
  defp group_label(%{supplied_route_pattern_id: nil}),
    do: "no supplied route pattern"

  defp group_label(%{supplied_route_pattern_id: supplied}),
    do: "imported pattern #{supplied}"

  defp stop_range([]), do: "No stops"
  defp stop_range([only]), do: only
  defp stop_range(names), do: "#{List.first(names)} → #{List.last(names)}"

  defp shape_label([]), do: "no imported line"

  defp shape_label(shapes),
    do: shapes |> Enum.map_join(", ", fn {shape, _count} -> shape end)

  # Derivation's reason names are the vocabulary of the validator, not the
  # operator's, so each one is said here in the words the review would use.
  defp blocked_reasons(blocked) do
    blocked
    |> Enum.map_join(" and ", fn %{reason: reason, trip_ids: trip_ids} ->
      "#{length(trip_ids)} #{blocked_reason_phrase(reason, length(trip_ids))}"
    end)
  end

  defp blocked_reason_phrase(:invalid_chronology, _count), do: "with times out of order"
  defp blocked_reason_phrase(:unusable_stops, _count), do: "that serves a station"
  defp blocked_reason_phrase(_other, 1), do: "that cannot be served yet"
  defp blocked_reason_phrase(_other, _count), do: "that cannot be served yet"

  defp blocked_trips(blocked), do: blocked |> Enum.map(&length(&1.trip_ids)) |> Enum.sum()
  # A paired group is each other's reverse, so the route's own patterns cannot say
  # which way it runs and the card asks the question outright. Every other group
  # asks for its direction directly.
  defp legend_for(%{suggestion: {:paired, _pair}}), do: "Which way is Direction 0?"
  defp legend_for(_group), do: "Direction"
  # The user's choice when the form carries one, and the suggested direction
  # otherwise, so opening a review shows the suggestion preselected and a later
  # round trip keeps what the operator picked.
  defp chosen_direction(group, selection) do
    case Map.get(selection, "direction_id") do
      "0" -> 0
      "1" -> 1
      _absent -> suggested_or_preview_direction(group)
    end
  end

  defp suggested_or_preview_direction(%{direction_id: direction}) when direction in [0, 1],
    do: direction

  defp suggested_or_preview_direction(_group), do: nil

  defp suggested_direction(%{suggestion: {:suggested, direction, _reason}}), do: direction
  defp suggested_direction(_group), do: nil

  defp suggestion_heading(%{suggestion: {:suggested, direction, _reason}}),
    do: "Why we suggest Direction #{direction}:"

  defp suggestion_heading(_group), do: "Why there is no suggestion:"

  defp suggestion_reason(%{suggestion: {:suggested, _direction, {:same_endpoints, _pattern}}}),
    do:
      " this group starts and ends at the same stops, in the same order, as one of this route’s patterns."

  defp suggestion_reason(%{suggestion: {:suggested, _direction, {:within, _pattern}}}),
    do: " this group runs within one of this route’s patterns."

  defp suggestion_reason(%{suggestion: {:paired, _pair}}),
    do:
      " another group on this route runs these same stops the other way, so the route cannot say which one is Direction 0."

  defp suggestion_reason(_group),
    do:
      " this group shares only one end with this route’s patterns, which is not enough to decide a direction."

  defp direction_hint(0), do: "With the Direction 0 patterns on this route"
  defp direction_hint(1), do: "With the Direction 1 patterns on this route"

  defp direction_summary(nil), do: "not chosen yet"
  defp direction_summary(direction), do: "Direction #{direction}"

  # Rule 5's head is what the apply takes when the chooser is left alone, so the
  # chooser offers the same candidates in the same order, plus the new pattern the
  # alternative is.
  defp target_options(%{candidates: candidates}) do
    [{"Creates a new pattern in this direction", "new"}] ++
      Enum.map(candidates, &{"Joins #{&1.route_pattern_id}", &1.id})
  end

  # The candidates belong to the preview's direction. With the chooser untouched
  # the apply joins the rule-5 head, so that is what the chooser shows and what
  # the headline names; a choice no longer on offer falls back the same way.
  defp chosen_target(
         %{candidates: [head | _rest] = candidates, direction_id: direction},
         direction,
         selection
       ) do
    chosen = Map.get(selection, "target")

    if chosen == "new" or Enum.any?(candidates, &(&1.id == chosen)), do: chosen, else: head.id
  end

  defp chosen_target(_group, _direction, _selection), do: nil

  # With no direction chosen there is nothing to name yet. A direction other than
  # the preview's has no candidates listed here, so the apply decides between the
  # same-stop pattern of that direction and a new one.
  defp target_headline(_group, nil, _target),
    do: "Once you choose a direction, this shows the pattern it joins or the one it creates."

  defp target_headline(%{direction_id: preview}, direction, _target) when direction != preview,
    do:
      "Joins the Direction #{direction} pattern with these stops, or creates one if there is none."

  defp target_headline(%{candidates: candidates}, direction, target) do
    case Enum.find(candidates, &(&1.id == target)) do
      nil -> "Creates a new pattern in Direction #{direction}."
      candidate -> "Joins #{candidate.route_pattern_id}, as a new timing. No new pattern."
    end
  end

  defp timing_label(%{timing_names: []}), do: "Named after their service"

  defp timing_label(%{timing_names: [name]}),
    do: "#{name}, named after their service and made from their times"

  defp timing_label(%{timing_names: names}),
    do:
      "#{Enum.join(names, " and ")}, one per set of times, because these trips do not all run the same times"

  defp map_line_label(%{stop_distances_m: nil, shapes: []}),
    do: "No imported line. You make it editable after grouping."

  defp map_line_label(%{stop_distances_m: nil, shapes: shapes}),
    do:
      "Imported line #{shape_label(shapes)}, kept for the Map line tab. You make it editable after grouping."

  defp map_line_label(%{stop_distances_m: distances, shapes: shapes}) when is_list(distances),
    do:
      "Imported line #{shape_label(shapes)}. The target’s saved map line follows these stops, so the distances below are measured against it."

  # The preview returns one distance per stop in the group's own stop order, and
  # the names are that same order, so zipping the two pairs each stop with its
  # measurement without a second lookup.
  defp distance_rows(%{stop_names: names, stop_distances_m: distances}),
    do:
      Enum.zip(names, distances) |> Enum.map(fn {name, {_stop_id, meters}} -> {name, meters} end)
end
