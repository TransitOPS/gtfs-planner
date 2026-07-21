defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents do
  @moduledoc """
  Function components for the change-history panel rendered in the
  child-stop, pathway, and level sidebars of the station diagram editor.

  ## Caller-owned state

  This module renders; it never loads, converts, or decides. `StationDiagramLive`
  owns the asynchronous lifecycle (`:initial_loading | :ready | :refreshing |
  :error`), the assigned filter form, and the agency-local timestamps produced by
  one batch `Gtfs.localize_display_times/2` call. The component receives those
  local `NaiveDateTime` values keyed by entry id and groups by their local date —
  it never converts a zone itself, and it never mutates the stored UTC value it
  still emits in every `<time datetime>` attribute.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents,
    only: [button: 1, callout: 1, count_strip: 1, empty_state: 1, icon: 1, input: 1, skeleton: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.Stop

  @system_noise_diff_fields MapSet.new(
                              ~w(organization_id gtfs_version_id id inserted_at updated_at)
                            )

  @change_value_max_chars 60

  if Mix.env() == :test do
    def __test_display_name__(arg), do: display_name(arg)
    def __test_format_date_header__(d, t), do: format_date_header(d, t)
    def __test_format_time_short__(local, t), do: format_time_short(local, t)

    def __test_group_entries_by_date__(entries, local_times),
      do: group_entries_by_local_date(entries, local_times)

    def __test_relative_time__(local, now), do: relative_time(local, now)
    def __test_field_groups__(et), do: field_groups(et)
    def __test_categorical_value__(key, value), do: categorical_value(key, value)

    def __test_apply_field_filter__(rows, entity_type, filter_key),
      do: apply_field_filter(rows, entity_type, filter_key)

    def __test_rollback_button_variant__(entry, rollback_by_original_id, latest?),
      do: rollback_button_variant(entry, rollback_by_original_id, latest?)

    def __test_rollback_button_label__(variant), do: rollback_button_label(variant)

    def __test_preview_matches_entry__(preview, entity_type, entry),
      do: preview_matches_entry?(preview, entity_type, entry)
  end

  attr :entity_type, :string, required: true
  attr :entity_id, :string, required: true
  attr :history_active, :boolean, required: true

  def history_tab_strip(assigns) do
    ~H"""
    <div
      id={"#{@entity_type}-tabs"}
      class="flex gap-6 mb-4 border-b border-base-300"
      role="tablist"
      aria-orientation="horizontal"
      phx-hook="TablistHook"
    >
      <button
        id={"#{@entity_type}-tab-details"}
        type="button"
        role="tab"
        phx-click={if @history_active, do: "hide_history"}
        aria-selected={if @history_active, do: "false", else: "true"}
        aria-controls={"#{@entity_type}-panel-details"}
        tabindex={if @history_active, do: "-1", else: "0"}
        class={[
          "py-3 text-sm bg-transparent border-0 -mb-px border-b-2",
          "focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:rounded-sm",
          if(@history_active,
            do: "text-base-content/60 hover:text-base-content border-transparent",
            else: "text-base-content font-medium border-base-content"
          )
        ]}
      >
        Details
      </button>
      <button
        id={"#{@entity_type}-tab-history"}
        type="button"
        role="tab"
        phx-click={if @history_active, do: nil, else: "show_history"}
        phx-value-entity-type={@entity_type}
        phx-value-entity-id={@entity_id}
        aria-selected={if @history_active, do: "true", else: "false"}
        aria-controls={"#{@entity_type}-panel-history"}
        tabindex={if @history_active, do: "0", else: "-1"}
        class={[
          "py-3 text-sm bg-transparent border-0 -mb-px border-b-2",
          "focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 focus-visible:rounded-sm",
          if(@history_active,
            do: "text-base-content font-medium border-base-content",
            else: "text-base-content/60 hover:text-base-content border-transparent"
          )
        ]}
      >
        History
      </button>
    </div>
    """
  end

  @doc """
  Renders one entity's change history from caller-owned lifecycle state.

  `state` drives the visible region: `:initial_loading` paints a skeleton,
  `:refreshing` keeps the previous entries and adds a small refreshing strip,
  and `:error` keeps them as an explicitly labelled stale preview beside one
  retry action. `local_times` maps entry id to the agency-local
  `NaiveDateTime` the caller already localized in one batch.
  """
  attr :entries, :list, default: []
  attr :entity_type, :string, required: true

  attr :state, :atom,
    default: :ready,
    values: [:idle, :initial_loading, :ready, :refreshing, :error]

  attr :filter_form, :any, required: true
  attr :rollback_preview, :map, default: nil
  attr :history_field_filter, :string, default: "all"
  attr :zone, :any, default: nil
  attr :local_times, :map, default: %{}
  attr :today, :any, default: nil
  attr :now, :any, default: nil

  def change_log_list(assigns) do
    entries = assigns.entries
    entity_type = assigns.entity_type
    filter_key = assigns.history_field_filter
    local_times = assigns.local_times
    today = assigns.today || Date.utc_today()
    now = assigns.now || NaiveDateTime.utc_now()

    rollback_by_original_id = rollback_by_original_id(entries)
    reverted_count = map_size(rollback_by_original_id)
    last_modified_entry = List.first(entries)

    visible_entries = Enum.reject(entries, &(&1.action == "rolled_back"))

    rows_by_id =
      Map.new(visible_entries, fn entry ->
        {entry.id, apply_field_filter(diff_rows(entry), entity_type, filter_key)}
      end)

    matching_entries =
      Enum.filter(visible_entries, &entry_matches_filter?(&1, rows_by_id, filter_key))

    matching_change_count =
      matching_entries |> Enum.map(&length(Map.fetch!(rows_by_id, &1.id))) |> Enum.sum()

    current_state_entry_id =
      case last_modified_entry do
        %{action: "rolled_back"} -> nil
        %{id: id} -> id
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:today, today)
      |> assign(:now, now)
      |> assign(:rollback_by_original_id, rollback_by_original_id)
      |> assign(:rows_by_id, rows_by_id)
      |> assign(:grouped, group_entries_by_local_date(matching_entries, local_times))
      |> assign(:entry_count, length(entries))
      |> assign(:reverted_count, reverted_count)
      |> assign(:last_modified_entry, last_modified_entry)
      |> assign(
        :last_modified_local,
        last_modified_entry && local_time(last_modified_entry, local_times)
      )
      |> assign(:current_state_entry_id, current_state_entry_id)
      |> assign(:filter_options, filter_options(entity_type, visible_entries, filter_key))
      |> assign(:panel_state, panel_state(assigns.state, entries, matching_entries))
      |> assign(
        :count_items,
        count_items(length(matching_entries), matching_change_count, reverted_count)
      )
      |> assign(:zone_label, zone_label(assigns.zone))
      |> assign(:fallback_reason_text, fallback_reason_text(assigns.zone))

    ~H"""
    <div
      id={"history-#{@entity_type}"}
      data-role="history-panel"
      data-state={@panel_state}
      class="space-y-4"
    >
      <.skeleton
        :if={@state in [:idle, :initial_loading]}
        id={"history-loading-#{@entity_type}"}
        rows={3}
        label={"Loading history for this #{entity_label(@entity_type)}…"}
      />

      <div
        :if={@state == :refreshing}
        id={"history-refreshing-#{@entity_type}"}
        class="flex items-center gap-2 border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content"
      >
        <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
        <span>Refreshing history…</span>
      </div>

      <.callout
        :if={@state == :error}
        kind="error"
        id={"history-error-#{@entity_type}"}
        title="History could not load"
      >
        <p>
          The change history for this {entity_label(@entity_type)} did not load. Nothing was changed.
        </p>
        <div class="mt-3">
          <.button
            id={"history-retry-#{@entity_type}"}
            size="sm"
            phx-click="retry_history"
            class="min-h-11"
          >
            Retry history
          </.button>
        </div>
      </.callout>

      <p
        :if={@state == :error and @entries != []}
        id={"history-stale-#{@entity_type}"}
        class="text-sm text-base-content/70"
      >
        Showing the history loaded before that failure. It may be out of date.
      </p>

      <.empty_state
        :if={@state not in [:idle, :initial_loading] and @entries == []}
        id={"history-empty-#{@entity_type}"}
        title={"No changes have been recorded for this #{entity_label(@entity_type)}"}
      >
        Edits are recorded automatically. The first change will appear in this panel.
        <:action>
          <.button
            id={"history-open-details-#{@entity_type}"}
            variant="secondary"
            size="sm"
            phx-click="hide_history"
            class="min-h-11"
          >
            Edit {entity_label(@entity_type)}
          </.button>
        </:action>
      </.empty_state>

      <%= if @state not in [:idle, :initial_loading] and @entries != [] do %>
        <div
          data-testid="history-summary"
          class="flex flex-wrap items-end justify-between gap-3 px-3 py-2.5 bg-base-200 border border-base-300 rounded-md"
        >
          <div class="min-w-0">
            <div class="text-[13px] text-base-content">
              Last modified
              <time datetime={DateTime.to_iso8601(@last_modified_entry.inserted_at)}>
                {relative_time(@last_modified_local, @now)}
              </time>
              by
              <span class="font-medium">
                {display_name(@last_modified_entry.actor_email)}
              </span>
            </div>
            <div class="text-xs text-base-content/70 mt-0.5">
              {@entry_count} {if @entry_count == 1, do: "change", else: "changes"}, {@reverted_count} reverted
            </div>
          </div>

          <.form
            for={@filter_form}
            id={"history-filter-form-#{@entity_type}"}
            phx-change="filter_history"
            class="shrink-0"
          >
            <.input
              field={@filter_form[:key]}
              id={"history-filter-#{@entity_type}"}
              type="select"
              label="Fields"
              options={@filter_options}
              class="select w-auto"
            />
          </.form>
        </div>

        <.count_strip id={"history-counts-#{@entity_type}"} items={@count_items} />

        <p
          :if={@zone_label && is_nil(@fallback_reason_text)}
          id={"history-timezone-#{@entity_type}"}
          class="text-xs text-base-content/70"
        >
          Times shown in {@zone_label}.
        </p>

        <.callout
          :if={@fallback_reason_text}
          kind="warning"
          id={"history-utc-fallback-#{@entity_type}"}
          title="Times shown in UTC"
        >
          {@fallback_reason_text} Stored timestamps are unchanged.
        </.callout>

        <.empty_state
          :if={@grouped == []}
          id={"history-filtered-empty-#{@entity_type}"}
          title="No changes match this filter"
        >
          No recorded change touched these fields. Clear the filter to see the full history.
          <:action>
            <.button
              id={"history-clear-filter-#{@entity_type}"}
              variant="secondary"
              size="sm"
              phx-click="clear_history_filter"
              class="min-h-11"
            >
              Clear filter
            </.button>
          </:action>
        </.empty_state>

        <div :for={{date, entries_for_date} <- @grouped} class="space-y-3">
          <div class="flex items-center gap-2">
            <h3
              data-testid="history-date-header"
              class="text-xs font-medium text-base-content/70 tracking-wide uppercase m-0"
            >
              <time datetime={Date.to_iso8601(date)}>
                {format_date_header(date, @today)}
              </time>
            </h3>
            <div aria-hidden="true" class="flex-1 h-px bg-base-content/20"></div>
          </div>

          <div class="relative pl-6">
            <div
              aria-hidden="true"
              class="absolute left-[9px] top-2 bottom-2 w-0.5 bg-base-content/20"
            >
            </div>

            <ul class="space-y-3 list-none m-0 p-0">
              <li
                :for={entry <- entries_for_date}
                id={"history-entry-#{entry.id}"}
                data-role="history-entry"
                class="relative"
              >
                <% current? = entry.id == @current_state_entry_id
                rollback_entry = Map.get(@rollback_by_original_id, entry.id)
                reverted? = rollback_entry != nil

                rows = Map.get(@rows_by_id, entry.id, [])

                variant =
                  rollback_button_variant(entry, @rollback_by_original_id, current?)

                target_log_id =
                  case variant do
                    :reapply -> rollback_entry.id
                    :original -> nil
                    :none -> nil
                    _ -> entry.id
                  end %>

                <div
                  aria-hidden="true"
                  class={[
                    "absolute -left-[21px] top-2 w-3.5 h-3.5 rounded-full bg-base-100 border-2",
                    if(current?, do: "border-emerald-600", else: "border-base-content/40")
                  ]}
                >
                </div>

                <div class={[
                  "bg-base-100 border rounded-lg p-3.5",
                  if(current?,
                    do: "border-emerald-600/40 ring-2 ring-emerald-500/30",
                    else: "border-base-300"
                  )
                ]}>
                  <div class="flex items-center gap-2 mb-2 flex-wrap">
                    <div
                      aria-hidden="true"
                      class="w-[22px] h-[22px] rounded-full bg-base-300 text-base-content text-[10px] font-medium flex items-center justify-center shrink-0"
                    >
                      {display_initials(entry.actor_email)}
                    </div>
                    <span class="text-[13px] font-medium text-base-content">
                      {display_name(entry.actor_email)}
                    </span>
                    <span
                      :if={current?}
                      class="text-[10px] font-medium px-2 py-0.5 rounded-full bg-emerald-50 text-emerald-900 tracking-wide uppercase"
                    >
                      Current
                    </span>
                    <span
                      :if={reverted?}
                      class="text-[10px] font-medium px-2 py-0.5 rounded-full bg-base-300 text-base-content tracking-wide uppercase"
                    >
                      Reverted
                    </span>
                    <time
                      datetime={DateTime.to_iso8601(entry.inserted_at)}
                      class="ml-auto text-xs text-base-content/70 tabular-nums"
                    >
                      {format_time_short(local_time(entry, @local_times), @today)}
                    </time>
                  </div>

                  <div class="text-[13px] mb-2.5">
                    <span class={if(reverted?, do: "text-base-content/70", else: "text-base-content")}>
                      {entry_summary(entry, @entity_type)}
                    </span>
                  </div>

                  <.change_diff
                    entry={entry}
                    entity_type={@entity_type}
                    rows={rows}
                  />

                  <div
                    :if={reverted?}
                    class="mt-2.5 text-xs text-base-content/70 flex items-center gap-1.5"
                  >
                    <span aria-hidden="true">↩</span>
                    <span>
                      Reverted by
                      <span class="font-medium text-base-content">
                        {display_name(rollback_entry.actor_email)}
                      </span>
                      at
                      <time datetime={DateTime.to_iso8601(rollback_entry.inserted_at)}>
                        {format_time_short(local_time(rollback_entry, @local_times), @today)}
                      </time>
                    </span>
                  </div>

                  <.rollback_preview
                    :if={
                      preview_matches_entry?(@rollback_preview, @entity_type, entry) or
                        (reverted? and
                           preview_matches_entry?(@rollback_preview, @entity_type, rollback_entry))
                    }
                    rollback_preview={@rollback_preview}
                    entity_type={@entity_type}
                  />

                  <%= if variant != :none do %>
                    <div class="flex justify-end mt-2.5">
                      <button
                        type="button"
                        data-history-entry-action={Atom.to_string(variant)}
                        phx-click={if variant != :original, do: "preview_rollback_change_log"}
                        phx-value-log-id={target_log_id}
                        aria-disabled={if variant == :original, do: "true"}
                        disabled={variant == :original}
                        title={
                          if variant == :original,
                            do: "Cannot restore to before this #{entity_label(@entity_type)} existed"
                        }
                        class={[
                          "text-xs px-2.5 py-1 rounded-md border",
                          "focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500",
                          if(variant == :original,
                            do:
                              "border-base-200 text-base-content/60 bg-base-200/60 cursor-not-allowed",
                            else: "border-control-border text-base-content hover:bg-base-200"
                          )
                        ]}
                      >
                        {rollback_button_label(variant)}
                      </button>
                    </div>
                  <% end %>
                </div>
              </li>
            </ul>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :entity_type, :string, required: true
  attr :rows, :list, default: nil

  def change_diff(assigns) do
    assigns =
      assign_new(assigns, :resolved_rows, fn -> assigns.rows || diff_rows(assigns.entry) end)

    ~H"""
    <div
      :if={@resolved_rows != []}
      class="bg-base-200 rounded-md p-2.5 grid [grid-template-columns:max-content_minmax(0,1fr)] gap-x-3 gap-y-1.5 items-baseline"
    >
      <%= for row <- @resolved_rows do %>
        <div class="text-xs text-base-content/70">{row.field}</div>
        <div class="text-xs flex items-baseline gap-1.5 flex-wrap min-w-0 break-words">
          <span class="line-through text-base-content/70">
            <.diff_cell entity_type={@entity_type} field={row.field} value={row.from} />
          </span>
          <span class="sr-only">changed to</span>
          <span aria-hidden="true" class="text-base-content/60">→</span>
          <span class="text-base-content">
            <.diff_cell entity_type={@entity_type} field={row.field} value={row.to} />
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :entity_type, :string, required: true
  attr :field, :string, required: true
  attr :value, :any, required: true

  defp diff_cell(assigns) do
    ~H"""
    <%= case categorical_value({@entity_type, @field}, @value) do %>
      <% :passthrough -> %>
        {render_diff_value_text(@value)}
      <% {label, nil} -> %>
        {label}
      <% {label, dot_class} -> %>
        <span class="inline-flex items-center gap-1">
          <span aria-hidden="true" class={"w-1.5 h-1.5 rounded-full " <> dot_class}></span>
          {label}
        </span>
    <% end %>
    """
  end

  defp render_diff_value_text(:__missing__), do: "—"
  defp render_diff_value_text(value), do: render_present_value(value)

  attr :rollback_preview, :map, required: true
  attr :entity_type, :string, required: true

  def rollback_preview(assigns) do
    ~H"""
    <div
      id={"rollback-preview-#{@entity_type}"}
      role="region"
      aria-live="polite"
      aria-labelledby={"rollback-preview-heading-#{@entity_type}"}
      class="mt-2.5 border border-amber-300 bg-amber-50 rounded-md p-3 space-y-2"
    >
      <p
        id={"rollback-preview-heading-#{@entity_type}"}
        class="text-[13px] font-medium text-amber-950"
      >
        Revert these changes?
      </p>

      <div class="bg-base-100 border border-amber-300 rounded-md p-2.5 grid [grid-template-columns:max-content_minmax(0,1fr)] gap-x-3 gap-y-1 items-baseline">
        <%= for row <- @rollback_preview.field_changes do %>
          <div class="text-xs text-base-content/70">{row.field}</div>
          <div class="text-xs flex items-baseline gap-1.5 flex-wrap min-w-0 break-words">
            <span class="line-through text-base-content/70">{truncate_value(row.current)}</span>
            <span class="sr-only">changed to</span>
            <span aria-hidden="true" class="text-base-content/60">→</span>
            <span class="text-base-content">{truncate_value(row.restored)}</span>
          </div>
        <% end %>
      </div>

      <div class="flex justify-end gap-2">
        <button
          id={"rollback-preview-cancel-#{@entity_type}"}
          type="button"
          class="text-xs px-2.5 py-1 rounded-md border border-control-border text-base-content hover:bg-base-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
          phx-click="cancel_rollback_preview"
        >
          Cancel
        </button>
        <button
          id={"rollback-preview-confirm-#{@entity_type}"}
          type="button"
          class="text-xs px-2.5 py-1 rounded-md bg-amber-600 text-white hover:bg-amber-700 font-medium focus:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-1"
          phx-click="confirm_rollback_change_log"
          phx-value-log-id={@rollback_preview.log.id}
        >
          Confirm revert
        </button>
      </div>
    </div>
    """
  end

  defp rollback_by_original_id(entries) do
    Enum.reduce(entries, %{}, fn
      %{action: "rolled_back", rolled_back_to_log_id: original_id} = entry, acc
      when not is_nil(original_id) ->
        Map.put(acc, original_id, entry)

      _entry, acc ->
        acc
    end)
  end

  defp diff_rows(%{changed_fields: fields}) when is_map(fields) and map_size(fields) > 0 do
    fields
    |> Enum.reject(fn {field, _change} ->
      MapSet.member?(@system_noise_diff_fields, to_string(field))
    end)
    |> Enum.map(fn {field, change} ->
      %{
        field: to_string(field),
        from: extract_change_value(change, "from", :from),
        to: extract_change_value(change, "to", :to)
      }
    end)
    |> Enum.sort_by(& &1.field)
  end

  defp diff_rows(_entry), do: []

  defp extract_change_value(change, string_key, atom_key) do
    case Map.get(change, string_key, :__missing__) do
      :__missing__ -> Map.get(change, atom_key, :__missing__)
      value -> value
    end
  end

  defp render_present_value(nil), do: "nil"
  defp render_present_value(value), do: truncate_value(value)

  defp truncate_value(nil), do: "—"
  defp truncate_value(value) when is_binary(value), do: truncate_string(value)
  defp truncate_value(value), do: value |> inspect() |> truncate_string()

  defp truncate_string(str) do
    if String.length(str) > @change_value_max_chars do
      String.slice(str, 0, @change_value_max_chars) <> "…"
    else
      str
    end
  end

  def valid_filter_key?(entity_type, key) when is_binary(entity_type) and is_binary(key) do
    Enum.any?(field_groups(entity_type), &(&1.key == key))
  end

  defp field_groups("stop") do
    [
      %{key: "all", label: "All fields", fields: :all},
      %{
        key: "position",
        label: "Position only",
        fields: ~w(stop_lat stop_lon position_x position_y)
      },
      %{key: "accessibility", label: "Accessibility only", fields: ~w(wheelchair_boarding)},
      %{
        key: "naming",
        label: "Name & description",
        fields: ~w(stop_name stop_desc tts_stop_name)
      }
    ]
  end

  defp field_groups("pathway") do
    [
      %{key: "all", label: "All fields", fields: :all},
      %{key: "mode", label: "Mode only", fields: ~w(pathway_mode is_bidirectional)},
      %{
        key: "geometry",
        label: "Geometry only",
        fields: ~w(length traversal_time stair_count max_slope min_width)
      },
      %{key: "signage", label: "Signage", fields: ~w(signposted_as reversed_signposted_as)}
    ]
  end

  defp field_groups("level") do
    [
      %{key: "all", label: "All fields", fields: :all},
      %{key: "naming", label: "Name only", fields: ~w(level_name)},
      %{key: "index", label: "Index only", fields: ~w(level_index)}
    ]
  end

  defp display_name(nil), do: "Unknown"
  defp display_name(""), do: "Unknown"

  defp display_name(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[._\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &:string.titlecase/1)
  end

  defp display_initials(email) do
    email
    |> display_name()
    |> String.split(" ", trim: true)
    |> case do
      [single] -> String.slice(single, 0, 2)
      parts -> parts |> Enum.take(2) |> Enum.map_join("", &String.first/1)
    end
    |> String.upcase()
  end

  defp entry_summary(entry, entity_type) do
    label = entity_label(entity_type)

    case entry.action do
      "created" -> "Created #{label}"
      "deleted" -> "Deleted #{label}"
      _ -> "Edited #{label}#{field_count_suffix(entry.changed_fields)}"
    end
  end

  defp field_count_suffix(fields) when is_map(fields) do
    count =
      fields
      |> Enum.reject(fn {field, _} ->
        MapSet.member?(@system_noise_diff_fields, to_string(field))
      end)
      |> length()

    case count do
      0 -> ""
      1 -> " · 1 field changed"
      n -> " · #{n} fields changed"
    end
  end

  defp field_count_suffix(_), do: ""

  defp entity_label("stop"), do: "stop"
  defp entity_label("pathway"), do: "pathway"
  defp entity_label("level"), do: "level"
  defp entity_label(other) when is_binary(other), do: other

  defp upcased_month_day(%Date{} = d),
    do: d |> Calendar.strftime("%b %-d") |> String.upcase()

  defp format_date_header(%Date{} = date, %Date{} = today) do
    cond do
      Date.compare(date, today) == :eq -> "TODAY · " <> upcased_month_day(date)
      Date.diff(today, date) == 1 -> "YESTERDAY · " <> upcased_month_day(date)
      true -> upcased_month_day(date)
    end
  end

  # Every time below is already agency-local: the caller localized the whole
  # collection in one batch and the component only formats what it received.
  defp format_time_short(%NaiveDateTime{} = local, %Date{} = today) do
    if NaiveDateTime.to_date(local) == today do
      Gtfs.format_display_time(local)
    else
      Calendar.strftime(local, "%b %-d") <> " · " <> Gtfs.format_display_time(local)
    end
  end

  defp local_time(entry, local_times) do
    case Map.get(local_times, entry.id) do
      %NaiveDateTime{} = local -> local
      _ -> DateTime.to_naive(entry.inserted_at)
    end
  end

  defp group_entries_by_local_date(entries, local_times) do
    entries
    |> Enum.group_by(fn entry -> NaiveDateTime.to_date(local_time(entry, local_times)) end)
    |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
  end

  defp entry_matches_filter?(_entry, _rows_by_id, "all"), do: true

  defp entry_matches_filter?(entry, rows_by_id, _filter_key),
    do: Map.get(rows_by_id, entry.id, []) != []

  defp panel_state(state, _entries, _matching) when state in [:idle, :initial_loading],
    do: "loading"

  defp panel_state(:error, _entries, _matching), do: "error"
  defp panel_state(:refreshing, _entries, _matching), do: "refreshing"
  defp panel_state(:ready, [], _matching), do: "empty"
  defp panel_state(:ready, _entries, []), do: "filtered"
  defp panel_state(:ready, _entries, _matching), do: "ready"

  defp count_items(entry_count, change_count, reverted_count) do
    [
      %{key: "entries", label: "Matching entries", count: entry_count, tone: :neutral},
      %{key: "changes", label: "Matching changes", count: change_count, tone: :info},
      %{key: "reverted", label: "Reverted", count: reverted_count, tone: :warning}
    ]
  end

  # Options carry their own match count so a selection that will land on the
  # filtered-empty state announces itself before it is made.
  defp filter_options(entity_type, visible_entries, _filter_key) do
    Enum.map(field_groups(entity_type), fn group ->
      count =
        visible_entries
        |> Enum.map(&length(apply_field_filter(diff_rows(&1), entity_type, group.key)))
        |> Enum.sum()

      {"#{group.label} (#{count})", group.key}
    end)
  end

  defp zone_label(%{timezone: timezone}) when is_binary(timezone), do: timezone
  defp zone_label(_), do: nil

  defp fallback_reason_text(%{fallback?: true, fallback_reason: reason}),
    do: fallback_reason_sentence(reason)

  defp fallback_reason_text(_), do: nil

  defp fallback_reason_sentence(:conflicting),
    do:
      "This version's agencies declare more than one time zone, so no single agency zone applies."

  defp fallback_reason_sentence(:invalid),
    do: "This version's agency time zone is not a recognized IANA name."

  defp fallback_reason_sentence(_),
    do: "This version has no agency time zone recorded."

  defp relative_time(%NaiveDateTime{} = local, %NaiveDateTime{} = now) do
    seconds = NaiveDateTime.diff(now, local, :second)

    cond do
      seconds < 60 ->
        "just now"

      seconds < 3600 ->
        minutes = div(seconds, 60)
        "#{minutes} #{pluralize(minutes, "minute")} ago"

      NaiveDateTime.to_date(local) == NaiveDateTime.to_date(now) ->
        hours = div(seconds, 3600)
        "#{hours} #{pluralize(hours, "hour")} ago"

      true ->
        days = Date.diff(NaiveDateTime.to_date(now), NaiveDateTime.to_date(local))

        cond do
          days == 1 -> "yesterday"
          days < 7 -> "#{days} days ago"
          true -> Calendar.strftime(local, "%b %-d")
        end
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  defp apply_field_filter(diff_rows, _entity_type, "all"), do: diff_rows

  defp apply_field_filter(diff_rows, entity_type, filter_key) do
    case Enum.find(field_groups(entity_type), &(&1.key == filter_key)) do
      %{fields: :all} -> diff_rows
      %{fields: keys} -> Enum.filter(diff_rows, &(&1.field in keys))
      nil -> diff_rows
    end
  end

  defp rollback_button_variant(%{id: id}, rollback_by_original_id, _current?)
       when is_map_key(rollback_by_original_id, id),
       do: :reapply

  defp rollback_button_variant(%{action: "created"}, _rollback_by_original_id, _current?),
    do: :original

  defp rollback_button_variant(%{action: "deleted"}, _rollback_by_original_id, _current?),
    do: :none

  defp rollback_button_variant(entry, _rollback_by_original_id, current?) do
    cond do
      not rollback_eligible?(entry) -> :none
      current? -> :undo
      true -> :restore
    end
  end

  defp rollback_eligible?(%ChangeLog{} = entry), do: Gtfs.rollback_previewable_fields(entry) != []
  defp rollback_eligible?(_entry), do: true

  defp rollback_button_label(:undo), do: "Undo this change"
  defp rollback_button_label(:restore), do: "Restore to this state"
  defp rollback_button_label(:reapply), do: "Re-apply this change"
  defp rollback_button_label(:original), do: "Original version"
  defp rollback_button_label(:none), do: nil

  defp preview_matches_entry?(nil, _entity_type, _entry), do: false

  defp preview_matches_entry?(%{} = preview, entity_type, entry) do
    preview.entity_type == entity_type and preview.log.id == entry.id
  end

  defp categorical_value({"stop", "wheelchair_boarding"}, 0),
    do: {"No information", "bg-base-300"}

  defp categorical_value({"stop", "wheelchair_boarding"}, 1),
    do: {"Wheelchair accessible", "bg-emerald-600"}

  defp categorical_value({"stop", "wheelchair_boarding"}, 2),
    do: {"Not accessible", "bg-rose-600"}

  defp categorical_value({"stop", "location_type"}, code),
    do: {Stop.location_type_label(code), nil}

  defp categorical_value({"pathway", "pathway_mode"}, code), do: {Pathway.mode_label(code), nil}
  defp categorical_value({"pathway", "is_bidirectional"}, true), do: {"Bidirectional", nil}
  defp categorical_value({"pathway", "is_bidirectional"}, false), do: {"One-way", nil}
  defp categorical_value(_, _), do: :passthrough
end
