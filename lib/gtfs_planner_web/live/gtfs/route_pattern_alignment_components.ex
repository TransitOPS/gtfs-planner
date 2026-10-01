defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents do
  @moduledoc """
  Server-rendered Alignment task shell (slice A).

  Presents the `Gtfs.alignment_editor/4` read model: workspace header with the
  R9 status badge, the section inspector with per-section status and scope,
  the selected-section detail and the GTFS shape footer. Step 32 wires the
  street-generation controls (CR-10's slice-A restriction is lifted for
  these controls only): the empty-state overlay, the per-section Generate
  button with its replace dialog, the in-flight overlay with cancel, and
  the routing failure notices. Generation only produces drafts (CR-9); Save
  stays the only commit.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]
  import GtfsPlannerWeb.RouteWorkspace, only: [badge: 1]

  attr :alignment, :map, default: nil, doc: "the Gtfs.alignment_editor/4 read model"
  attr :version_id, :string, default: nil, doc: "the published version the download is scoped to"
  attr :state, :map, required: true, doc: "alignment UI state (selected section first)"
  attr :notice, :atom, default: nil, doc: ":read_only, :out_of_date, :imported_shape or nil"
  attr :dialog_open, :boolean, default: false, doc: "opens the help dialog"
  attr :editable?, :boolean, default: false, doc: "false renders the read-only notice"
  attr :offline?, :boolean, default: false, doc: "kept for later steps; save stays disabled"
  attr :version_name, :string, default: nil, doc: "named in the help dialog scope line"
  attr :organization_name, :string, default: nil, doc: "named in the help dialog scope line"

  attr :delete_dialog, :map,
    default: nil,
    doc: "%{position, from, to} when the delete dialog is open"

  attr :discard_dialog, :any,
    default: nil,
    doc: "non-nil when the alignment discard dialog is open"

  attr :simplify_dialog, :map,
    default: nil,
    doc: "%{position, tolerance} when the simplify dialog is open"

  attr :pending, :map,
    default: nil,
    doc: "save review pending a dialog choice (%{kind} :save | :blocked | :conflict)"

  attr :save_notice, :any,
    default: nil,
    doc: ":stale_stops, :stale_review, :busy, :save_error or {:error, message}"

  attr :import_card, :map,
    default: nil,
    doc: "%{shape_id} when the imported-line card is open"

  attr :applying?, :boolean,
    default: false,
    doc: "disables Save while a save apply round-trips"

  attr :generation, :map,
    default: nil,
    doc: "%{token, positions, pattern_id} while street routing is in flight"

  attr :generate_dialog, :map,
    default: nil,
    doc: "%{positions, from, to} when the generate replace dialog is open"

  attr :generate_notice, :map,
    default: nil,
    doc: "%{kind: :no_route | :unavailable, failures: [%{position, from, to}]}"

  attr :file_import, :map, default: nil, doc: "the open path-file import panel, or nil"

  attr :file_fit, :map,
    default: nil,
    doc: "the hook's reported fit, or nil before the hook answers"

  attr :map_line_upload, Phoenix.LiveView.UploadConfig,
    required: true,
    doc: "the path-file upload"

  def alignment_task(assigns) do
    assigns =
      assigns
      |> assign(:visits_by_position, visits_by_position(assigns.alignment))
      |> assign(:selected, selected_section(assigns.alignment, assigns.state))
      |> assign(:dirty_positions, dirty_positions(assigns.state))
      |> assign(:flagged_positions, flagged_positions(assigns.state))
      |> assign(:header_status, header_status(assigns.alignment))
      |> assign(:footer_status, footer_status(assigns.alignment))
      |> assign(:saved_count, saved_count(assigns.alignment))
      |> assign(:missing_count, missing_count(assigns.alignment))
      |> assign(:generating?, not is_nil(assigns[:generation]))
      |> assign(:save_pending?, not is_nil(assigns[:pending]))
      |> assign(:generate_overlay?, generate_overlay?(assigns.alignment, assigns[:editable?]))
      # The imported-line card and the path-file panel are two ways into the
      # same fit review, so only one of them owns the column at a time.
      |> assign(
        :import_card?,
        assigns.notice == :imported_shape and not is_nil(assigns[:import_card])
      )

    # The first-alignment overlay is a nudge, not a gate: once a draft
    # exists (generated or drawn) the hook owns visible geometry, so the
    # overlay gets out of the way. The imported-line card previews a shape
    # the same way, so it counts as visible geometry too. Discarding the
    # draft brings the overlay back.
    assigns =
      assign(
        assigns,
        :overlay_dismissed?,
        assigns.generating? or assigns.dirty_positions != [] or assigns.import_card?
      )

    assigns =
      assign(
        assigns,
        :header_status,
        dirty_header_status(assigns.dirty_positions, assigns.header_status)
      )

    assigns =
      assign(
        assigns,
        :any_notice?,
        assigns.notice != nil or assigns.save_notice != nil or assigns.generate_notice != nil
      )

    ~H"""
    <div id="alignment-task">
      <div :if={@any_notice?} class="mb-4 grid gap-3">
        <.message
          :if={@notice == :map_error}
          id="alignment-notice"
          kind="warning"
          title="The background map couldn't load"
        >
          Your alignment and stop list are still available.
          <:action>
            <button type="button" phx-click="alignment_retry_tiles" class="btn btn-outline min-h-11">
              <.icon name="hero-arrow-path" class="size-4" /> Retry map
            </button>
          </:action>
        </.message>

        <.message
          :if={@notice == :read_only}
          id="alignment-notice"
          kind="info"
          title="You can view this alignment"
        >
          An editor can change the vehicle&rsquo;s path.
        </.message>

        <.message
          :if={@notice == :out_of_date}
          id="alignment-notice"
          kind="warning"
          title="Out of date"
        >
          Stops or shared paths changed since this pattern was saved. The feed export uses the
          saved shape until you save the pattern again.
        </.message>

        <.message
          :if={@notice == :imported_shape}
          id="alignment-notice"
          kind="info"
          title={import_notice_title(@alignment)}
        >
          {import_notice_body(@alignment)}
          <:action>
            <button
              type="button"
              id="alignment-review-import"
              phx-click="alignment_open_import"
              class="btn btn-outline min-h-11"
            >
              {import_notice_cta(@alignment)}
            </button>
          </:action>
        </.message>

        <.message
          :if={@save_notice == :stale_stops}
          id="alignment-save-notice"
          kind="warning"
          title="Stops changed since you opened this alignment"
        >
          Your previous saved path is retained until you review the new stop order.
          <:action>
            <button
              type="button"
              id="alignment-save-reload"
              phx-click="alignment_reload"
              class="btn btn-outline min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Reload
            </button>
          </:action>
        </.message>

        <.message
          :if={@save_notice == :stale_review}
          id="alignment-save-notice"
          kind="warning"
          title="The patterns this save affects changed. Review again."
        >
          Your draft is still here. Review the latest paths before saving.
          <:action>
            <button
              type="button"
              id="alignment-review-again"
              phx-click="alignment_review_again"
              class="btn btn-outline min-h-11"
            >
              Review again
            </button>
          </:action>
        </.message>

        <.message
          :if={@save_notice in [:busy, :save_error]}
          id="alignment-save-notice"
          kind="error"
          title="Your changes weren't saved. Try again."
        >
          Your draft is still here.
          <:action>
            <button
              type="button"
              id="alignment-save-retry"
              phx-click={
                JS.dispatch("alignment:action", to: "#alignment-map-root", detail: %{action: "save"})
              }
              class="btn btn-outline min-h-11"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try again
            </button>
          </:action>
        </.message>

        <.message
          :if={match?({:error, _}, @save_notice)}
          id="alignment-save-notice"
          kind="error"
          title="Your changes weren't saved."
        >
          {save_notice_message(@save_notice)}
        </.message>

        <%!-- Step 32 routing failures: name the failed sections with Retry and
          Draw manually, and push nothing (AC-37). Drafts and saved paths stay
          unchanged; the API key never appears here. --%>
        <.message
          :if={@generate_notice != nil and @generate_notice.kind == :no_route}
          id="alignment-generate-notice"
          kind="warning"
          title="No street path found"
        >
          {generate_notice_body(@generate_notice)}
          <:action>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                id="alignment-generate-retry"
                phx-click="alignment_generate_paths"
                phx-value-retry="true"
                data-commit="alignment"
                class="btn btn-outline min-h-11"
              >
                Retry
              </button>
              <button
                type="button"
                id="alignment-generate-draw"
                phx-click={
                  JS.dispatch("alignment:action",
                    to: "#alignment-map-root",
                    detail: %{action: "draw", position: generate_draw_position(@generate_notice)}
                  )
                }
                class="btn btn-outline min-h-11"
              >
                Draw manually
              </button>
            </div>
          </:action>
        </.message>

        <.message
          :if={@generate_notice != nil and @generate_notice.kind == :unavailable}
          id="alignment-generate-notice"
          kind="error"
          title="Street routing is unavailable"
        >
          Draw the section or try again later.
          <:action>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                id="alignment-generate-retry"
                phx-click="alignment_generate_paths"
                phx-value-retry="true"
                data-commit="alignment"
                class="btn btn-outline min-h-11"
              >
                Retry
              </button>
              <button
                :if={generate_draw_position(@generate_notice) != nil}
                type="button"
                id="alignment-generate-draw"
                phx-click={
                  JS.dispatch("alignment:action",
                    to: "#alignment-map-root",
                    detail: %{action: "draw", position: generate_draw_position(@generate_notice)}
                  )
                }
                class="btn btn-outline min-h-11"
              >
                Draw manually
              </button>
            </div>
          </:action>
        </.message>
      </div>

      <div class="grid overflow-hidden rounded-card border border-subtle bg-white lg:h-[clamp(520px,calc(100vh-380px),780px)] lg:grid-cols-[minmax(340px,430px)_minmax(0,1fr)]">
        <section
          aria-label="Alignment map"
          class="relative order-1 flex min-h-0 min-w-0 flex-col max-lg:h-[520px] lg:order-2"
        >
          <div
            id="alignment-map-root"
            phx-hook="PatternAlignment"
            phx-update="ignore"
            data-tile-url="/map/tiles/osm-bright/{z}/{x}/{y}"
            class="flex min-h-0 flex-1 items-center justify-center bg-canvas p-6"
          >
            <p id="alignment-map-loading" role="status" class="text-sm text-muted">
              Loading map…
            </p>
          </div>
          <%!-- Step 32 generation overlays: server-rendered siblings over the
            map container, outside the ignored hook element. --%>
          <div
            :if={@generate_overlay? and not @overlay_dismissed?}
            id="alignment-generate-overlay"
            class="absolute inset-0 z-[1100] flex items-center justify-center bg-white/85 p-6"
          >
            <div class="max-w-sm text-center">
              <h3 class="text-base font-bold text-strong">Give this pattern a path</h3>
              <p class="mt-2 text-sm text-muted">
                Start with a suggested street path, then adjust it to match where
                your bus actually travels.
              </p>
              <button
                type="button"
                id="alignment-generate-all"
                phx-click="alignment_generate_paths"
                data-commit="alignment"
                disabled={@offline? or @save_pending?}
                title={generate_all_title(@offline?, @save_pending?)}
                class="btn btn-primary mt-4 min-h-11 w-full"
              >
                Generate street paths
              </button>
              <button
                type="button"
                id="alignment-overlay-draw"
                phx-click={
                  JS.dispatch("alignment:action",
                    to: "#alignment-map-root",
                    detail: %{action: "draw", position: first_missing_position(@alignment)}
                  )
                }
                class="btn btn-ghost mt-2 min-h-11 w-full"
              >
                Or draw a section
              </button>
            </div>
          </div>
          <div
            :if={@generating?}
            id="alignment-generating"
            role="status"
            class="absolute inset-0 z-[1100] flex items-center justify-center bg-white/85 p-6"
          >
            <div class="max-w-sm text-center">
              <h3 class="text-base font-bold text-strong">Finding a street path…</h3>
              <p class="mt-2 text-sm text-muted">
                Your saved paths stay unchanged.
              </p>
              <button
                type="button"
                id="alignment-cancel-generation"
                phx-click="alignment_cancel_generation"
                class="btn btn-outline mt-4 min-h-11 w-full"
              >
                Cancel generation
              </button>
            </div>
          </div>
        </section>

        <aside
          aria-label="Alignment sections"
          class="order-2 flex min-h-0 min-w-0 flex-col overflow-y-auto border-subtle max-lg:border-t lg:order-1 lg:border-r"
        >
          <%!-- Step 32: a pattern still on an imported shape reviews that line
            in the panel itself instead of behind a dialog, so the fit the hook
            measured sits beside the choice and its draft action. The path-file
            panel owns the column while it is open. --%>
          <.imported_line_card
            :if={@import_card? and @file_import == nil}
            card={@import_card}
            alignment={@alignment}
            fit={@file_fit}
            visits={@visits_by_position}
          />

          <.file_import_panel
            :if={not @import_card? and (@file_import != nil or @file_fit != nil)}
            upload={@map_line_upload}
            file={@file_import}
            fit={@file_fit}
            visits={@visits_by_position}
          />
          <div
            :if={@file_import == nil and (@file_fit == nil or @import_card?)}
            class="flex min-h-0 flex-1 flex-col"
          >
            <div class="sticky top-0 z-10 border-b border-subtle bg-white px-4 pb-3 pt-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 id="alignment-title" class="text-base font-bold text-strong">
                  Path between stops
                </h2>
                <div class="ml-auto flex flex-wrap items-center gap-2">
                  <.badge id="alignment-status" tone={badge_tone(@header_status.tone)}>
                    {@header_status.text}
                  </.badge>
                  <.import_export_menu
                    alignment={@alignment}
                    version_id={@version_id}
                    editable?={@editable?}
                    dirty?={@dirty_positions != []}
                  />
                </div>
              </div>
              <p class="mt-1 text-[13px] text-muted">
                <span class="tabular-nums">{@saved_count} of {length(@alignment.sections)}</span>
                sections saved. Select a section to see its actions.
              </p>
              <div class="mt-3 flex flex-wrap gap-2">
                <%!-- Step 32 all-missing generation for partially drawn patterns:
                the empty-state overlay covers the first-alignment moment only,
                so this entry point fires the same event while sections remain. --%>
                <button
                  :if={
                    @editable? and @missing_count > 0 and @missing_count < length(@alignment.sections)
                  }
                  type="button"
                  id="alignment-generate-missing"
                  phx-click="alignment_generate_paths"
                  data-commit="alignment"
                  disabled={@offline? or @generating? or @save_pending?}
                  title={generate_button_title(@offline?, @generating?, @save_pending?)}
                  class="btn btn-outline min-h-11"
                >
                  <.icon name="hero-map" class="size-4" /> Generate street paths
                </button>
                <button
                  :if={@editable?}
                  type="button"
                  id="alignment-open-file-import"
                  phx-click="alignment_open_file_import"
                  class="btn btn-outline min-h-11"
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Import a path file
                </button>
                <button
                  id="alignment-help"
                  type="button"
                  phx-click="alignment_open_help"
                  class="btn btn-ghost min-h-11"
                >
                  <.icon name="hero-question-mark-circle" class="size-4" /> How to edit
                </button>
              </div>
            </div>

            <div id="alignment-sections" class="grid gap-2 px-4 py-4">
              <%= for section <- @alignment.sections do %>
                <.section_row
                  section={section}
                  visits_by_position={@visits_by_position}
                  selected={@selected != nil and section.position == @selected.position}
                  dirty?={section.position in @dirty_positions}
                  flagged?={section.position in @flagged_positions}
                />
                <.section_detail
                  :if={@selected != nil and section.position == @selected.position}
                  section={section}
                  visits_by_position={@visits_by_position}
                  editable?={@editable?}
                  offline?={@offline?}
                  generating?={@generating?}
                  save_pending?={@save_pending?}
                  dirty?={section.position in @dirty_positions}
                  flagged?={section.position in @flagged_positions}
                />
              <% end %>
            </div>

            <div
              id="alignment-footer"
              class="sticky bottom-0 mt-auto border-t border-subtle bg-white px-4 py-3"
            >
              <div class="flex items-center justify-between gap-2">
                <p class="text-[13px] font-[650] text-strong">
                  In the feed export <span class="font-normal text-muted">(GTFS shapes)</span>
                </p>
                <p class="text-[13px] font-semibold text-default">{@footer_status.word}</p>
              </div>
              <p class="mt-0.5 text-[13px] text-muted">{@footer_status.sentence}</p>
            </div>
          </div>
        </aside>
      </div>

      <.help_dialog
        open={@dialog_open}
        version_name={@version_name}
        organization_name={@organization_name}
      />

      <.discard_dialog dialog={@discard_dialog} />
      <.delete_dialog dialog={@delete_dialog} />
      <.simplify_dialog dialog={@simplify_dialog} />
      <.save_dialog
        pending={@pending}
        visits_by_position={@visits_by_position}
        applying?={@applying?}
        version_name={@version_name}
        organization_name={@organization_name}
      />

      <.generate_replace_dialog dialog={@generate_dialog} />
      <.blocked_dialog pending={@pending} />
      <.conflict_dialog pending={@pending} visits_by_position={@visits_by_position} />
    </div>
    """
  end

  @doc """
  The "Import or export" disclosure on the Map line tab (step 35).

  It carries the two file downloads for this one pattern, linking straight at
  the step 34 route (`MapLineDownloadController`) as `<a download>` elements, and
  says what the file will contain before it is fetched. The note is derived from
  the read model the task already has: a pattern with no saved section falls back
  to its imported shape, a pattern with gaps downloads its line in pieces, and a
  pattern with a saved line downloads one line. Unsaved drafts are named as not
  included, because the download reads the saved line.
  """
  attr :alignment, :map, required: true, doc: "the Gtfs.alignment_editor/4 read model"

  attr :version_id, :string,
    required: true,
    doc: "the published version the download is scoped to"

  attr :editable?, :boolean,
    default: false,
    doc: "false labels the disclosure Download, because a viewer cannot import"

  attr :dirty?, :boolean, default: false, doc: "an unsaved draft is not in the file"

  def import_export_menu(assigns) do
    ~H"""
    <details id="map-line-files" class="relative">
      <summary
        id="map-line-files-toggle"
        class="flex min-h-11 cursor-pointer list-none items-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas [&::-webkit-details-marker]:hidden"
      >
        {if @editable?, do: "Import or export", else: "Download"}
        <.icon name="hero-chevron-down" class="size-4 text-muted" />
      </summary>
      <div
        role="menu"
        aria-label="Map line files"
        class="absolute right-0 top-full z-30 mt-2 w-[min(320px,calc(100vw-48px))] rounded-card border border-subtle bg-white p-2 shadow-float"
      >
        <button
          :if={@editable?}
          type="button"
          id="map-line-import-file"
          role="menuitem"
          phx-click="alignment_open_file_import"
          class="flex min-h-11 w-full items-start gap-2 rounded-control px-3 py-2 text-left hover:bg-canvas"
        >
          <.icon name="hero-arrow-up-tray" class="mt-0.5 size-4 shrink-0 text-muted" />
          <span class="min-w-0">
            <span class="block font-[650] text-strong">Import a path file&hellip;</span>
            <span class="block text-[13px] text-muted">
              GeoJSON, KML, KMZ or GPX. You check the fit before anything changes.
            </span>
          </span>
        </button>
        <div :if={@editable?} class="my-1 border-t border-subtle"></div>
        <p class="px-3 pb-1 pt-2 text-[13px] font-[650] text-default">Download this map line</p>
        <.download_item
          id="map-line-download-kml"
          href={download_path(@version_id, @alignment.route_id, @alignment.route_pattern_id, "kml")}
          title="KML file"
          subtitle="For Google Earth and Google My Maps"
        />
        <.download_item
          id="map-line-download-geojson"
          href={
            download_path(@version_id, @alignment.route_id, @alignment.route_pattern_id, "geojson")
          }
          title="GeoJSON file"
          subtitle="For QGIS, ArcGIS and geojson.io"
        />
        <p
          id="map-line-download-note"
          class="mx-1 mt-1 rounded-control bg-canvas px-3 py-2 text-[13px] text-default"
        >
          {download_note(@alignment, @dirty?)}
        </p>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true

  defp download_item(assigns) do
    ~H"""
    <a
      id={@id}
      role="menuitem"
      href={@href}
      download
      class="flex min-h-11 w-full items-start gap-2 rounded-control px-3 py-2 text-left hover:bg-canvas"
    >
      <.icon name="hero-arrow-down-tray" class="mt-0.5 size-4 shrink-0 text-muted" />
      <span class="min-w-0">
        <span class="block font-[650] text-strong">{@title}</span>
        <span class="block text-[13px] text-muted">{@subtitle}</span>
      </span>
    </a>
    """
  end

  # Step 34's route, named for one pattern. `?format=` is required there, so it
  # is always written; `?pattern=` names this pattern rather than the route.
  defp download_path(version_id, route_id, route_pattern_id, format) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}/map-lines?#{%{pattern: route_pattern_id, format: format}}"
  end

  # What the file holds, in the pattern's own stops. A pattern whose sections all
  # resolve to gaps has no saved line to draw, so the download falls back to the
  # imported shape the feed already uses; a pattern with some gaps keeps its
  # saved runs and downloads them as separate pieces rather than straight lines
  # across the gaps.
  defp download_note(alignment, dirty?) do
    pieces = line_pieces(alignment)
    missing = Enum.count(alignment.sections, &(&1.kind in [:missing, :blocked]))

    text =
      cond do
        pieces == [] and imported_note(alignment) != nil ->
          imported_note(alignment)

        missing > 0 ->
          "#{section_count(missing)} no saved path, so the file has the line in " <>
            "#{length(pieces)} #{piece_word(length(pieces))}: " <>
            Enum.map_join(Enum.map(pieces, &piece_span(&1, alignment)), ", and ", &"#{&1}.")

        pieces == [] ->
          "The file has the #{length(alignment.visits)} stops only, so far."

        true ->
          "The file has the saved map line and the #{length(alignment.visits)} stops."
      end

    if dirty?, do: text <> " Unsaved changes aren\u2019t included.", else: text
  end

  # `2 sections have` / `1 section has`
  defp section_count(count) do
    if count == 1, do: "1 section has", else: "#{count} sections have"
  end

  # `2 pieces` / `1 piece`
  defp piece_word(count), do: if(count == 1, do: "piece", else: "pieces")

  # `Lincoln City to Depoe Bay`, the two stops a run of saved sections joins.
  defp piece_span({first, last}, alignment) do
    from = Enum.at(alignment.visits, first)
    to = Enum.at(alignment.visits, last + 1)

    "#{visit_name(from)} to #{visit_name(to)}"
  end

  defp visit_name(%{name: name}) when is_binary(name), do: name
  defp visit_name(_visit), do: "the next stop"

  # `The file has the imported line (shape 1045) and the 13 stops.`
  defp imported_note(alignment) do
    case Enum.find(alignment.imported_shapes, &(&1.points != [])) do
      nil ->
        nil

      shape ->
        "The file has the imported line (shape #{shape.shape_id}) and the " <>
          "#{length(alignment.visits)} stops."
    end
  end

  # The runs of consecutive sections that carry a saved path, as inclusive
  # `{first, last}` section indices. Mirrors `Alignments.line_file/4`'s split, so
  # the note never promises fewer pieces than the file draws.
  defp line_pieces(%{sections: sections}) do
    sections
    |> Enum.with_index()
    |> Enum.reduce([], fn {section, index}, runs ->
      if section.kind in [:missing, :blocked] do
        runs
      else
        case List.last(runs) do
          {^index, _} = _ -> runs
          {first, last} when last == index - 1 -> List.replace_at(runs, -1, {first, index})
          _ -> runs ++ [{index, index}]
        end
      end
    end)
  end

  @doc """
  The state of the Save alignment button, which the page's save bar renders:
  whether Save can run now and, in `title`, the reason it cannot.

  Save enables for editors with a dirty draft; the hook pushes only dirty
  sections, so a clean draft has nothing to review.
  """
  def save_state(%{} = state) do
    %{
      enabled?:
        state.editable? and not state.offline? and not state.applying? and
          not state.generating? and state.dirty_positions != [],
      title:
        save_button_title(
          state.alignment,
          state.editable?,
          state.offline?,
          state.applying?,
          state.dirty_positions,
          state.generating?
        )
    }
  end

  attr :section, :map, required: true
  attr :visits_by_position, :map, required: true
  attr :selected, :boolean, required: true
  attr :dirty?, :boolean, default: false
  attr :flagged?, :boolean, default: false

  def section_row(assigns) do
    assigns =
      assigns
      |> assign(:names, section_names(assigns.section, assigns.visits_by_position))
      |> assign(:status, draft_status(assigns.section, assigns[:dirty?], assigns[:flagged?]))
      |> assign(:scope, section_scope(assigns.section, assigns.visits_by_position))

    ~H"""
    <button
      type="button"
      id={"alignment-section-#{@section.position}"}
      phx-click="alignment_select_section"
      phx-value-position={@section.position}
      aria-pressed={to_string(@selected)}
      class={[
        "flex min-h-[58px] w-full items-start gap-3 rounded-card border bg-white px-3 py-2 text-left hover:bg-canvas",
        if(@selected, do: "border-cyan-700 ring-1 ring-cyan-700", else: "border-subtle")
      ]}
    >
      <span
        aria-hidden="true"
        class="mt-0.5 flex size-[26px] shrink-0 items-center justify-center rounded-full border border-control text-[13px] font-bold tabular-nums text-strong"
      >
        {@section.position}
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm font-semibold text-strong">{@names.from}</span>
        <span class="flex items-center gap-1 text-sm text-default">
          <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-muted" />{@names.to}
        </span>
        <span class="mt-0.5 block text-[13px] text-muted">{@scope}</span>
      </span>
      <.badge
        id={"alignment-section-status-#{@section.position}"}
        tone={badge_tone(@status.tone)}
        class="shrink-0"
      >
        {@status.text}
      </.badge>
    </button>
    """
  end

  attr :section, :map, required: true
  attr :visits_by_position, :map, required: true

  attr :editable?, :boolean,
    default: false,
    doc: "shows the keyboard point list toggle for editable non-missing sections"

  attr :offline?, :boolean, default: false, doc: "disables Generate until reconnected"
  attr :generating?, :boolean, default: false, doc: "disables Generate while routing"

  attr :save_pending?, :boolean,
    default: false,
    doc: "disables Generate while a save review is open"

  attr :dirty?, :boolean, default: false
  attr :flagged?, :boolean, default: false

  def section_detail(assigns) do
    assigns =
      assigns
      |> assign(:repeat, repeat_labels(assigns.section, assigns.visits_by_position))
      |> assign(:guidance, section_guidance(assigns.section))
      |> assign(:draw?, draw_section?(assigns.section, assigns.editable?))
      |> assign(:generate?, generate_section?(assigns.section, assigns.editable?))
      |> assign(:more?, more_actions?(assigns.section, assigns.editable?))
      |> assign(:use_shared?, use_shared?(assigns.section))
      |> assign(
        :simplify?,
        simplify_section?(assigns.section, assigns.visits_by_position, assigns.editable?)
      )

    # Frequency sets the order: a section without a path leads with Generate
    # and Draw; a saved one leads with the point list and keeps replacing its
    # path with the rare actions.
    assigns =
      assign(assigns, :generate_lead?, assigns.generate? and assigns.section.kind == :missing)

    ~H"""
    <div id="alignment-detail" data-position={@section.position} class="rounded-card bg-canvas p-3">
      <p :if={@repeat} class="text-[13px] font-semibold text-strong">
        Visits {@repeat.from} → {@repeat.to}
      </p>
      <p class="text-[13px] text-default">{@guidance}</p>
      <div :if={@generate_lead? or @draw? or @editable?} class="mt-3 flex flex-wrap gap-2">
        <%!-- Generate street path (step 32): the street-routing entry point on
          sections with stop coordinates. Replacing saved points asks first
          through the replace dialog; nothing is written before Save (CR-9). --%>
        <button
          :if={@generate_lead?}
          type="button"
          id="alignment-generate-section"
          phx-click="alignment_generate_paths"
          phx-value-position={@section.position}
          data-commit="alignment"
          disabled={@offline? or @generating? or @save_pending?}
          title={generate_button_title(@offline?, @generating?, @save_pending?)}
          class="btn btn-outline min-h-11"
        >
          <.icon name="hero-map" class="size-4" /> Generate street path
        </button>
        <%!-- Draw manually (step 26): the primary action on sections without
          saved geometry. --%>
        <button
          :if={@draw?}
          type="button"
          id="alignment-draw"
          phx-click={
            JS.dispatch("alignment:action",
              to: "#alignment-map-root",
              detail: %{action: "draw", position: @section.position}
            )
          }
          class="btn btn-outline min-h-11"
        >
          <.icon name="hero-pencil-square" class="size-4" /> Draw manually
        </button>
        <%!-- The keyboard point list (steps 25, 30): the button dispatches a DOM
          action to the PatternAlignment hook, which owns the ignored list
          container below (CR-5). Rendered for every editable section, including
          missing ones: after Draw manually the hook holds a `set` draft, so the
          list offers "No interior points yet. Use Add midpoint to start." and
          keyboard users can complete a drawn section. Before the draw the hook
          no-ops the toggle, since a missing section without a draft is not
          editable. --%>
        <button
          :if={@editable?}
          type="button"
          id="alignment-point-list-toggle"
          phx-click={
            JS.dispatch("alignment:action",
              to: "#alignment-map-root",
              detail: %{action: "toggle_points"}
            )
          }
          class="btn btn-outline min-h-11"
          aria-expanded="false"
          aria-controls="alignment-point-list"
        >
          <.icon name="hero-list-bullet" class="size-4" /> Point list
        </button>
      </div>
      <div :if={@editable?} id="alignment-point-list" phx-update="ignore"></div>
      <%!-- More section actions (step 26): Simplify, Clear and Delete for
        saved sections, plus Use shared path on overrides beside a shared
        path. Simplify lives here (not beside Point list) because the
        server cannot see hook drafts; it renders from saved geometry. --%>
      <details :if={@more?} class="group mt-2">
        <summary class="flex min-h-11 cursor-pointer list-none items-center gap-1.5 text-[13px] font-[650] text-muted hover:text-strong [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right"
            class="size-4 transition-transform group-open:rotate-90"
          /> More section actions
        </summary>
        <div class="mt-1 grid gap-1">
          <button
            :if={@generate? and not @generate_lead?}
            type="button"
            id="alignment-generate-section"
            phx-click="alignment_generate_paths"
            phx-value-position={@section.position}
            data-commit="alignment"
            disabled={@offline? or @generating? or @save_pending?}
            title={generate_button_title(@offline?, @generating?, @save_pending?)}
            class="btn btn-outline min-h-11 justify-start"
          >
            Replace with a street path
          </button>
          <button
            :if={@simplify?}
            type="button"
            id="alignment-simplify-open"
            phx-click="alignment_open_simplify"
            phx-value-position={@section.position}
            class="btn btn-outline min-h-11 justify-start"
          >
            Simplify
          </button>
          <button
            type="button"
            id="alignment-clear"
            phx-click={
              JS.dispatch("alignment:action",
                to: "#alignment-map-root",
                detail: %{action: "clear", position: @section.position}
              )
            }
            class="btn btn-outline min-h-11 justify-start"
          >
            Clear interior points
          </button>
          <button
            :if={@use_shared?}
            type="button"
            id="alignment-use-shared"
            phx-click={
              JS.dispatch("alignment:action",
                to: "#alignment-map-root",
                detail: %{action: "use_shared", position: @section.position}
              )
            }
            class="btn btn-outline min-h-11 justify-start"
          >
            Use shared path
          </button>
          <button
            type="button"
            id="alignment-delete-open"
            phx-click="alignment_open_delete"
            phx-value-position={@section.position}
            class="btn btn-outline min-h-11 justify-start"
          >
            Delete section path
          </button>
        </div>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :tone, :string, required: true

  # Named `alignment_status_badge` (not the subspec's `status_badge`): the
  # CoreComponents `status_badge/1` import through `:html` conflicts with a
  # local of that name. This one is the daisyUI badge with symbol + text.
  def alignment_status_badge(assigns) do
    ~H"""
    <span id={@id} class={["badge", @tone]}>{@text}</span>
    """
  end

  attr :dialog, :map, default: nil, doc: "%{position, from, to} or nil"

  def delete_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-delete-dialog"
      open={@dialog != nil}
      title="Delete this section's path?"
      confirm_label="Delete path"
      cancel_label="Keep path"
      pending_label="Deleting…"
      chrome="planner"
      on_confirm="alignment_confirm_delete"
      on_cancel="alignment_close_dialog"
      described_by="alignment-delete-dialog-body"
      return_focus_id="alignment-delete-open"
    >
      <div>
        <p :if={@dialog}>
          <strong class="text-strong">{@dialog.from} → {@dialog.to}</strong>
          will have no path in this pattern. The stops and their running times stay in place.
        </p>
        <p class="mt-2 text-[13px]">
          Other patterns keep their paths. You can undo this draft change.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :map, default: nil, doc: "%{position, tolerance} or nil"

  def simplify_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-simplify-dialog"
      open={@dialog != nil}
      title="Simplify this section"
      confirm_label="Preview simplification"
      pending_label="Simplifying…"
      chrome="planner"
      on_confirm="alignment_confirm_simplify"
      on_cancel="alignment_close_dialog"
      described_by="alignment-simplify-dialog-body"
      return_focus_id="alignment-simplify-open"
    >
      <div>
        <p>Preview fewer points while keeping the stop anchors fixed.</p>
        <form
          id="alignment-simplify-tolerance-form"
          phx-change="alignment_simplify_tolerance"
          class="mt-4"
        >
          <div class="fieldset">
            <label>
              <span class="label">Maximum path deviation</span>
              <select
                id="alignment-simplify-tolerance"
                name="tolerance_m"
                class="w-full select select-lg"
              >
                <option value="5" selected={@dialog && @dialog.tolerance == 5}>
                  5 metres · preserve detail
                </option>
                <option value="10" selected={@dialog == nil or @dialog.tolerance == 10}>
                  10 metres · balanced
                </option>
                <option value="25" selected={@dialog && @dialog.tolerance == 25}>
                  25 metres · fewer points
                </option>
              </select>
            </label>
          </div>
        </form>
        <p class="mt-3 text-[13px]">
          Applies to the selected points, or to this section when none are
          selected. Stop anchors stay fixed.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :pending, :map, default: nil, doc: "save review pending a scope choice"
  attr :visits_by_position, :map, required: true
  attr :applying?, :boolean, default: false
  attr :version_name, :string, default: nil
  attr :organization_name, :string, default: nil

  # Step 28 scope dialog: per changed section the scope radios default to
  # "Only this pattern"; shared deletions list the patterns left missing;
  # replaced imports name each shape and trip count (INV-5). The radios
  # report through the form's phx-change into the pending scopes, so the
  # Save path confirm applies exactly the chosen outcome.
  def save_dialog(assigns) do
    assigns = assign(assigns, :review, save_review(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-save-dialog"
      open={@review != nil}
      title={save_dialog_title(@review)}
      confirm_label="Save path"
      pending_label="Saving…"
      pending={@applying?}
      chrome="planner"
      on_confirm="confirm_alignment_save"
      on_cancel="alignment_cancel_save"
      described_by="alignment-save-dialog-body"
      return_focus_id="alignment-save"
      size="xl"
    >
      <div :if={@review}>
        <form id="alignment-save-form" phx-change="alignment_save_choice">
          <div :for={section <- save_scope_sections(@review)} class="mt-4 first:mt-0">
            <.save_scope_fieldset
              section={section}
              pending={@pending}
              visits_by_position={@visits_by_position}
            />
          </div>
          <div
            :for={section <- save_delete_sections(@review)}
            class="mt-4 rounded-card border border-subtle p-3 first:mt-0"
          >
            <p class="text-sm font-[650] text-strong">
              {section_name(section, @visits_by_position)} will have no path in {length(
                section.affected
              )} {if(length(section.affected) == 1, do: "pattern", else: "patterns")}:
            </p>
            <ul class="mt-2 list-disc pl-5 text-sm">
              <li :for={user <- section.affected}>
                {user.route_label} · {user.pattern_label}
              </li>
            </ul>
          </div>
          <div :if={@review.replaced_shapes != []} class="mt-4 rounded-card border border-subtle p-3">
            <p class="text-sm font-[650] text-strong">Replace imported shapes</p>
            <ul class="mt-2 list-disc pl-5 text-sm">
              <li :for={entry <- @review.replaced_shapes}>
                Shape {entry.shape_id} ({entry.trip_count} {if(entry.trip_count == 1,
                  do: "trip",
                  else: "trips"
                )})
              </li>
            </ul>
            <p class="mt-2 text-[13px]">
              Shapes no trip still uses are removed. Their points are kept in change history.
            </p>
          </div>
        </form>
        <p :if={@version_name && @organization_name} class="mt-4 text-[13px]">
          Changes apply within {@version_name}, {@organization_name}.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :section, :map, required: true
  attr :pending, :map, required: true
  attr :visits_by_position, :map, required: true

  def save_scope_fieldset(assigns) do
    assigns =
      assigns
      |> assign(:names, section_names(assigns.section, assigns.visits_by_position))
      |> assign(:checked, save_scope_value(assigns.pending, assigns.section.position))
      |> assign(:rematerialize_by_pattern, rematerialize_by_pattern(assigns.section))

    ~H"""
    <fieldset>
      <legend class="mb-1 text-sm font-[650] text-strong">
        {@names.from} → {@names.to} has a shared path. Choose where to apply your edit.
      </legend>
      <.scope_option
        id={"alignment-save-scope-#{@section.position}-local"}
        name={"scopes[#{@section.position}]"}
        value="local"
        checked={@checked == "local"}
      >
        <strong class="text-strong">Only this pattern</strong>
        <span class="mt-0.5 block text-[13px] text-muted">
          Create a custom path for this pattern. Other patterns keep the shared path.
        </span>
      </.scope_option>
      <.scope_option
        id={"alignment-save-scope-#{@section.position}-shared"}
        name={"scopes[#{@section.position}]"}
        value="shared"
        checked={@checked == "shared"}
      >
        <strong class="text-strong">
          All {length(@section.affected) + 1} patterns using the shared path
        </strong>
        <span class="mt-0.5 block text-[13px] text-muted">
          <span :for={user <- @section.affected} class="block">
            {user.route_label} · {user.pattern_label} — {affected_export_note(
              user,
              @rematerialize_by_pattern
            )}
          </span>
          <span :for={user <- @section.custom_unchanged} class="block">
            {user.pattern_label} has a custom path and will not change.
          </span>
        </span>
      </.scope_option>
    </fieldset>
    """
  end

  # One choice card of the save dialog's scope question; the same card
  # `PlannerComponents.choice_cards/1` draws, with room for a list of patterns.
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, default: false
  slot :inner_block, required: true

  defp scope_option(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "mt-2 flex min-h-11 cursor-pointer items-start gap-3 rounded-control border border-control bg-white px-4 py-3 text-sm",
        "has-[:checked]:border-action has-[:checked]:bg-selection",
        "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
      ]}
    >
      <input
        type="radio"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        class="mt-0.5 size-5 shrink-0 accent-action focus-visible:outline-0"
      />
      <span class="min-w-0">{render_slot(@inner_block)}</span>
    </label>
    """
  end

  attr :pending, :map, default: nil, doc: "blocked review with %{blockers}"

  # Step 28 blocked dialog: names each pattern and trip whose stop-time
  # count no longer matches. Nothing was written.
  def blocked_dialog(assigns) do
    assigns = assign(assigns, :blockers, blocked_blockers(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-blocked-dialog"
      open={@blockers != []}
      title="This path can't be saved yet"
      confirm_label="Close"
      pending_label="Closing…"
      chrome="planner"
      on_confirm="alignment_cancel_save"
      on_cancel="alignment_cancel_save"
      cancel_label="Close"
      single_action={true}
      described_by="alignment-blocked-dialog-body"
      return_focus_id="alignment-save"
    >
      <div :if={@blockers != []}>
        <p :for={blocker <- @blockers} class="mt-2 first:mt-0">
          Trip {blocker.trip_id} in {blocker.pattern_label} has {blocker.stop_time_count} stop times, but the pattern has {blocker.visit_count} visits. Fix the
          trip's stop times, then save again. Nothing was saved.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :pending, :map, default: nil, doc: "conflict with %{draft, current}"
  attr :visits_by_position, :map, required: true

  # Step 28 conflict dialog: the latest saved sections beside the draft.
  # "Load latest" discards the draft; "Keep as local draft" rebases the
  # hook and records the positions so the next save stays local.
  def conflict_dialog(assigns) do
    assigns = assign(assigns, :current, conflict_current(assigns.pending))

    ~H"""
    <.confirm_dialog
      id="alignment-conflict-dialog"
      open={@current != []}
      title="Review the newer shared path"
      confirm_label="Keep as local draft"
      pending_label="Keeping…"
      chrome="planner"
      on_confirm="alignment_conflict_keep_local"
      on_cancel="alignment_close_dialog"
      described_by="alignment-conflict-dialog-body"
      return_focus_id="alignment-save"
      size="xl"
    >
      <div :if={@current != []}>
        <p>
          A newer shared path was saved while you were editing. Review both
          versions before applying your draft.
        </p>
        <div :for={section <- @current} class="mt-3 grid gap-3 sm:grid-cols-2">
          <div class="rounded-card border border-subtle p-3">
            <p class="text-sm font-[650] text-strong">Latest shared path</p>
            <p class="mt-1 text-[13px]">
              {conflict_section_name(section, @visits_by_position)} · {length(section.points || [])} points ·
              used by {section_usage(section)} {if(section_usage(section) == 1,
                do: "pattern",
                else: "patterns"
              )}
            </p>
          </div>
          <div class="rounded-card border border-subtle p-3">
            <p class="text-sm font-[650] text-strong">Your draft</p>
            <p class="mt-1 text-[13px]">
              {conflict_section_name(section, @visits_by_position)} · {conflict_draft_points(
                @pending,
                section.position
              )} points ·
              unsaved
            </p>
          </div>
        </div>
        <p class="mt-4 text-[13px]">
          Keep your draft as a path for this pattern, or discard it and load the latest shared path.
        </p>
        <button
          type="button"
          id="alignment-conflict-load-latest"
          phx-click="alignment_conflict_load_latest"
          class="btn btn-outline mt-3 min-h-11"
        >
          Load latest
        </button>
      </div>
    </.confirm_dialog>
    """
  end

  # --- Import a path file ------------------------------------------------
  #
  # Step 29's panel, in place of the section list while a path file is being
  # chosen: the prototype's `import-choose`, `import-pick` and `err-*` states
  # (`.specs/27-shapes-again/references/pattern-path-prototype.html`). The
  # file is read by the server, so a line is listed by the name, length and
  # point count the parser found, and each file problem gets its own message
  # (AC-22). "Check the fit" is the next step and belongs to the fit review
  # the hook drives, so this panel stops at the chosen line.

  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :file, :map, default: nil, doc: "%{step: :choose | :pick | :error, name, size} or nil"
  attr :fit, :map, default: nil, doc: "the hook's reported fit, or nil before the hook answers"
  attr :visits, :map, default: %{}, doc: "visits by position, for the names the review uses"

  def file_import_panel(assigns) do
    # A reported fit puts the panel on its third step: the line has been
    # chosen and the hook has measured it, so what the panel shows is the
    # review of that answer rather than another chooser.
    review? = not is_nil(assigns.fit)
    step = if review?, do: :review, else: assigns.file && assigns.file.step

    assigns =
      assigns
      |> assign(:step, step)
      |> assign(:review?, review?)
      |> assign(:lines, Map.get(assigns.file || %{}, :lines) || [])
      |> assign(:reading?, upload_reading?(assigns.upload))
      |> assign(:ready?, upload_ready?(assigns.upload))
      |> assign(:step_index, file_import_step_index(step))

    ~H"""
    <div id="file-import-panel" class="flex min-h-0 flex-1 flex-col">
      <div class="border-b border-subtle bg-white px-4 pb-3 pt-4">
        <button
          type="button"
          id="file-import-cancel"
          phx-click="alignment_close_file_import"
          class="inline-flex min-h-11 items-center gap-1.5 text-sm font-[650] text-action hover:underline"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Map line
        </button>
        <h2
          id="file-import-title"
          tabindex="-1"
          class="mt-1 text-base font-bold text-strong focus-visible:outline-none"
        >
          Import a path file
        </h2>
        <p :if={@step == :choose} class="mt-1 text-[13px] text-muted">
          Use a line drawn in Google My Maps, Google Earth or QGIS, or a recorded run.
          You check how it fits this pattern&rsquo;s stops first.
        </p>
        <ol class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-[13px]" aria-label="Import steps">
          <li
            :for={
              {label, index} <- Enum.with_index(["Choose a file", "Pick the line", "Check the fit"])
            }
            class={[
              "flex items-center gap-1.5",
              index == @step_index && "font-[650] text-strong",
              index != @step_index && "text-muted"
            ]}
            aria-current={index == @step_index && "step"}
          >
            <span class={[
              "flex size-5 items-center justify-center rounded-full text-[12px] font-bold",
              index < @step_index && "bg-success-bg text-success-fg",
              index == @step_index && "bg-inverse text-white",
              index > @step_index && "bg-canvas text-muted"
            ]}>
              {if index < @step_index, do: "✓", else: index + 1}
            </span>
            {label}
          </li>
        </ol>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
        <%!-- A reported fit is the whole of the panel's body: there is
          nothing left to choose, only what the hook found to review. --%>
        <.fit_review :if={@review?} fit={@fit} visits={@visits} />
        <%!-- The chooser is only useful before a file is read: the prototype's
          `import-pick` shows the file and the choice, not another dropzone. --%>
        <.form
          :if={not @review? and @step != :pick}
          for={%{}}
          id="map-line-upload-form"
          phx-change="alignment_file_validate"
          phx-submit="alignment_file_consume"
        >
          <%!-- A file that has been read does not need a second dropzone: the
          chooser collapses to a button so the file's lines or its message
          are what the panel shows. --%>
          <.upload_field
            id="map-line-file-upload"
            upload={@upload}
            label="Path file"
            help="GeoJSON, KML, KMZ or GPX, up to 10 MB. Nothing changes until you save the map line."
            appearance={if @step == :choose, do: :dropzone, else: :button}
            action_label={
              if @step == :choose,
                do: "Choose a file or drag and drop",
                else: "Choose another file"
            }
            cancel_event="alignment_cancel_file"
            state={file_upload_state(@step, @reading?)}
          />
          <button
            :if={@step == :choose and @ready?}
            type="submit"
            id="file-import-read"
            class="btn btn-primary mt-3 min-h-11 w-full"
          >
            Read this file
          </button>
        </.form>

        <div
          :if={@file != nil and @file.step in [:pick, :error]}
          id="file-import-file-row"
          class="mt-3 flex items-center gap-3 rounded-card border border-subtle bg-white py-0.5 pl-3 pr-1"
        >
          <.icon
            name={if @file.step == :error, do: "hero-exclamation-triangle", else: "hero-document"}
            class={[
              "size-5 shrink-0",
              if(@file.step == :error, do: "text-error-fg", else: "text-muted")
            ]}
          />
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-[650] text-strong" title={@file.name}>{@file.name}</p>
            <p class="text-[13px] text-muted">
              <span class="tabular-nums">{file_import_size(@file)}</span>
              <span :if={@file.step == :error}>&middot; Not used</span>
            </p>
          </div>
        </div>

        <.message
          :for={reason <- file_import_error(@file)}
          id={"file-error-#{reason}"}
          kind="error"
          title={file_import_error_title(reason)}
          class="mt-3"
        >
          {file_import_error_body(reason)}
        </.message>

        <form
          :if={@step == :pick}
          id="file-line-form"
          phx-change="alignment_file_choose"
          class="mt-4"
        >
          <fieldset>
            <legend class="text-sm font-bold text-strong">
              Which line is this pattern&rsquo;s path?
            </legend>
            <p class="mt-0.5 text-[13px] text-muted">
              The file has {length(@lines)} {if length(@lines) == 1, do: "line", else: "lines"}.
              Pick the one that follows this pattern&rsquo;s stops.
            </p>
            <div class="mt-2 grid gap-2">
              <.scope_option
                :for={{line, index} <- Enum.with_index(@lines)}
                id={"file-line-#{index}"}
                name="line"
                value={to_string(index)}
                checked={false}
              >
                <strong class="text-strong">{file_line_name(line, index)}</strong>
                <span class="mt-0.5 block text-[13px] text-muted">
                  {file_line_length(line)} &middot; {line.point_count}
                  {if line.point_count == 1, do: "point", else: "points"}
                </span>
                <span :if={line.joined_from > 1} class="mt-0.5 block text-[13px] text-muted">
                  Joined from {line.joined_from} pieces of the file
                </span>
              </.scope_option>
            </div>
          </fieldset>
        </form>
      </div>

      <div class="border-t border-subtle bg-white px-4 py-3">
        <%= if @review? do %>
          <%!-- AC-24: a line that runs the other way cannot be drafted, and
            the reason sits beside the button that is disabled because of it. --%>
          <p id="fit-footer-note" class="text-[13px] text-muted">
            <span :if={@fit.direction == "reversed"} class="font-semibold text-error-fg">
              Reverse the line to continue. It runs the other way from this pattern.
            </span>
            <span :if={@fit.direction != "reversed"}>
              Nothing is saved until you save the map line.
            </span>
          </p>
          <div class="mt-2 grid gap-2">
            <button
              type="button"
              id="file-import-restart"
              phx-click="alignment_open_file_import"
              class="btn btn-outline min-h-11"
            >
              Choose another file
            </button>
            <button
              type="button"
              id="fit-create-draft"
              phx-click="alignment_create_file_draft"
              disabled={@fit.direction == "reversed"}
              title={if @fit.direction == "reversed", do: "Reverse the line first", else: nil}
              class="btn btn-primary min-h-11"
            >
              Create editable draft
            </button>
          </div>
        <% else %>
          <p class="text-[13px] text-muted">
            Nothing is saved until you save the map line.
          </p>
          <button
            :if={@step == :pick}
            type="button"
            id="file-import-restart"
            phx-click="alignment_open_file_import"
            class="btn btn-outline mt-2 min-h-11 w-full"
          >
            Choose another file
          </button>
        <% end %>
      </div>
    </div>

    <%!-- The hook's fit arrives without a click of the editor's own, so the
      panel's headline takes focus when it lands (a colocated hook, no inline
      script). --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FileImportFocus">
      export default {
        mounted() {
          this.handleEvent("alignment:file_fit", () => {
            this.el.querySelector("#file-import-title")?.focus()
          })
        }
      }
    </script>
    """
  end

  defp file_upload_state(:error, _reading?), do: :idle
  defp file_upload_state(_step, true), do: :uploading
  defp file_upload_state(_step, _reading?), do: :idle

  # The panel names the file's own problems; a missing or unknown reason still
  # leaves the panel open with an honest message rather than a blank step.
  defp file_import_error(%{step: :error, error: reason}), do: [reason]
  defp file_import_error(_file), do: []

  defp file_import_error_title(:unsupported), do: "Shapefiles can’t be imported yet"

  defp file_import_error_title(:network_link),
    do: "This KMZ links to a map online and has no line in it"

  defp file_import_error_title(:points_only), do: "This file has points, not a line"
  defp file_import_error_title(:areas_only), do: "This file has areas, not a line"

  defp file_import_error_title(:swapped),
    do: "This file lists latitude and longitude the wrong way round"

  defp file_import_error_title(:too_large), do: "This file expands to more than the limit allows"
  defp file_import_error_title(:empty), do: "This file has no line in it"
  defp file_import_error_title(:unreadable), do: "This file couldn’t be read"
  defp file_import_error_title(_reason), do: "This file could not be used"

  defp file_import_error_body(:unsupported),
    do:
      "Export the line from QGIS or ArcGIS as GeoJSON, or from Google Earth as KML, then choose that file."

  defp file_import_error_body(:network_link),
    do:
      "Google My Maps writes a link like this when “Keep data up to date with network link KML” is on. Export again with it off, then choose the new file."

  defp file_import_error_body(:points_only),
    do:
      "It looks like a list of stops. A path file needs a line that follows the road. In Google My Maps, export the layer with the driving directions."

  defp file_import_error_body(:areas_only),
    do:
      "A map line follows the road from stop to stop. If this is a service area, use it on the Flex pages instead."

  defp file_import_error_body(:swapped),
    do: "GeoJSON lists longitude first; this file seems to list latitude first."

  defp file_import_error_body(:too_large),
    do: "It may hold a whole road network. Export only the route’s line, then choose that file."

  defp file_import_error_body(:empty),
    do: "The file has no line to draw. Export the route’s line, then choose that file."

  defp file_import_error_body(:unreadable),
    do: "It’s empty or damaged. Export it again, then choose the new file."

  defp file_import_error_body(_reason),
    do: "Choose the file again. Nothing has changed on this pattern."

  defp file_line_name(%{name: nil}, index), do: "Line #{index + 1}"
  defp file_line_name(%{name: ""}, index), do: "Line #{index + 1}"
  defp file_line_name(%{name: name}, _index), do: name

  defp file_line_length(%{length_m: length_m}) when is_number(length_m),
    do: "#{:erlang.float_to_binary(length_m / 1000, decimals: 1)} km"

  defp file_line_length(_line), do: "—"

  defp file_import_size(%{size: size}) when is_integer(size) and size < 1_000_000,
    do: "#{Float.round(size / 1_000, 1)} KB"

  defp file_import_size(%{size: size}) when is_integer(size),
    do: "#{Float.round(size / 1_000_000, 1)} MB"

  defp file_import_size(_file), do: ""

  # The step markers follow the panel's own state: the pick is step two, the
  # fit review step three, and a file problem stays on step one because
  # nothing has been chosen yet.
  defp file_import_step_index(:review), do: 2
  defp file_import_step_index(:pick), do: 1
  defp file_import_step_index(_step), do: 0

  # An entry that has not finished arriving keeps the reading state honest
  # instead of offering a line; a refused entry never appears here at all.
  defp upload_reading?(%Phoenix.LiveView.UploadConfig{entries: entries}) when is_list(entries) do
    Enum.any?(entries, &(not &1.done?))
  end

  defp upload_reading?(_upload), do: false

  defp upload_ready?(%Phoenix.LiveView.UploadConfig{entries: entries}) when is_list(entries),
    do: Enum.any?(entries, & &1.done?)

  defp upload_ready?(_upload), do: false

  # --- fit review (step 31) ----------------------------------------------
  #
  # The hook's own measurement of the file line against this pattern's stops,
  # in the prototype's `import-review`, `import-review-reversed`,
  # `import-short` and `import-good` states (AC-24). Nothing here is measured
  # again: every number is the one the hook reported, and the only work this
  # side does is naming the stops those numbers are about (rule 11, INV-5).
  # Findings come in the reference's order — direction, then the ends, then
  # the stops more than 100 m (330 ft) from the line.
  attr :fit, :map, required: true, doc: "the hook's reported fit (`@file_fit`)"
  attr :visits, :map, default: %{}, doc: "visits by position, for the names the findings use"

  def fit_review(assigns) do
    fit = assigns.fit

    assigns =
      assigns
      |> assign(:first_stop, stop_name(assigns.visits, first_position(assigns.visits)))
      |> assign(:last_stop, stop_name(assigns.visits, last_position(assigns.visits)))
      |> assign(:far, Enum.map(fit.far, &far_finding(&1, assigns.visits)))
      |> assign(:blocked?, fit.direction == "reversed")

    ~H"""
    <div id="file-fit-review" class="mt-1">
      <div class="flex flex-wrap items-end justify-between gap-x-4 gap-y-1">
        <p id="file-fit-headline" tabindex="-1" class="focus-visible:outline-none">
          <strong class="font-display text-[26px] font-semibold tabular-nums text-strong">
            {@fit.within} of {@fit.visit_count}
          </strong>
          <span class="text-sm text-default">stops within 330 ft</span>
        </p>
        <p id="file-fit-length" class="text-[13px] tabular-nums text-muted">
          {file_line_length(@fit)}
        </p>
      </div>

      <div class="mt-3 grid gap-2">
        <%!-- The three directions get three different answers. "unknown" is
          the loop case: both end visits land in the same place on the line,
          so there is no direction to report and nothing to block. --%>
        <.message
          :if={@blocked?}
          id="fit-direction-reversed"
          kind="error"
          title="This line runs the other way"
        >
          This pattern runs from {@first_stop} to {@last_stop}. This line&rsquo;s stops are in the
          opposite order, so its sections would be measured against the wrong end.
          <:action>
            <button
              type="button"
              id="fit-reverse"
              phx-click="alignment_reverse_file_line"
              class="btn btn-outline min-h-11"
            >
              <.icon name="hero-arrows-right-left" class="size-4" /> Reverse line
            </button>
          </:action>
        </.message>

        <.message
          :if={@fit.direction == "unknown"}
          id="fit-direction-unknown"
          kind="info"
          title="This line runs the same way at both ends"
        >
          Both of this pattern&rsquo;s end stops land in the same place on it, so the fit cannot
          say which way it runs. Check the arrows on the map before you draft it.
        </.message>

        <.message
          :if={not @fit.reaches_start}
          id="fit-start"
          kind="warning"
          title={"The line starts after " <> @first_stop}
        >
          It doesn&rsquo;t reach this pattern&rsquo;s first stop, so that section comes in without a
          path.
        </.message>

        <.message
          :if={not @fit.reaches_end}
          id="fit-end"
          kind="warning"
          title={"The line ends before " <> @last_stop}
        >
          It stops short of this pattern&rsquo;s last stop, so that section comes in without a path.
        </.message>

        <.message
          :if={@far == [] and @fit.reaches_start and @fit.reaches_end}
          id="fit-ok"
          kind="success"
          title="Every stop is on the line"
        >
          All {@fit.visit_count} stops are within 330 ft of it, and it runs from {@first_stop} to {@last_stop}.
        </.message>

        <.message
          :if={@far != []}
          id="fit-far"
          kind="warning"
          title={fit_far_title(@far)}
        >
          These stops are more than 330 ft from the line:
          <ul class="mt-1 grid list-disc pl-5">
            <li :for={stop <- @far} id={stop.id}>{stop.name}, {stop.distance} from the line</li>
          </ul>
        </.message>
      </div>
    </div>
    """
  end

  defp fit_far_title([first]), do: "#{first.name} is #{first.distance} from the line"
  defp fit_far_title(far), do: "#{length(far)} stops are more than 330 ft from the line"

  defp far_finding(far, visits) do
    %{
      id: "fit-far-#{far.position}",
      name: stop_name(visits, far.position),
      distance: fit_distance_ft(far.distance_m)
    }
  end

  # A far stop the model carries no name for is named by its position in the
  # pattern, which is what the section list calls it too.
  defp stop_name(visits, position) when is_map(visits) and is_integer(position) do
    case Map.get(visits, position) do
      %{name: name} when is_binary(name) and name != "" -> name
      _other -> "Stop #{position}"
    end
  end

  defp stop_name(_visits, _position), do: "this pattern's last stop"

  defp first_position(visits) when map_size(visits) == 0, do: nil
  defp first_position(visits), do: visits |> Map.keys() |> Enum.min()

  defp last_position(visits) when map_size(visits) == 0, do: nil
  defp last_position(visits), do: visits |> Map.keys() |> Enum.max()

  # The hook measures in metres (INV-1). 100 m is the one threshold the fit
  # and the conversion share; this is where it becomes the 330 ft the review
  # reads in.
  @fit_feet_per_meter 3.28084

  defp fit_distance_ft(distance_m) when is_number(distance_m) do
    "#{round(distance_m * @fit_feet_per_meter / 10) * 10} ft"
  end

  defp fit_distance_ft(_distance_m), do: "more than 330 ft"

  # --- imported line card (imported shapes) ------------------------------

  attr :card, :map, default: nil, doc: "%{shape_id} when the imported-line card is open"
  attr :alignment, :map, default: nil, doc: "the Gtfs.alignment_editor/4 read model"
  attr :fit, :map, default: nil, doc: "the hook's reported fit for the shown shape, or nil"
  attr :visits, :map, default: %{}, doc: "visits by position, for the names the review uses"

  # Step 32 imported line card: the review a dialog used to hold, in the
  # panel itself (the prototype's `imported-shape` state). The shape's own
  # numbers come from the model, the fit from the hook's report through
  # `fit_review/1`, and one card covers both one shape and divergent shapes
  # by rendering the chooser when the trips disagree (INV-5, no modal).
  def imported_line_card(assigns) do
    shapes = import_shapes(assigns.alignment)

    assigns =
      assigns
      |> assign(:shapes, shapes)
      |> assign(:shape, import_shape(shapes, assigns[:card]))
      |> assign(:total_trips, import_total_trips(assigns.alignment))
      |> assign(:visit_count, import_visit_count(assigns.alignment))
      |> assign(:blocked?, assigns[:fit] != nil and assigns[:fit].direction == "reversed")

    ~H"""
    <div
      :if={@shape}
      id="imported-line-card"
      class="mx-4 mt-4 rounded-card border border-subtle bg-white"
    >
      <div class="px-4 py-3">
        <h3 id="imported-line-card-title" class="text-sm font-bold text-strong">
          Imported shape {@shape.shape_id}
        </h3>
        <p class="mt-0.5 text-[13px] text-muted">
          <span class="tabular-nums">{import_shape_km(@shape)}</span>
          &middot; <span class="tabular-nums">{length(@shape.points || [])}</span>
          points &middot; used by the {@shape.trip_count} {if @shape.trip_count == 1,
            do: "trip",
            else: "trips"} on this pattern &middot; {@visit_count} {if @visit_count == 1,
            do: "visit",
            else: "visits"}
        </p>
      </div>

      <form
        :if={length(@shapes) > 1}
        id="imported-shape-form"
        phx-change="alignment_import_choice"
        class="border-t border-subtle px-4 py-3"
      >
        <fieldset>
          <legend class="text-sm font-bold text-strong">
            Which imported shape is this pattern&rsquo;s path?
          </legend>
          <p class="mt-0.5 text-[13px] text-muted">
            This pattern&rsquo;s trips reference {length(@shapes)} shapes. They are retained until you
            explicitly replace them, and the fit below is measured on the one you choose.
          </p>
          <div class="mt-2 grid gap-2">
            <.scope_option
              :for={shape <- @shapes}
              id={"imported-shape-#{shape.shape_id}"}
              name="import_shape"
              value={shape.shape_id}
              checked={import_selected?(@card, shape, @shapes)}
            >
              <strong class="text-strong">Shape {shape.shape_id}</strong>
              <span class="mt-0.5 block text-[13px] text-muted">
                {shape.trip_count} {if shape.trip_count == 1, do: "trip", else: "trips"} &middot; {import_shape_km(
                  shape
                )} &middot; {length(shape.points || [])} points
              </span>
            </.scope_option>
          </div>
        </fieldset>
        <p class="mt-3">
          <.badge tone="warning" icon="hero-exclamation-triangle">
            Saving the replacement would affect all {@total_trips} trips.
          </.badge>
        </p>
      </form>

      <div class="border-t border-subtle px-4 py-3">
        <%!-- The fit is the hook's own measurement of the chosen shape
          against this pattern's stops, so the card waits for it rather
          than repeating the work on the server (INV-5). --%>
        <.fit_review :if={@fit} fit={@fit} visits={@visits} />
        <p :if={is_nil(@fit)} id="imported-line-checking" class="text-[13px] text-muted">
          Checking this shape against the pattern&rsquo;s stops&hellip;
        </p>
      </div>

      <div class="border-t border-subtle px-4 py-3">
        <p id="imported-line-note" class="text-[13px] text-muted">
          <span :if={@blocked?} class="font-semibold text-error-fg">
            Reverse the line to continue. It runs the other way from this pattern.
          </span>
          <span :if={not @blocked?}>
            Nothing changes until you save. Until then, trips and exports keep shape {@shape.shape_id}.
          </span>
        </p>
        <div class="mt-2 flex flex-wrap gap-2">
          <button
            type="button"
            id="imported-line-close"
            phx-click="alignment_close_import"
            class="btn btn-outline min-h-11"
          >
            Close
          </button>
          <button
            type="button"
            id="imported-line-draft"
            phx-click="alignment_confirm_import"
            disabled={@blocked?}
            title={if @blocked?, do: "Reverse the line first", else: nil}
            class="btn btn-primary min-h-11"
          >
            <.icon name="hero-pencil-square" class="size-4" /> Create editable draft
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp import_shape(shapes, %{shape_id: shape_id}) when is_list(shapes),
    do: Enum.find(shapes, &(&1.shape_id == shape_id))

  defp import_shape(_shapes, _card), do: nil

  attr :dialog, :map,
    default: nil,
    doc: "%{positions, from, to} when the generate replace dialog is open"

  def generate_replace_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-generate-replace-dialog"
      open={@dialog != nil}
      title="Replace the drawn path?"
      confirm_label="Generate new path"
      pending_label="Generating…"
      chrome="planner"
      on_confirm="alignment_confirm_generate"
      on_cancel="alignment_close_dialog"
      described_by="alignment-generate-replace-dialog-body"
      return_focus_id="alignment-generate-section"
    >
      <div>
        <p :if={@dialog}>
          <strong class="text-strong">{@dialog.from} → {@dialog.to}</strong>
          already has a path. Generating replaces it with a suggested street path.
        </p>
        <p class="mt-2 text-[13px]">
          Nothing is written until you save. You can undo this draft change.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :dialog, :any, default: nil, doc: "non-nil when the discard dialog is open"

  def discard_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-discard-dialog"
      open={@dialog != nil}
      title="Discard unsaved changes?"
      confirm_label="Discard changes"
      cancel_label="Keep editing"
      pending_label="Discarding…"
      chrome="planner"
      on_confirm="alignment_confirm_discard"
      on_cancel="alignment_close_dialog"
      described_by="alignment-discard-dialog-body"
      return_focus_id="alignment-discard"
    >
      <div>
        <p>
          Your saved path will stay unchanged. The edits in this draft will be lost.
        </p>
      </div>
    </.confirm_dialog>
    """
  end

  attr :open, :boolean, required: true
  attr :version_name, :string, default: nil
  attr :organization_name, :string, default: nil

  def help_dialog(assigns) do
    ~H"""
    <.confirm_dialog
      id="alignment-help-dialog"
      open={@open}
      title="Draw the path your bus takes"
      confirm_label="Close"
      pending_label="Closing…"
      chrome="planner"
      on_confirm="alignment_close_help"
      on_cancel="alignment_close_help"
      cancel_label="Close"
      single_action={true}
      described_by="alignment-help-dialog-body"
      return_focus_id="alignment-help"
    >
      <ol class="list-decimal space-y-3 pl-5">
        <li>
          <strong class="text-strong">Select a section.</strong>
          Choose two consecutive stop visits from the list.
        </li>
        <li>
          <strong class="text-strong">Generate or draw the path.</strong>
          A generated street path is a starting point. Check bus lanes, turns and terminal access.
          The stop locations stay fixed.
        </li>
        <li>
          <strong class="text-strong">Review shared sections.</strong>
          A path shared with other patterns asks who should receive the change.
        </li>
        <li>
          <strong class="text-strong">Review and save.</strong>
          Saving writes the path so exports include it in shapes.txt.
        </li>
      </ol>
      <p :if={@version_name && @organization_name} class="mt-4 text-[13px]">
        Saved paths belong to {@organization_name} in version {@version_name}.
      </p>
    </.confirm_dialog>
    """
  end

  # The badge tones the status helpers still name as daisyUI classes.
  defp badge_tone("badge-error"), do: "error"
  defp badge_tone("badge-warning"), do: "warning"
  defp badge_tone("badge-success"), do: "success"
  defp badge_tone(_tone), do: "neutral"

  # Generate needs stop coordinates, like Draw, and additionally offers
  # replacing a saved path (the replace dialog asks first). Blocked
  # sections keep their guidance instead: generation cannot fix them.
  defp generate_section?(%{kind: kind}, true) when kind in [:missing, :override, :shared],
    do: true

  defp generate_section?(_section, _editable?), do: false

  # The first-alignment overlay shows while every section is still missing
  # and an editor can generate. Viewers never see generation controls.
  defp generate_overlay?(%{sections: [_ | _] = sections}, true),
    do: Enum.all?(sections, &(&1.kind == :missing))

  defp generate_overlay?(_alignment, _editable?), do: false

  defp first_missing_position(%{sections: sections}) do
    case Enum.find(sections, &(&1.kind == :missing)) do
      %{position: position} -> position
      nil -> nil
    end
  end

  defp first_missing_position(_alignment), do: nil

  defp generate_notice_body(%{failures: failures}) do
    failures
    |> Enum.map(fn %{from: from, to: to} -> "#{from} → #{to}" end)
    |> Enum.map_join("; ", & &1)
    |> case do
      "" -> "Street routing found no path. Draw the section or try again."
      names -> "#{names} may be unreachable by street routing. Draw the section or try again."
    end
  end

  defp generate_notice_body(_notice),
    do: "Street routing found no path. Draw the section or try again."

  defp generate_draw_position(%{failures: [%{position: position} | _]}), do: position
  defp generate_draw_position(_notice), do: nil

  defp generate_button_title(true, _generating?, _save_pending?),
    do: "Reconnect before generating"

  defp generate_button_title(_offline?, true, _save_pending?),
    do: "Generation is already running"

  defp generate_button_title(_offline?, _generating?, true),
    do: "Finish or cancel the open save before generating"

  defp generate_button_title(_offline?, _generating?, _save_pending?), do: nil

  defp generate_all_title(true, _save_pending?), do: "Reconnect before generating"

  defp generate_all_title(_offline?, true),
    do: "Finish or cancel the open save before generating"

  defp generate_all_title(_offline?, _save_pending?), do: nil

  # Draw is the primary action on sections without saved geometry:
  # missing sections, and blocked zero-length connectors whose anchors
  # resolve. A blocked section without coordinates cannot be drawn.
  defp draw_section?(%{kind: :missing}, true), do: true

  defp draw_section?(%{kind: :blocked, blocked_reason: reason}, true),
    do: reason != :no_coordinates

  defp draw_section?(_section, _editable?), do: false

  # Clear, Delete (and Simplify below) act on saved geometry.
  defp more_actions?(%{kind: kind}, true) when kind in [:override, :shared],
    do: true

  defp more_actions?(_section, _editable?), do: false

  defp use_shared?(%{kind: :override, shared_points: shared})
       when is_list(shared) and shared != [],
       do: true

  defp use_shared?(_section), do: false

  # Simplify needs at least 4 anchor-to-anchor points: both anchors plus
  # at least 2 interior points. Sections without resolvable anchors never
  # reach 4.
  defp simplify_section?(section, visits_by_position, true) do
    interior = length(section.points || [])
    anchors = if section_anchors?(section, visits_by_position), do: 2, else: 0
    anchors + interior >= 4
  end

  defp simplify_section?(_section, _visits, _editable?), do: false

  defp section_anchors?(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    visit_coords?(from) and visit_coords?(to)
  end

  defp visit_coords?(%{lat: lat, lon: lon})
       when is_number(lat) and is_number(lon),
       do: true

  defp visit_coords?(_visit), do: false

  defp visits_by_position(nil), do: %{}

  defp visits_by_position(alignment) do
    Map.new(alignment.visits, &{&1.position, &1})
  end

  defp section_names(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    %{from: Map.get(from, :name, ""), to: Map.get(to, :name, "")}
  end

  defp selected_section(nil, _state), do: nil

  defp selected_section(alignment, state) do
    wanted = (state && state[:selected]) || 1
    Enum.find(alignment.sections, &(&1.position == wanted)) || List.first(alignment.sections)
  end

  defp section_status(%{kind: :missing}), do: %{text: "! Missing", tone: "badge-error"}
  defp section_status(%{kind: :blocked}), do: %{text: "⚠ Blocked", tone: "badge-error"}
  defp section_status(_section), do: %{text: "✓ Saved", tone: "badge-success"}

  # Draft badges (step 27 guards): a dirty section reads ◷ Unsaved even
  # when its saved kind is Saved/Shared, and a flagged section asks for
  # review. Text plus symbol, never color alone.
  defp draft_status(_section, true, _flagged?),
    do: %{text: "◷ Unsaved", tone: "badge-warning"}

  defp draft_status(_section, _dirty?, true),
    do: %{text: "Check this section", tone: "badge-warning"}

  defp draft_status(section, _dirty?, _flagged?), do: section_status(section)

  defp dirty_positions(%{dirty_positions: positions}) when is_list(positions),
    do: positions

  defp dirty_positions(_state), do: []

  defp flagged_positions(%{flagged_positions: positions}) when is_list(positions),
    do: positions

  defp flagged_positions(_state), do: []

  defp dirty_header_status([_ | _] = _dirty, _status),
    do: %{text: "◷ Unsaved changes", tone: "badge-warning"}

  defp dirty_header_status(_dirty, status), do: status

  defp section_scope(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})

    if String.contains?(Map.get(from, :label, ""), "/") or
         String.contains?(Map.get(to, :label, ""), "/") do
      "Visit #{section.position} → #{section.position + 1}"
    else
      section_scope(section)
    end
  end

  defp section_scope(%{kind: :shared, shared_users: users}) when is_integer(users),
    do: "Shared by #{users} patterns"

  defp section_scope(%{kind: :shared}), do: "Shared"
  defp section_scope(%{kind: :override}), do: "Custom path"
  defp section_scope(_section), do: "This pattern"

  defp header_status(nil), do: list_status_parts(nil)

  defp header_status(alignment), do: list_status_parts(alignment.status)

  # Six-state Route › Patterns wording shared by the Alignment task header
  # and the patterns-list cell (step 35): symbol + text, never colour alone.
  defp list_status_parts(nil), do: %{text: "Not exported", tone: "badge-ghost"}

  defp list_status_parts(status) do
    cond do
      status.missing > 0 -> %{text: "! #{status.missing} missing", tone: "badge-error"}
      status.blocked > 0 -> %{text: "⚠ Blocked", tone: "badge-error"}
      status.export == :current -> %{text: "✓ Exported", tone: "badge-success"}
      status.export == :stale -> %{text: "◷ Out of date", tone: "badge-warning"}
      status.export == :imported -> %{text: "Imported shape", tone: "badge-ghost"}
      true -> %{text: "Not exported", tone: "badge-ghost"}
    end
  end

  defp footer_status(nil),
    do: %{word: "Not exported", sentence: "Draw the missing paths to export this pattern."}

  # The footer answers what the export contains, so a present or imported
  # shape reports its export state even when sections are missing; the header
  # badge already summarizes section completeness.
  defp footer_status(alignment) do
    status = alignment.status

    cond do
      status.export == :current ->
        %{word: "✓ Exported", sentence: "Saved paths are included in shapes.txt."}

      status.export == :stale ->
        %{word: "◷ Out of date", sentence: "Saving again refreshes the exported shape."}

      status.export == :imported ->
        %{word: "Imported shape", sentence: "The export uses the imported shape."}

      status.missing > 0 or status.blocked > 0 ->
        %{word: "Incomplete", sentence: "Add the missing paths to complete this pattern."}

      true ->
        %{word: "Not exported", sentence: "Draw the missing paths to export this pattern."}
    end
  end

  defp save_title(alignment, true) do
    status = alignment.status

    cond do
      status.missing > 0 or status.blocked > 0 ->
        "Add the missing paths to complete this pattern."

      status.export == :current ->
        "Saved paths are included in shapes.txt."

      true ->
        "Saving is enabled once paths can be drawn."
    end
  end

  defp saved_count(nil), do: 0

  defp saved_count(alignment) do
    Enum.count(alignment.sections, &(&1.kind in [:override, :shared]))
  end

  defp missing_count(nil), do: 0

  defp missing_count(alignment) do
    Enum.count(alignment.sections, &(&1.kind == :missing))
  end

  defp save_button_title(_alignment, false, _offline?, _applying?, _dirty?, _generating?),
    do: "Only editors can save alignment."

  defp save_button_title(_alignment, true, true, _applying?, _dirty?, _generating?),
    do: "Reconnect before saving."

  defp save_button_title(_alignment, true, _offline?, true, _dirty?, _generating?),
    do: "Saving your alignment…"

  defp save_button_title(_alignment, true, _offline?, _applying?, _dirty?, true),
    do: "Finish or cancel generation before saving."

  defp save_button_title(_alignment, true, _offline?, _applying?, [], _generating?),
    do: "Edit a path to enable saving."

  defp save_button_title(alignment, true, _offline?, _applying?, _dirty?, _generating?),
    do: save_title(alignment, true)

  defp save_notice_message({:error, message}) when is_binary(message), do: message
  defp save_notice_message(_notice), do: "Your draft is still here. Try saving again."

  # Step 29 import notice/dialog copy. A single imported shape keeps the
  # "Imported path" title with a review entry point; divergent shapes
  # name their count and keep both originals until an explicit save.
  defp import_shapes(%{imported_shapes: shapes}) when is_list(shapes), do: shapes
  defp import_shapes(_alignment), do: []

  defp import_notice_title(alignment) do
    case import_shapes(alignment) do
      [_single] -> "Imported path · original shape retained"
      [_ | _] = shapes -> "This pattern uses #{length(shapes)} imported shapes"
      [] -> "Imported path · original shape retained"
    end
  end

  defp import_notice_body(alignment) do
    case import_shapes(alignment) do
      [_single] ->
        "This pattern already has a shape. Review it before converting it into editable sections."

      [_first, _second] ->
        "Choose how to handle these paths before editing. Export retains both originals."

      [_ | _] = shapes ->
        "Choose how to handle these paths before editing. Export retains all #{length(shapes)} originals."

      [] ->
        "This pattern already has a shape. Review it before converting it into editable sections."
    end
  end

  defp import_notice_cta(alignment) do
    if length(import_shapes(alignment)) > 1, do: "Compare shapes", else: "Review imported path"
  end

  defp import_total_trips(alignment) do
    alignment |> import_shapes() |> Enum.map(& &1.trip_count) |> Enum.sum()
  end

  defp import_visit_count(%{visits: visits}) when is_list(visits), do: length(visits)
  defp import_visit_count(_alignment), do: 0

  defp import_shape_km(%{length_m: length_m}) when is_number(length_m) do
    "#{:erlang.float_to_binary(length_m / 1000, decimals: 1)} km"
  end

  defp import_shape_km(_shape), do: "—"

  defp import_selected?(%{shape_id: selected}, %{shape_id: shape_id}, _shapes),
    do: selected == shape_id

  defp import_selected?(_dialog, %{shape_id: shape_id}, [first | _]),
    do: shape_id == first.shape_id

  defp import_selected?(_dialog, _shape, _shapes), do: false

  # The save dialog shows the pending review; any other pending kind
  # leaves it closed.
  defp save_review(%{kind: :save, review: review}), do: review
  defp save_review(_pending), do: nil

  defp save_dialog_title(nil), do: "Who should use this path?"

  defp save_dialog_title(review) do
    if length(save_scope_sections(review)) + length(save_delete_sections(review)) == 1 do
      "Who should use this path?"
    else
      "Who should use these paths?"
    end
  end

  defp save_scope_sections(nil), do: []

  defp save_scope_sections(review) do
    Enum.filter(review.sections, &(&1.action == :choose_scope))
  end

  defp save_delete_sections(nil), do: []

  defp save_delete_sections(review) do
    Enum.filter(review.sections, &(&1.action == :delete_shared and &1.affected != []))
  end

  defp section_name(section, visits_by_position) do
    names = section_names(section, visits_by_position)
    "#{names.from} → #{names.to}"
  end

  defp save_scope_value(%{scopes: scopes}, position),
    do: Map.get(scopes, to_string(position), "local")

  defp save_scope_value(_pending, _position), do: "local"

  defp rematerialize_by_pattern(section) do
    Map.new(section.shared_rematerialize, &{&1.route_pattern_id, &1})
  end

  # What a shared save does to each affected pattern's export, from the
  # review's rematerialization plan: shape-owning complete patterns move
  # to the new path, other shape owners keep theirs, and the rest keep
  # their imported shapes until their own save.
  defp affected_export_note(user, rematerialize_by_pattern) do
    case Map.get(rematerialize_by_pattern, user.route_pattern_id) do
      %{trips: trips} ->
        "updates its exported shape (#{trips} #{if(trips == 1, do: "trip", else: "trips")})"

      nil when user.owns_shape? ->
        "keeps its current shape"

      nil ->
        "keeps its imported shape"
    end
  end

  defp blocked_blockers(%{kind: :blocked, blockers: blockers}), do: blockers
  defp blocked_blockers(_pending), do: []

  defp conflict_current(%{kind: :conflict, current: current}) when is_list(current),
    do: current

  defp conflict_current(_pending), do: []

  defp conflict_section_name(section, visits_by_position) do
    section_name(section, visits_by_position)
  end

  defp section_usage(%{shared_users: users}) when is_integer(users), do: users
  defp section_usage(_section), do: 1

  defp conflict_draft_points(%{draft: draft}, position) when is_list(draft) do
    draft
    |> Enum.find(&(draft_position(&1) == position))
    |> draft_point_count()
  end

  defp conflict_draft_points(_pending, _position), do: 0

  defp draft_position(%{"position" => position}) when is_integer(position), do: position
  defp draft_position(%{position: position}) when is_integer(position), do: position
  defp draft_position(_entry), do: nil

  defp draft_point_count(%{"points" => points}) when is_list(points), do: length(points)
  defp draft_point_count(%{points: points}) when is_list(points), do: length(points)
  defp draft_point_count(_entry), do: 0

  defp section_guidance(%{kind: :missing}),
    do: "This section has no saved path. Draw where the bus travels."

  defp section_guidance(%{kind: :blocked, blocked_reason: :no_coordinates}),
    do: "A stop on this section has no coordinates, so no path can be drawn."

  defp section_guidance(%{kind: :blocked}),
    do: "Both ends of this section are at the same location, so no path can be drawn."

  defp section_guidance(%{kind: :shared, shared_users: users}) when is_integer(users) do
    others = max(users - 1, 0)
    "This section has a saved path. Used by this pattern and #{others} others."
  end

  defp section_guidance(%{kind: :shared}), do: "This section has a saved path."
  defp section_guidance(_section), do: "This section has a saved path for this pattern."

  defp repeat_labels(section, visits_by_position) do
    from = Map.get(visits_by_position, section.position, %{})
    to = Map.get(visits_by_position, section.position + 1, %{})
    from_label = Map.get(from, :label, "")
    to_label = Map.get(to, :label, "")

    if String.contains?(from_label, "/") or String.contains?(to_label, "/") do
      %{from: from_label, to: to_label}
    else
      nil
    end
  end
end
