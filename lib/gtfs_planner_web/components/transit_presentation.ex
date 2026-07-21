defmodule GtfsPlannerWeb.Components.TransitPresentation do
  @moduledoc """
  Small GTFS presentation components shared by station-facing interfaces.

  These components translate already-resolved display values only; they do not alter
  stored accessibility values or inherit values across GTFS records.
  """
  use Phoenix.Component

  alias GtfsPlanner.Gtfs.Pathway

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]

  attr :status, :atom, required: true, values: [:accessible, :not_accessible, :unknown]
  attr :source, :atom, default: :direct, values: [:direct, :inherited, :missing]
  attr :class, :any, default: nil

  @doc "Renders the explicit accessibility state for a transit entity."
  def accessibility_status(assigns) do
    {label, tone} = accessibility_copy(assigns.status)
    assigns = assigns |> assign(:label, label) |> assign(:tone, tone)

    ~H"""
    <span
      class={["inline-flex items-center gap-1 text-sm font-medium", @tone, @class]}
      data-accessibility={@status}
    >
      <.icon name="hero-information-circle" class="size-4" />
      {@label}
      <span
        :if={@source == :inherited}
        class="font-normal text-base-content/70"
        data-accessibility-source="inherited"
      >
        Inherited from station
      </span>
    </span>
    """
  end

  attr :pathway, :map, required: true
  attr :class, :any, default: nil

  @doc "Renders mode, travel direction, and the metrics applicable to a pathway."
  def pathway_summary(assigns) do
    pathway = assigns.pathway
    mode = Map.get(pathway, :pathway_mode)

    assigns =
      assigns
      |> assign(:mode_label, Pathway.mode_label(mode))
      |> assign(
        :direction,
        if(Map.get(pathway, :is_bidirectional, true), do: "Bidirectional", else: "One way")
      )
      |> assign(:metrics, pathway_metrics(pathway, mode))

    ~H"""
    <span
      class={[
        "inline-flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-base-content/80",
        @class
      ]}
      data-pathway-summary
    >
      <span class="font-medium text-base-content">{@mode_label}</span>
      <span aria-hidden="true">·</span>
      <span>{@direction}</span>
      <span :for={metric <- @metrics} class="inline-flex items-center gap-2">
        <span aria-hidden="true">·</span>
        <span class="inline-flex items-baseline gap-1">
          <span class="font-mono tabular-nums">{metric.value}</span>
          <span class="text-base-content/70">{metric.unit}</span>
        </span>
      </span>
    </span>
    """
  end

  @version_diff_action_words %{
    add: "Added",
    modify: "Modified",
    remove: "Removed",
    conflict: "Conflict"
  }

  @version_diff_status_words %{
    pending: "Pending",
    approved: "Approved",
    rejected: "Rejected",
    preview: "Preview",
    applied: "Applied",
    failed: "Failed"
  }

  @version_diff_action_tones %{
    add: "bg-success",
    modify: "bg-info",
    remove: "bg-error",
    conflict: "bg-warning"
  }

  # Word plus tinted field, matching `<.status_badge>`: the theme's semantic
  # text colors hold ≥4.5:1 on a 10% tint of themselves, and the word still
  # carries the meaning without the color.
  @version_diff_status_tones %{
    pending: "border-base-content/40 bg-base-content/10 text-base-content",
    approved: "border-success/40 bg-success/10 text-success",
    rejected: "border-error/40 bg-error/10 text-error",
    preview: "border-warning/40 bg-warning/10 text-warning",
    applied: "border-success/40 bg-success/10 text-success",
    failed: "border-error/40 bg-error/10 text-error"
  }

  @version_diff_change_required [:label, :before, :after]
  @version_diff_change_allowed [:label, :before, :after, :key]

  @absent_value :__absent__

  @doc """
  The sentinel meaning "this side of the change holds no recorded value".

  It is distinct from `nil`, which is itself a real stored value. An added
  record has no *before*; a removed record has no *after*; a change record that
  never captured one side has neither. Pass `absent_value/0` on that side and
  the row says so in words instead of inventing a value.
  """
  @spec absent_value() :: :__absent__
  def absent_value, do: @absent_value

  @doc """
  Renders one record's difference between two versions.

  Shared structure only. The caller owns the entity vocabulary, the human
  labels, the raw keys, the values, and the actions; this component decides
  nothing about the domain. It performs no truncation: a value is rendered
  complete and wraps, because an audit row that hides the end of a value is
  not evidence.

  ## Contract

    * `action` — what happened to the record. Rendered as a word plus a tone.
    * `status` — where the change stands. Rendered as a word plus a tone.
      Both are always words; colour never carries the meaning alone.
    * `entity_label` / `natural_key` — the human entity name and its raw
      source key, rendered as secondary metadata beside it.
    * `summary` — one optional sentence describing the change.
    * `changes` — an ordered list of `%{label:, before:, after:}` maps, each
      with an optional `:key` carrying the raw source field name as secondary
      metadata. `before`/`after` accept any term; `nil`, `false`, `0`, and `""`
      render as those exact values, and `absent_value/0` renders as
      "Not recorded".
    * `dependency_keys` — raw keys of records this change depends on.
    * `edited?` — the change was locally edited relative to its source.
    * `expanded?` — `false` keeps the complete changes in the document but
      hidden, so a caller-owned control can reveal them without a round trip.
    * `actions` — a slot rendered in one fixed action zone.

  Items are validated before rendering: a malformed change, dependency key,
  label, or natural key raises `ArgumentError` so a consumer cannot silently
  render a row that misstates an audit record.

  ## Examples

      <.version_diff_row
        id="history-diff-1"
        action={:modify}
        entity_label="Stop"
        natural_key="ALEWIFE-1"
        status={:applied}
        summary="Edited stop · 2 fields changed"
        changes={[%{label: "Stop name", key: "stop_name", before: "Old", after: "New"}]}
        dependency_keys={[]}
        edited?={false}
        expanded?={true}
      >
        <:actions>
          <.button phx-click="undo">Undo change</.button>
        </:actions>
      </.version_diff_row>
  """
  attr :id, :string, required: true
  attr :action, :atom, required: true, values: [:add, :modify, :remove, :conflict]
  attr :entity_label, :string, required: true
  attr :natural_key, :string, required: true

  attr :status, :atom,
    required: true,
    values: [:pending, :approved, :rejected, :preview, :applied, :failed]

  attr :summary, :string, default: nil
  attr :changes, :list, default: []
  attr :dependency_keys, :list, default: []
  attr :edited?, :boolean, default: false
  attr :expanded?, :boolean, default: true
  attr :class, :any, default: nil

  slot :actions

  def version_diff_row(assigns) do
    assigns =
      assigns
      |> assign(
        :entity_label,
        validate_diff_text!(assigns.entity_label, :entity_label, assigns.id)
      )
      |> assign(:natural_key, validate_diff_text!(assigns.natural_key, :natural_key, assigns.id))
      |> assign(:rows, normalize_version_diff_changes(assigns.changes, assigns.id))
      |> assign(
        :dependency_keys,
        normalize_version_diff_dependencies(assigns.dependency_keys, assigns.id)
      )
      |> assign(:action_word, Map.fetch!(@version_diff_action_words, assigns.action))
      |> assign(:action_tone, Map.fetch!(@version_diff_action_tones, assigns.action))
      |> assign(:status_word, Map.fetch!(@version_diff_status_words, assigns.status))
      |> assign(:status_tone, Map.fetch!(@version_diff_status_tones, assigns.status))

    ~H"""
    <article
      id={@id}
      data-role="version-diff-row"
      data-action={@action}
      data-status={@status}
      data-expanded={to_string(@expanded?)}
      data-edited={to_string(@edited?)}
      class={["rounded-box border border-base-300 bg-base-100 text-sm", @class]}
    >
      <header class="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-b border-base-300 px-3 py-2">
        <span data-role="version-diff-action" class="inline-flex items-baseline gap-1.5">
          <span class={["size-2 shrink-0 rounded-full", @action_tone]} aria-hidden="true"></span>
          <span class="font-medium text-base-content">{@action_word}</span>
        </span>
        <span data-role="version-diff-entity" class="font-medium text-base-content">
          {@entity_label}
        </span>
        <span
          data-role="version-diff-key"
          class="min-w-0 font-mono text-xs text-base-content/70 [overflow-wrap:anywhere]"
        >
          {@natural_key}
        </span>
        <span
          :if={@edited?}
          data-role="version-diff-edited"
          class="rounded-selector border border-base-content/40 px-1.5 text-xs text-base-content"
        >
          Edited
        </span>
        <span
          data-role="version-diff-status"
          class={["rounded-selector ms-auto border px-1.5 text-xs font-medium", @status_tone]}
        >
          {@status_word}
        </span>
      </header>

      <p :if={@summary} data-role="version-diff-summary" class="px-3 pt-2 text-base-content">
        {@summary}
      </p>

      <dl
        :if={@rows != []}
        data-role="version-diff-changes"
        hidden={!@expanded?}
        class="@container m-0 divide-y divide-base-300 px-3 py-2"
      >
        <div
          :for={row <- @rows}
          data-role="version-diff-change"
          data-change-key={row.key}
          class={
            [
              "grid grid-cols-1 gap-x-4 gap-y-0.5 py-1.5",
              # A container query, not a viewport one: this row is rendered inside a
              # 480px drawer and inside a full-page review list, and only the space it
              # actually has may decide whether the label sits beside its values.
              "@md:grid-cols-[minmax(0,12rem)_minmax(0,1fr)]"
            ]
          }
        >
          <dt class="min-w-0">
            <span data-role="version-diff-change-label" class="text-base-content/70">
              {row.label}
            </span>
            <span
              :if={row.key}
              data-role="version-diff-change-key"
              class="block font-mono text-xs text-base-content/70 [overflow-wrap:anywhere]"
            >
              {row.key}
            </span>
          </dt>
          <dd class="m-0 flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span
              phx-no-format
              data-role="version-diff-before"
              data-value-kind={row.before.kind}
              class={[
                "min-w-0 whitespace-pre-wrap [overflow-wrap:anywhere] text-base-content/70 line-through",
                row.before.kind == "number" && "tabular-nums"
              ]}
            >{row.before.text}</span>
            <span class="sr-only">changed to</span>
            <span aria-hidden="true" class="text-base-content/70">→</span>
            <span
              phx-no-format
              data-role="version-diff-after"
              data-value-kind={row.after.kind}
              class={[
                "min-w-0 whitespace-pre-wrap [overflow-wrap:anywhere] text-base-content",
                row.after.kind == "number" && "tabular-nums"
              ]}
            >{row.after.text}</span>
          </dd>
        </div>
      </dl>

      <p
        :if={@dependency_keys != []}
        data-role="version-diff-dependencies"
        class="px-3 pb-2 text-xs text-base-content/70"
      >
        Depends on
        <span
          :for={key <- @dependency_keys}
          data-role="version-diff-dependency"
          class="ms-1 font-mono [overflow-wrap:anywhere]"
        >
          {key}
        </span>
      </p>

      <div
        :if={@actions != []}
        data-role="version-diff-actions"
        class="flex flex-wrap items-center justify-end gap-2 border-t border-base-300 px-3 py-2"
      >
        {render_slot(@actions)}
      </div>
    </article>
    """
  end

  defp normalize_version_diff_changes(changes, id) when is_list(changes) do
    Enum.map(changes, &normalize_version_diff_change(&1, id))
  end

  defp normalize_version_diff_changes(changes, id) do
    version_diff_error(id, ":changes must be a list, got: #{inspect(changes)}")
  end

  defp normalize_version_diff_change(%{} = change, id) do
    fields = Map.keys(change)

    case fields -- @version_diff_change_allowed do
      [] -> :ok
      extra -> version_diff_error(id, "change carries unsupported field(s) #{inspect(extra)}")
    end

    case @version_diff_change_required -- fields do
      [] -> :ok
      missing -> version_diff_error(id, "change is missing required field(s) #{inspect(missing)}")
    end

    %{
      label: validate_diff_text!(change.label, :label, id),
      key: validate_diff_change_key!(Map.get(change, :key), id),
      before: diff_value(change.before),
      after: diff_value(change.after)
    }
  end

  defp normalize_version_diff_change(change, id) do
    version_diff_error(id, "change must be a map, got: #{inspect(change)}")
  end

  defp normalize_version_diff_dependencies(keys, id) when is_list(keys) do
    Enum.map(keys, fn key ->
      if is_binary(key) and String.trim(key) != "" do
        key
      else
        version_diff_error(
          id,
          ":dependency_keys must hold non-empty strings, got: #{inspect(key)}"
        )
      end
    end)
  end

  defp normalize_version_diff_dependencies(keys, id) do
    version_diff_error(id, ":dependency_keys must be a list, got: #{inspect(keys)}")
  end

  defp validate_diff_text!(value, field, id) do
    if is_binary(value) and String.trim(value) != "" do
      value
    else
      version_diff_error(
        id,
        "#{inspect(field)} must be a non-empty string, got: #{inspect(value)}"
      )
    end
  end

  defp validate_diff_change_key!(nil, _id), do: nil

  defp validate_diff_change_key!(key, id) do
    if is_binary(key) and String.trim(key) != "" do
      key
    else
      version_diff_error(
        id,
        "change :key must be a non-empty string or nil, got: #{inspect(key)}"
      )
    end
  end

  defp version_diff_error(id, message) do
    raise ArgumentError, "version_diff_row #{inspect(id)} #{message}"
  end

  # Values are rendered exactly as stored. `nil`, `false`, `0`, and `""` are
  # real GTFS values and never collapse into a blank cell or into each other.
  defp diff_value(@absent_value), do: %{kind: "absent", text: "Not recorded"}
  defp diff_value(nil), do: %{kind: "nil", text: "nil"}
  defp diff_value(true), do: %{kind: "boolean", text: "true"}
  defp diff_value(false), do: %{kind: "boolean", text: "false"}

  defp diff_value(%Decimal{} = value),
    do: %{kind: "number", text: Decimal.to_string(value, :normal)}

  defp diff_value(value) when is_integer(value) or is_float(value),
    do: %{kind: "number", text: to_string(value)}

  defp diff_value(value) when is_binary(value) do
    if String.trim(value) == "" do
      %{kind: "blank", text: inspect(value)}
    else
      %{kind: "string", text: value}
    end
  end

  defp diff_value(%module{} = value) when module in [Date, Time, NaiveDateTime, DateTime],
    do: %{kind: "string", text: to_string(value)}

  defp diff_value(value) when is_atom(value), do: %{kind: "atom", text: inspect(value)}
  defp diff_value(value), do: %{kind: "term", text: inspect(value)}

  defp accessibility_copy(:accessible), do: {"Accessible", "text-success"}
  defp accessibility_copy(:not_accessible), do: {"Not accessible", "text-error"}
  defp accessibility_copy(:unknown), do: {"No data", "text-base-content/70"}

  defp pathway_metrics(pathway, mode) do
    []
    |> maybe_add(
      mode == 2 && present?(Map.get(pathway, :stair_count)),
      %{value: to_string(Map.get(pathway, :stair_count)), unit: "stairs"}
    )
    |> maybe_add(
      present?(Map.get(pathway, :length)),
      %{value: decimal_string(Map.get(pathway, :length)), unit: "m"}
    )
    |> maybe_add(
      present?(Map.get(pathway, :traversal_time)),
      %{value: to_string(Map.get(pathway, :traversal_time)), unit: "sec"}
    )
  end

  defp maybe_add(metrics, true, metric), do: metrics ++ [metric]
  defp maybe_add(metrics, false, _metric), do: metrics
  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_float(value), do: true
  defp present?(%Decimal{}), do: true
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: to_string(value)
end
