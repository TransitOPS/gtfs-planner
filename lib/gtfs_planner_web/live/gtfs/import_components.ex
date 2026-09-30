defmodule GtfsPlannerWeb.Gtfs.ImportComponents do
  @moduledoc """
  Presentation for the Import page: the head-band cards each import state is
  drawn in, the file chooser with its entry list, the rows of unfinished imports,
  the station-review rows and the counts a finished import reports.

  These are function components over values `ImportLive` has already resolved.
  They own wording and markup only; every event, upload and durable-state
  decision stays in the LiveView. Wording follows the design system: what
  happened, what it left behind, and what to do next, with reason codes and
  file detail kept in a disclosure.

  The classes come from the application design-system tokens in
  `assets/css/app.css`, so the page needs only the shared `ds-page` scope.
  """
  use Phoenix.Component
  use GtfsPlannerWeb, :verified_routes

  import GtfsPlannerWeb.CoreComponents, only: [icon: 1]
  import GtfsPlannerWeb.ResultComponents, only: [tone_badge: 1]

  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlannerWeb.Components.RouteIdentity
  alias GtfsPlannerWeb.Components.TransitPresentation
  alias GtfsPlannerWeb.Gtfs.LeftOutWording

  @doc """
  A card with the design system's head band: a title and one line under it on the
  canvas ground, an optional badge at the right, and the body below.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :badge
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={"#{@id}-title"}
      class={["overflow-clip rounded-card border border-subtle bg-white", @class]}
      {@rest}
    >
      <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-b border-subtle bg-canvas px-5 py-4">
        <div class="min-w-0">
          <h2
            id={"#{@id}-title"}
            class="text-lg font-bold leading-snug tracking-[-0.01em] text-strong [overflow-wrap:anywhere]"
          >
            {@title}
          </h2>
          <p :if={@subtitle} class="mt-0.5 text-[13px] text-muted">{@subtitle}</p>
        </div>
        {render_slot(@badge)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Counts as large figures under a small label, one per column. `items` are
  `{id, label, value}`; the id lets a test or a link target one figure.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :class, :string, default: "sm:grid-cols-4"

  def figures(assigns) do
    ~H"""
    <dl id={@id} class={["m-0 grid grid-cols-2 gap-x-4 gap-y-4", @class]}>
      <div :for={{id, label, value} <- @items} class="min-w-0">
        <dt class="text-[13px] text-muted">{label}</dt>
        <dd
          id={id}
          class="m-0 font-display text-[30px] font-semibold leading-tight tabular-nums text-strong"
        >
          {value}
        </dd>
      </div>
    </dl>
    """
  end

  @doc """
  A link inside a sentence. The label is an attribute so no whitespace can
  land inside the anchor and show as a gap before the punctuation that follows.
  """
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :class, :string, default: "font-semibold text-action hover:underline"

  def text_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={@class}>{@label}</.link>
    """
  end

  @doc """
  The choice that comes first on the page: which workflow to show. Each option is
  a whole-card radio target with what it does and the files it takes, side by
  side from the `sm` breakpoint up, so the two are read together before one is
  chosen. The group is one `fieldset`; input ids are `<id>-<value>`.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :selected, :string, required: true
  attr :options, :list, required: true, doc: "maps with :value, :label, :description, :hint"

  def source_cards(assigns) do
    ~H"""
    <fieldset id={@id} class="m-0 min-w-0 border-0 p-0">
      <legend class="p-0 text-[13px] font-semibold text-strong">{@label}</legend>
      <div class="mt-2.5 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <label
          :for={option <- @options}
          class={[
            "relative flex cursor-pointer gap-3 rounded-card border border-control bg-white px-4 py-3.5 hover:bg-canvas",
            "has-[:checked]:border-action has-[:checked]:bg-selection",
            "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus"
          ]}
        >
          <input
            type="radio"
            id={"#{@id}-#{option.value}"}
            name={@name}
            value={option.value}
            checked={option.value == @selected}
            class="mt-0.5 size-[18px] shrink-0 accent-action focus-visible:outline-none"
          />
          <span class="min-w-0">
            <span class="block text-sm font-bold text-strong">{option.label}</span>
            <span class="mt-1 block text-[13px] leading-relaxed text-default">
              {option.description}
            </span>
            <span class="mt-1.5 block text-[13px] text-muted">{option.hint}</span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  @doc """
  A numbered explanation step for an aside: the step, a bold line and one
  muted line.
  """
  attr :step, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  def aside_step(assigns) do
    ~H"""
    <li class="flex gap-3">
      <span class="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-white text-[13px] font-bold text-strong ring-1 ring-subtle">
        {@step}
      </span>
      <span>
        <strong class="block font-semibold text-strong">{@title}</strong>
        <span class="text-[13px] text-muted">{render_slot(@inner_block)}</span>
      </span>
    </li>
    """
  end

  # ── File chooser ──────────────────────────────────────────────────────────

  @doc """
  The file chooser for one upload: a labelled drop zone, a help line, the chosen
  files with their size and a control to remove each, and the reason a file was
  refused, in words that say what to do.

  Ids follow one scheme so tests and hooks can address the parts: `<id>` is the
  wrapper (with `data-upload-state`), `<id>-label`, `<id>-help`, `<id>-input`
  around the file input, `<id>-entries`, `<id>-entry-<ref>` and
  `<id>-rejected`. `phx-drop-target` makes the whole zone accept a dropped file,
  which the input alone could not because it is visually hidden.
  """
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true
  attr :action, :string, required: true, doc: "the call to action inside the zone"
  attr :hint, :string, required: true, doc: "the line under the call to action"
  attr :cancel_event, :string, required: true
  attr :skipped, :list, default: [], doc: "client names of chosen files this import will skip"

  def dropzone(assigns) do
    failed? =
      assigns.upload.errors != [] or
        Enum.any?(assigns.upload.entries, &(upload_errors(assigns.upload, &1) != []))

    assigns =
      assigns
      |> assign(:state, if(failed?, do: :failed, else: :idle))
      |> assign(:filled?, assigns.upload.entries != [])
      |> assign(:describedby, "#{assigns.id}-help")

    ~H"""
    <div id={@id} data-upload-state={@state}>
      <p id={"#{@id}-label"} class="text-[13px] font-semibold text-strong">{@label}</p>
      <label
        id={"#{@id}-zone"}
        phx-drop-target={@upload.ref}
        class={[
          "mt-1.5 flex cursor-pointer flex-col items-center gap-1 rounded-card border-2 border-dashed border-control bg-canvas px-6 text-center",
          "hover:border-action hover:bg-selection",
          "has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-focus",
          if(@filled?, do: "py-3", else: "py-6")
        ]}
      >
        <.icon name="hero-arrow-up-tray" class="size-6 text-muted" />
        <span class="text-sm font-semibold text-action">{@action}</span>
        <span class="text-[13px] text-muted">{@hint}</span>
        <span id={"#{@id}-input"}>
          <.live_file_input
            upload={@upload}
            class="sr-only"
            aria-labelledby={"#{@id}-label"}
            aria-describedby={@describedby}
            aria-invalid={to_string(@state == :failed)}
          />
        </span>
      </label>
      <p id={"#{@id}-help"} class="mt-2 text-[13px] text-muted">{@help}</p>

      <ul
        :if={upload_errors(@upload) != []}
        id={"#{@id}-rejected"}
        class="m-0 mt-2 list-none p-0 text-[13px] font-semibold text-error-fg"
      >
        <li :for={reason <- upload_errors(@upload)} class="flex items-start gap-1.5">
          <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
          <span>{upload_error_text(reason, nil, @upload)}</span>
        </li>
      </ul>

      <ul
        :if={@filled?}
        id={"#{@id}-entries"}
        class="m-0 mt-3 list-none divide-y divide-subtle rounded-control border border-subtle p-0"
      >
        <.dropzone_entry
          :for={entry <- @upload.entries}
          id={"#{@id}-entry-#{entry.ref}"}
          entry={entry}
          upload={@upload}
          skipped?={entry.client_name in @skipped}
          cancel_event={@cancel_event}
        />
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, Phoenix.LiveView.UploadEntry, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :skipped?, :boolean, required: true
  attr :cancel_event, :string, required: true

  defp dropzone_entry(assigns) do
    entry = assigns.entry
    errors = upload_errors(assigns.upload, entry)

    assigns =
      assigns
      |> assign(:errors, errors)
      |> assign(:uploading?, entry.progress > 0 and not entry.done?)
      |> assign(
        :icon_tone,
        cond do
          errors != [] -> "text-error-fg"
          assigns.skipped? -> "text-warning-fg"
          true -> "text-muted"
        end
      )

    ~H"""
    <li id={@id} class="flex items-center gap-3 px-3 py-1.5">
      <.icon name="hero-document" class={["size-5 shrink-0", @icon_tone]} />
      <div class="min-w-0 flex-1">
        <p class="truncate text-sm font-semibold text-strong" title={@entry.client_name}>
          {@entry.client_name}<span :if={@skipped?} class="font-normal text-warning-fg"> · skipped</span>
        </p>
        <%= cond do %>
          <% @errors != [] -> %>
            <p
              :for={error <- @errors}
              id={"#{@id}-error"}
              class="text-[13px] font-semibold text-error-fg"
            >
              {upload_error_text(error, @entry, @upload)}
            </p>
          <% @uploading? -> %>
            <div class="mt-1 flex items-center gap-3">
              <div
                id={"#{@id}-progress"}
                class="h-2 flex-1 overflow-hidden rounded-badge bg-canvas"
                role="progressbar"
                aria-label={"Upload progress for #{@entry.client_name}"}
                aria-valuemin="0"
                aria-valuemax="100"
                aria-valuenow={@entry.progress}
              >
                <div class="h-full bg-info-line" style={"width: #{@entry.progress}%"}></div>
              </div>
              <span class="text-[13px] tabular-nums text-muted">{@entry.progress}%</span>
            </div>
          <% true -> %>
            <p class="text-[13px] text-muted">
              {format_bytes(@entry.client_size)}<span :if={@entry.done?}> · Uploaded</span>
            </p>
        <% end %>
      </div>
      <.icon
        :if={@entry.done? and @errors == []}
        name="hero-check"
        class="size-5 shrink-0 text-success-fg"
      />
      <button
        type="button"
        class="grid min-h-11 min-w-11 place-items-center rounded-control text-muted hover:bg-canvas hover:text-strong"
        phx-click={@cancel_event}
        phx-value-ref={@entry.ref}
        aria-label={
          if(@uploading?, do: "Cancel #{@entry.client_name}", else: "Remove #{@entry.client_name}")
        }
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </li>
    """
  end

  # A refused file says what to do about it: the limit and the file's own size,
  # or the format to save it as. `entry` is nil for a refusal of the whole
  # selection, such as too many files.
  defp upload_error_text(:too_large, %{client_size: size}, upload) do
    "This file is #{format_bytes(size)}. The limit is #{format_bytes(upload.max_file_size)}. Remove it and choose a smaller file."
  end

  defp upload_error_text(:too_many_files, _entry, upload) do
    "You can choose up to #{upload.max_entries} files at a time. Remove the extra files, or zip them together."
  end

  defp upload_error_text(:not_accepted, %{client_name: name}, _upload) do
    if spreadsheet?(name) do
      "Spreadsheets can’t be imported. Save it as a .csv or .txt file, or include it in a .zip."
    else
      "Only .zip, .txt and .csv files can be imported. Choose a different file."
    end
  end

  defp upload_error_text(:not_accepted, nil, _upload),
    do: "Only .zip, .txt and .csv files can be imported. Choose a different file."

  defp upload_error_text(:external_client_failure, _entry, _upload),
    do: "The upload stopped. Remove the file and choose it again."

  defp upload_error_text({:error, reason}, _entry, _upload) when is_binary(reason), do: reason
  defp upload_error_text(error, _entry, _upload) when is_binary(error), do: error
  defp upload_error_text(_error, _entry, _upload), do: "This file couldn’t be uploaded."

  defp spreadsheet?(name),
    do: String.downcase(Path.extname(name)) in ~w(.xls .xlsx .xlsm .ods .numbers)

  @doc "A count with thousands separators, so 1204338 reads as 1,204,338."
  def format_count(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "A byte count in the decimal units a file limit is quoted in (200 MB, not 190.7 MiB)."
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB" |> String.replace(".0 MB", " MB")

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_000,
    do: "#{max(1, round(bytes / 1_000))} KB"

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"

  # ── Unfinished imports ────────────────────────────────────────────────────

  @doc """
  One import that has not published: what it is called, one word for where it
  stands, a sentence that says what that leaves behind and what is safe, and
  the actions that apply. The row's ids stay stable across stream updates, so a
  keyboard user's focus survives a state change.
  """
  attr :id, :string, required: true
  attr :run, Run, required: true
  attr :processing_publish, :any, default: nil
  attr :discardable?, :boolean, required: true

  def run_row(assigns) do
    {tone, icon_name, spin?, word} = run_status(assigns.run)

    assigns =
      assigns
      |> assign(:tone, tone)
      |> assign(:icon_name, icon_name)
      |> assign(:spin?, spin?)
      |> assign(:word, word)
      |> assign(:saved, saved_counts(assigns.run))

    ~H"""
    <li id={@id} class="px-5 py-4">
      <div class="flex flex-wrap items-start justify-between gap-x-6 gap-y-3">
        <div class="min-w-0 grow basis-[18rem]">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <p class="font-semibold text-strong [overflow-wrap:anywhere]">{@run.version_name}</p>
            <.tone_badge class="whitespace-nowrap" tone={@tone} icon={@icon_name} spin={@spin?}>
              {@word}
            </.tone_badge>
          </div>
          <p class="mt-1 text-sm text-default">{run_sentence(@run)}</p>
          <p :if={@saved} class="mt-0.5 text-sm text-default">{@saved}</p>
          <p :if={@run.state == "partial" and @run.failed_file} class="mt-0.5 text-sm text-default">
            Last file: {@run.failed_file}{if @run.failed_row,
              do: " (row #{format_count(@run.failed_row)})"}
          </p>
          <div :if={closure_rejection?(@run)} class="mt-3 grid max-w-[760px] gap-2">
            <p class="m-0 text-sm text-default">
              “{@run.version_name}” remains unpublished until this failed import is discarded.
            </p>
            <p
              id={"import-evolution-rejection-#{@run.id}"}
              data-evolution-rejection={@run.reason_code}
              data-evolution-file={@run.failed_file}
              data-evolution-row={@run.failed_row}
              class="m-0 border-l-2 border-error-line py-1 pl-3 text-sm text-default"
            >
              <span class="tabular-nums text-muted">Row {@run.failed_row}</span>
              · {evolution_rejection_sentence(@run.reason_code)}
              <span class="mt-0.5 block font-mono text-[12px] text-muted">{@run.failed_file}</span>
            </p>
            <p class="m-0 text-[13px] text-muted">
              Correct the row in your file, discard this import, then import the corrected feed.
            </p>
          </div>
        </div>
        <div class="flex shrink-0 flex-wrap gap-2">
          <button
            :if={@run.state == "publication_failed"}
            id={"publish-version-#{@run.id}"}
            type="button"
            class="btn btn-outline min-h-11"
            phx-click="publish_version"
            phx-value-run_id={@run.id}
            disabled={@processing_publish == @run.id}
          >
            <.icon
              :if={@processing_publish == @run.id}
              name="hero-arrow-path"
              class="size-4 motion-safe:animate-spin"
            />
            {if @processing_publish == @run.id, do: "Publishing…", else: "Publish version"}
          </button>
          <button
            :if={@discardable?}
            id={"discard-#{@run.id}"}
            type="button"
            class="btn btn-outline min-h-11"
            phx-click="begin_discard"
            phx-value-run_id={@run.id}
          >
            Discard failed import
          </button>
        </div>
      </div>
    </li>
    """
  end

  defp run_status(%Run{state: "pending"}), do: {"info", "hero-arrow-path", true, "Preparing"}
  defp run_status(%Run{state: "running"}), do: {"info", "hero-arrow-path", true, "Running"}

  defp run_status(%Run{state: "partial"}),
    do: {"warning", "hero-exclamation-triangle", false, "Partly imported"}

  defp run_status(%Run{state: "failed"}),
    do: {"error", "hero-exclamation-triangle", false, "Failed"}

  defp run_status(%Run{state: "interrupted"}),
    do: {"error", "hero-exclamation-triangle", false, "Interrupted"}

  defp run_status(%Run{state: "publication_failed"}),
    do: {"warning", "hero-exclamation-triangle", false, "Not published"}

  defp run_status(%Run{state: "cleaning"}), do: {"info", "hero-arrow-path", true, "Deleting"}

  defp run_status(%Run{state: "cleanup_failed"}),
    do: {"error", "hero-exclamation-triangle", false, "Delete failed"}

  defp run_status(%Run{}), do: {"neutral", "hero-information-circle", false, "Unfinished"}

  defp run_sentence(%Run{state: "pending"}), do: "Preparing the upload."

  defp run_sentence(%Run{state: "running"}),
    do: "Importing into a new version. You can leave this page; the import keeps running."

  defp run_sentence(%Run{state: "partial"}),
    do: "Stopped partway. Some rows were saved, and the version isn’t published."

  defp run_sentence(%Run{state: "failed"}),
    do:
      "Stopped before anything was saved, so it’s safe to delete. Delete this version and import again."

  defp run_sentence(%Run{state: "interrupted"}),
    do:
      "The import stopped unexpectedly, so we can’t tell how much was saved. Delete this version and import again."

  defp run_sentence(%Run{state: "publication_failed"}),
    do:
      "Every file imported, but the version couldn’t be published. Publishing again doesn’t re-read your files."

  defp run_sentence(%Run{state: "cleaning"}),
    do:
      "Deleting the failed version and everything it imported. This can take a minute for large feeds."

  defp run_sentence(%Run{state: "cleanup_failed"}),
    do:
      "We couldn’t finish deleting this version. What’s already deleted stays deleted; delete it again to finish."

  defp run_sentence(%Run{}), do: "This import didn’t finish."

  # The bounded codes for a scheduled-closure row outside the supported
  # interchange subset. Each sentence names the field and the fix, and none of
  # them can quote a value from the rejected row, which the run never stores.
  @evolution_rejection_codes ~w(
    evolution_pathway_required evolution_service_required
    evolution_opening_unsupported evolution_direction_unsupported
    evolution_time_invalid evolution_pathway_missing evolution_service_missing
    evolution_duplicate
  )

  # A run that stores one of the bounded closure-rejection codes also stores the
  # file it came from, so the row can name all three without touching the
  # rejected row.
  defp closure_rejection?(%Run{reason_code: code, failed_file: "pathway_evolutions.txt"})
       when code in @evolution_rejection_codes,
       do: true

  defp closure_rejection?(%Run{}), do: false

  defp evolution_rejection_sentence("evolution_pathway_required"),
    do: "pathway_id is blank. Name the pathway, using the exact pathway_id from pathways.txt."

  defp evolution_rejection_sentence("evolution_service_required"),
    do:
      "service_id is blank. Name the calendar, using the exact service_id from calendar.txt or calendar_dates.txt."

  defp evolution_rejection_sentence("evolution_opening_unsupported"),
    do: "is_closed is not 1. Remove the opening row: this file cannot reopen a pathway."

  defp evolution_rejection_sentence("evolution_direction_unsupported"),
    do:
      "direction has a value. Leave direction blank or remove the column: a closure closes the pathway both ways."

  defp evolution_rejection_sentence("evolution_time_invalid"),
    do:
      "A time is unreadable, blank, or the end is not later than the start. Use H:MM:SS with the end above the start, and a value above 24:00:00 for a window that continues past midnight."

  defp evolution_rejection_sentence("evolution_pathway_missing"),
    do:
      "No pathway with that pathway_id exists in this version. Import pathways.txt in the same feed, or correct the pathway_id."

  defp evolution_rejection_sentence("evolution_service_missing"),
    do:
      "The service has no calendar.txt or calendar_dates.txt row in this version. Import the calendar file in the same feed, or correct the service_id."

  defp evolution_rejection_sentence("evolution_duplicate"),
    do:
      "The same pathway, service and window already appears in this import or in the version. Remove the repeated row, or give the two closures different windows."

  defp evolution_rejection_sentence(_code), do: "This row is not in the supported closure subset."

  @count_order ~w(routes stops trips stop_times shapes calendars levels pathways pathway_evolutions patterns_created
                  timings_created trips_linked trips_custom extensions_stop_coordinates
                  extensions_stop_levels extensions_route_flags extensions_images)

  @count_labels %{
    "pathway_evolutions" => "pathway closures",
    "patterns_created" => "patterns created",
    "timings_created" => "timings created",
    "trips_linked" => "trips linked",
    "trips_custom" => "trips kept custom",
    "extensions_stop_coordinates" => "stop coordinates",
    "extensions_stop_levels" => "stop levels",
    "extensions_route_flags" => "route flags",
    "extensions_images" => "images"
  }

  # What a partial import committed before it stopped: the counts a person checks
  # a feed by first (routes, stops, trips), then the rest of the importer's
  # counters, and any other file it counted last, named without the underscore.
  defp saved_counts(%Run{state: "partial", committed_counts: counts}) when is_map(counts) do
    parts =
      counts
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.filter(fn {_key, value} -> is_integer(value) and value > 0 end)
      |> Enum.sort_by(fn {key, _value} ->
        {Enum.find_index(@count_order, &(&1 == key)) || length(@count_order), key}
      end)
      |> Enum.map(fn {key, value} -> "#{format_count(value)} #{count_label(key, value)}" end)

    if parts != [], do: "Saved before it stopped: #{Enum.join(parts, ", ")}."
  end

  defp saved_counts(_run), do: nil

  # Each counted file reads correctly at one and at many: "1 level", "2 pathway
  # closures". Every known label is a plural that ends in "s" on its noun.
  defp count_label(key, value) do
    plural = Map.get(@count_labels, key, String.replace(key, "_", " "))
    if value == 1, do: singular(plural), else: plural
  end

  defp singular(label) do
    case String.split(label, " ") do
      [noun] -> String.replace_suffix(noun, "s", "")
      [first, "created"] -> String.replace_suffix(first, "s", "") <> " created"
      [first, "linked"] -> String.replace_suffix(first, "s", "") <> " linked"
      [first, "kept", rest] -> String.replace_suffix(first, "s", "") <> " kept " <> rest
      words -> words |> List.update_at(-1, &String.replace_suffix(&1, "s", "")) |> Enum.join(" ")
    end
  end

  # ── Station review ────────────────────────────────────────────────────────

  @action_styles %{
    add: {"Added", "hero-plus", "text-success-fg"},
    modify: {"Changed", "hero-pencil", "text-info-fg"},
    conflict: {"Edited here", "hero-exclamation-triangle", "text-warning-fg"},
    remove: {"Removed", "hero-minus", "text-error-fg"}
  }

  @doc "The visible name of a change kind, as the filter tabs and the counts use it."
  def action_label(action), do: elem(Map.fetch!(@action_styles, action), 0)

  @doc "How a change kind reads in \"Approve all 3 …\": the plural the reviewer is agreeing to."
  def action_plural(:add), do: "added"
  def action_plural(:modify), do: "changed"
  def action_plural(:conflict), do: "that replace edits"
  def action_plural(:remove), do: "removals"

  def action_icon(action), do: elem(Map.fetch!(@action_styles, action), 1)
  def action_tone(action), do: elem(Map.fetch!(@action_styles, action), 2)

  @doc """
  One station change to approve or reject: what kind of change it is, which
  record, what it does in a sentence, the field-by-field before and after
  without a click, and the two decisions.

  The buttons are toggles: the pressed state is the status. A change that
  removes a record or replaces someone's edits names that on its button, so the
  costlier approvals are never a bare "Approve". A `:preview` row comes from a
  file that was only partly readable and has no decisions.
  """
  attr :id, :string, required: true
  attr :decision, ChangeDecision, required: true

  attr :dependents_note, :string,
    default: nil,
    doc: "what still uses the record a removal deletes"

  def review_row(assigns) do
    decision = assigns.decision
    subject = "#{entity_word(decision.entity_type)} #{decision.natural_key}"

    assigns =
      assigns
      |> assign(:subject, subject)
      |> assign(:entity, entity_word(decision.entity_type))
      |> assign(:fields, decision_fields(decision))
      |> assign(:actionable?, decision.status in [:pending, :approved, :rejected])
      |> assign(:approve_label, approve_label(decision.action))
      |> assign(:approved_label, approved_label(decision.action))
      |> assign(:approve_width, approve_width(decision.action))

    ~H"""
    <li
      id={@id}
      data-review-row
      data-action={@decision.action}
      data-status={@decision.status}
      class="grid gap-x-5 gap-y-2 px-5 py-4 md:grid-cols-[8.5rem_minmax(0,1fr)_auto] md:items-start"
    >
      <div class={["flex items-center gap-2 text-sm font-semibold", action_tone(@decision.action)]}>
        <.icon name={action_icon(@decision.action)} class="size-4 shrink-0" />
        {action_label(@decision.action)}
      </div>

      <div class="min-w-0">
        <p class="m-0 text-sm font-semibold text-strong [overflow-wrap:anywhere]">
          {@entity} <span class="font-mono">{@decision.natural_key}</span>
        </p>
        <p class="m-0 mt-0.5 text-sm text-default">{decision_note(@decision)}</p>
        <dl
          :if={@fields != []}
          class="m-0 mt-2 grid gap-1.5 border-l-2 border-subtle pl-3 text-[13px]"
        >
          <div
            :for={field <- @fields}
            class="grid gap-0.5 lg:grid-cols-[14rem_minmax(0,1fr)] lg:gap-3"
          >
            <dt class="font-semibold text-default">
              {field.label} <span class="font-mono font-normal text-muted">{field.key}</span>
            </dt>
            <dd class="m-0 min-w-0 break-words text-default">
              <span class="text-muted">{field.before}</span>
              <span aria-hidden="true">→</span>
              <span class="font-semibold text-strong">{field.after}</span>
            </dd>
          </div>
        </dl>
        <p :if={@decision.dependency_keys != []} class="m-0 mt-2 text-[13px] text-muted">
          Needs {Enum.join(@decision.dependency_keys, ", ")}
        </p>
        <p
          :if={@dependents_note}
          id={"diff-decision-dependents-#{@decision.id}"}
          class="m-0 mt-2 text-[13px] font-semibold text-warning-fg"
        >
          {@dependents_note}
        </p>
        <p :if={@decision.status == :rejected} class="m-0 mt-1 text-[13px] text-muted">
          This change won’t be applied.
        </p>
      </div>

      <div class="flex flex-wrap items-center gap-2 md:justify-end">
        <.tone_badge
          :if={@decision.status == :preview}
          class="whitespace-nowrap"
          tone="info"
          icon="hero-eye"
        >
          Preview only
        </.tone_badge>
        <.tone_badge
          :if={@decision.status in [:applied, :failed, :stale]}
          class="whitespace-nowrap"
          tone="neutral"
          icon="hero-clock"
        >
          {status_word(@decision.status)}
        </.tone_badge>
        <%= if @actionable? do %>
          <button
            type="button"
            id={"#{@id}-approve"}
            aria-pressed={to_string(@decision.status == :approved)}
            aria-label={"#{@approve_label}: #{@subject}"}
            class={[
              "inline-flex min-h-11 items-center justify-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas",
              "aria-pressed:border-success-line aria-pressed:bg-success-bg aria-pressed:text-success-fg",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
              @approve_width
            ]}
            phx-click="approve-decision"
            phx-value-id={@decision.decision_id}
          >
            <.icon :if={@decision.status == :approved} name="hero-check" class="size-4" />
            {if @decision.status == :approved, do: @approved_label, else: @approve_label}
          </button>
          <button
            type="button"
            id={"#{@id}-reject"}
            aria-pressed={to_string(@decision.status == :rejected)}
            aria-label={"Reject: #{@subject}"}
            class={[
              "inline-flex min-h-11 min-w-[6rem] items-center justify-center gap-1.5 rounded-control border border-control bg-white px-3 text-sm font-[650] text-strong hover:bg-canvas",
              "aria-pressed:border-strong aria-pressed:bg-canvas",
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
            ]}
            phx-click="reject-decision"
            phx-value-id={@decision.decision_id}
          >
            <.icon :if={@decision.status == :rejected} name="hero-x-mark" class="size-4" />
            {if @decision.status == :rejected, do: "Rejected", else: "Reject"}
          </button>
        <% end %>
      </div>
    </li>
    """
  end

  @doc "The word for a kind of record in a sentence about one of them."
  def entity_word(:level), do: "Level"
  def entity_word(:stop), do: "Stop"
  def entity_word(:pathway), do: "Pathway"

  defp approve_label(:conflict), do: "Approve overwrite"
  defp approve_label(:remove), do: "Approve removal"
  defp approve_label(_action), do: "Approve"

  defp approved_label(:conflict), do: "Overwrite approved"
  defp approved_label(:remove), do: "Removal approved"
  defp approved_label(_action), do: "Approved"

  # The two costlier labels are longer, so their button holds a width and the
  # toggle does not resize the row when it is pressed.
  defp approve_width(action) when action in [:conflict, :remove], do: "min-w-[10.5rem]"
  defp approve_width(_action), do: "min-w-[6.5rem]"

  defp status_word(:applied), do: "Applied"
  defp status_word(:failed), do: "Failed"
  defp status_word(:stale), do: "Changed since review"

  defp decision_note(%ChangeDecision{action: :add, entity_type: type}),
    do: "A new #{type_noun(type)}. It isn’t in this version yet."

  defp decision_note(%ChangeDecision{action: :modify, changed_fields: fields, entity_type: type}) do
    case length(fields) do
      0 -> "Changes this #{type_noun(type)}."
      1 -> "Changes 1 field."
      count -> "Changes #{count} fields."
    end
  end

  defp decision_note(%ChangeDecision{action: :conflict}),
    do: "Edited since it was created. Approving replaces those edits with your file’s values."

  defp decision_note(%ChangeDecision{action: :remove}),
    do: "In this version but not in your file. Approving deletes it from this version."

  defp type_noun(:level), do: "level"
  defp type_noun(:stop), do: "stop"
  defp type_noun(:pathway), do: "pathway"

  defp decision_fields(%ChangeDecision{changed_fields: fields}) when is_list(fields) do
    for field <- fields do
      key = Map.get(field, "field", "field")

      %{
        key: key,
        label: key |> to_string() |> String.replace("_", " ") |> String.capitalize(),
        before: diff_text(Map.get(field, "before")),
        after: diff_text(Map.get(field, "after"))
      }
    end
  end

  defp decision_fields(_decision), do: []

  @absent TransitPresentation.absent_value()

  defp diff_text(@absent), do: "Not recorded"
  defp diff_text(nil), do: "Empty"
  defp diff_text(""), do: "Empty"
  defp diff_text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp diff_text(value) when is_binary(value), do: value
  defp diff_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp diff_text(value) when is_atom(value), do: Atom.to_string(value)
  defp diff_text(value), do: inspect(value)

  # ── Trips left outside patterns ───────────────────────────────────────────

  @doc """
  The trips this import could not group, grouped by route: a route badge and name
  with the route's own total, then one row per derivation reason with the fix
  that reason can have, and the raw codes in a disclosure.

  `groups` is empty for a feed whose every trip is in a pattern, and the block
  then renders nothing at all rather than an empty table.
  """
  attr :groups, :list,
    required: true,
    doc: "one entry per route from `GtfsPlannerWeb.Gtfs.ImportLive.import_left_out/2`"

  attr :version_id, :string, required: true, doc: "the version this import published"

  def left_out_block(assigns) do
    assigns =
      assigns
      |> assign(:total, Enum.reduce(assigns.groups, 0, &(&1.trip_count + &2)))
      |> then(fn assigns -> assign(assigns, :one?, assigns.total == 1) end)

    ~H"""
    <section
      :if={@groups != []}
      id="import-patterns"
      aria-labelledby="import-patterns-title"
      class="border-t border-subtle px-5 py-5"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3
          id="import-patterns-title"
          class="font-display text-[18px] font-semibold leading-tight tracking-[-0.01em] text-strong"
        >
          {LeftOutWording.title(@total)}
        </h3>
      </div>
      <p class="mt-1 max-w-[86ch] text-[15px] leading-relaxed text-default">
        Import could not group {if @one?, do: "it", else: "them"} by direction and stop order. {if @one?,
          do: "It stays",
          else: "They stay"} exactly as imported, and {if @one?,
          do: "its map line can’t",
          else: "their map lines can’t"} be edited until {if @one?, do: "it is", else: "they are"} in a pattern. Trips with no direction can be
        grouped on the route’s Patterns tab; the rest need a fix in the source feed and a
        re-import.
      </p>
      <div class="mt-4 overflow-hidden rounded-card border border-subtle">
        <table id="import-left-out" class="w-full border-collapse text-left text-sm">
          <thead>
            <tr class="bg-canvas text-[13px] font-[650] text-default">
              <th scope="col" class="py-0 pl-4 pr-4">
                <span class="inline-flex min-h-11 items-center">Why</span>
              </th>
              <th scope="col" class="w-20 px-4 py-0 text-right max-sm:hidden">
                <span class="inline-flex min-h-11 items-center">Trips</span>
              </th>
              <th scope="col" class="w-44 py-0 pl-4 pr-4 text-right max-sm:hidden"><span /></th>
            </tr>
          </thead>
          <tbody :for={group <- @groups}>
            <tr>
              <th
                scope="rowgroup"
                colspan="3"
                class="border-t border-subtle px-4 pb-2 pt-4 text-left font-normal"
              >
                <span class="inline-flex flex-wrap items-center gap-x-3 gap-y-1">
                  <RouteIdentity.route_badge :if={group.route} route={group.route} />
                  <span class="text-[15px] font-[650] text-strong">{route_label(group)}</span>
                  <span class="text-[13px] text-muted tabular-nums">
                    {group.trip_count}
                    {if group.trip_count == 1, do: " trip", else: " trips"}
                  </span>
                </span>
              </th>
            </tr>
            <tr :for={row <- group.rows} id={row.id} class="border-t border-subtle">
              <td class="py-3 pl-4 pr-4 align-top">
                <p class="text-[15px] font-[650] text-strong">{row.title}</p>
                <p class="mt-0.5 max-w-[62ch] text-[13px] text-muted">{row.body}</p>
                <p class="mt-1 flex flex-wrap items-center gap-x-3 text-[13px] text-default sm:hidden">
                  {row.count} {if row.count == 1, do: "trip", else: "trips"}
                  <.link
                    :if={row.action}
                    id={"#{row.action.id}-compact"}
                    navigate={left_out_path(row.action.target, @version_id, group.route_id)}
                    class="inline-flex min-h-11 items-center font-semibold text-action hover:underline"
                  >
                    {row.action.label}
                  </.link>
                </p>
              </td>
              <td class="w-20 px-4 py-3 text-right align-top tabular-nums text-default max-sm:hidden">
                {row.count}
              </td>
              <td class="w-44 pb-1.5 pl-4 pr-4 pt-0.5 text-right align-top max-sm:hidden">
                <.link
                  :if={row.action}
                  id={row.action.id}
                  navigate={left_out_path(row.action.target, @version_id, group.route_id)}
                  class="inline-flex min-h-11 items-center justify-end font-semibold text-action hover:underline"
                >
                  {row.action.label}
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <details
        id="import-left-out-codes"
        class="group mt-2 text-[13px] text-muted"
      >
        <summary class="inline-flex min-h-11 cursor-pointer items-center gap-1 font-[650] text-default hover:underline">
          <.icon name="hero-chevron-right" class="size-4 transition-transform group-open:rotate-90" />
          Technical details
        </summary>
        <p class="pb-2">
          Derivation reasons:
          <%= for group <- @groups do %>
            <%= for row <- group.rows do %>
              <code class="font-mono text-[12px] text-strong">{row.code}</code>
            <% end %>
          <% end %>
        </p>
      </details>
    </section>
    """
  end

  # A route the feed named by id alone still needs a label. The route badge falls
  # back to the same three fields when the row is missing entirely.
  defp route_label(%{route: nil} = group), do: group.route_id

  defp route_label(%{route: route}),
    do: route.route_long_name || route.route_short_name || route.route_id

  defp left_out_path(:group, version_id, route_id),
    do: ~p"/gtfs/#{version_id}/routes/#{route_id}/patterns?review=group"

  defp left_out_path(:schedules, version_id, route_id),
    do: ~p"/gtfs/#{version_id}/routes/#{route_id}/schedules"

  @doc """
  What the sticky apply bar says beside its button, in the words of the two
  costs a reviewer should not miss: removals and replaced edits.
  """
  def consequence(approved) do
    removals = Enum.count(approved, &(&1.action == :remove))
    overwrites = Enum.count(approved, &(&1.action == :conflict))

    parts =
      [
        removals > 0 && "#{removals} #{if removals == 1, do: "removal", else: "removals"}",
        overwrites > 0 &&
          "#{overwrites} #{if overwrites == 1, do: "change that replaces", else: "changes that replace"} edits"
      ]
      |> Enum.filter(& &1)

    if parts != [], do: "Includes #{Enum.join(parts, " and ")}."
  end
end
