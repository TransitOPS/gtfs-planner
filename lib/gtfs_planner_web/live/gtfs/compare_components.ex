defmodule GtfsPlannerWeb.Gtfs.CompareComponents do
  @moduledoc """
  The Compare page's presentation, on the application design system.

  One card walks the comparison in order: name two retained full feed files and
  one explicit date range (`comparison/1`), then read what the completed
  comparison found (`comparison_results/1`). The helper entry
  (`comparison_helper/1`) offers the comparison helper once a comparison has
  finished, and the difference, structural, unresolved and unknown row
  components render each paged stream's rows.

  The components carry no state and run no queries: `CompareLive` owns the
  events and the data, and passes the choices, the chosen rows and the result
  in.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.ResultComponents, only: [result_section: 1, tone_badge: 1]

  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare

  @doc """
  Compare two retained full feed files over one explicit date range.

  The form names both sides and the window, and starts nothing by itself: the
  draft is `%{"left_run_id", "right_run_id", "from", "to"}` and
  `.CompareLive` owns the events, the choices and the running comparison. The two
  run selectors carry a prompt and never a default, and the date range starts
  blank: a comparison always compares two named files over dates the editor
  chose.

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

  def comparison(assigns) do
    assigns =
      assigns
      |> assign(:options, Enum.map(assigns.choices.rows, &{run_label(&1), to_string(&1.run_id)}))
      |> assign(:running?, assigns.status in [:running, :cancelling])
      |> assign(:view, comparison_view(assigns.status, assigns.chosen, assigns.result))

    ~H"""
    <div id="export-comparison" class="px-5 py-5">
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
          <div class="mt-2.5 grid gap-3 sm:grid-cols-2">
            <.input
              field={@form[:left_run_id]}
              type="select"
              id="comparison-left"
              label="Earlier export"
              prompt="Choose an export"
              options={@options}
            />
            <.input
              field={@form[:right_run_id]}
              type="select"
              id="comparison-right"
              label="Candidate export"
              prompt="Choose an export"
              options={@options}
            />
          </div>
        </fieldset>

        <div class="mt-3 grid gap-3 sm:grid-cols-2">
          <.input field={@form[:from]} type="date" id="comparison-from" label="From" />
          <.input field={@form[:to]} type="date" id="comparison-to" label="To" />
        </div>

        <p id="comparison-window-note" class="mt-2 text-[13px] leading-relaxed text-muted">
          The same dates are compared on both sides. One comparison covers at most 62 dates.
        </p>

        <div class="mt-4 flex flex-wrap items-center gap-2 max-sm:w-full max-sm:[&>*]:flex-1">
          <.button
            :if={not @running?}
            id="comparison-start"
            class="min-h-11"
            phx-click={JS.focus(to: "#comparison-status-title")}
          >
            Compare exports
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
    </div>
    """
  end

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
  attr :page, :map, required: true
  attr :true_totals, :map, required: true

  # Each list is passed in as a slot because only the template that owns a
  # stream may iterate it. A stream consumed anywhere else renders its first
  # page and then stops pruning, so a narrowed scope would leave the full
  # comparison's rows on the page.
  slot :differences_list, required: true
  slot :structural_list, required: true
  slot :unresolved_list, required: true
  slot :unknowns_list, required: true

  def comparison_results(assigns) do
    assigns =
      assigns
      |> assign(:window, assigns.view.window)
      |> assign(:route_pairs, route_pair_options(assigns.view))
      |> assign(:date_options, date_options(assigns.view.window))
      |> assign(:totals, assigns.view.totals)
      |> assign(:completeness, assigns.view.completeness)
      |> assign(:omitted, omitted_units(assigns.view.exclusions))

    ~H"""
    <div id="comparison-results" class="grid gap-6">
      <.result_section
        id="comparison-summary"
        title="What the comparison found"
        lede={summary_lede(@completeness)}
      >
        <div class="grid gap-5 px-5 py-5">
          <dl id="comparison-artifacts" class="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2">
            <.artifact_column label="Earlier export" identity={@result.left} />
            <.artifact_column label="Candidate export" identity={@result.right} />
          </dl>

          <p id="comparison-window" class="text-[13px] leading-relaxed text-muted">
            Both files were compared over the same dates, {format_date_range(@window)}.
          </p>

          <div id="comparison-totals">
            <p class="text-[13px] font-semibold text-strong">Totals across the compared routes</p>
            <%= if @totals.exact_count_delta == nil do %>
              <p id="comparison-totals-unknown" class="mt-1.5 text-sm leading-relaxed text-default">
                A whole-feed total was not measured, so none is shown. The comparison found:
              </p>
              <ul
                id="comparison-total-reasons"
                class="mt-1.5 grid gap-1 text-[13px] leading-relaxed text-default"
              >
                <li :for={reason <- @totals.reasons} data-reason={reason}>
                  {totals_reason(reason)}
                </li>
              </ul>
            <% else %>
              <dl class="mt-1.5 grid grid-cols-2 gap-3">
                <div class="rounded-control border border-subtle bg-canvas px-3 py-2.5">
                  <dt class="text-[13px] text-muted">Scheduled trips</dt>
                  <dd
                    id="comparison-scheduled-delta"
                    class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums"
                  >
                    {signed(@totals.scheduled_count_delta)}
                  </dd>
                </div>
                <div class="rounded-control border border-subtle bg-canvas px-3 py-2.5">
                  <dt class="text-[13px] text-muted">Exact departures</dt>
                  <dd
                    id="comparison-exact-delta"
                    class="mt-0.5 font-display text-[26px] font-semibold leading-none tabular-nums"
                  >
                    {signed(@totals.exact_count_delta)}
                  </dd>
                </div>
              </dl>
              <p class="mt-1.5 text-[13px] text-muted">{measured_units_label(@totals)}</p>
            <% end %>

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

          <div id="comparison-completeness">
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
        </div>
      </.result_section>

      <.result_section
        id="comparison-differences"
        title="Service differences"
        count={@true_totals.comparison_differences}
        lede="What changed in the compared service, one row per difference."
      >
        {render_slot(@differences_list)}
        <p
          :if={@true_totals.comparison_differences == 0}
          id="comparison-differences-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          No service differences were found in this scope.
        </p>
        <.page_bar
          collection={:comparison_differences}
          page={@page.comparison_differences}
          true_total={@true_totals.comparison_differences}
          noun="difference"
        />
      </.result_section>

      <.result_section
        id="comparison-structural"
        title="Identifier and presence changes"
        count={@true_totals.comparison_structural}
        lede="Renamed, added and removed entities. These are not service loss on their own."
      >
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
      </.result_section>

      <.result_section
        id="comparison-unresolved"
        title="Unresolved entity matches"
        count={@true_totals.comparison_unresolved}
        lede="Entities this comparison could not pair with confidence. They are never counted as a loss."
      >
        {render_slot(@unresolved_list)}
        <p
          :if={@true_totals.comparison_unresolved == 0}
          id="comparison-unresolved-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          Every entity was paired.
        </p>
        <.page_bar
          collection={:comparison_unresolved}
          page={@page.comparison_unresolved}
          true_total={@true_totals.comparison_unresolved}
          noun="unresolved match"
        />
      </.result_section>

      <.result_section
        id="comparison-unknowns-section"
        title="What this comparison could not read"
        count={@true_totals.comparison_unknowns}
        lede="Rows the files did not state clearly. They are never counted as zero service."
      >
        {render_slot(@unknowns_list)}
        <p
          :if={@true_totals.comparison_unknowns == 0}
          id="comparison-unknowns-empty"
          class="px-5 py-6 text-center text-[13px] text-muted"
        >
          Nothing was unreadable.
        </p>
        <.page_bar
          collection={:comparison_unknowns}
          page={@page.comparison_unknowns}
          true_total={@true_totals.comparison_unknowns}
          noun="unknown row"
        />
      </.result_section>

      <div
        :if={@inspected}
        id="comparison-inspected"
        role="region"
        aria-labelledby="comparison-inspected-title"
        tabindex="-1"
        class="rounded-card border border-subtle bg-white px-5 py-5 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
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

      <details
        id="comparison-exclusions"
        class="group rounded-card border border-subtle bg-white px-5 py-4"
      >
        <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 text-sm font-semibold text-strong [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-4 text-muted transition-transform group-open:rotate-90"
          /> What this comparison does not cover
        </summary>
        <ul
          id="comparison-exclusion-list"
          class="grid gap-1.5 pt-2 text-[13px] leading-relaxed text-default"
        >
          <li :for={exclusion <- @view.exclusions} data-reason={exclusion.reason}>
            {exclusion.detail}
          </li>
        </ul>
      </details>
    </div>
    """
  end

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
  defp short_collection(:comparison_differences), do: "differences"
  defp short_collection(:comparison_structural), do: "structural"
  defp short_collection(:comparison_unresolved), do: "unresolved"
  defp short_collection(:comparison_unknowns), do: "unknowns"

  defp first_shown(%{offset: offset}), do: offset + 1

  defp last_shown(%{offset: offset, limit: limit}, true_total),
    do: min(offset + limit, true_total)

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

  defp summary_lede(%{status: :complete}),
    do: "Every supported dimension of both files was compared over these dates."

  defp summary_lede(%{status: :incomplete}),
    do: "Some of what these files describe could not be compared, so this is a partial answer."

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

  defp change_delta(%{delta: delta, counts: counts}) do
    "trips #{signed(delta[:scheduled_count])} · exact #{signed(delta[:exact_count])} · was #{counts_description(counts)}"
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

  defp inspect_counts(%{left: left, right: right}) when is_map(left) and is_map(right) do
    "earlier #{side_count(Map.take(left, [:scheduled_count, :exact_count]))}, " <>
      "candidate #{side_count(Map.take(right, [:scheduled_count, :exact_count]))}"
  end

  defp inspect_counts(%{left: left, right: right}),
    do: "earlier #{side_count(left)}, candidate #{side_count(right)}"

  defp inspect_counts(%{entity: entity}),
    do: "This #{entity} has no trip counts; it is an identity or presence change."

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

  @doc """
  One row of the differences list. The list itself is a slot on
  `comparison_results/1`; this is only the row's own markup, so the owning
  template stays the one that iterates the stream.
  """
  attr :dom_id, :string, required: true
  attr :change, :map, required: true

  def comparison_difference_row(assigns) do
    ~H"""
    <div
      id={@dom_id}
      class="flex flex-col gap-2 px-5 py-3.5 sm:flex-row sm:items-start sm:justify-between"
    >
      <div class="min-w-0">
        <p class="text-sm font-semibold text-strong">
          {change_kind(@change.kind)} · {route_label(@change.route_ids)}
        </p>
        <p class="mt-0.5 text-[13px] text-muted">
          {change_dates(@change)}
          {if @change.direction_id, do: " · direction #{@change.direction_id}"}
        </p>
        <p :if={@change.reason} class="mt-0.5 text-[13px] text-muted">
          {difference_reason(@change.reason)}
        </p>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span id={"#{@dom_id}-delta"} class="text-sm font-semibold tabular-nums text-strong">
          {change_delta(@change)}
        </span>
        <.button
          id={"#{@dom_id}-inspect"}
          variant="quiet"
          size="sm"
          phx-click="inspect_comparison_row"
          phx-value-collection={:comparison_differences}
          phx-value-row={@dom_id}
        >
          Inspect
        </.button>
      </div>
    </div>
    """
  end

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
