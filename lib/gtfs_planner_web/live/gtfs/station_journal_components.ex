defmodule GtfsPlannerWeb.Gtfs.StationJournalComponents do
  @moduledoc """
  Presentation components for the station diagram journal queue.

  The caller owns every state transition and the streamed entry collection.
  This module only maps caller-owned journal state into semantic controls and
  repository UI primitives. `journal_targets` is keyed by a node/pathway target
  ID or pin level ID; each value supplies a display `:label`. Timestamps in
  `journal_local_times` are already localized by the caller, while the stored
  UTC timestamps remain authoritative for every `<time datetime>` attribute.

  This is deliberately a library-only boundary. `StationDiagramLive` integrates
  the trigger and panel with the production workspace in journal package step 6.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents,
    only: [button: 1, callout: 1, empty_state: 1, icon: 1, skeleton: 1]

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.StationJournal.PhotoStorage
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias Phoenix.LiveView.JS

  @doc """
  Compacts a roster user or email into a journal byline.

  Multiple local-part tokens use the first token's initial and final token;
  single-token addresses use title case. Missing or unusable authors are
  represented as `Unknown`.
  """
  @spec author_label(User.t() | String.t() | nil) :: String.t()
  def author_label(%User{email: email}), do: author_label(email)

  def author_label(email) when is_binary(email) do
    local_part = email |> String.split("@", parts: 2) |> List.first()

    tokens =
      local_part
      |> to_string()
      |> String.trim()
      |> String.split(~r/[._+\-\s]+/u, trim: true)

    case tokens do
      [] ->
        "Unknown"

      [token] ->
        title_token(token)

      [first | _] ->
        last = List.last(tokens)

        case String.first(first) do
          nil -> "Unknown"
          initial -> String.upcase(initial) <> ". " <> title_token(last)
        end
    end
  end

  def author_label(_author), do: "Unknown"

  @doc """
  Formats a caller-localized journal time as a compact relative label.
  """
  @spec relative_time(NaiveDateTime.t(), NaiveDateTime.t()) :: String.t()
  def relative_time(%NaiveDateTime{} = local, %NaiveDateTime{} = now) do
    seconds = max(NaiveDateTime.diff(now, local, :second), 0)

    cond do
      seconds < 60 ->
        "just now"

      seconds < 3600 ->
        "#{div(seconds, 60)}m ago"

      NaiveDateTime.to_date(local) == NaiveDateTime.to_date(now) ->
        "#{div(seconds, 3600)}h ago"

      true ->
        days = Date.diff(NaiveDateTime.to_date(now), NaiveDateTime.to_date(local))

        cond do
          days == 1 -> "yesterday"
          days < 7 -> "#{days}d ago"
          true -> Calendar.strftime(local, "%b %-d")
        end
    end
  end

  @doc """
  Formats a caller-localized wall-clock value for expanded journal metadata.
  """
  @spec absolute_time(NaiveDateTime.t()) :: String.t()
  def absolute_time(%NaiveDateTime{} = local) do
    Calendar.strftime(local, "%b %-d, %Y") <> " · " <> Gtfs.format_display_time(local)
  end

  attr :entry_count, :integer, required: true
  attr :panel_open?, :boolean, required: true

  @doc """
  Renders the journal panel's only toolbar trigger.
  """
  def journal_trigger(assigns) do
    ~H"""
    <button
      id="journal-trigger"
      type="button"
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1.5 text-xs font-medium text-blue-900 transition-colors",
        "hover:bg-blue-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-blue-50",
        @panel_open? && "bg-blue-100"
      ]}
      phx-click={if @panel_open?, do: "close_journal", else: "open_journal"}
      aria-expanded={to_string(@panel_open?)}
      aria-controls="station-journal-panel"
    >
      <.icon name="hero-clipboard-document-list" class="size-4" />
      <span>Journal</span>
      <span
        id="journal-trigger-count"
        class="inline-flex min-w-4 items-center justify-center rounded-full border border-control-border bg-base-100 px-1.5 text-[11px] leading-4 tabular-nums text-base-content"
      >
        {@entry_count}
      </span>
    </button>
    """
  end

  attr :journal_scope, Scope, required: true
  attr :journal_entries, :any, required: true

  attr :journal_state, :atom,
    default: :idle,
    values: [:idle, :loading, :ready, :error]

  attr :station_name, :string, default: nil
  attr :journal_loaded_once?, :boolean, default: false
  attr :journal_refresh_error?, :boolean, default: false
  attr :journal_open_count, :integer, default: 0
  attr :journal_closed_count, :integer, default: 0
  attr :journal_visible_count, :integer, default: 0
  attr :journal_pending_new_ids, :any, default: MapSet.new()
  attr :journal_new_entry_ids, :any, default: MapSet.new()
  attr :journal_photo_viewer, :any, default: nil
  attr :journal_authors, :map, default: %{}
  attr :journal_targets, :map, default: %{}
  attr :journal_local_times, :map, default: %{}
  attr :journal_display_zone, :any, default: nil
  attr :journal_now, :any, default: nil
  attr :journal_live_message, :string, default: nil
  attr :journal_error_message, :string, default: nil

  attr :journal_target_scope, :map, default: nil
  attr :journal_scoped_open_count, :integer, default: nil
  attr :journal_scoped_closed_count, :integer, default: nil
  attr :journal_floorplan_entry_ids, :any, default: MapSet.new()

  @doc """
  Renders the complete journal panel shell and its ready/non-ideal states.

  `journal_entries` consumes the caller's stream tuples directly. Count,
  lifecycle, presentation, and pending-ID metadata remain separate assigns so
  this component never needs a duplicate full entry collection.
  """
  def journal_panel(assigns) do
    flags = panel_flags(assigns)

    assigns =
      assigns
      |> assign(flags)
      |> assign(:pending_count, collection_count(assigns.journal_pending_new_ids))
      |> assign(:panel_state, panel_state(assigns, flags.first_loading?, flags.first_load_error?))
      |> assign(:now, assigns.journal_now || NaiveDateTime.utc_now())

    ~H"""
    <aside
      id="station-journal-panel"
      aria-label="Station journal"
      data-state={@panel_state}
      phx-mounted={journal_panel_enter()}
      phx-remove={journal_panel_exit()}
      phx-window-keydown="close_journal"
      phx-key="escape"
      class="journal-panel-shell flex min-h-0 w-[340px] min-w-[340px] max-w-[340px] shrink-0 flex-col overflow-hidden border-r border-base-300 bg-base-100 text-sm text-base-content"
    >
      <header class="flex items-center gap-2 px-4 pb-2 pt-3">
        <h2 class="text-base font-semibold leading-tight">Journal</h2>
        <span
          :if={!@first_loading? and !@first_load_error? and @total_count > 0}
          id="journal-count-summary"
          class="min-w-0 text-xs tabular-nums text-base-content/70"
        >
          {@total_count} {if @total_count == 1, do: "entry", else: "entries"}
        </span>
        <.button
          id="journal-panel-close"
          type="button"
          variant="quiet"
          size="sm"
          class="ml-auto min-h-11 min-w-11 p-0"
          phx-click="close_journal"
          aria-label="Close journal panel"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.button>
      </header>

      <div
        :if={@journal_target_scope}
        id="journal-target-scope"
        class="flex items-center justify-between gap-2 border-y border-base-300 bg-base-200/50 px-4 py-2 text-xs"
      >
        <span class="min-w-0 truncate font-medium text-base-content/80">
          {@journal_target_scope.label}
        </span>
        <.button
          id="journal-clear-target-scope"
          type="button"
          variant="quiet"
          size="sm"
          class="h-auto min-h-0 shrink-0 p-0 font-normal text-primary underline hover:bg-transparent"
          phx-click="clear_journal_target_scope"
        >
          Show all entries
        </.button>
      </div>

      <div :if={@pending_count > 0} class="border-y border-info/30 bg-info/10 px-3 py-2">
        <.button
          id="journal-pending-entries"
          type="button"
          variant="quiet"
          size="sm"
          class="min-h-11 w-full justify-center text-info"
          phx-click="refresh_journal"
        >
          <.icon name="hero-arrow-up" class="size-4" />
          {@pending_count} {if @pending_count == 1, do: "new entry", else: "new entries"}
        </.button>
      </div>

      <div :if={@stale_error?} class="px-4 pb-3">
        <.callout
          id="journal-refresh-error"
          kind="error"
          title="Journal entries may be out of date"
        >
          <p>The last saved entries remain available.</p>
          <.button
            id="journal-refresh-retry"
            type="button"
            variant="secondary"
            size="sm"
            class="mt-3 min-h-11"
            phx-click="refresh_journal"
          >
            Retry
          </.button>
        </.callout>
      </div>

      <div :if={@journal_error_message && !@first_load_error?} class="px-4 pb-3">
        <.callout id="journal-mutation-error" kind="error" title="Journal action failed">
          The entry was not changed. Try again.
        </.callout>
      </div>

      <.loading_state :if={@first_loading?} />
      <.load_error_state :if={@first_load_error?} />
      <.first_use_empty_state :if={@first_use_empty?} />

      <div
        :if={@journal_visible_count > 0}
        id="journal-entry-list"
        phx-update="stream"
        class="min-h-0 flex-1 divide-y divide-base-300 overflow-y-auto overscroll-contain"
      >
        <.journal_entry_row
          :for={{dom_id, entry} <- @journal_entries}
          id={dom_id}
          entry={entry}
          scope={@journal_scope}
          new?={collection_member?(@journal_new_entry_ids, entry.id)}
          show_on_floorplan?={collection_member?(@journal_floorplan_entry_ids, entry.id)}
          author={Map.get(@journal_authors, entry.author_id)}
          target={target_presentation(entry, @journal_targets, @station_name)}
          captured_local={local_time(entry, :captured, @journal_local_times)}
          now={@now}
          zone={@journal_display_zone}
        />
      </div>

      <p
        id="journal-status"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        class="sr-only"
      >
        {@journal_live_message}
      </p>

      <.journal_photo_viewer :if={@journal_photo_viewer} viewer={@journal_photo_viewer} />
    </aside>
    """
  end

  attr :context, :any, default: nil

  @doc """
  Renders the originating journal entry above an edit form.

  Opening an edit from the journal closes the panel, so the drawer restates the
  note the reviewer is acting on. Renders nothing without a context.
  """
  def journal_context_box(assigns) do
    ~H"""
    <div
      :if={@context}
      id="journal-form-context"
      data-role="journal-form-context"
      class="mb-4 border-l-4 border-[color:var(--diagram-journal-open)] bg-base-200/60 px-3 py-2 text-sm"
    >
      <p class="flex min-w-0 flex-wrap items-center gap-x-1.5 text-xs font-medium text-base-content/70">
        <.icon name="hero-clipboard-document-list" class="size-3.5 shrink-0" />
        <span>Journal entry</span>
        <span aria-hidden="true">·</span>
        <span>{@context.byline}</span>
        <span :if={@context.captured_label} aria-hidden="true">·</span>
        <span :if={@context.captured_label}>{@context.captured_label}</span>
      </p>
      <p class="mt-1 break-words leading-relaxed text-base-content [overflow-wrap:anywhere]">
        {note_body(@context.body)}
      </p>
    </div>
    """
  end

  attr :viewer, :map, required: true

  # In-app lightbox for journal photos. Escape is handled by the panel's shared
  # keydown binding: `close_journal` dismisses this viewer first when it is open.
  defp journal_photo_viewer(assigns) do
    ~H"""
    <div
      id="journal-photo-viewer"
      role="dialog"
      aria-modal="true"
      aria-label={"Journal photo #{@viewer.index} of #{@viewer.count}"}
      class="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-8"
    >
      <div
        id="journal-photo-viewer-backdrop"
        class="absolute inset-0 bg-black/75"
        aria-hidden="true"
        phx-click="close_journal_photo"
      >
      </div>
      <figure class="relative flex max-h-full max-w-3xl flex-col">
        <img
          src={@viewer.src}
          alt={"Journal photo #{@viewer.index}"}
          class="max-h-[80vh] w-auto rounded-md object-contain"
        />
        <figcaption class="mt-2 flex items-center gap-3 text-sm text-white">
          <span>Photo {@viewer.index} of {@viewer.count}</span>
          <a
            id="journal-photo-viewer-original"
            href={@viewer.src}
            target="_blank"
            rel="noopener noreferrer"
            class="underline underline-offset-2 hover:text-white/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white"
          >
            Open original
          </a>
        </figcaption>
        <button
          id="journal-photo-viewer-close"
          type="button"
          class="absolute -right-2 -top-2 flex size-11 items-center justify-center rounded-full bg-base-100 text-base-content shadow-md hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          phx-click="close_journal_photo"
          aria-label="Close photo"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </figure>
    </div>
    """
  end

  defp panel_flags(assigns) do
    total_count =
      if assigns.journal_target_scope do
        (assigns.journal_scoped_open_count || 0) + (assigns.journal_scoped_closed_count || 0)
      else
        assigns.journal_open_count + assigns.journal_closed_count
      end

    %{
      total_count: total_count,
      first_loading?: first_loading?(assigns),
      first_load_error?: first_load_error?(assigns),
      stale_error?: stale_error?(assigns),
      first_use_empty?: first_use_empty?(assigns, total_count)
    }
  end

  defp first_loading?(assigns),
    do: assigns.journal_state in [:idle, :loading] and not assigns.journal_loaded_once?

  defp first_load_error?(assigns),
    do: assigns.journal_state == :error and not assigns.journal_loaded_once?

  defp stale_error?(assigns),
    do:
      assigns.journal_refresh_error? or
        (assigns.journal_state == :error and assigns.journal_loaded_once?)

  defp first_use_empty?(assigns, total_count),
    do: assigns.journal_state == :ready and assigns.journal_loaded_once? and total_count == 0

  attr :id, :string, required: true
  attr :entry, JournalEntry, required: true
  attr :scope, Scope, required: true
  attr :new?, :boolean, default: false
  attr :show_on_floorplan?, :boolean, default: false
  attr :author, :any, default: nil
  attr :target, :map, required: true
  attr :captured_local, NaiveDateTime, required: true
  attr :now, NaiveDateTime, required: true
  attr :zone, :any, default: nil

  # Every entry renders complete — note, photos, metadata, and actions — so the
  # queue never hides content or controls behind an unlabeled disclosure click.
  defp journal_entry_row(assigns) do
    photos = loaded_photos(assigns.entry.photos)

    assigns =
      assigns
      |> assign(:photos, photos)
      |> assign(:photo_count, length(photos))
      |> assign(:byline, author_label(assigns.author))
      |> assign(:relative_capture, relative_time(assigns.captured_local, assigns.now))
      |> assign(:zone_title, zone_title(assigns.captured_local, assigns.zone))

    ~H"""
    <article
      id={@id}
      data-role="journal-entry"
      data-entry-id={@entry.id}
      tabindex="-1"
      class={[
        "bg-base-100 px-4 py-3 transition-colors",
        "focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary",
        @new? && "journal-entry-motion"
      ]}
    >
      <div class="flex items-start gap-2 text-xs">
        <span
          id={"journal-entry-target-#{@entry.id}"}
          class="inline-flex min-w-0 items-center gap-1 font-medium text-base-content/70"
        >
          <.icon name={@target.icon} class="size-3.5 shrink-0" />
          <span class="truncate">{@target.label}</span>
        </span>
      </div>

      <p
        data-role="journal-note"
        class="mt-1.5 break-words leading-relaxed text-base-content [overflow-wrap:anywhere]"
      >
        {note_body(@entry.body)}
      </p>

      <div :if={@photo_count > 0} class="mt-2 flex flex-wrap gap-1.5">
        <button
          :for={{photo, index} <- Enum.with_index(@photos, 1)}
          id={"journal-photo-#{photo.id}"}
          type="button"
          class="group relative size-14 overflow-hidden rounded-md border border-base-300 bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          phx-click="open_journal_photo"
          phx-value-photo_id={photo.id}
          phx-value-entry_id={@entry.id}
          aria-label={"View journal photo #{index} of #{@photo_count}"}
        >
          <img
            src={PhotoStorage.public_path(@scope, photo)}
            alt={"Journal photo #{index}"}
            loading="lazy"
            decoding="async"
            class="h-full w-full object-cover transition-transform group-hover:scale-[1.02] motion-reduce:transition-none"
          />
        </button>
      </div>

      <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
        <span class="min-w-0 truncate">
          <span>{@byline}</span>
          <span aria-hidden="true">·</span>
          <time datetime={DateTime.to_iso8601(@entry.captured_at)} title={@zone_title}>
            {@relative_capture}
          </time>
        </span>

        <span class="ml-auto flex shrink-0 items-center gap-1">
          <.button
            :if={@show_on_floorplan?}
            id={"journal-show-entry-#{@entry.id}"}
            type="button"
            variant="quiet"
            size="sm"
            class="text-xs"
            phx-click="show_journal_entry_on_floorplan"
            phx-value-id={@entry.id}
          >
            Show on floorplan
          </.button>

          <.button
            :if={@target.edit_event}
            id={"journal-edit-target-#{@entry.id}"}
            type="button"
            variant="quiet"
            size="sm"
            class="text-xs"
            phx-click={@target.edit_event}
            phx-value-id={@target.edit_id}
            phx-value-journal_entry_id={@entry.id}
          >
            {@target.edit_label}
          </.button>
        </span>
      </div>
    </article>
    """
  end

  defp loading_state(assigns) do
    ~H"""
    <.skeleton
      id="journal-loading"
      label="Loading journal entries"
      aria-busy="true"
      class="journal-loading-delay min-h-0 flex-1 px-4 pb-4"
    >
      <div class="divide-y divide-base-300">
        <div
          :for={width <- ["w-2/3", "w-1/2", "w-3/4"]}
          data-role="journal-skeleton-row"
          class="space-y-2 py-3"
        >
          <div class="flex gap-2">
            <div class={["h-5 rounded-full bg-base-300", width]}></div>
            <div class="ml-auto h-4 w-16 bg-base-300"></div>
          </div>
          <div class="h-4 w-full bg-base-300"></div>
          <div class="h-4 w-2/3 bg-base-300"></div>
        </div>
      </div>
    </.skeleton>
    """
  end

  defp first_use_empty_state(assigns) do
    ~H"""
    <.empty_state
      id="journal-empty-first-use"
      title="No journal entries"
      class="mx-4 mt-2 border-0 px-4 py-10"
    >
      <span class="journal-empty-icon">
        <.icon name="hero-clipboard-document-list" class="size-8 text-base-content/40" />
      </span>
      <span class="journal-empty-copy">
        Notes and photos captured at this station with the Pathways field companion appear here for review.
      </span>
    </.empty_state>
    """
  end

  defp load_error_state(assigns) do
    ~H"""
    <div class="min-h-0 flex-1 px-4 pt-2">
      <.callout
        id="journal-load-error"
        role="alert"
        kind="error"
        title="Couldn't load journal entries"
      >
        <p>The station's journal didn't respond. The floorplan and its stops are unaffected.</p>
        <.button
          id="journal-retry"
          type="button"
          variant="secondary"
          size="sm"
          class="mt-3 min-h-11"
          phx-click="refresh_journal"
        >
          Retry
        </.button>
      </.callout>
    </div>
    """
  end

  defp journal_panel_enter do
    JS.show(
      display: "flex",
      time: 180,
      transition: {"journal-panel-motion", "journal-panel-enter-start", "journal-panel-enter-end"}
    )
  end

  defp journal_panel_exit do
    JS.hide(
      time: 140,
      transition: {"journal-panel-motion", "journal-panel-exit-start", "journal-panel-exit-end"}
    )
  end

  defp target_presentation(%JournalEntry{} = entry, targets, station_name) do
    target_key = if entry.target_type == "pin", do: entry.stop_level_id, else: entry.target_id
    target = Map.get(targets, target_key)
    label = target_label(entry, target, target_key, station_name)

    {edit_event, edit_label} =
      case {entry.target_type, target} do
        {"node", target} when not is_nil(target) -> {"edit_child_stop", "Edit node"}
        {"pathway", target} when not is_nil(target) -> {"edit_pathway", "Edit pathway"}
        _ -> {nil, nil}
      end

    %{
      label: label,
      icon: target_icon(entry.target_type),
      edit_event: edit_event,
      edit_label: edit_label,
      edit_id: target_key
    }
  end

  defp target_label(%{target_type: "station"}, _target, _key, _station_name), do: "Station"

  defp target_label(%{target_type: type}, target, key, station_name) do
    kind = type |> to_string() |> String.capitalize()

    case presentation_label(target) do
      nil when is_nil(key) -> "#{kind} (removed)"
      nil -> "#{kind} · #{key} (removed)"
      label -> "#{kind} · #{strip_station_prefix(label, station_name)}"
    end
  end

  # Child-stop names conventionally embed the parent station name
  # ("Olney Transportation Center Entrance A"). Inside that station's own
  # journal the prefix is redundant, so drop it and keep the distinguishing
  # tail ("Entrance A"). Falls back to the full label when it does not match.
  defp strip_station_prefix(label, station_name)
       when is_binary(label) and is_binary(station_name) and station_name != "" do
    if String.starts_with?(label, station_name) do
      label
      |> binary_part(byte_size(station_name), byte_size(label) - byte_size(station_name))
      |> String.trim_leading()
      |> String.trim_leading("-")
      |> String.trim_leading("·")
      |> String.trim()
      |> case do
        "" -> label
        rest -> rest
      end
    else
      label
    end
  end

  defp strip_station_prefix(label, _station_name), do: label

  defp presentation_label(nil), do: nil

  defp presentation_label(target) when is_map(target) do
    [:label, :name, :stop_name, :stop_id, :pathway_id, :level_name, :id]
    |> Enum.find_value(fn key ->
      case Map.get(target, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp target_icon("station"), do: "hero-building-office-2"
  defp target_icon("node"), do: "hero-map-pin"
  defp target_icon("pathway"), do: "hero-arrows-right-left"
  defp target_icon(_type), do: "hero-map-pin"

  defp local_time(entry, kind, local_times) do
    case Map.get(local_times, {entry.id, kind}) do
      %NaiveDateTime{} = local ->
        local

      _ ->
        entry
        |> utc_time(kind)
        |> fallback_local_time()
    end
  end

  defp utc_time(entry, :captured), do: entry.captured_at

  defp fallback_local_time(%DateTime{} = timestamp), do: DateTime.to_naive(timestamp)
  defp fallback_local_time(_timestamp), do: nil

  defp loaded_photos(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_photos(photos) when is_list(photos), do: photos
  defp loaded_photos(_photos), do: []

  defp collection_member?(%MapSet{} = collection, value), do: MapSet.member?(collection, value)
  defp collection_member?(collection, value) when is_list(collection), do: value in collection
  defp collection_member?(_collection, _value), do: false

  defp collection_count(%MapSet{} = collection), do: MapSet.size(collection)
  defp collection_count(collection) when is_list(collection), do: length(collection)
  defp collection_count(_collection), do: 0

  defp panel_state(_assigns, true, _first_load_error?), do: "loading"
  defp panel_state(_assigns, _first_loading?, true), do: "error"
  defp panel_state(%{journal_state: :error}, _first_loading?, _first_load_error?), do: "stale"

  defp panel_state(%{journal_open_count: 0, journal_closed_count: 0}, _loading?, _error?),
    do: "empty"

  defp panel_state(_assigns, _first_loading?, _first_load_error?), do: "ready"

  defp note_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> "No note provided"
      note -> note
    end
  end

  defp note_body(_body), do: "No note provided"

  defp zone_title(local, %{timezone: timezone}) when is_binary(timezone),
    do: absolute_time(local) <> " " <> timezone

  defp zone_title(local, _zone), do: absolute_time(local)

  attr :entity_type, :string, required: true
  attr :entity_id, :string, required: true
  attr :entity_label, :string, required: true
  attr :journal_entries, :any, required: true

  attr :journal_state, :atom,
    default: :idle,
    values: [:idle, :initial_loading, :ready, :refreshing, :error]

  attr :journal_entries_exist?, :boolean, default: false
  attr :journal_error_fallback?, :boolean, default: false
  attr :journal_scope, Scope, required: true
  attr :journal_authors, :map, default: %{}
  attr :journal_local_times, :map, default: %{}
  attr :journal_now, :any, default: nil

  @doc """
  Renders an entity-scoped journal panel for a stop or pathway edit drawer.

  Consumes `journal_entries` stream tuples directly under a `phx-update="stream"`
  parent. Each card renders the note body, zero or more photo thumbnails linked
  to the scoped public path (new tab), author byline, and localized capture
  time — without a target chip, lifecycle controls, status indicators, or
  panel-handoff actions.
  """
  def entity_journal_panel(assigns) do
    now = assigns.journal_now || NaiveDateTime.utc_now()

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(:id_prefix, "drawer-journal-#{assigns.entity_type}")
      |> assign(:panel_id, "drawer-journal-#{assigns.entity_type}-#{assigns.entity_id}")
      |> assign(:loading?, assigns.journal_state == :initial_loading)
      |> assign(:refreshing?, assigns.journal_state == :refreshing)
      |> assign(
        :initial_error?,
        assigns.journal_state == :error and not assigns.journal_error_fallback?
      )
      |> assign(
        :stale_error?,
        assigns.journal_state == :error and assigns.journal_error_fallback?
      )
      |> assign(
        :show_entries?,
        assigns.journal_state not in [:idle, :initial_loading] and assigns.journal_entries_exist?
      )
      |> assign(
        :show_empty?,
        assigns.journal_state == :ready and not assigns.journal_entries_exist?
      )

    ~H"""
    <div
      id={@panel_id}
      data-role="entity-journal-panel"
      class="space-y-3"
    >
      <.entity_journal_loading :if={@loading?} id_prefix={@id_prefix} />

      <div
        :if={@refreshing?}
        id={"#{@id_prefix}-refreshing"}
        class="flex items-center gap-2 border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content"
      >
        <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
        <span>Refreshing journal entries</span>
      </div>

      <.callout
        :if={@initial_error?}
        kind="error"
        id={"#{@id_prefix}-error"}
        title="Journal entries could not load"
      >
        <p>
          The journal for this {@entity_label} did not load. The form and other tabs are unaffected.
        </p>
        <div class="mt-3">
          <.button
            id={"#{@id_prefix}-retry"}
            size="sm"
            phx-click="retry_drawer_journal"
            class="min-h-11"
          >
            Retry
          </.button>
        </div>
      </.callout>

      <.callout
        :if={@stale_error?}
        kind="error"
        id={"#{@id_prefix}-stale-error"}
        title="Journal entries may be out of date"
      >
        <p>
          The journal for this {@entity_label} failed to refresh. The last saved entries remain available.
        </p>
        <div class="mt-3">
          <.button
            id={"#{@id_prefix}-retry"}
            size="sm"
            phx-click="retry_drawer_journal"
            class="min-h-11"
          >
            Retry
          </.button>
        </div>
      </.callout>

      <.empty_state
        :if={@show_empty?}
        id={"#{@id_prefix}-empty"}
        title={"No journal entries for this #{@entity_label}"}
      >
        Notes and photos captured in the field for this {@entity_label} appear here once they are synced.
      </.empty_state>

      <div
        :if={@show_entries?}
        id={"#{@id_prefix}-entry-list"}
        phx-update="stream"
        class="space-y-2.5"
      >
        <.entity_journal_card
          :for={{dom_id, entry} <- @journal_entries}
          id={dom_id}
          entry={entry}
          scope={@journal_scope}
          author={Map.get(@journal_authors, entry.author_id)}
          captured_local={entity_local_time(entry, @journal_local_times)}
          now={@now}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, JournalEntry, required: true
  attr :scope, Scope, required: true
  attr :author, :any, default: nil
  attr :captured_local, NaiveDateTime, required: true
  attr :now, NaiveDateTime, required: true

  defp entity_journal_card(assigns) do
    photos = loaded_photos(assigns.entry.photos)

    assigns =
      assigns
      |> assign(:photos, photos)
      |> assign(:photo_count, length(photos))
      |> assign(:byline, author_label(assigns.author))
      |> assign(:relative_capture, relative_time(assigns.captured_local, assigns.now))

    ~H"""
    <article
      id={@id}
      data-role="entity-journal-entry"
      class="bg-white border border-gray-200 rounded-lg px-4 py-3"
    >
      <p
        data-role="journal-note"
        class="text-sm text-gray-800 leading-relaxed break-words [overflow-wrap:anywhere]"
      >
        {note_body(@entry.body)}
      </p>

      <div :if={@photo_count > 0} class="flex flex-wrap gap-1.5 mt-2.5">
        <a
          :for={photo <- @photos}
          id={"entity-journal-photo-#{photo.id}"}
          href={PhotoStorage.public_path(@scope, photo)}
          target="_blank"
          rel="noopener noreferrer"
          class="block size-14 shrink-0 overflow-hidden rounded-md border border-base-300 bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
          aria-label={"View journal photo #{photo.id}"}
        >
          <img
            src={PhotoStorage.public_path(@scope, photo)}
            alt="Journal photo"
            loading="lazy"
            decoding="async"
            class="h-full w-full object-cover"
          />
        </a>
      </div>

      <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/70">
        <span class="min-w-0 truncate">
          <span>{@byline}</span>
          <span aria-hidden="true">·</span>
          <time datetime={DateTime.to_iso8601(@entry.captured_at)}>
            {@relative_capture}
          </time>
        </span>
      </div>
    </article>
    """
  end

  attr :id_prefix, :string, required: true

  defp entity_journal_loading(assigns) do
    ~H"""
    <.skeleton
      id={"#{@id_prefix}-loading"}
      label="Loading journal entries"
      rows={3}
      class="journal-loading-delay"
      aria-busy="true"
    />
    """
  end

  defp entity_local_time(entry, local_times) do
    case Map.get(local_times, {entry.id, :captured}) do
      %NaiveDateTime{} = local ->
        local

      _ ->
        entry.captured_at
        |> case do
          %DateTime{} = dt -> DateTime.to_naive(dt)
          _ -> nil
        end
    end
  end

  defp title_token(token) do
    token
    |> String.downcase()
    |> String.capitalize()
  end
end
