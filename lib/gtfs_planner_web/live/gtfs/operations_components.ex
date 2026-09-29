defmodule GtfsPlannerWeb.Gtfs.OperationsComponents do
  @moduledoc """
  Function components shared by the Garages and Fleet pages.

  Garages, vehicle types and vehicles belong to the organization rather than to a
  GTFS version, so both pages import the same TODS files through one drawer whose
  copy and derived apply state stay in one place.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, message: 1]

  # AC-22 bounds each listed row group; the remainder is reported as a count.
  @note_limit 100

  # The prepared AC-22 message for an apply whose recomputed plan no longer
  # matches the reviewed preview.
  @stale_message "Records changed since the preview. Review the updated counts, then import again."

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
      |> assign(:counts, import_counts(assigns.kind, review))
      |> assign(:apply_label, import_label(assigns.kind, apply_count))
      |> assign(:importable?, disabled_reason == nil)
      |> assign(:disabled_reason, disabled_reason)
      |> assign(:error_message, import_error_message(assigns.stale?, assigns.parse_error))

    ~H"""
    <.drawer
      id="tods-import-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title={"Import #{kind_label(@kind)}"}
      initial_focus={:first_field}
      return_focus_id={@return_focus_id}
      class="max-w-[520px]"
    >
      <:lede>Shared across all versions</:lede>

      <div id="tods-import-content" phx-hook="FormErrorFocus" class="flex min-h-0 flex-1 flex-col">
        <%!-- LiveView starts a file upload from the input's change event, which it
        routes through the surrounding form, so the field needs one even though the
        drawer carries no other form state. --%>
        <form
          id="tods-import-form"
          phx-change={@on_validate}
          phx-submit={@on_apply}
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <p id="tods-import-description" class="text-sm text-default">
              {kind_intro(@kind)}
            </p>

            <.message
              :if={@error_message}
              id="tods-import-error"
              kind="error"
              title="Import not applied"
              tabindex="-1"
            >
              {@error_message}
            </.message>

            <.upload_field
              id="tods-file-upload"
              upload={@upload}
              label="TODS file"
              help={kind_file_help(@kind)}
              cancel_event={@on_cancel_upload}
            />

            <div :if={@preview?} id="tods-import-preview" class="grid gap-5">
              <h3 class="text-base font-bold text-strong">Review {@filename}</h3>

              <div class="flex flex-wrap gap-x-9 gap-y-4">
                <div :for={count <- @counts}>
                  <strong
                    id={count.id}
                    class={[
                      "block font-display text-[28px] font-semibold leading-none tabular-nums",
                      count.tone
                    ]}
                  >
                    {count.value}
                  </strong>
                  <span class="mt-1 block text-[13px] text-muted">{count.label}</span>
                </div>
              </div>

              <%!-- The message spreads global attributes onto its own class list, so a
              margin would have to sit on a wrapper; the grid gap spaces it. --%>
              <.message id="tods-import-scope" kind="info" title="What gets imported">
                {kind_scope(@kind)}
              </.message>

              <.note_list
                :if={@error_count > 0}
                id="tods-import-errors"
                more_id="tods-import-errors-more"
                title="Rows to fix"
                count={@error_count}
                tone="text-error-fg"
                notes={@error_rows}
                more={@error_more}
              />

              <.note_list
                :if={@skipped_count > 0}
                id="tods-import-skipped"
                more_id="tods-import-skipped-more"
                title="Skipped rows"
                count={@skipped_count}
                tone="text-strong"
                notes={@skipped_rows}
                more={@skipped_more}
              />

              <div :if={@ignored_columns != []}>
                <h4 class="text-[13px] font-[650] text-default">Columns not used</h4>
                <ul id="tods-import-ignored" class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-[13px]">
                  <li :for={column <- @ignored_columns} class="font-mono text-muted">{column}</li>
                </ul>
              </div>
            </div>
          </.drawer_scroll>

          <.drawer_footer>
            <%!-- The reason names why the apply action is unavailable, and it sits
            with the control that cannot be used. --%>
            <p
              :if={@disabled_reason}
              id="tods-import-apply-reason"
              class="basis-full text-[13px] text-muted"
            >
              {@disabled_reason}
            </p>

            <.button type="button" variant="secondary" class="min-h-11" phx-click={@on_close}>
              Cancel
            </.button>
            <.button
              id="apply-tods-import"
              type="button"
              class="min-h-11"
              disabled={!@importable?}
              data-unavailable={!@importable?}
              phx-click={@on_apply}
              phx-disable-with="Importing…"
            >
              {@apply_label}
            </.button>
          </.drawer_footer>
        </form>
      </div>
    </.drawer>
    """
  end

  # One bounded group of row notes: what the row is and why it is listed. The
  # note text comes from `Tods.classify/1` and stays one string so a row reads
  # the same wherever it is quoted.
  attr :id, :string, required: true
  attr :more_id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :tone, :string, required: true
  attr :notes, :list, required: true
  attr :more, :integer, required: true

  defp note_list(assigns) do
    ~H"""
    <div>
      <h4 class={["text-sm font-bold", @tone]}>{@title} ({@count})</h4>
      <ul id={@id} class="mt-2 grid text-sm">
        <li :for={note <- @notes} class="border-t border-subtle py-2 [overflow-wrap:anywhere]">
          {note_text(note)}
        </li>
      </ul>
      <p :if={@more > 0} id={@more_id} class="border-t border-subtle pt-2 text-[13px] text-muted">
        {@more} more
      </p>
    </div>
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
  # twice. Errors read in the error ink only when there is one to fix.
  defp import_counts(kind, %{add_count: add, update_count: update} = review) do
    [
      %{id: "tods-import-count-add", label: "New #{kind_label(kind)}", value: add, tone: nil},
      %{id: "tods-import-count-update", label: "Updated", value: update, tone: nil},
      %{
        id: "tods-import-count-skipped",
        label: "Skipped",
        value: review.skipped_count,
        tone: nil
      },
      %{
        id: "tods-import-count-error",
        label: "Errors",
        value: review.error_count,
        tone: if(review.error_count > 0, do: "text-error-fg", else: "text-strong")
      }
    ]
  end

  # With nothing to apply the label names the action, not a count of zero.
  defp import_label(:garages, 0), do: "Import garages"
  defp import_label(:garages, 1), do: "Import 1 garage"
  defp import_label(:garages, count), do: "Import #{count} garages"
  defp import_label(:vehicles, 0), do: "Import vehicles"
  defp import_label(:vehicles, 1), do: "Import 1 vehicle"
  defp import_label(:vehicles, count), do: "Import #{count} vehicles"

  defp kind_label(:garages), do: "garages"
  defp kind_label(:vehicles), do: "vehicles"

  defp kind_intro(kind) do
    "Add or update #{kind_label(kind)} from a TODS file exported by your operations system. Nothing changes until you review the file and import it."
  end

  defp kind_file_help(:garages),
    do: "One .txt or .csv file, up to 2 MB. It's usually named stops_supplement.txt."

  defp kind_file_help(:vehicles),
    do: "One .txt or .csv file, up to 2 MB. It's usually named vehicles.txt."

  # What an import leaves alone, so nobody has to guess what a file can overwrite:
  # `Operations.apply_tods_import/4` never touches a garage's address or a
  # vehicle's type and garage, and never deletes a record the file omits.
  defp kind_scope(:garages),
    do:
      "Only garage rows. Public stops aren't changed. A garage already here is updated from the file's name and coordinates, and keeps its address and vehicles. Garages the file doesn't list stay as they are."

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
