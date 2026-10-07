defmodule GtfsPlannerWeb.Gtfs.CompareComponents do
  @moduledoc """
  The Compare page's presentation, on the application design system.

  One card walks the comparison in order: name two retained full feed files and
  one explicit date range (`comparison/1`), then read what the completed
  comparison found (`comparison_results/1`). The helper entry
  (`comparison_helper/1`) offers the comparison helper once a comparison has
  finished, and the structural, unresolved and unknown row components render
  each paged stream's rows.

  The components carry no state and run no queries: `CompareLive` owns the
  events and the data, and passes the choices, the chosen rows and the result
  in.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]

  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Gtfs.ComparePresentation

  @doc """
  Compare two retained full feed files over one explicit date range.

  The form names both sides and the window, and starts nothing by itself: the
  draft is `%{"left_run_id", "right_run_id", "from", "to"}` and
  `.CompareLive` owns the events, the choices and the running comparison. The
  file selects DO carry server-provided defaults — `apply_comparison_defaults/3`
  supplies newest-file-right and second-newest-left — which must be distinguished
  from the dates the server leaves empty for the editor to enter: the window
  starts blank and a comparison always compares two named files over dates the
  editor chose.

  `choices` is `%{rows: [row], next_cursor: String.t() | nil}` for the page the
  server listed. A run the editor chose on an earlier page is still an option
  here, because `CompareLive` keeps the selected identities server-side rather
  than trusting the submitted value.

  The caps and the storage effect sit beside the action rather than behind a
  disclosure, because both change what starting a comparison does: it takes the
  existing download claim on each file, and a file that turns out to be damaged
  is closed and removed by the existing failed-run path.

  The status band is a polite live region whose title takes focus when the
  comparison starts, so a keyboard reader lands on the new state.
  """
  attr :form, :any, required: true
  attr :choices, :map, required: true

  attr :chosen, :map,
    required: true,
    doc: "`%{left: row | nil, right: row | nil}` the chosen rows, retained server-side"

  attr :status, :atom, required: true
  attr :notice, :string, default: nil
  attr :result, :map, default: nil
  attr :version_id, :string, required: true

  def comparison(assigns) do
    assigns =
      assigns
      |> assign(:options, Enum.map(assigns.choices.rows, &{run_label(&1), to_string(&1.run_id)}))
      |> assign(:running?, assigns.status in [:running, :cancelling])
      |> assign(:view, comparison_view(assigns.status, assigns.chosen, assigns.result))
      |> assign(:window_dates, comparison_window_dates(assigns.form))
      |> assign(:too_long?, comparison_too_long?(assigns.form))
      |> assign(:empty?, length(assigns.choices.rows) < 2)
      |> assign(:no_change?, no_change?(assigns.status, assigns.result))

    ~H"""
    <div id="export-comparison">
      <%= if @empty? do %>
        <section
          id="comparison-empty"
          class="rounded-card border border-subtle bg-white px-6 py-10 text-center"
        >
          <.icon name="hero-arrows-right-left" class="mx-auto size-8 text-muted" />
          <p class="mt-3 text-base font-semibold text-strong">
            Comparing needs two full feed files from the last 24 hours
          </p>
          <p class="mt-1 text-sm text-muted">
            You have {length(@choices.rows)}. Export the version you want to compare against.
          </p>
          <.link
            id="comparison-export-full"
            navigate={~p"/gtfs/#{@version_id}/export?type=full"}
            class="mt-5 inline-flex min-h-11 items-center justify-center rounded-control bg-strong px-4 py-2.5 text-sm font-[650] text-white no-underline hover:bg-strong/90"
          >
            Export full feed
          </.link>
        </section>
      <% else %>
        <.form
          for={@form}
          id="export-comparison-form"
          phx-change="select_comparison"
          phx-submit="start_comparison"
        >
          <fieldset>
            <legend class="text-[13px] font-semibold text-strong">
              Which two files do you want to compare?
            </legend>
            <div class="mt-2.5 grid items-end gap-3 sm:grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)]">
              <.input
                field={@form[:left_run_id]}
                type="select"
                id="comparison-left"
                label="Earlier file"
                prompt="Choose a file"
                options={@options}
              />
              <span class="hidden pb-2.5 text-muted sm:block" aria-hidden="true">
                <.icon name="hero-arrow-right" class="size-4" />
              </span>
              <.input
                field={@form[:right_run_id]}
                type="select"
                id="comparison-right"
                label="Newer file"
                prompt="Choose a file"
                options={@options}
              />
            </div>
          </fieldset>

          <div class="mt-3 flex flex-wrap items-end gap-3">
            <.input
              field={@form[:from]}
              type="date"
              id="comparison-from"
              label="From"
              invalid={@too_long?}
            />
            <span class="pb-2.5 text-[13px] text-muted">to</span>
            <.input
              field={@form[:to]}
              type="date"
              id="comparison-to"
              label="To"
              invalid={@too_long?}
            />
          </div>

          <p
            id="comparison-window-note"
            class={[
              "mt-2 text-[13px] leading-relaxed",
              @too_long? && "font-semibold text-error-fg",
              !@too_long? && "text-muted"
            ]}
          >
            {window_note(@window_dates, @too_long?)}
          </p>

          <div class="mt-4 flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
            <.button
              :if={not @running?}
              id="comparison-start"
              class="min-h-11"
              phx-click={JS.focus(to: "#comparison-status-title")}
            >
              Compare files
            </.button>
            <.button
              :if={@status == :cancelling}
              id="comparison-start"
              class="min-h-11"
              disabled
            >
              Cancelling…
            </.button>
            <.button
              :if={@running?}
              id="comparison-cancel"
              variant="secondary"
              class="min-h-11"
              phx-click="cancel_comparison"
            >
              Cancel comparison
            </.button>
            <.button
              :if={@status in [:completed, :refused]}
              id="comparison-close"
              variant="quiet"
              class="min-h-11"
              phx-click="close_comparison"
            >
              Start over
            </.button>
            <.button
              :if={@choices.next_cursor}
              id="comparison-more-choices"
              variant="quiet"
              class="min-h-11"
              phx-click="load_more_comparison_choices"
            >
              Show more exports
            </.button>
          </div>

          <div
            id="comparison-caps"
            class="mt-4 rounded-card border border-subtle bg-canvas px-4 py-3 text-[13px] leading-relaxed text-default"
          >
            <p class="font-semibold text-strong">What one comparison reads</p>
            <ul class="mt-1.5 grid gap-1">
              <li>At most 150 MB compressed and 20 MB of the compared tables per file.</li>
              <li>At most 100,000 rows per file, and 200,000 exact departures per file.</li>
              <li>A file over any of these limits is refused whole, never partly compared.</li>
            </ul>
            <p class="mt-2">
              Comparing takes the normal download claim on each file, so that file’s download count goes
              up. If a file turns out to be damaged, it is closed and deleted and must be exported again.
            </p>
          </div>
        </.form>

        <.comparison_status view={@view} notice={@notice} />

        <%= if @running? do %>
          <section
            id="comparison-progress"
            class="mt-4 rounded-card border border-subtle bg-white px-5 py-5"
          >
            <div class="h-1.5 overflow-hidden rounded-full bg-info-bg">
              <div class="h-full w-1/3 rounded-full bg-info-fg motion-safe:animate-pulse" />
            </div>
            <p class="mt-3 text-sm font-semibold text-strong">
              Comparing service on {window_date_count(@window_dates)} dates…
            </p>
            <p class="text-[13px] text-muted">Usually under a minute.</p>
          </section>
        <% end %>

        <%= if @status == :refused and @notice do %>
          <.callout id="comparison-refused" kind="error" title="The comparison couldn’t finish">
            <p class="text-[13px] leading-relaxed">{@notice}</p>
          </.callout>
        <% end %>

        <%= if @no_change? do %>
          <section
            id="comparison-nochange"
            class="mt-4 rounded-card border border-t-4 border-subtle border-t-success-line bg-white px-5 py-5"
          >
            <span class="inline-flex items-center gap-1 rounded-badge bg-success-bg px-2 py-0.5 text-[12px] font-semibold text-success-fg">
              <.icon name="hero-check" class="size-3.5" /> No differences
            </span>
            <h2 class="mt-2 font-display text-[26px] leading-tight text-strong">
              Riders get the same service from both files.
            </h2>
            <p class="mt-1 text-sm text-default">
              Every route has the same service on all {window_date_count(@window_dates)} dates.
            </p>
            <p class="mt-3 text-[12px] text-muted">
              Not compared: fares, station pathways and flex services.
            </p>
          </section>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp comparison_window_dates(form) do
    from = form[:from].value
    to = form[:to].value

    with true <- is_binary(from) and from != "",
         true <- is_binary(to) and to != "",
         {:ok, from_date} <- Date.from_iso8601(from),
         {:ok, to_date} <- Date.from_iso8601(to),
         false <- Date.compare(from_date, to_date) == :gt do
      {Date.diff(to_date, from_date) + 1, from_date, to_date}
    else
      _ -> nil
    end
  end

  defp comparison_too_long?(form) do
    case comparison_window_dates(form) do
      {count, _from, _to} -> count > 62
      nil -> false
    end
  end

  defp window_note(nil, _too_long?),
    do: "The same dates are compared on both sides. One comparison covers at most 62 dates."

  defp window_note({count, _from, _to}, true),
    do: "Choose 62 dates or fewer. This range has #{count}."

  defp window_note({count, from, to}, false),
    do: "#{count} dates · #{format_date_range(%{from: from, to: to})}"

  # The note is written before either file has been read, so it states only what
  # the draft itself proves: how many dates and which range. A service-coverage
  # claim here would describe files the page has not opened.
  defp window_date_count(nil), do: "the chosen"
  defp window_date_count({count, _from, _to}), do: count

  # A no-change verdict is only affordable for a comparison the engine itself
  # called complete: an empty difference list beside unreadable rows or a window
  # with no service states what could not be measured, not identical service.
  defp no_change?(:completed, %{comparison: comparison}),
    do: ComparePresentation.no_change?(comparison)

  defp no_change?(_status, _result), do: false

  attr :view, :map, required: true
  attr :notice, :string, default: nil

  defp comparison_status(assigns) do
    ~H"""
    <div
      id="comparison-status"
      role="status"
      aria-live="polite"
      class="mt-4 flex items-start gap-3.5 rounded-card border border-subtle px-4 py-3.5"
    >
      <span class={[
        "flex size-10 shrink-0 items-center justify-center rounded-full",
        comparison_tone_class(@view.tone)
      ]}>
        <.icon name={@view.icon} class={["size-5", @view[:spin?] && "motion-safe:animate-spin"]} />
      </span>
      <div class="min-w-0">
        <h3
          id="comparison-status-title"
          tabindex="-1"
          class="text-base font-bold leading-snug text-strong focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-focus"
        >
          {@view.title}
        </h3>
        <p id="comparison-status-detail" class="mt-1 text-sm leading-relaxed text-default">
          {@view.detail}
        </p>
        <p :if={@notice} id="comparison-notice" class="mt-1 text-[13px] font-semibold text-strong">
          {@notice}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  The way into the comparison helper, shown once a comparison has finished.

  `context` is the immutable copy `CompareLive` admitted for the helper, or `nil`
  when none was. With one, the helper is offered; without one, the card says why
  and what to do, and the finished comparison above it is untouched. `notice` is
  `:source_too_large` when the whole comparison is more than the helper can hold,
  and `:invalid_scope` for any other refusal. Both point at the explicit scope
  form, because narrowing is the only way to a smaller copy.

  The refusal is a polite live region: it appears with the finished comparison,
  and a keyboard reader should hear it without looking for it.
  """
  attr :context, :map, default: nil
  attr :notice, :atom, default: nil
  attr :open?, :boolean, default: false

  def comparison_helper(assigns) do
    ~H"""
    <section
      id="comparison-helper-entry"
      aria-labelledby="comparison-helper-title"
      class="rounded-card border border-subtle bg-white px-5 py-4"
    >
      <%= if @context do %>
        <h3 id="comparison-helper-title" class="text-base font-bold text-strong">
          Ask about this comparison
        </h3>
        <p class="mt-1 text-[13px] leading-relaxed text-muted">
          The helper explains what changed and what could not be compared, using only the rows on
          this page. It can’t change your feed or start another comparison.
        </p>
        <.button
          id="comparison-helper-open"
          type="button"
          phx-click="comparison_helper_open"
          aria-expanded={to_string(@open?)}
          aria-controls="agent-panel"
          variant="quiet"
          class="mt-2 min-h-11"
        >
          Open comparison helper
        </.button>
      <% else %>
        <h3 id="comparison-helper-title" class="text-base font-bold text-strong">
          {helper_refusal_title(@notice)}
        </h3>
        <p
          id="comparison-helper-notice"
          role="status"
          class="mt-1 text-[13px] leading-relaxed text-default"
        >
          {helper_refusal_detail(@notice)}
        </p>
        <.button
          id="comparison-helper-narrow"
          type="button"
          variant="quiet"
          class="mt-2 min-h-11"
          phx-click={JS.focus(to: "#comparison-scope-routes")}
        >
          Choose routes and dates
        </.button>
      <% end %>
    </section>
    """
  end

  defp helper_refusal_title(:source_too_large), do: "The helper can’t read all of this comparison"
  defp helper_refusal_title(_other), do: "The helper can’t read this comparison"

  defp helper_refusal_detail(:source_too_large),
    do:
      "It has more rows than the helper can hold. Choose fewer routes and dates under “Narrow this comparison”, then ask again. The comparison below is unchanged."

  defp helper_refusal_detail(_other),
    do:
      "The comparison below is unchanged. Narrow it to the routes and dates you care about to try the helper again."

  # Two files of the same version exported on the same day are different
  # comparisons, so the label names the version and the exact export time. A run
  # that never recorded a version name is labelled as an export rather than
  # rendering a leading separator, and the time keeps two same-day files apart.
  defp run_label(row) do
    "#{version_label(row.version_name)} · exported #{format_timestamp(row.created_at)}"
  end

  defp version_label(name) when is_binary(name) and name != "", do: name
  defp version_label(_absent), do: "Full feed export"

  defp comparison_view(status, _chosen, _result) when status in [:idle],
    do: %{
      tone: :neutral,
      icon: "hero-document",
      title: "No comparison running",
      detail:
        "Choose two exported full feed files and the dates to compare them over. Nothing is read until you compare."
    }

  defp comparison_view(status, _chosen, _result) when status in [:running, :cancelling],
    do: %{
      tone: if(status == :running, do: :info, else: :warning),
      icon: "hero-arrow-path",
      spin?: true,
      title: if(status == :running, do: "Comparing exports", else: "Cancelling comparison"),
      detail:
        if(
          status == :running,
          do:
            "Reading both files and comparing their service over the dates you chose. This page updates on its own.",
          else: "The comparison stops at the next safe point and releases both files."
        )
    }

  defp comparison_view(:completed, chosen, result) do
    %{
      tone: :success,
      icon: "hero-check",
      title: "Comparison finished",
      detail:
        "Compared #{chosen_label(chosen.left)} with #{chosen_label(chosen.right)} over #{format_date_range(result.window)}."
    }
  end

  defp comparison_view(:refused, _chosen, _result),
    do: %{
      tone: :error,
      icon: "hero-exclamation-triangle",
      title: "The comparison couldn’t finish",
      detail: "Nothing in your feed was changed. Your dates and file choices are still here."
    }

  # The chosen rows are server-held, so a file that vanished from the current
  # page still names itself honestly instead of rendering an empty comparison.
  defp chosen_label(nil), do: "a chosen export"

  defp chosen_label(%{version_name: name} = row) when is_binary(name) and name != "",
    do: "#{name} (exported #{format_timestamp(row.created_at)})"

  # A run that recorded no version name still names itself by what it is and
  # when it was exported, so the finished band never reads "the other export"
  # twice and leaves the reader with no way to tell the two files apart.
  defp chosen_label(%{created_at: created_at}) when not is_nil(created_at),
    do: "the export made #{format_timestamp(created_at)}"

  defp chosen_label(_row), do: "an export with no recorded time"

  @doc """
  What the completed comparison found: the two files' identities, the shared
  window, the totals with their reason when a total could not be measured, the
  differences, structural changes, unresolved matches and unknowns as paged
  streams, and the explicit scope chooser.

  Every list is a LiveView stream, so a large native result pages instead of
  rendering thousands of rows, and a row is inspectable with the keyboard
  through an ordinary button.

  `view` is the result actually in view: the full native result, or the narrowed
  one `Compare.narrow/2` produced. `result` stays the full comparison, so
  clearing a scope restores it without recomputing anything.
  """
  attr :result, :map, required: true
  attr :view, :map, required: true
  attr :scope, :map, default: nil
  attr :scope_form, :any, required: true
  attr :scope_notice, :string, default: nil
  attr :inspected, :map, default: nil
  attr :inspected_route, :map, default: nil
  attr :no_change?, :boolean, default: false
  attr :page, :map, required: true
  attr :true_totals, :map, required: true
  attr :kind_filter, :atom, default: nil
  attr :per_date, :any, default: nil
  attr :day_classes, :any, default: nil
  attr :conclusion, :any, default: nil
  attr :kind_counts, :any, default: nil

  # Each list is passed in as a slot because only the template that owns a
  # stream may iterate it. A stream consumed anywhere else renders its first
  # page and then stops pruning, so a narrowed scope would leave the full
  # comparison's rows on the page.
  slot :structural_list, required: true
  slot :unresolved_list, required: true
  slot :unknowns_list, required: true

  def comparison_results(assigns) do
    per_date = assigns.per_date || []
    kind_counts = assigns.kind_counts || %{}
    kind_filter = assigns.kind_filter

    assigns =
      assigns
      |> assign(:window, assigns.view.window)
      |> assign(:route_pairs, route_pair_options(assigns.view))
      |> assign(:date_options, date_options(assigns.view.window))
      |> assign(:totals, assigns.view.totals)
      |> assign(:completeness, assigns.view.completeness)
      |> assign(:omitted, omitted_units(assigns.view.exclusions))
      |> assign(:per_date, per_date)
      |> assign(:per_date_max, per_date_max(per_date))
      |> assign(:day_classes, assigns.day_classes || [])
      |> assign(:conclusion, assigns.conclusion || %{changed: 0, compared: 0})
      |> assign(:kind_counts, kind_counts)
      |> assign(:kind_counts_list, kind_counts_list(kind_counts))
      |> assign(:change_total, kind_counts |> Map.values() |> Enum.sum())
      |> assign(:route_rows, ComparePresentation.route_rows(assigns.view, kind_filter))

    ~H"""
    <div id="comparison-results" class="grid gap-6">
      <section
        :if={not @no_change?}
        id="comparison-result"
        aria-labelledby="verdict-h"
        class="min-w-0 overflow-hidden rounded-card border border-subtle bg-white"
      >
        <div class="border-t-4 border-t-info-line px-5 pt-5">
          <dl id="comparison-artifacts" class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
            <.artifact_column label="Earlier export" identity={@result.left} />
            <.artifact_column label="Candidate export" identity={@result.right} />
          </dl>

          <p id="comparison-window" class="mt-3 text-[13px] leading-relaxed text-muted">
            Both files were compared over the same dates, {format_date_range(@window)}.
          </p>

          <div id="comparison-verdict" class="mt-3">
            <h2 id="verdict-h" class="font-display text-[26px] leading-tight text-strong">
              {@conclusion.changed} of {@conclusion.compared} routes change.
            </h2>
            <p
              :if={@day_classes != []}
              id="comparison-day-classes"
              class="mt-1 text-sm text-default"
            >
              {day_class_sentence(@day_classes)}
            </p>
          </div>

          <div id="comparison-totals" class="mt-4">
            <dl class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <.total_cell
                id="comparison-scheduled-delta"
                label="Scheduled trips"
                value={@totals.scheduled_count_delta}
              />
              <.total_cell
                id="comparison-exact-delta"
                label="Departures at stops"
                value={@totals.exact_count_delta}
              />
              <.total_cell
                id="comparison-routes-changed"
                label="Routes changed"
                value={@conclusion.changed}
              />
              <.total_cell id="comparison-stops-changed" label="Stops" value={nil} />
            </dl>
            <p
              :if={@totals.scheduled_count_delta == nil}
              id="comparison-totals-unknown"
              class="mt-1.5 text-sm leading-relaxed text-default"
            >
              A whole-feed total was not measured, so it is shown as —. The comparison found:
            </p>
            <ul
              :if={@totals.reasons != []}
              id="comparison-total-reasons"
              class="mt-1.5 grid gap-1 text-[13px] leading-relaxed text-default"
            >
              <li :for={reason <- @totals.reasons} data-reason={reason}>
                {totals_reason(reason)}
              </li>
            </ul>
            <p :if={@totals.scheduled_count_delta != nil} class="mt-1.5 text-[13px] text-muted">
              {measured_units_label(@totals)}
            </p>

            <p
              :if={@true_totals.comparison_unknowns > 0}
              id="comparison-totals-unknown-coverage"
              class="mt-1.5 text-[13px] leading-relaxed text-muted"
            >
              {@true_totals.comparison_unknowns} row{if @true_totals.comparison_unknowns == 1,
                do: "",
                else: "s"} could not be read from the bytes admitted above, so nothing above states
              anything about {if @true_totals.comparison_unknowns == 1, do: "it", else: "them"}.
              The reason and the file it came from are listed under Unknowns.
            </p>
          </div>

          <figure id="comparison-per-date" class="mt-5">
            <figcaption class="text-[13px] font-semibold text-strong">
              Trip change by date
            </figcaption>
            <div class="mt-2 overflow-x-auto pb-1">
              <ol class="flex min-w-max items-end gap-1">
                <li
                  :for={entry <- @per_date}
                  id={"comparison-date-#{Date.to_iso8601(entry.date)}"}
                  aria-label={per_date_label(entry)}
                  class="flex w-11 shrink-0 flex-col items-center gap-1"
                >
                  <span class={[
                    "text-[11px] font-semibold tabular-nums",
                    per_date_value_class(entry.value)
                  ]}>
                    {per_date_value(entry.value)}
                  </span>
                  <div class="relative h-11 w-full" aria-hidden="true">
                    <div
                      :if={is_integer(entry.value) and entry.value > 0}
                      class="absolute bottom-1/2 w-full rounded-t-[3px] bg-info-line"
                      style={"height: #{per_date_bar_height(entry.value, @per_date_max)}px"}
                    />
                    <div
                      :if={is_integer(entry.value) and entry.value < 0}
                      class="absolute top-1/2 w-full rounded-b-[3px] bg-action"
                      style={"height: #{per_date_bar_height(entry.value, @per_date_max)}px"}
                    />
                    <div class="absolute top-1/2 h-px w-full bg-control" />
                  </div>
                  <span class="text-[11px] text-muted">{format_chart_date(entry.date)}</span>
                </li>
              </ol>
            </div>
          </figure>
        </div>

        <div
          id="comparison-kind-chips"
          role="group"
          aria-label="Show changes"
          class="mt-5 flex flex-wrap gap-2 border-t border-subtle px-5 py-3"
        >
          <.kind_chip
            id="comparison-kind-all"
            label={"All #{@change_total}"}
            kind="all"
            pressed={is_nil(@kind_filter)}
          />
          <.kind_chip
            :for={{kind, count} <- @kind_counts_list}
            id={"comparison-kind-#{kind}"}
            label={"#{change_kind(kind)} #{count}"}
            kind={kind}
            pressed={@kind_filter == kind}
          />
        </div>

        <div id="comparison-rows" class="overflow-x-auto border-t border-subtle">
          <table class="w-full min-w-[44rem] text-left">
            <thead>
              <tr class="border-b border-subtle text-[12px] text-muted">
                <th class="px-5 py-2 font-semibold">Route</th>
                <th class="px-4 py-2 font-semibold">Change</th>
                <th class="px-4 py-2 font-semibold">When</th>
                <th class="px-4 py-2 text-right font-semibold">Trips a day</th>
                <th class="px-5 py-2"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@route_rows == []}>
                <td colspan="5" class="px-5 py-6 text-center text-[13px] text-muted">
                  No changes match this filter.
                </td>
              </tr>
              <%= for row <- @route_rows do %>
                <tr id={row.id} class="border-b border-subtle align-top last:border-b-0">
                  <td class="px-5 py-3">
                    <div class="flex items-center gap-2">
                      <RouteIdentity.route_badge
                        size="compact"
                        title={row.route}
                        route={route_badge_route(row.route)}
                      />
                      <span class="text-sm font-semibold text-strong">
                        {route_label(row.route_ids)}
                      </span>
                    </div>
                  </td>
                  <td class="px-4 py-3 text-sm font-semibold text-strong">
                    {change_kind(row.kind)}
                  </td>
                  <td class="px-4 py-3 text-[13px] text-default">{route_row_dates(row)}</td>
                  <td class="px-4 py-3 text-right text-[13px] tabular-nums text-strong">
                    {route_row_delta(row)}
                  </td>
                  <td class="px-5 py-3 text-right">
                    <.button
                      id={"#{row.id}-inspect"}
                      variant="quiet"
                      size="sm"
                      aria-expanded={to_string(@inspected_route && @inspected_route.id == row.id)}
                      phx-click="inspect_comparison_route"
                      phx-value-row={row.id}
                    >
                      Inspect
                    </.button>
                  </td>
                </tr>
                <tr
                  :if={@inspected_route && @inspected_route.id == row.id}
                  id="comparison-inspected"
                  class="border-b border-subtle last:border-b-0"
                >
                  <td colspan="5" class="bg-canvas px-5 py-4">
                    <.grouped_route_detail row={@inspected_route} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <details id="comparison-structural" class="group border-t border-subtle">
          <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-5 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right"
              class="size-4 text-muted transition-transform group-open:rotate-90"
            /> Stops and routes added, removed or renamed
            <span class="font-normal tabular-nums text-muted">
              · {@true_totals.comparison_structural}
            </span>
          </summary>
          <p class="px-5 pb-1 text-[13px] leading-relaxed text-muted">
            Renamed, added and removed entities. These are not service loss on their own.
          </p>
          {render_slot(@structural_list)}
          <p
            :if={@true_totals.comparison_structural == 0}
            id="comparison-structural-empty"
            class="px-5 py-6 text-center text-[13px] text-muted"
          >
            No identifiers changed.
          </p>
          <.page_bar
            collection={:comparison_structural}
            page={@page.comparison_structural}
            true_total={@true_totals.comparison_structural}
            noun="change"
          />
        </details>

        <div :if={@true_totals.comparison_unresolved > 0} id="comparison-unresolved">
          <div class="border-t border-subtle px-5 pt-4">
            <p class="text-[13px] font-semibold text-strong">
              Unresolved entity matches
              <span class="font-normal tabular-nums text-muted">
                · {@true_totals.comparison_unresolved}
              </span>
            </p>
            <p class="mt-0.5 text-[13px] leading-relaxed text-muted">
              Entities this comparison could not pair with confidence. They are never counted as a
              loss.
            </p>
          </div>
          {render_slot(@unresolved_list)}
          <.page_bar
            collection={:comparison_unresolved}
            page={@page.comparison_unresolved}
            true_total={@true_totals.comparison_unresolved}
            noun="unresolved match"
          />
        </div>

        <div :if={@true_totals.comparison_unknowns > 0} id="comparison-unknowns-section">
          <div class="border-t border-subtle px-5 pt-4">
            <p class="text-[13px] font-semibold text-strong">
              What this comparison could not read
              <span class="font-normal tabular-nums text-muted">
                · {@true_totals.comparison_unknowns}
              </span>
            </p>
            <p class="mt-0.5 text-[13px] leading-relaxed text-muted">
              Rows the files did not state clearly. They are never counted as zero service.
            </p>
          </div>
          {render_slot(@unknowns_list)}
          <.page_bar
            collection={:comparison_unknowns}
            page={@page.comparison_unknowns}
            true_total={@true_totals.comparison_unknowns}
            noun="unknown row"
          />
        </div>

        <div
          :if={@inspected}
          id="comparison-inspected"
          role="region"
          aria-labelledby="comparison-inspected-title"
          tabindex="-1"
          class="border-t border-subtle bg-canvas px-5 py-5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <h3 id="comparison-inspected-title" class="text-base font-bold text-strong">
              One row in full
            </h3>
            <.button
              id="comparison-inspected-close"
              variant="quiet"
              size="sm"
              phx-click={
                JS.push("close_comparison_detail") |> JS.focus(to: "#comparison-inspected-title")
              }
            >
              Close
            </.button>
          </div>
          <p class="mt-1 text-[13px] leading-relaxed text-muted">
            The row as the comparison recorded it, including the file and row it came from.
          </p>
          <dl
            id="comparison-inspected-body"
            class="mt-3 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]"
          >
            <.detail_term term="Kind" value={inspect_kind(@inspected)} />
            <.detail_term term="Route" value={inspect_route(@inspected)} />
            <.detail_term term="Dates" value={inspect_dates(@inspected)} />
            <.detail_term term="Counts" value={inspect_counts(@inspected)} />
            <.detail_term term="Reason" value={inspect_reason(@inspected)} />
            <.detail_term term="Source rows" value={inspect_refs(@inspected)} />
            <.detail_term term="Frequency windows" value={inspect_frequency(@inspected)} />
          </dl>
        </div>

        <div id="comparison-completeness" class="border-t border-subtle px-5 py-4">
          <.tone_badge tone={completeness_tone(@completeness.status)}>
            {completeness_label(@completeness.status)}
          </.tone_badge>
          <ul
            :if={@completeness.reasons != []}
            id="comparison-completeness-reasons"
            class="mt-2 grid gap-1 text-[13px] leading-relaxed text-default"
          >
            <li :for={reason <- @completeness.reasons} data-reason={reason}>
              {completeness_reason(reason)}
            </li>
          </ul>
        </div>

        <div id="comparison-exclusions" class="border-t border-subtle bg-canvas px-5 py-3">
          <p class="text-[12px] font-semibold text-muted">Not compared</p>
          <ul
            id="comparison-exclusion-list"
            class="mt-1 grid gap-1 text-[13px] leading-relaxed text-default"
          >
            <li :for={exclusion <- @view.exclusions} data-reason={exclusion.reason}>
              {exclusion.detail}
            </li>
          </ul>
        </div>
      </section>

      <div
        :if={@view[:scope]}
        id="comparison-scope-applied"
        class="rounded-card border border-info-line bg-info-bg px-4 py-3 text-[13px] leading-relaxed"
      >
        <p class="font-semibold">Showing a narrowed scope</p>
        <p class="mt-0.5">
          {length(@view.scope.route_pair_keys)} route{plural(@view.scope.route_pair_keys)} and {length(
            @view.scope.dates
          )} date{plural(@view.scope.dates)}. The totals above
          count only these; the full comparison is still held by this page.
        </p>
        <p :if={@omitted != []} id="comparison-omitted-count" class="mt-1">
          {length(@omitted)} route and date group{plural(@omitted)} from the full
          comparison {if length(@omitted) == 1, do: "is", else: "are"} left out of this scope.
        </p>
        <.button
          id="comparison-clear-scope"
          variant="quiet"
          class="mt-2 min-h-11"
          phx-click="clear_comparison_scope"
        >
          Show the whole comparison
        </.button>
      </div>

      <.form for={@scope_form} id="comparison-scope-form" phx-submit="narrow_comparison">
        <fieldset class="rounded-card border border-subtle bg-white px-5 py-5">
          <legend class="text-[13px] font-semibold text-strong">
            Narrow this comparison to the routes and dates you care about
          </legend>
          <p class="mt-1 text-[13px] leading-relaxed text-muted">
            Narrowing is explicit and stays on this page. The full comparison is kept: the totals
            above count only what you select, and every group left out is named below. This is an
            internal comparison of two of your own files. Nothing here is published or shared
            automatically.
          </p>

          <div class="mt-3 grid gap-3 sm:grid-cols-2">
            <.input
              field={@scope_form[:route_pair_keys]}
              type="select"
              id="comparison-scope-routes"
              label="Routes"
              multiple
              options={@route_pairs}
            />
            <.input
              field={@scope_form[:dates]}
              type="select"
              id="comparison-scope-dates"
              label="Dates"
              multiple
              options={@date_options}
            />
          </div>

          <p
            :if={@scope_notice}
            id="comparison-scope-notice"
            class="mt-2 text-[13px] font-semibold text-strong"
          >
            {@scope_notice}
          </p>

          <div class="mt-4 flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
            <.button
              id="comparison-share-scope"
              class="min-h-11"
              phx-click={JS.focus(to: "#comparison-scope-routes")}
            >
              Narrow to this selection
            </.button>
          </div>
        </fieldset>
      </.form>
    </div>
    """
  end

  attr :row, :map, required: true

  # A grouped route row's detail: one line per change in the group, naming the
  # dates it covers, the trip each file states and the timing that trip departed.
  defp grouped_route_detail(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h3 id="comparison-inspected-title" class="text-sm font-bold text-strong">
          {change_kind(@row.kind)} · {route_label(@row.route_ids)}
        </h3>
        <p class="mt-0.5 text-[13px] leading-relaxed text-muted">
          The changes behind this row, with the trip each file states and the timing it departed.
        </p>
      </div>
      <.button
        id="comparison-inspected-close"
        variant="quiet"
        size="sm"
        phx-click="close_comparison_detail"
      >
        Close
      </.button>
    </div>
    <table class="mt-3 w-full max-w-3xl text-left text-[13px]">
      <thead>
        <tr class="border-b border-subtle text-[12px] text-muted">
          <th class="py-1 pr-4 font-semibold">Date</th>
          <th class="py-1 pr-4 font-semibold">Earlier file</th>
          <th class="py-1 pr-4 font-semibold">Candidate file</th>
          <th class="py-1 font-semibold">Change</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={change <- @row.changes} class="border-b border-subtle/60 last:border-0">
          <td class="py-1.5 pr-4 align-top text-strong">{change_dates(change)}</td>
          <td class="py-1.5 pr-4 align-top tabular-nums text-strong">
            {trip_note(change, :left)}
          </td>
          <td class="py-1.5 pr-4 align-top tabular-nums text-strong">
            {trip_note(change, :right)}
          </td>
          <td class="py-1.5 align-top tabular-nums text-default">{route_detail_delta(change)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  # A grouped change carries its own trip identities and the per-stop timing the
  # comparison recorded. A file cell names the trip and its first departure, or
  # "—" when the change identified no trip (a count or frequency churn).
  defp trip_note(change, side) do
    trip = get_in(change, [:trips, side])
    timing = change |> Map.get(:timing, []) |> List.wrap() |> List.first()

    [trip && to_string(trip), timing && format_seconds(timing_seconds(timing, side))]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "—"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp timing_seconds(%{left_secs: left}, :left), do: left
  defp timing_seconds(%{right_secs: right}, :right), do: right
  defp timing_seconds(_entry, _side), do: nil

  defp route_detail_delta(%{timing: timing}) when is_list(timing) and timing != [] do
    case timing |> Enum.map(& &1.delta_secs) |> Enum.uniq() do
      [0] -> "no change"
      [delta] -> "#{signed_seconds(delta)} at #{length(timing)} stops"
      _varies -> "differs by stop"
    end
  end

  defp route_detail_delta(change), do: "trips #{signed(change.delta[:scheduled_count])}"

  defp signed_seconds(seconds) when seconds > 0, do: "later by #{div(seconds, 60)} min"
  defp signed_seconds(seconds) when seconds < 0, do: "earlier by #{div(abs(seconds), 60)} min"
  defp signed_seconds(_seconds), do: "no change"

  defp format_seconds(seconds) when is_integer(seconds) and seconds >= 0 do
    "#{pad2(div(seconds, 3600))}:#{pad2(div(rem(seconds, 3600), 60))}:#{pad2(rem(seconds, 60))}"
  end

  defp format_seconds(_seconds), do: "—"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  # One value per date, so the chart scales to its own window: the tallest bar
  # is 44px and every other bar keeps its proportion, with a floor so a small
  # change stays visible. A date whose value is nil draws no bar, only "—".
  defp per_date_max(entries) do
    entries
    |> Enum.map(&abs(&1.value || 0))
    |> Enum.max(fn -> 0 end)
  end

  defp per_date_bar_height(value, max) when is_integer(value) and max > 0,
    do: max(div(abs(value) * 44, max), 3)

  defp per_date_bar_height(_value, _max), do: 0

  defp per_date_value(nil), do: "—"
  defp per_date_value(0), do: "0"
  defp per_date_value(value) when value > 0, do: "+#{value}"
  defp per_date_value(value), do: "−#{abs(value)}"

  defp per_date_value_class(nil), do: "text-muted"
  defp per_date_value_class(0), do: "text-muted"
  defp per_date_value_class(value) when value > 0, do: "text-info-fg"
  defp per_date_value_class(_value), do: "text-action"

  # The bar's value and the date are both read aloud, so the chart's meaning
  # survives without seeing colour or height.
  defp per_date_label(%{date: date, value: value}) do
    "#{format_chart_date(date)}: #{per_date_meaning(value)}"
  end

  defp per_date_meaning(nil), do: "not measured"
  defp per_date_meaning(0), do: "no change"
  defp per_date_meaning(value) when value > 0, do: "gain #{value} trip#{plural(value)}"
  defp per_date_meaning(value), do: "lose #{abs(value)} trip#{plural(abs(value))}"

  defp format_chart_date(%Date{} = date), do: Calendar.strftime(date, "%b %-d")

  attr :label, :string, required: true
  attr :identity, :map, required: true

  defp artifact_column(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="text-[13px] font-semibold text-strong">{@label}</dt>
      <dd class="mt-0.5 text-[13px] leading-relaxed text-muted">
        <p>Feed version <span class="font-mono">{short_id(@identity.version_id)}</span></p>
        <p class="mt-0.5">SHA-256 <span class="font-mono">{short_id(@identity.sha256)}</span></p>
        <p class="mt-0.0.5">
          {format_bytes(@identity.size)} · expires {format_timestamp(@identity.expires_at)}
        </p>
        <p :if={@identity[:estimate_missing_times]} class="mt-0.5">
          Missing stop times were estimated at export time
          ({estimate_label(@identity[:estimate_method])}), so no original value is available to
          compare.
        </p>
      </dd>
    </div>
    """
  end

  attr :term, :string, required: true
  attr :value, :string, required: true

  defp detail_term(assigns) do
    ~H"""
    <dt class="text-[13px] text-muted">{@term}</dt>
    <dd class="min-w-0 break-words text-strong">{@value}</dd>
    """
  end

  attr :collection, :atom, required: true
  attr :page, :map, required: true
  attr :true_total, :integer, required: true
  attr :noun, :string, required: true

  # Paging is deterministic: the same page of the same result always shows the
  # same rows, and the counter states the whole collection's size, not the page's.
  defp page_bar(assigns) do
    ~H"""
    <div
      :if={@true_total > @page.limit}
      id={"comparison-#{short_collection(@collection)}-paging"}
      class="flex flex-wrap items-center justify-between gap-2 border-t border-subtle bg-canvas px-5 py-3"
    >
      <p class="text-[13px] tabular-nums text-muted">
        Showing {first_shown(@page)}–{last_shown(@page, @true_total)} of {@true_total}
        {if @true_total == 1, do: @noun, else: @noun <> "s"}
      </p>
      <div class="flex items-center gap-2">
        <.button
          :if={@page.offset > 0}
          id={"comparison-#{short_collection(@collection)}-previous"}
          variant="secondary"
          size="sm"
          class="min-h-11"
          phx-click="page_comparison"
          phx-value-collection={@collection}
          phx-value-offset={max(@page.offset - @page.limit, 0)}
          phx-value-limit={@page.limit}
        >
          Previous
        </.button>
        <.button
          :if={last_shown(@page, @true_total) < @true_total}
          id={"comparison-#{short_collection(@collection)}-next"}
          variant="secondary"
          size="sm"
          class="min-h-11"
          phx-click="page_comparison"
          phx-value-collection={@collection}
          phx-value-offset={@page.offset + @page.limit}
          phx-value-limit={@page.limit}
        >
          Next
        </.button>
      </div>
    </div>
    """
  end

  # The DOM ids of the paging controls drop the stream's own `comparison_`
  # prefix, so the page's ids stay short and stable.
  defp short_collection(:comparison_structural), do: "structural"
  defp short_collection(:comparison_unresolved), do: "unresolved"
  defp short_collection(:comparison_unknowns), do: "unknowns"

  defp first_shown(%{offset: offset}), do: offset + 1

  defp last_shown(%{offset: offset, limit: limit}, true_total),
    do: min(offset + limit, true_total)

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp total_cell(assigns) do
    ~H"""
    <div class="rounded-control border border-subtle bg-canvas px-3 py-2.5">
      <dt class="text-[13px] text-muted">{@label}</dt>
      <dd id={@id} class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums">
        {total_value(@value)}
      </dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :kind, :string, required: true
  attr :pressed, :boolean, required: true

  defp kind_chip(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="filter_comparison_kind"
      phx-value-kind={@kind}
      aria-pressed={to_string(@pressed)}
      class={[
        "min-h-11 rounded-full border px-3 py-1.5 text-[13px] font-semibold",
        @pressed && "border-strong bg-strong text-white",
        !@pressed && "border-subtle bg-white text-strong hover:bg-canvas"
      ]}
    >
      {@label}
    </button>
    """
  end

  defp total_value(nil), do: "—"
  defp total_value(value), do: signed(value)

  defp kind_counts_list(counts) do
    for kind <- [:count_changed, :timing_changed, :added, :removed, :frequency_changed],
        count = Map.get(counts, kind, 0),
        count > 0,
        do: {kind, count}
  end

  defp day_class_sentence(classes) do
    classes
    |> Enum.map(fn %{class: class, value: value} ->
      "#{day_class_name(class)} #{signed_phrase(value)}."
    end)
    |> Enum.join(" ")
  end

  defp day_class_name(:weekdays), do: "Weekdays"
  defp day_class_name(:saturdays), do: "Saturdays"
  defp day_class_name(:sundays), do: "Sundays"

  defp signed_phrase(nil), do: "are not measured"
  defp signed_phrase(0), do: "are unchanged"
  defp signed_phrase(value) when value > 0, do: "gain #{value} trips"
  defp signed_phrase(value), do: "lose #{abs(value)} trips"

  defp route_row_dates(%{dates: dates}) when is_list(dates) and dates != [] do
    Enum.map_join(dates, ", ", &Date.to_iso8601/1)
  end

  defp route_row_dates(_row), do: "All compared dates"

  defp route_row_delta(%{delta: %{scheduled_count: count}}), do: "trips #{signed(count)}"
  defp route_row_delta(_row), do: ""

  defp route_badge_route(route) do
    %{
      route_id: route,
      route_short_name: route,
      route_color: nil,
      route_text_color: nil
    }
  end

  # The narrowing form only ever offers route pairs and dates this very result
  # proved, so a selection cannot name something the comparison never found.
  defp route_pair_options(view) do
    case Compare.route_pairs(view) do
      [] -> [{"No routes were compared", ""}]
      pairs -> Enum.map(pairs, &{&1.label, &1.key})
    end
  end

  defp date_options(window) do
    window.from
    |> Date.range(window.to)
    |> Enum.map(&{Date.to_iso8601(&1), Date.to_iso8601(&1)})
  end

  defp omitted_units(exclusions),
    do: Enum.filter(exclusions, &(&1.reason == :narrowed_out_of_scope))

  defp completeness_tone(:complete), do: "success"
  defp completeness_tone(:incomplete), do: "warning"

  defp completeness_label(:complete), do: "Complete for this window"
  defp completeness_label(:incomplete), do: "Incomplete for this window"

  defp completeness_reason(:no_service_groups),
    do: "Neither file stated service for these routes and dates."

  defp completeness_reason(:unmeasured_units),
    do: "At least one route and date could not be compared on both sides."

  defp completeness_reason(:unresolved_entity_matches),
    do: "Some entities could not be paired with confidence."

  defp completeness_reason(:stop_meaning_changed),
    do: "A stop moved or changed type, so its trips were not compared for timing."

  defp completeness_reason(:left_evaluation_incomplete),
    do: "The earlier file has rows that could not be read."

  defp completeness_reason(:right_evaluation_incomplete),
    do: "The candidate file has rows that could not be read."

  defp completeness_reason(:unpaired_trips),
    do: "Some trips on the same route and date could not be paired between the two files."

  defp completeness_reason(reason),
    do: "This comparison is incomplete for another reason: #{reason}."

  defp totals_reason(:unmapped_route), do: "A route in one file has no proven match in the other."
  defp totals_reason(:one_sided_unit), do: "A route states service on one side only."

  defp totals_reason(:incomplete_counts),
    do: "A route states frequency windows rather than exact departures."

  defp totals_reason(:unknown_timezone),
    do: "A route’s timezone is unknown, so its timing is not compared."

  defp totals_reason(:timezone_mismatch), do: "The two files give a route different timezones."
  defp totals_reason(:stop_meaning_changed), do: "A stop’s correspondence changed meaning."
  defp totals_reason(:stop_ambiguous), do: "A stop could not be told apart from a similar one."
  defp totals_reason(:stop_unresolved), do: "A stop has no proven correspondence."

  defp totals_reason(:left_evaluation_incomplete),
    do: "The earlier file has rows that could not be read."

  defp totals_reason(:right_evaluation_incomplete),
    do: "The candidate file has rows that could not be read."

  defp totals_reason(reason), do: "This total was not measured: #{reason}."

  defp measured_units_label(%{measured_units: measured, total_units: total}) do
    "Measured across #{measured} of #{total} compared route and date #{if total == 1, do: "group", else: "groups"}."
  end

  defp difference_reason(:one_sided_unit),
    do: "One file states service here and the other states none, so no change is claimed."

  defp difference_reason(:incomplete_counts),
    do:
      "One file states frequency windows rather than exact departures, so counts are not compared."

  defp difference_reason(:unmapped_route), do: "This route has no proven match in the other file."
  defp difference_reason(reason), do: "Not compared: #{reason}."

  defp change_kind(:added), do: "Service added"
  defp change_kind(:removed), do: "Service removed"
  defp change_kind(:count_changed), do: "Trip count changed"
  defp change_kind(:timing_changed), do: "Timing changed"
  defp change_kind(:frequency_changed), do: "Frequency changed"
  defp change_kind(:identifier), do: "Renamed"
  defp change_kind(reason), do: humanize(reason)

  # A structural change is a rename, a presence change, or a field of an entity that
  # kept its identifier (its service dates, stop times, frequency windows, name and
  # so on). The last kind is neither new nor missing, so it says which field moved.
  defp structural_title(change) when change in [:identifier, :added, :removed],
    do: change_kind(change)

  defp structural_title(_field), do: "Changed"

  defp structural_note(:identifier),
    do: "Renamed; the service it carries was compared under both identifiers."

  defp structural_note(:removed), do: "This entity is missing from the candidate file."
  defp structural_note(:added), do: "This entity is new in the candidate file."

  defp structural_note(field),
    do: "Same identifier, but its #{structural_field(field)} changed between the two files."

  defp structural_field(:service_dates), do: "service dates"
  defp structural_field(:time_vector), do: "stop times"
  defp structural_field(:stop_pattern), do: "stops"
  defp structural_field(:frequencies), do: "frequency windows"
  defp structural_field(field), do: field |> to_string() |> String.replace("_", " ")

  defp unresolved_reason(:no_candidate), do: "no candidate on the other side"
  defp unresolved_reason(:ambiguous_signature), do: "several entities share its signature"
  defp unresolved_reason(:missing_field), do: "a field it needs was absent"
  defp unresolved_reason(:unproven_dependency), do: "something it depends on was unresolved"
  defp unresolved_reason(reason), do: humanize(reason)

  defp unknown_reason(reason), do: humanize(reason)

  defp humanize(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp side_label(:left), do: "Earlier"
  defp side_label(:right), do: "Candidate"
  defp side_label(other), do: humanize(other)

  defp route_label(%{left: left, right: right}) do
    cond do
      is_binary(left) and is_binary(right) -> "#{left} → #{right}"
      is_binary(left) -> "#{left} (earlier file only)"
      is_binary(right) -> "#{right} (candidate file only)"
      true -> "Unnamed route"
    end
  end

  defp change_dates(%{date: date, dates: dates}) do
    cond do
      is_map(date) -> Date.to_iso8601(date)
      dates != [] -> Enum.map_join(dates, ", ", &Date.to_iso8601/1)
      true -> "All compared dates"
    end
  end

  defp counts_description(%{left: left, right: right}),
    do: "#{side_count(left)} then #{side_count(right)}"

  defp side_count(nil), do: "none"

  defp side_count(counts) when is_map(counts),
    do: "#{counts[:scheduled_count] || 0} scheduled, #{counts[:exact_count] || 0} exact"

  defp signed(nil), do: "not measured"
  defp signed(0), do: "no change"
  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: "#{value}"

  # An entity of the earlier file is matched against candidates from the candidate
  # file and the other way round, so each candidate is named for the file it is in.
  defp unresolved_refs(%{left_ref: left, right_ref: right, candidates: candidates}) do
    candidate_file = if left, do: "candidate", else: "earlier"

    parts =
      ([
         left && "earlier #{left.id} (#{left.file} row #{left.row})",
         right && "candidate #{right.id} (#{right.file} row #{right.row})"
       ] ++
         Enum.map(candidates, &"#{candidate_file} #{&1.id} (#{&1.file} row #{&1.row})"))
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "No identifiers were recorded for this entry."
      parts -> Enum.join(parts, " · ")
    end
  end

  # A side, when a row has one, is what a reader needs first: an unreadable row
  # is evidence about one named file, not about the comparison in general.
  defp inspect_kind(%{side: side, reason: reason}),
    do: "#{side_label(side)} file · #{unknown_reason(reason)}"

  defp inspect_kind(%{kind: kind}), do: change_kind(kind)
  defp inspect_kind(%{change: change}), do: change_kind(change)

  defp inspect_kind(%{entity: entity, reason: reason}) when is_binary(entity),
    do: "#{entity} · #{unresolved_reason(reason)}"

  defp inspect_route(%{route_ids: route_ids}), do: route_label(route_ids)
  defp inspect_route(_row), do: "Not tied to a route pair."

  defp inspect_dates(%{date: date, dates: dates}) do
    cond do
      is_map(date) -> Date.to_iso8601(date)
      dates != [] -> Enum.map_join(dates, ", ", &Date.to_iso8601/1)
      true -> "No service date applies to this row."
    end
  end

  defp inspect_dates(_row), do: "No service date applies to this row."

  defp inspect_counts(%{delta: delta, counts: counts}) do
    "was #{counts_description(counts)}; now trips #{signed(delta[:scheduled_count])}, exact #{signed(delta[:exact_count])}"
  end

  defp inspect_counts(%{entity: entity}),
    do: "This #{entity} has no trip counts; it is an identity or presence change."

  defp inspect_counts(%{left: left, right: right}) when is_map(left) and is_map(right) do
    "earlier #{side_count(Map.take(left, [:scheduled_count, :exact_count]))}, " <>
      "candidate #{side_count(Map.take(right, [:scheduled_count, :exact_count]))}"
  end

  defp inspect_counts(%{reason: reason}), do: "This row has no counts: #{unknown_reason(reason)}."

  defp inspect_reason(%{reason: nil}), do: "The comparison measured this row."
  defp inspect_reason(%{reason: reason}) when is_atom(reason), do: difference_reason(reason)
  defp inspect_reason(_row), do: "The comparison measured this row."

  defp inspect_refs(%{source_refs: %{left: left, right: right}}) do
    [left, right]
    |> Enum.map_join(" · ", fn
      [] -> "no rows recorded"
      refs -> Enum.map_join(refs, ", ", &"#{&1.file} row #{&1.row}")
    end)
  end

  defp inspect_refs(%{left_ref: left, right_ref: right}) do
    [
      left && "earlier #{left.file} row #{left.row}",
      right && "candidate #{right.file} row #{right.row}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "No rows were recorded."
      refs -> refs
    end
  end

  defp inspect_refs(%{source: %{file: file, row: row}}), do: "#{file} row #{row}"
  defp inspect_refs(_row), do: "No rows were recorded."

  # Frequency windows are shown separately from a departure count, because a
  # window is a template rather than a proven number of trips.
  defp inspect_frequency(%{frequency_windows: %{left: left, right: right}}) do
    case {left, right} do
      {[], []} -> "None. Both files state exact trips here."
      _windows -> Enum.map_join([left, right], " · ", &window_description/1)
    end
  end

  defp inspect_frequency(_row), do: "None recorded."

  defp window_description([]), do: "no windows"

  defp window_description(windows) do
    Enum.map_join(windows, ", ", fn window ->
      exact = if window[:exact_times] == 1, do: "every trip", else: "a template"
      "#{window[:start_secs]}–#{window[:end_secs]}s every #{window[:headway_secs]}s (#{exact})"
    end)
  end

  defp short_id(nil), do: "unknown"
  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short_id(value), do: to_string(value)

  defp estimate_label(:even), do: "equal time per stop"
  defp estimate_label(_method), do: "distance along the path"

  defp format_bytes(nil), do: "unknown size"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp plural(1), do: ""
  defp plural(_count), do: "s"

  defp comparison_tone_class(:neutral), do: "border border-subtle bg-white text-muted"
  defp comparison_tone_class(:info), do: "bg-soft text-cyan-800"
  defp comparison_tone_class(:success), do: "bg-soft text-cyan-700"
  defp comparison_tone_class(:warning), do: "bg-warning-bg text-warning-fg"
  defp comparison_tone_class(:error), do: "bg-error-bg text-error-fg"

  # A window's bounds are plain `Date`s and a run's timestamp is a `DateTime`,
  # so both are formatted here rather than at each call site.
  defp format_timestamp(%DateTime{} = time),
    do: Calendar.strftime(time, "%b %-d, %Y %-I:%M %p")

  defp format_timestamp(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")
  defp format_timestamp(nil), do: "an unknown time"

  defp format_date_range(%{from: from, to: to}),
    do: "#{format_timestamp(from)} – #{format_timestamp(to)}"

  @doc "One row of the identifier and presence changes list."
  attr :dom_id, :string, required: true
  attr :change, :map, required: true

  def comparison_structural_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {structural_title(@change.change)} {@change.entity}
          <span class="font-mono text-[13px]">{@change.id}</span>
        </p>
        <p class="mt-0.5 text-[13px] leading-relaxed text-muted">
          {structural_note(@change.change)}
          {if @change.meaning_changed,
            do: " Its meaning changed, so aligned timing was not claimed."}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_structural}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end

  @doc "One row of the unresolved entity matches list."
  attr :dom_id, :string, required: true
  attr :entry, :map, required: true

  def comparison_unresolved_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {@entry.entity} · {unresolved_reason(@entry.reason)}
        </p>
        <p class="mt-0.5 font-mono text-[13px] leading-relaxed text-muted">
          {unresolved_refs(@entry)}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_unresolved}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end

  @doc "One row of the rows this comparison could not read list."
  attr :dom_id, :string, required: true
  attr :unknown, :map, required: true

  def comparison_unknown_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {side_label(@unknown.side)} file · {unknown_reason(@unknown.reason)}
        </p>
        <p class="mt-0.5 text-[13px] leading-relaxed text-muted">{@unknown.detail}</p>
        <p
          :if={@unknown[:source] && @unknown.source[:file]}
          class="mt-0.5 font-mono text-[13px] text-muted"
        >
          {@unknown.source.file} row {@unknown.source.row}
        </p>
      </div>
      <.button
        id={"#{@dom_id}-inspect"}
        variant="quiet"
        size="sm"
        phx-click="inspect_comparison_row"
        phx-value-collection={:comparison_unknowns}
        phx-value-row={@dom_id}
      >
        Inspect
      </.button>
    </div>
    """
  end
end
