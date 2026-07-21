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
        class="font-normal text-base-content/60"
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
          <span class="text-base-content/60">{metric.unit}</span>
        </span>
      </span>
    </span>
    """
  end

  @absent_value :__absent__

  @doc "Returns the sentinel used when one side of a change was not recorded."
  @spec absent_value() :: :__absent__
  def absent_value, do: @absent_value

  @doc """
  Renders one already-resolved version-diff decision.

  The consumer owns the decision collection, filtering, persistence, disclosure
  state, and every action. Pass only display-ready values; `changes` entries use
  `%{label: String.t(), before: term(), after: term()}`.
  """
  attr :id, :string, required: true
  attr :action, :atom, required: true, values: [:add, :modify, :remove, :conflict]
  attr :entity_label, :string, required: true
  attr :natural_key, :string, required: true

  attr :status, :atom,
    values: [:pending, :approved, :rejected, :preview, :applied, :failed],
    default: :pending

  attr :summary, :string, default: nil
  attr :changes, :list, default: []
  attr :dependency_keys, :list, default: []
  attr :edited?, :boolean, default: false
  attr :expanded?, :boolean, default: false
  attr :class, :any, default: nil
  slot :actions

  def version_diff_row(assigns) do
    {action_label, action_icon, action_tone} = version_diff_action(assigns.action)
    {status_label, status_icon, status_tone} = version_diff_status(assigns.status)

    assigns =
      assigns
      |> assign(:action_label, action_label)
      |> assign(:action_icon, action_icon)
      |> assign(:action_tone, action_tone)
      |> assign(:status_label, status_label)
      |> assign(:status_icon, status_icon)
      |> assign(:status_tone, status_tone)
      |> assign(:visible_action_label, visible_action_label(assigns.action))
      |> assign(:visible_status_label, visible_status_label(assigns.status))
      |> assign(:rows, Enum.map(assigns.changes, &normalize_change/1))

    ~H"""
    <article
      id={@id}
      data-version-diff-row
      data-version-diff-action={@action}
      data-version-diff-status={@status}
      data-role="version-diff-row"
      data-action={@action}
      data-status={@status}
      data-expanded={to_string(@expanded?)}
      data-edited={to_string(@edited?)}
      aria-labelledby={"#{@id}-title"}
      class={["border-b border-base-300 py-4 text-sm last:border-b-0", @class]}
    >
      <div class="grid gap-3 sm:grid-cols-[minmax(8rem,0.8fr)_minmax(0,2fr)_auto] sm:items-start sm:gap-4">
        <div data-role="version-diff-action" class="flex items-center gap-2 font-medium">
          <span data-version-diff-action-symbol aria-hidden="true">
            <.icon name={@action_icon} class={["size-4 shrink-0", @action_tone]} />
          </span>
          <span class={@action_tone} aria-label={@action_label}>{@visible_action_label}</span>
        </div>

        <div class="min-w-0">
          <h3
            id={"#{@id}-title"}
            data-role="version-diff-entity"
            class="font-medium text-base-content"
          >
            {@entity_label}
          </h3>
          <p
            data-role="version-diff-key"
            class="font-mono text-xs text-base-content/70 [overflow-wrap:anywhere]"
            title={@natural_key}
          >
            {@natural_key}
          </p>
          <p :if={@summary} data-role="version-diff-summary" class="mt-1 text-base-content/70">
            {@summary}
          </p>
          <p
            :if={@dependency_keys != []}
            data-role="version-diff-dependencies"
            class="mt-2 text-xs text-base-content/70"
          >
            Depends on: {Enum.join(@dependency_keys, ", ")}
          </p>
          <p
            :if={@edited?}
            data-role="version-diff-edited"
            class="mt-1 text-xs font-medium text-info"
          >
            Edited before applying
          </p>
          <p :if={@status == :rejected} class="mt-2 text-sm text-base-content/80">
            This change will not be applied.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2 sm:justify-end">
          <span
            data-role="version-diff-status"
            class={["inline-flex items-center gap-1.5 font-medium", @status_tone]}
          >
            <span data-version-diff-status-symbol aria-hidden="true">
              <.icon name={@status_icon} class="size-4 shrink-0" />
            </span>
            <span aria-label={@status_label}>{@visible_status_label}</span>
          </span>
          <div
            :if={@actions != []}
            data-role="version-diff-actions"
            class="flex min-h-11 items-center gap-2 [&_a]:min-h-11 [&_button]:min-h-11"
          >
            {render_slot(@actions)}
          </div>
        </div>
      </div>

      <details
        :if={@changes != []}
        id={"#{@id}-details"}
        open={@expanded?}
        class="mt-3 border-l-2 border-base-300 pl-3"
      >
        <summary
          id={"#{@id}-disclosure"}
          aria-controls={"#{@id}-details"}
          class="flex min-h-11 cursor-pointer items-center font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        >
          View field changes
        </summary>
        <dl
          data-role="version-diff-changes"
          hidden={!@expanded?}
          class="mt-3 space-y-2"
        >
          <div
            :for={row <- @rows}
            data-role="version-diff-change"
            data-change-key={row.key}
            class="grid gap-1 sm:grid-cols-[minmax(9rem,1fr)_minmax(0,2fr)] sm:gap-3"
          >
            <dt class="font-medium text-base-content/80">
              <span data-role="version-diff-change-label">{row.label}</span>
              <span
                :if={row.key}
                data-role="version-diff-change-key"
                class="block font-mono text-xs text-base-content/70 [overflow-wrap:anywhere]"
              >
                {row.key}
              </span>
            </dt>
            <dd class="min-w-0 font-mono text-xs text-base-content/80">
              <span
                data-role="version-diff-before"
                data-value-kind={row.before.kind}
                aria-label={row.before.label}
                class="break-words text-base-content/60"
              >
                {row.before.text}
              </span>
              <span class="px-1 text-base-content/50" aria-hidden="true">→</span>
              <span
                data-role="version-diff-after"
                data-value-kind={row.after.kind}
                aria-label={row.after.label}
                class="break-words"
              >
                {row.after.text}
              </span>
            </dd>
          </div>
        </dl>
      </details>
    </article>
    """
  end

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

  defp version_diff_action(:add), do: {"Added", "hero-plus", "text-success"}
  defp version_diff_action(:modify), do: {"Changed", "hero-pencil-square", "text-info"}
  defp version_diff_action(:remove), do: {"Removed", "hero-minus", "text-error"}

  defp version_diff_action(:conflict),
    do: {"Conflict", "hero-exclamation-triangle", "text-warning"}

  defp version_diff_status(:pending), do: {"Pending", "hero-clock", "text-warning"}
  defp version_diff_status(:approved), do: {"Approved", "hero-check-circle", "text-success"}
  defp version_diff_status(:rejected), do: {"Rejected", "hero-x-circle", "text-error"}
  defp version_diff_status(:preview), do: {"Preview only", "hero-eye", "text-info"}
  defp version_diff_status(:applied), do: {"Applied", "hero-check-circle", "text-success"}
  defp version_diff_status(:failed), do: {"Failed", "hero-exclamation-circle", "text-error"}

  defp visible_action_label(:modify), do: "Modified"
  defp visible_action_label(action), do: elem(version_diff_action(action), 0)
  defp visible_status_label(:preview), do: "Preview"
  defp visible_status_label(status), do: elem(version_diff_status(status), 0)

  defp normalize_change(%{label: label, before: before, after: after_value} = change) do
    %{
      label: label,
      key: Map.get(change, :key),
      before: diff_value(before),
      after: diff_value(after_value)
    }
  end

  defp diff_value(@absent_value), do: %{kind: "absent", text: "Not recorded", label: nil}
  defp diff_value(nil), do: %{kind: "nil", text: "nil", label: "No value"}
  defp diff_value(true), do: %{kind: "boolean", text: "true", label: nil}
  defp diff_value(false), do: %{kind: "boolean", text: "false", label: nil}

  defp diff_value(%Decimal{} = value),
    do: %{kind: "number", text: Decimal.to_string(value, :normal), label: nil}

  defp diff_value(value) when is_number(value),
    do: %{kind: "number", text: to_string(value), label: nil}

  defp diff_value(value) when is_binary(value), do: %{kind: "string", text: value, label: nil}

  defp diff_value(value) when is_atom(value),
    do: %{kind: "atom", text: Atom.to_string(value), label: nil}

  defp diff_value(value), do: %{kind: "term", text: inspect(value), label: nil}
end
