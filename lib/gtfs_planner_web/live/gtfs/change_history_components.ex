defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents do
  @moduledoc """
  Function components for the change-history panel rendered in the
  child-stop, pathway, and level sidebars of the station diagram editor.
  """
  use Phoenix.Component

  alias GtfsPlanner.Gtfs

  @system_noise_diff_fields MapSet.new(
                              ~w(organization_id gtfs_version_id id inserted_at updated_at)
                            )

  @change_value_max_chars 60

  if Mix.env() == :test do
    def __test_display_name__(arg), do: display_name(arg)
    def __test_format_date_header__(d, t), do: format_date_header(d, t)
    def __test_format_time_short__(dt, t), do: format_time_short(dt, t)
    def __test_group_entries_by_date__(entries), do: group_entries_by_date(entries)
    def __test_relative_time__(dt, now), do: relative_time(dt, now)
  end

  attr :entity_type, :string, required: true
  attr :entity_id, :string, required: true
  attr :history_active, :boolean, required: true

  def history_tab_strip(assigns) do
    ~H"""
    <div
      id={"#{@entity_type}-tabs"}
      class="flex gap-1 mb-4 border-b border-base-300"
      role="tablist"
    >
      <button
        id={"#{@entity_type}-tab-details"}
        type="button"
        role="tab"
        phx-click={if @history_active, do: "hide_history"}
        aria-selected={if @history_active, do: "false", else: "true"}
        aria-controls={"#{@entity_type}-panel-details"}
        class={[
          "btn btn-sm btn-ghost rounded-none border-b-2",
          if(@history_active, do: "border-transparent", else: "border-primary")
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
        class={[
          "btn btn-sm btn-ghost rounded-none border-b-2",
          if(@history_active, do: "border-primary", else: "border-transparent")
        ]}
      >
        History
      </button>
    </div>
    """
  end

  attr :entries, :list, required: true
  attr :entity_type, :string, required: true
  attr :rollback_preview, :map, default: nil

  def change_log_list(assigns) do
    assigns =
      assign(
        assigns,
        :rollback_by_original_id,
        rollback_by_original_id(assigns.entries)
      )

    ~H"""
    <div id={"history-#{@entity_type}"} class="space-y-3">
      <%= if @entries == [] do %>
        <p class="text-sm text-base-content/70">
          Earlier history is not available for imported entities.
        </p>
      <% else %>
        <ul class="divide-y divide-base-300">
          <li :for={entry <- @entries} id={"history-entry-#{entry.id}"} class="py-2 space-y-1">
            <div class="flex items-baseline justify-between gap-2">
              <div class="flex items-baseline gap-2 text-sm">
                <span class="font-medium">{history_action_label(entry)}</span>
                <span
                  :if={reverted_entry?(entry, @rollback_by_original_id)}
                  class="badge badge-neutral badge-xs"
                >
                  Reverted
                </span>
                <span class="text-base-content/70">{entry.actor_email}</span>
              </div>
              <span class="text-xs tabular-nums text-base-content/70">
                {format_timestamp(entry.inserted_at)}
              </span>
            </div>

            <.change_diff entry={entry} />

            <div :if={show_rollback_action?(entry, @rollback_by_original_id)}>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="preview_rollback_change_log"
                phx-value-log-id={entry.id}
              >
                {rollback_button_label(entry)}
              </button>
            </div>
          </li>
        </ul>

        <div :if={preview_matches_list?(@rollback_preview, @entity_type, @entries)}>
          <.rollback_preview rollback_preview={@rollback_preview} entity_type={@entity_type} />
        </div>
      <% end %>
    </div>
    """
  end

  attr :entry, :map, required: true

  def change_diff(assigns) do
    assigns = assign(assigns, :rows, diff_rows(assigns.entry))

    ~H"""
    <ul :if={@rows != []} class="space-y-0.5 text-xs text-base-content/80">
      <li :for={row <- @rows} class="font-mono leading-tight">
        <span class="font-medium">{row.field}:</span>
        <span>{row.from}</span>
        <span aria-hidden="true">→</span>
        <span>{row.to}</span>
      </li>
    </ul>
    """
  end

  attr :rollback_preview, :map, required: true
  attr :entity_type, :string, required: true

  def rollback_preview(assigns) do
    ~H"""
    <div id={"rollback-preview-#{@entity_type}"} class="border border-base-300 p-3 space-y-2">
      <p class="text-sm font-medium">Revert these changes?</p>

      <ul class="space-y-0.5 text-xs text-base-content/80">
        <li :for={row <- @rollback_preview.field_changes} class="font-mono leading-tight">
          <span class="font-medium">{row.field}:</span>
          <span>{truncate_value(row.current)}</span>
          <span aria-hidden="true">→</span>
          <span>{truncate_value(row.restored)}</span>
        </li>
      </ul>

      <div class="flex gap-2">
        <button
          id={"rollback-preview-cancel-#{@entity_type}"}
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="cancel_rollback_preview"
        >
          Cancel
        </button>
        <button
          id={"rollback-preview-confirm-#{@entity_type}"}
          type="button"
          class="btn btn-xs btn-primary"
          phx-click="confirm_rollback_change_log"
          phx-value-log-id={@rollback_preview.log.id}
        >
          Confirm revert
        </button>
      </div>
    </div>
    """
  end

  defp rollback_eligible?(%{action: action, snapshot: snapshot} = entry)
       when action in ["updated", "rolled_back"] and not is_nil(snapshot) do
    Gtfs.rollback_previewable_fields(entry) != []
  end

  defp rollback_eligible?(_), do: false

  defp rollback_by_original_id(entries) do
    Enum.reduce(entries, %{}, fn
      %{action: "rolled_back", rolled_back_to_log_id: original_id} = entry, acc
      when not is_nil(original_id) ->
        Map.put(acc, original_id, entry)

      _entry, acc ->
        acc
    end)
  end

  defp reverted_entry?(entry, rollback_by_original_id) do
    Map.has_key?(rollback_by_original_id, entry.id)
  end

  defp show_rollback_action?(entry, rollback_by_original_id) do
    rollback_eligible?(entry) and not reverted_entry?(entry, rollback_by_original_id)
  end

  defp history_action_label(%{action: "rolled_back"}), do: "Reverted"
  defp history_action_label(%{action: action}), do: action

  defp rollback_button_label(%{action: "rolled_back"}), do: "Restore change"
  defp rollback_button_label(_entry), do: "Revert change"

  defp preview_matches_list?(nil, _entity_type, _entries), do: false

  defp preview_matches_list?(
         %{entity_type: entity_type, log: %{id: log_id}},
         entity_type,
         entries
       ) do
    Enum.any?(entries, fn entry -> entry.id == log_id end)
  end

  defp preview_matches_list?(_preview, _entity_type, _entries), do: false

  defp diff_rows(%{changed_fields: fields}) when is_map(fields) and map_size(fields) > 0 do
    fields
    |> Enum.reject(fn {field, _change} ->
      MapSet.member?(@system_noise_diff_fields, to_string(field))
    end)
    |> Enum.map(fn {field, change} ->
      %{
        field: to_string(field),
        from: render_diff_value(change, "from", :from),
        to: render_diff_value(change, "to", :to)
      }
    end)
    |> Enum.sort_by(& &1.field)
  end

  defp diff_rows(_entry), do: []

  defp render_diff_value(change, string_key, atom_key) do
    case Map.get(change, string_key, :__missing__) do
      :__missing__ ->
        case Map.get(change, atom_key, :__missing__) do
          :__missing__ -> "—"
          value -> render_present_value(value)
        end

      value ->
        render_present_value(value)
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

  defp format_timestamp(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  defp format_timestamp(_), do: "—"

  if Mix.env() == :test do
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

    defp upcased_month_day(%Date{} = d),
      do: d |> Calendar.strftime("%b %-d") |> String.upcase()

    defp format_date_header(%Date{} = date, %Date{} = today) do
      cond do
        Date.compare(date, today) == :eq -> "TODAY · " <> upcased_month_day(date)
        Date.diff(today, date) == 1 -> "YESTERDAY · " <> upcased_month_day(date)
        true -> upcased_month_day(date)
      end
    end

    defp format_time_short(%DateTime{} = dt, %Date{} = today) do
      if DateTime.to_date(dt) == today do
        Calendar.strftime(dt, "%-I:%M %p")
      else
        Calendar.strftime(dt, "%b %-d · %-I:%M %p")
      end
    end

    defp group_entries_by_date(entries) do
      entries
      |> Enum.group_by(fn entry -> DateTime.to_date(entry.inserted_at) end)
      |> Enum.sort_by(fn {date, _} -> date end, {:desc, Date})
    end

    defp relative_time(%DateTime{} = dt, %DateTime{} = now) do
      seconds = DateTime.diff(now, dt, :second)

      cond do
        seconds < 60 ->
          "just now"

        seconds < 3600 ->
          minutes = div(seconds, 60)
          "#{minutes} #{pluralize(minutes, "minute")} ago"

        DateTime.to_date(dt) == DateTime.to_date(now) ->
          hours = div(seconds, 3600)
          "#{hours} #{pluralize(hours, "hour")} ago"

        true ->
          days = Date.diff(DateTime.to_date(now), DateTime.to_date(dt))

          cond do
            days == 1 -> "yesterday"
            days < 7 -> "#{days} days ago"
            true -> Calendar.strftime(dt, "%b %-d")
          end
      end
    end

    defp pluralize(1, word), do: word
    defp pluralize(_n, word), do: word <> "s"
  end
end
