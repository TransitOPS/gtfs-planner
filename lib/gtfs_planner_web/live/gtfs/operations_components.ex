defmodule GtfsPlannerWeb.Gtfs.OperationsComponents do
  @moduledoc """
  Function components shared by the Garages and Fleet pages.

  Garages, vehicle types and vehicles belong to the organization rather than to a
  GTFS version, so both pages carry the same all-versions scope note next to
  their introduction, and both import the same TODS files through one drawer
  whose copy and derived apply state stay in one place.
  """

  use GtfsPlannerWeb, :html

  # AC-22 bounds each listed row group; the remainder is reported as a count.
  @note_limit 100

  # The prepared AC-22 message for an apply whose recomputed plan no longer
  # matches the reviewed preview.
  @stale_message "Records changed since the preview. Review the updated counts, then import again."

  @doc """
  Renders the shared-scope note naming the organization these assets belong to.

  ## Examples

      <.scope_note organization_name={@current_organization.name} class="mt-2" />
  """
  attr :organization_name, :string, required: true
  attr :class, :any, default: nil

  def scope_note(assigns) do
    ~H"""
    <p class={["text-sm text-base-content/70", @class]}>
      <span class="mr-1 text-brand" aria-hidden="true">●</span>Shared across all service versions for {@organization_name}.
    </p>
    """
  end

  @doc """
  Whether a held review still describes the file the operator chose.

  A pending or rejected entry in `upload` means a replacement file has already
  been picked, so the plan held for the previous one no longer describes what the
  drawer shows. The drawer and the page's apply event read this one rule, so the
  control and the write can never disagree about which file is being reviewed.
  """
  @spec tods_review_current?(map() | nil, Phoenix.LiveView.UploadConfig.t()) :: boolean()
  def tods_review_current?(preview, upload) do
    is_map(preview) and upload.entries == [] and upload.errors == []
  end

  @doc """
  Renders the TODS import drawer both Blocks pages share.

  The page owns the upload, the parse and the apply; this component owns the
  import copy and the state derived from them. `preview` is the classification
  `Operations.preview_tods_import/2` returned for the file that was reviewed, so
  the counts, the skipped and error reasons and the ignored columns are exactly
  the module's output.

  Every outcome that leaves nothing to import — no review yet, an upload the
  browser rejected, a parse that returned a message, a preview whose recomputed
  plan changed, a preview with row errors, or a preview with nothing to add or
  update — keeps the drawer open, disables the apply action and states why.

  ## Examples

      <.tods_import_drawer
        open={@tods_import_open}
        kind={:garages}
        upload={@uploads.tods_file}
        preview={@tods_import_preview}
        filename={@tods_import_filename}
        parse_error={@tods_import_parse_error}
        stale?={@tods_import_stale?}
        return_focus_id={@tods_import_return_focus_id}
      />
  """
  attr :open, :boolean, required: true
  attr :kind, :atom, values: [:garages, :vehicles], required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :preview, :map, default: nil
  attr :filename, :string, default: nil
  attr :parse_error, :string, default: nil
  attr :stale?, :boolean, default: false
  attr :return_focus_id, :string, default: nil
  attr :on_close, :string, default: "close_tods_import_drawer"
  attr :on_apply, :string, default: "apply_tods_import"
  attr :on_cancel_upload, :string, default: "cancel_tods_upload"

  attr :on_validate, :string,
    default: "validate_tods_import",
    doc: "acknowledges the form change LiveView routes the file input's change through"

  def tods_import_drawer(assigns) do
    review = import_review(assigns.preview, assigns.upload)
    {apply_count, disabled_reason} = import_apply_state(review, assigns.upload)

    assigns =
      assigns
      |> assign(review)
      |> assign(:counts, import_counts(review))
      |> assign(:apply_label, import_label(assigns.kind, apply_count))
      |> assign(:importable?, disabled_reason == nil)
      |> assign(:disabled_reason, disabled_reason)
      |> assign(:error_message, import_error_message(assigns.stale?, assigns.parse_error))

    ~H"""
    <.drawer
      id="tods-import-drawer"
      open={@open}
      on_close={@on_close}
      title={"Import #{kind_label(@kind)}"}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
    >
      <div id="tods-import-content" phx-hook="FormErrorFocus">
        <p id="tods-import-description" class="mb-4 text-sm text-base-content/70">
          Choose {kind_file(@kind)} from your operations system.
        </p>

        <div :if={@error_message} class="mb-4">
          <.callout id="tods-import-error" kind="error" title="Import not applied" tabindex="-1">
            {@error_message}
          </.callout>
        </div>

        <%!-- LiveView starts a file upload from the input's change event, which it
        routes through the surrounding form, so the field needs one even though the
        drawer carries no other form state. --%>
        <form id="tods-import-form" phx-change={@on_validate} phx-submit={@on_apply}>
          <.upload_field
            id="tods-file-upload"
            upload={@upload}
            label="TODS file"
            help="One .txt or .csv file, up to 2 MB. Review the changes before importing."
            cancel_event={@on_cancel_upload}
          />

          <div :if={@preview?} id="tods-import-preview" class="mt-6">
            <h3 class="font-semibold">Review {@filename}</h3>

            <div class="mt-3 flex flex-wrap gap-7">
              <div :for={count <- @counts}>
                <strong id={count.id} class="block text-2xl font-semibold tabular-nums">
                  {count.value}
                </strong>
                <span class="text-sm text-base-content/70">{count.label}</span>
              </div>
            </div>

            <%!-- `callout/1` spreads global attributes next to its own class, so the
          margin lives on a wrapper rather than being passed to the component. --%>
            <div class="mt-4">
              <.callout id="tods-import-scope" kind="info" title="What gets imported">
                {kind_scope(@kind)}
              </.callout>
            </div>

            <div :if={@skipped_count > 0} class="mt-4">
              <h4 class="text-sm font-semibold">Skipped rows</h4>
              <ul id="tods-import-skipped" class="mt-1 space-y-1 text-sm">
                <li :for={note <- @skipped_rows}>{note_text(note)}</li>
              </ul>
              <p
                :if={@skipped_more > 0}
                id="tods-import-skipped-more"
                class="text-sm text-base-content/70"
              >
                {@skipped_more} more
              </p>
            </div>

            <div :if={@error_count > 0} class="mt-4">
              <h4 class="text-sm font-semibold">Rows with errors</h4>
              <ul id="tods-import-errors" class="mt-1 space-y-1 text-sm">
                <li :for={note <- @error_rows}>{note_text(note)}</li>
              </ul>
              <p
                :if={@error_more > 0}
                id="tods-import-errors-more"
                class="text-sm text-base-content/70"
              >
                {@error_more} more
              </p>
            </div>

            <div :if={@ignored_columns != []} class="mt-4">
              <h4 class="text-sm font-semibold">Ignored columns</h4>
              <ul id="tods-import-ignored" class="mt-1 text-sm text-base-content/70">
                <li :for={column <- @ignored_columns}>{column}</li>
              </ul>
            </div>
          </div>

          <div class="mt-6 flex flex-wrap items-center gap-3">
            <.button
              id="apply-tods-import"
              type="button"
              class="min-h-11"
              disabled={!@importable?}
              phx-click={@on_apply}
              phx-disable-with="Importing…"
            >
              {@apply_label}
            </.button>
            <.button type="button" variant="quiet" class="min-h-11" phx-click={@on_close}>
              Cancel
            </.button>
          </div>

          <p
            :if={@disabled_reason}
            id="tods-import-apply-reason"
            class="mt-2 text-sm text-base-content/70"
          >
            {@disabled_reason}
          </p>
        </form>
      </div>
    </.drawer>
    """
  end

  # What the drawer can say about the review it holds. Every count, note list and
  # the ignored columns come from the reviewed preview, so the counts and the
  # bounded note lists cannot disagree about what that file contained.
  defp import_review(preview, upload) do
    current? = tods_review_current?(preview, upload)
    {skipped, errors} = if current?, do: {preview.skipped, preview.errors}, else: {[], []}

    %{
      preview?: current?,
      add_count: if(current?, do: length(preview.add), else: 0),
      update_count: if(current?, do: length(preview.update), else: 0),
      skipped_count: length(skipped),
      error_count: length(errors),
      skipped_rows: Enum.take(skipped, @note_limit),
      skipped_more: max(length(skipped) - @note_limit, 0),
      error_rows: Enum.take(errors, @note_limit),
      error_more: max(length(errors) - @note_limit, 0),
      ignored_columns: if(current?, do: preview.ignored_columns, else: [])
    }
  end

  # The apply label's count and, when the action is unavailable, the visible
  # reason. A file the browser is sending or already refused has replaced the
  # reviewed one, so nothing on screen may be applied from the older plan.
  defp import_apply_state(review, upload) do
    apply_count = review.add_count + review.update_count

    reason =
      cond do
        upload.entries != [] or upload.errors != [] -> "Choose a different file to review."
        not review.preview? -> "Choose a TODS file to review."
        review.error_count > 0 -> "Fix the rows marked as errors before importing."
        apply_count == 0 -> "Nothing to import: every row is skipped or unchanged."
        true -> nil
      end

    {apply_count, reason}
  end

  # The four counts keep the reference's number-over-label shape. The apply label
  # reads them through `import_label/2`, so the count never has to be derived
  # twice.
  defp import_counts(%{add_count: add, update_count: update} = review) do
    [
      %{id: "tods-import-count-add", label: "Add", value: add},
      %{id: "tods-import-count-update", label: "Update", value: update},
      %{id: "tods-import-count-skipped", label: "Skipped", value: review.skipped_count},
      %{id: "tods-import-count-error", label: "Error", value: review.error_count}
    ]
  end

  defp import_label(:garages, 1), do: "Import 1 garage"
  defp import_label(:garages, count), do: "Import #{count} garages"
  defp import_label(:vehicles, 1), do: "Import 1 vehicle"
  defp import_label(:vehicles, count), do: "Import #{count} vehicles"

  defp kind_label(:garages), do: "garages"
  defp kind_label(:vehicles), do: "vehicles"

  defp kind_file(:garages), do: "stops_supplement.txt"
  defp kind_file(:vehicles), do: "vehicles.txt"

  defp kind_scope(:garages),
    do: "Only garage rows are imported. Public stops stay unchanged."

  defp kind_scope(:vehicles),
    do:
      "Vehicle IDs, labels and plates are imported. Existing type and garage assignments stay unchanged; new vehicles start unassigned."

  defp import_error_message(true, _parse_error), do: @stale_message
  defp import_error_message(false, parse_error) when is_binary(parse_error), do: parse_error
  defp import_error_message(_stale?, _parse_error), do: nil

  defp note_text(note) do
    "Row #{note.row} · #{note.id || "No ID"} · #{note.reason}"
  end
end
