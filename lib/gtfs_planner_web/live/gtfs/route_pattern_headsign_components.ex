defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents do
  @moduledoc """
  Headsign surfaces for the pattern editor: the usage line under the Details and
  Running-times headsign fields, the inline update box that replaces it while a
  value is edited, the non-blocking wording warnings, and the review drawer that
  groups trips by the headsign they show.

  The components present what they are given: the usage map from
  `GtfsPlanner.Gtfs.RoutePatterns.headsign_usage/3`, the staged selection the
  LiveView derives from it, and the lint atoms from
  `GtfsPlanner.Gtfs.Headsigns.lint/2`. They decide nothing about saving. Copy,
  hierarchy and states follow the headsign propagation prototype
  (`.specs/20-headsign-propagation/references/headsign-propagation-prototype.html`).
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [drawer_footer: 1, drawer_scroll: 1]

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Wording

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
        <strong class="font-[650] tabular-nums text-strong">
          {Wording.count_noun(@usage.total, "trip")}
        </strong>
        <span aria-hidden="true" class="text-muted">·</span>
        <%= if @usage.differ == 0 do %>
          {@all_match_copy}
        <% else %>
          <strong class="font-[650] tabular-nums text-strong">{@usage.differ}</strong>
          {if(@usage.differ == 1, do: "shows", else: "show")} a different headsign
        <% end %>
        <span :if={@usage.shielded != []}>
          <span aria-hidden="true" class="text-muted">·</span>
          {Wording.count_noun(length(@usage.shielded), "timing")}
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
        Review {Wording.count_noun(@usage.differ, "trip")}
        <.icon name="hero-chevron-right" class="size-4" />
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
                Also clear the headsign on {maybe_partial(@partial?, @selected_follow)}{Wording.count_noun(
                  @followers,
                  "trip"
                )} that {if(@followers == 1, do: "shows", else: "show")}
                <.headsign_value value={@from} />
              <% is_nil(@from) -> %>
                Also give {maybe_partial(@partial?, @selected_follow)}{Wording.count_noun(
                  @followers,
                  "trip"
                )} with no headsign
                this headsign
              <% true -> %>
                Also update {maybe_partial(@partial?, @selected_follow)}{Wording.count_noun(
                  @followers,
                  "trip"
                )} that {if(
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
            <span :if={@extra > 0}>
              Plus {Wording.count_noun(@extra, "trip")} you added in the review.
            </span>
            <span :if={@others > 0}>
              {Wording.count_noun(@others, "trip")} with a different headsign {if(@others == 1,
                do: "stays",
                else: "stay"
              )} as {if(@others == 1, do: "it is", else: "they are")}.
            </span>
            <span :for={shield <- @shielded}>
              {shield.name} sets its own headsign, <span class="font-[650] text-strong">{shield.headsign}</span>; its {Wording.count_noun(
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
              <.headsign_value value={@to} />. {Wording.count_noun(@followers, "trip")} keep
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

  @review_row_limit 6

  @review_callout_tones %{
    "success" => {"bg-success-bg text-success-fg", "hero-check"},
    "warning" => {"bg-warning-bg text-warning-fg", "hero-exclamation-triangle"},
    "error" => {"bg-error-bg text-error-fg", "hero-exclamation-triangle"}
  }

  @doc """
  Renders the headsign review drawer in one of two modes.

  Exceptions mode (opened from a usage line) groups the trips that differ from
  the scope's default with nothing preselected, and its primary writes each
  selected trip's effective default now. Change mode (opened from the inline
  update box) leads with the trips that follow the old value, preselected, and
  its primary hands the selection back to the page; nothing is written from it.

  `usage` is the map `Gtfs.headsign_usage/4` returns, or nil while `state` is
  `:loading`. `selected` is the MapSet of usage trip ids currently checked and
  `open_groups` the group indices expanded past the six-row preview. `done`
  carries `%{title:, body:}` for the success callout after a reset; `change`
  carries change mode's `%{from:, to:}` draft. Copy, hierarchy and states
  follow the prototype's change-review and review states.
  """
  attr :mode, :atom, values: [:change, :exceptions], required: true

  attr :usage, :map,
    required: true,
    doc: "the usage map from Gtfs.headsign_usage/4, or nil while state is :loading"

  attr :selected, :any, default: MapSet.new(), doc: "MapSet of usage trip ids currently checked"

  attr :open_groups, :list,
    default: [],
    doc: "indices of the groups shown past the six-row preview"

  attr :state, :atom,
    values: [:loading, :ready, :applying, :done, :stale, :failed],
    default: :ready

  attr :done, :map, default: nil, doc: "%{title:, body:} of the success callout after a reset"
  attr :change, :map, default: nil, doc: "change mode's %{from:, to:} draft"

  attr :scope_label, :string,
    default: "pattern",
    doc: ~s{names the scope in the context line, such as "pattern" or "Weekday base timing"}

  attr :version_label, :string, default: nil, doc: "the version name in the context line"

  attr :return_focus_id, :string,
    default: nil,
    doc: "where Escape returns focus; defaults to the mode's standard opener"

  attr :id, :string, default: "headsign-review-drawer"
  attr :open, :boolean, default: false

  def review_drawer(assigns) do
    groups = if(is_map(assigns.usage), do: assigns.usage.groups, else: [])

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:applying?, assigns.state == :applying)
      |> assign(:stale?, assigns.state == :stale)
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(:typos, typo_trips(groups))
      |> assign(:target, drawer_target(assigns))
      |> assign(
        :return_focus_id,
        assigns.return_focus_id || default_return_focus_id(assigns.mode)
      )

    ~H"""
    <.drawer
      id={@id}
      chrome="planner"
      open={@open}
      on_close="close_drawer"
      pending={@applying?}
      return_focus_id={@return_focus_id}
      title={
        if(@mode == :change,
          do: "Trips the new headsign reaches",
          else: "Trips with a different headsign"
        )
      }
      class="max-w-[min(100vw,760px)]"
    >
      <:lede>
        <span>{@scope_label}</span>
        <%= if @mode == :change and is_map(@change) do %>
          <span aria-hidden="true" class="px-1.5">·</span>
          <span class="inline-flex items-center gap-1">
            <.headsign_value value={Map.get(@change, :from)} />
            <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-muted" />
            <.headsign_value value={Map.get(@change, :to)} />
          </span>
          <span class="inline-flex max-w-full items-center gap-1.5 whitespace-nowrap rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] leading-normal text-warning-fg">
            <.icon name="hero-exclamation-triangle" class="size-3.5" /> Preview · not saved
          </span>
        <% else %>
          <span :if={is_map(@usage)} aria-hidden="true" class="px-1.5">·</span>
          <span :if={is_map(@usage)}>Default <.headsign_value value={@usage.default} /></span>
          <span :if={@version_label} aria-hidden="true" class="px-1.5">·</span>
          <span :if={@version_label}>{@version_label}</span>
        <% end %>
      </:lede>
      <.drawer_scroll>
        <%= if @state == :loading do %>
          <div aria-busy="true">
            <p role="status" class="text-sm text-muted">Loading trips…</p>
            <div
              :for={_ <- 1..3}
              aria-hidden="true"
              class="mt-4 rounded-card border border-subtle p-4"
            >
              <div class="h-5 w-48 animate-pulse rounded-control bg-canvas"></div>
              <div class="mt-3 h-4 w-72 animate-pulse rounded-control bg-canvas"></div>
              <div class="mt-4 h-10 w-full animate-pulse rounded-control bg-canvas"></div>
            </div>
          </div>
        <% else %>
          <.review_callout
            :if={@done}
            kind="success"
            id={"#{@id}-done"}
            role="status"
            title={Map.get(@done, :title)}
          >
            {Map.get(@done, :body)}
            <:action>
              <button
                type="button"
                id={"#{@id}-undo"}
                phx-click="undo_headsign"
                phx-value-source="review"
                class="inline-flex min-h-11 items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" /> Undo
              </button>
            </:action>
          </.review_callout>
          <.review_callout
            :if={@stale?}
            kind="warning"
            id={"#{@id}-stale"}
            role="alert"
            title="These trips changed since the list loaded"
          >
            Nothing was changed. Refresh the list; your selection is kept where the trips still match.
          </.review_callout>
          <.review_callout
            :if={@state == :failed}
            kind="error"
            id={"#{@id}-failed"}
            role="alert"
            title="No trips were changed"
          >
            The update didn’t reach the server. Your selection is kept. Try again.
          </.review_callout>
          <%= if @groups == [] do %>
            <div class="rounded-card border border-subtle p-6 text-center">
              <p class="text-base font-bold text-strong">
                All {Wording.count_noun(@usage.total, "trip")} show
                <.headsign_value value={@usage.default} />
              </p>
              <p class="mt-1 text-sm text-muted">
                Nothing to review. A trip gets a different headsign when someone edits it in
                Schedules or an import brings one in.
              </p>
            </div>
          <% else %>
            <p class="text-sm text-default">
              <%= if @mode == :change do %>
                Selected trips get <.headsign_value value={@target} /> when you save. The rest keep
                their headsign. Nothing changes until you save.
              <% else %>
                <%!-- A component boundary gets an engine newline, so the intro's
                periods hug plain spans, like the follows why below. --%>
                <strong class="font-[650] tabular-nums text-strong">{@usage.same}</strong>
                of {@usage.total} trips show
                <%= if is_binary(@usage.default) do %>
                  <span class="font-[650] text-strong">{@usage.default}</span>. Select trips to
                  change to <span class="font-[650] text-strong">{@usage.default}</span>. Trips
                  you don’t select keep their headsign.
                <% else %>
                  <span class="italic text-muted">No headsign</span>. Select trips to change to <span class="italic text-muted">No headsign</span>. Trips you don’t select keep
                  their headsign.
                <% end %>
              <% end %>
            </p>
            <div :if={show_select_typos?(@typos, @selected, @applying?)} class="mt-2">
              <button
                type="button"
                id={"#{@id}-select-typos"}
                phx-click="select_headsign_typos"
                class="inline-flex min-h-11 items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
              >
                <.icon name="hero-check-circle" class="size-4" />
                Select {Wording.count_noun(length(@typos), "likely typo")}
              </button>
            </div>
            <div class="mt-4 grid gap-4">
              <.review_group
                :for={{group, index} <- Enum.with_index(@groups)}
                group={group}
                index={index}
                base_id={@id}
                selected={@selected}
                open={index in @open_groups}
                applying={@applying?}
                default={@usage.default}
                change={@change}
              />
            </div>
            <p class="mt-4 text-[13px] text-muted">
              Only the trip headsign changes. Times, stops, blocks and stop headsigns stay as they
              are. Each changed trip is recorded in History.
            </p>
          <% end %>
        <% end %>
      </.drawer_scroll>
      <.drawer_footer>
        <%= cond do %>
          <% @state == :loading -> %>
            <button
              type="button"
              id={"#{@id}-loading-close"}
              class="btn btn-outline min-h-11"
              phx-click="close_drawer"
            >
              Close
            </button>
          <% @groups == [] -> %>
            <button
              type="button"
              id={"#{@id}-empty-close"}
              class="btn btn-outline min-h-11"
              phx-click="close_drawer"
            >
              Close
            </button>
          <% @mode == :change -> %>
            <p id={"#{@id}-status"} class="min-w-0 flex-1 basis-[220px] text-[13px] text-muted">
              {Wording.count_noun(@selected_count, "trip")} selected. Nothing changes until you save the
              headsign.
            </p>
            <button
              type="button"
              id={"#{@id}-cancel"}
              class="btn btn-outline min-h-11"
              phx-click="close_drawer"
              disabled={@applying?}
            >
              Cancel
            </button>
            <button
              type="button"
              id={"#{@id}-use"}
              class="btn btn-primary min-h-11"
              phx-click="use_headsign_selection"
            >
              Use this selection
            </button>
          <% true -> %>
            <p id={"#{@id}-status"} class="min-w-0 flex-1 basis-[220px] text-[13px] text-muted">
              {exceptions_status(@state, @selected_count)}
            </p>
            <button
              type="button"
              id={"#{@id}-cancel"}
              class="btn btn-outline min-h-11"
              phx-click="close_drawer"
              disabled={@applying?}
            >
              {if(@state == :done, do: "Close", else: "Cancel")}
            </button>
            <button
              type="button"
              id={"#{@id}-apply"}
              class="btn btn-primary min-h-11"
              phx-click={if(@stale?, do: "refresh_headsign_review", else: "apply_headsign_reset")}
              disabled={@applying? or (@selected_count == 0 and not @stale?)}
              data-unavailable={if(not @applying? and @selected_count == 0 and not @stale?, do: true)}
              title={exceptions_primary_title(@state, @selected_count)}
            >
              {exceptions_primary_label(@state, @selected_count, @target)}
            </button>
        <% end %>
      </.drawer_footer>
    </.drawer>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".IndeterminateCheckbox">
      export default {
        mounted() { this.sync() },
        updated() { this.sync() },
        sync() {
          this.el.indeterminate = this.el.dataset.indeterminate === "true"
        },
      }
    </script>
    """
  end

  @doc false
  attr :kind, :string, values: ~w(success warning error), required: true
  attr :id, :string, required: true
  attr :role, :string, required: true
  attr :title, :string, required: true
  slot :inner_block
  slot :action

  # The drawer's state callouts: success with an Undo action, and the warning
  # and error states that keep the selection on screen.
  defp review_callout(assigns) do
    {tone, icon} = Map.fetch!(@review_callout_tones, assigns.kind)
    assigns = assign(assigns, tone: tone, icon: icon)

    ~H"""
    <div
      id={@id}
      role={@role}
      tabindex="-1"
      class={["mb-4 flex gap-3 rounded-card px-4 py-3 text-sm", @tone]}
    >
      <.icon name={@icon} class="mt-0.5 size-5 shrink-0" />
      <div class="min-w-0 flex-1">
        <p class="font-bold">{@title}</p>
        <div :if={@inner_block != []} class="mt-0.5 text-default">{render_slot(@inner_block)}</div>
        <div :if={@action != []} class="mt-2 flex flex-wrap items-center gap-2">
          {render_slot(@action)}
        </div>
      </div>
    </div>
    """
  end

  @doc false
  attr :group, :map, required: true, doc: "one usage group: value, kind, likely_typo, trips"
  attr :index, :integer, required: true
  attr :base_id, :string, required: true
  attr :selected, :any, required: true, doc: "MapSet of usage trip ids currently checked"
  attr :open, :boolean, required: true
  attr :applying, :boolean, required: true
  attr :default, :string, default: nil, doc: "the scope's default, for the difference copy"
  attr :change, :map, default: nil, doc: "change mode's %{from:, to:} draft"

  defp review_group(assigns) do
    trips = assigns.group.trips
    selected_count = Enum.count(trips, &MapSet.member?(assigns.selected, &1.id))
    total = length(trips)

    follow_value =
      if assigns.group.kind == :follows and is_map(assigns.change),
        do: Headsigns.normalize(Map.get(assigns.change, :from))

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:selected_count, selected_count)
      |> assign(:all?, selected_count == total and selected_count > 0)
      |> assign(:mixed?, selected_count > 0 and selected_count < total)
      |> assign(:rows, if(assigns.open, do: trips, else: Enum.take(trips, @review_row_limit)))
      |> assign(:more?, total > @review_row_limit and not assigns.open)
      |> assign(:follow_value, follow_value)

    ~H"""
    <section
      class={[
        "rounded-card border",
        @selected_count > 0 && "border-action",
        @selected_count == 0 && "border-subtle"
      ]}
      aria-labelledby={"#{@base_id}-group-#{@index}"}
    >
      <div class="flex flex-wrap items-start gap-3 px-4 pt-3">
        <%= if @total > 1 do %>
          <input
            id={"#{@base_id}-group-#{@index}-toggle"}
            type="checkbox"
            phx-hook=".IndeterminateCheckbox"
            phx-click="select_headsign_group"
            phx-value-group={@index}
            checked={@all?}
            disabled={@applying}
            data-indeterminate={if(@mixed?, do: "true", else: nil)}
            aria-label={"Select all #{@total} trips showing #{group_aria_value(@group)}"}
            class="mt-1 size-5 shrink-0 cursor-pointer accent-action"
          />
        <% else %>
          <span class="mt-1 size-5 shrink-0" aria-hidden="true"></span>
        <% end %>
        <div class="min-w-0 flex-1">
          <h3
            id={"#{@base_id}-group-#{@index}"}
            class="flex flex-wrap items-center gap-x-2 gap-y-1 text-base"
          >
            <span class="font-[650] text-strong">
              <%= cond do %>
                <% @group.kind == :follows and @follow_value -> %>
                  Show {@follow_value}
                <% @group.kind == :follows -> %>
                  Have no headsign
                <% true -> %>
                  <.headsign_value value={@group.value} />
              <% end %>
            </span>
            <span class="text-sm font-normal text-muted">
              · {Wording.count_noun(@total, "trip")}{if(@mixed?, do: " · #{@selected_count} selected")}
            </span>
            <span
              :if={@group.likely_typo}
              class="inline-flex max-w-full items-center gap-1.5 whitespace-nowrap rounded-badge bg-warning-bg px-2 py-0.5 text-[13px] font-[650] leading-normal text-warning-fg"
            >
              <.icon name="hero-exclamation-triangle" class="size-3.5" /> Likely typo
            </span>
          </h3>
          <p class="mt-1 text-[13px] text-default">
            <%= if @group.kind == :follows do %>
              These trips match the old headsign, so they start selected. Clear any trip that should
              <%= if @follow_value do %>
                keep <span class="font-[650] text-strong">{@follow_value}</span>.
              <% else %>
                keep <span class="italic text-muted">No headsign</span>.
              <% end %>
            <% else %>
              {group_why(@group, @default)}
            <% end %>
          </p>
        </div>
      </div>
      <table class="mt-2 w-full border-collapse text-sm">
        <thead class="sr-only">
          <tr>
            <th>Select</th>
            <th>Departs</th>
            <th>Service day</th>
            <th>Timing</th>
            <th>Trip</th>
          </tr>
        </thead>
        <tbody>
          <.review_row
            :for={trip <- @rows}
            trip={trip}
            selected={MapSet.member?(@selected, trip.id)}
            applying={@applying}
          />
        </tbody>
      </table>
      <div :if={@more?} class="border-t border-subtle px-4">
        <button
          type="button"
          id={"#{@base_id}-group-#{@index}-more"}
          phx-click="show_headsign_group"
          phx-value-group={@index}
          class="inline-flex min-h-11 items-center px-1 font-[650] text-action hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          Show all {@total} trips
        </button>
      </div>
    </section>
    """
  end

  @doc false
  attr :trip, :map, required: true, doc: "one usage_trip from the read model"
  attr :selected, :boolean, required: true
  attr :applying, :boolean, required: true

  defp review_row(assigns) do
    assigns = assign(assigns, :notes, row_notes(assigns.trip))

    ~H"""
    <tr class={["border-t border-subtle align-top", @selected && "bg-selection/50"]}>
      <td class="w-12 py-0.5 pl-4">
        <label class="inline-flex size-11 cursor-pointer items-center justify-center">
          <input
            type="checkbox"
            phx-click="select_headsign_trip"
            phx-value-trip={@trip.id}
            checked={@selected}
            disabled={@applying}
            aria-label={"Change trip #{GtfsTime.display(@trip.departure_secs)} #{row_aria_timing(@trip)}"}
            class="size-5 shrink-0 cursor-pointer accent-action"
          />
        </label>
      </td>
      <td class="px-2 py-3 font-[650] tabular-nums text-strong">
        {GtfsTime.display(@trip.departure_secs)}
      </td>
      <td class="px-2 py-3 text-default">
        <span class="font-mono text-[13px] text-muted [overflow-wrap:anywhere]">
          {@trip.service_id}
        </span>
      </td>
      <td class="px-2 py-3 text-default">
        <%= if @trip.custom? do %>
          <span class="inline-flex items-center gap-1.5 whitespace-nowrap rounded-badge bg-canvas px-2 py-0.5 text-[13px] font-[650] leading-normal text-muted">
            Custom times
          </span>
        <% else %>
          {@trip.timing_name}
        <% end %>
        <span :for={note <- @notes} class="mt-0.5 block text-[13px] text-muted">{note}</span>
      </td>
      <td class="px-4 py-3 text-right font-mono text-[13px] text-muted">
        <span class="[overflow-wrap:anywhere]">{@trip.trip_id}</span>
      </td>
    </tr>
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

    warnings
    # A :sibling_case note names its sibling; with no sibling to name the note
    # is dropped instead of crashing on the nil assign.
    |> Enum.reject(&(&1 == :sibling_case and is_nil(assigns.sibling)))
    |> Enum.map(fn
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

  # The value the drawer's primary acts toward: change mode's draft, else the
  # scope's default. Nil reads as words in the footer, never an empty quote.
  defp drawer_target(%{mode: :change, change: %{} = change}),
    do: Headsigns.normalize(Map.get(change, :to))

  defp drawer_target(%{usage: %{} = usage}), do: usage.default
  defp drawer_target(_assigns), do: nil

  defp default_return_focus_id(:change), do: "headsign-update-review"
  defp default_return_focus_id(:exceptions), do: "headsign-usage-review"

  defp typo_trips(groups) do
    groups
    |> Enum.filter(& &1.likely_typo)
    |> Enum.flat_map(& &1.trips)
  end

  # The shortcut stays available until applying starts and every likely typo
  # is already in the selection.
  defp show_select_typos?(typos, selected, applying?) do
    typos != [] and not applying? and not Enum.all?(typos, &MapSet.member?(selected, &1.id))
  end

  defp group_aria_value(%{value: value}) when is_binary(value), do: value
  defp group_aria_value(_group), do: "no headsign"

  # The observable reason a group differs, one sentence per kind from
  # Headsigns.difference/3; the component only names what the kind states.
  defp group_why(%{kind: :case_or_spacing}, default),
    do:
      "Differs from #{default} only in capital letters or spacing. Riders see two spellings of one destination."

  defp group_why(%{kind: :blank}, _default),
    do: "Trip planner apps show these trips with the last stop’s name instead."

  defp group_why(
         %{
           kind: :interline,
           trips: [%{next_block: %{route_short_name: route, headsign: dest}} | _]
         },
         _default
       )
       when is_binary(route) do
    toward = if is_binary(dest), do: " toward #{dest}", else: ""

    "The bus continues as Route #{route}#{toward}, so the sign shows where riders can stay on to."
  end

  defp group_why(_group, _default), do: "Riders see this instead of the default."

  defp row_notes(trip), do: Enum.concat(next_block_notes(trip), mid_trip_notes(trip))

  defp next_block_notes(%{next_block: %{route_short_name: route} = next_block})
       when is_binary(route) do
    toward = if is_binary(next_block[:headsign]), do: " toward #{next_block[:headsign]}", else: ""
    ["Next in block: Route #{route} at #{GtfsTime.display(next_block[:departure_secs])}#{toward}"]
  end

  defp next_block_notes(_trip), do: []

  defp mid_trip_notes(%{mid_trip_change: stop}) when is_binary(stop),
    do: ["Headsign changes at #{stop}"]

  defp mid_trip_notes(_trip), do: []

  defp row_aria_timing(%{custom?: true}), do: "custom times"
  defp row_aria_timing(%{timing_name: name}) when is_binary(name), do: name
  defp row_aria_timing(_trip), do: "timing"

  defp exceptions_status(:applying, count), do: "Changing #{Wording.count_noun(count, "trip")}…"
  defp exceptions_status(:stale, _count), do: "Nothing was changed."

  defp exceptions_status(_state, 0),
    do: "Select the trips to change. Nothing changes until you apply."

  defp exceptions_status(_state, count),
    do: "#{Wording.count_noun(count, "trip")} selected. Nothing changes until you apply."

  defp exceptions_primary_label(:stale, _count, _target), do: "Refresh list"
  defp exceptions_primary_label(:applying, _count, _target), do: "Changing…"
  defp exceptions_primary_label(_state, 0, _target), do: "Change trips"

  defp exceptions_primary_label(_state, count, target) do
    toward = if(is_binary(target), do: target, else: "no headsign")
    "Change #{Wording.count_noun(count, "trip")} to #{toward}"
  end

  defp exceptions_primary_title(_state, count) when count > 0, do: nil
  defp exceptions_primary_title(:stale, _count), do: nil
  defp exceptions_primary_title(:applying, _count), do: nil
  defp exceptions_primary_title(_state, 0), do: "Select at least one trip"
end
