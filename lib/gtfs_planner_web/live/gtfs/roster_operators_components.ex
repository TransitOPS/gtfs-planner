defmodule GtfsPlannerWeb.Gtfs.RosterOperatorsComponents do
  @moduledoc """
  The operators drawer: the organization's list of operators, and the form that
  adds one or edits one.

  Operators are the one roster input the organization owns across every version,
  so this drawer is not version-scoped: its lede says so, and the Line column is
  the *this version's* line only, because a line is a fact of one version's week
  while an operator is a fact of the organization.

  ## The order is the organization's, not this page's

  `Operations.list_operators/1` already answers the one order AC-4 asks for —
  seniority ascending with blanks last, then employee ID, then unnumbered
  operators by name. `RostersLive` reads that list once when the drawer opens and
  hands the rows here in that order, so the table and the pick select cannot
  disagree about who is most senior (domain rule 11).

  ## The form validates on blur, and the blur is what the page believes

  Each field carries `phx-blur` and `phx-debounce="blur"`, and the page keeps the
  set of fields the editor has left at least once. An error is drawn for a field
  only after that field has been blurred, or after a submit, so a reader who is
  halfway through an employee ID is not told the employee ID is wrong while
  typing it. The rules themselves are `GtfsPlanner.Operations.Operator`'s
  changeset, run with the `:validate` action: this module draws the result and
  invents none of it.

  ## Only these three values are stored

  The form says so in its own words, because the alternative is a reader
  wondering what else the app keeps about their staff (domain rules 11 and 12,
  and the "Operator data stays minimal" criterion). An employee ID another
  operator already holds is refused by the writer with the holder's name, and the
  refusal is the writer's own sentence under the field — the page never computes
  a second answer to the same question (domain rule 13).
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents,
    only: [drawer_footer: 1, drawer_scroll: 1, form_error_summary: 1, message: 1]

  alias GtfsPlanner.Wording

  # AC-22 bounds each listed row group; the remainder is reported as a count, so
  # a 5,000-row HR export cannot turn the review into an unusable wall.
  @note_limit 100

  # The prepared refusal for an apply whose recomputed plan no longer matches the
  # review on screen. The context hands back the fresh preview rather than
  # writing, so the reader is told what changed and asked to look again.
  @stale_message "Operators changed since the preview. Review the updated counts, then import again."

  @doc """
  The operators drawer: the organization's operators in seniority order.

  `lines` maps an operator id to the line number that operator holds *in this
  version*, because the table's Line column is about this version's week and an
  operator belongs to no version at all. An operator nobody here holds reads
  "No line" rather than an empty cell, so the column says the same thing in
  every row.

  With no operators at all the empty state is drawn instead of the table: a table
  with a header and nothing under it is a table with nothing to say, and the
  sentence below says what belongs here instead.

  The footer's one primary is "Add operator". Editing is reached by selecting a
  name in the table, which is the row's own identifier — the same choice the
  prototype and the pick row make.
  """
  attr :open, :boolean, default: true
  attr :operators, :list, required: true
  attr :lines, :map, required: true, doc: "operator id to the line number held in this version"
  attr :on_close, :string, default: "close_operators"

  def operators_drawer(assigns) do
    assigns = assign(assigns, :held_count, map_size(assigns.lines))

    ~H"""
    <.drawer
      id="rosters-operators-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title="Operators"
      class="max-w-[720px]"
    >
      <:lede>
        <span id="rosters-operators-lede">
          {length(@operators)} {if length(@operators) == 1, do: "operator", else: "operators"} · {@held_count} hold a line in this version
        </span>
      </:lede>

      <.drawer_scroll>
        <p id="rosters-operators-order" class="text-[13px] text-muted">
          Most senior first; operators without a seniority number follow by name. Select a name to edit or delete it.
        </p>

        <p :if={@operators == []} id="rosters-operators-empty" class="py-10 text-center">
          <span class="block font-display text-[20px] font-semibold text-strong">
            No operators yet
          </span>
          <span class="mx-auto mt-2 block max-w-[400px] text-sm text-muted">
            Add operators one at a time, or import a CSV file of employee IDs and names.
          </span>
        </p>

        <div
          :if={@operators != []}
          class="mt-3 overflow-x-auto rounded-control border border-subtle"
        >
          <table id="rosters-operators-table" class="w-full border-separate border-spacing-0 text-sm">
            <caption class="sr-only">Operators</caption>
            <thead>
              <tr class="border-b border-subtle bg-canvas text-[13px] text-muted">
                <th
                  scope="col"
                  title="1 is most senior"
                  class="px-3 py-2 text-right font-semibold text-strong"
                >
                  Seniority
                </th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Employee ID</th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Name</th>
                <th scope="col" class="px-3 py-2 font-semibold text-strong">Line</th>
              </tr>
            </thead>
            <tbody id="rosters-operators-rows">
              <tr
                :for={operator <- @operators}
                id={"rosters-operator-#{operator.id}"}
                class="border-b border-subtle last:border-b-0 hover:bg-canvas"
              >
                <td class="tabular px-3 py-1 text-right align-middle">
                  <span :if={operator.seniority_number}>{operator.seniority_number}</span>
                  <span :if={is_nil(operator.seniority_number)} class="text-muted">—</span>
                </td>
                <td class="px-3 py-1 align-middle font-mono text-[13px]">{operator.employee_id}</td>
                <td class="px-3 py-1 align-middle">
                  <button
                    type="button"
                    id={"rosters-edit-operator-#{operator.id}"}
                    phx-click="edit_operator"
                    phx-value-id={operator.id}
                    aria-label={"Edit #{operator.display_name}"}
                    class="-ml-1 inline-flex min-h-11 items-center rounded-control px-1 text-sm font-[650] text-action underline underline-offset-4 hover:text-action-hover focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  >
                    {operator.display_name}
                  </button>
                </td>
                <td class="px-3 py-1 align-middle">
                  <span :if={Map.get(@lines, operator.id)}>
                    Line {Map.get(@lines, operator.id)}
                  </span>
                  <span :if={is_nil(Map.get(@lines, operator.id))} class="text-muted">No line</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.drawer_scroll>

      <.drawer_footer>
        <%!-- Import is the second way in and stays secondary: one operator at a
        time is the ordinary case, and a file is the larger, less common one. --%>
        <.button
          id="rosters-import-operators"
          type="button"
          variant="secondary"
          class="min-h-11"
          phx-click="open_operator_import"
          phx-value-opener_id="rosters-import-operators"
        >
          Import operators
        </.button>
        <.button
          id="rosters-drawer-add-operator"
          type="button"
          class="min-h-11"
          phx-click="new_operator"
        >
          Add operator
        </.button>
      </.drawer_footer>
    </.drawer>
    """
  end

  @doc """
  The add/edit form for one operator, in the same drawer.

  The three fields are the three stored values and nothing else; the sentence
  under them says so, because a form that shows three fields already answers the
  question and saying it in words costs one line.

  Errors are drawn under the field they name, and the summary at the top of the
  scrolling body appears only after a submit was refused — live validation is not
  a rejection and must not produce a panel that scolds a reader who is still
  typing (see `PlannerComponents.form_error_summary/1`).

  An operator who holds a line in this version is told so, and where the pick
  lives: the pick is a fact about the bid recorded in the grid, and this form is
  not where it changes.

  The footer's one primary is the save, and its label is what will have happened:
  "Add operator" for a new one, "Save operator" for an edit.
  """
  attr :open, :boolean, default: true
  attr :form, :any, required: true
  attr :editing, :boolean, default: false
  attr :name, :string, default: nil, doc: "the operator being edited; nil when adding"
  attr :line_number, :integer, default: nil
  attr :failures, :list, default: []
  attr :on_close, :string, default: "cancel_operator"
  attr :on_delete, :string, default: "ask_delete_operator"
  attr :operator_id, :string, default: nil, doc: "the operator being edited; nil when adding"

  def operator_form(assigns) do
    ~H"""
    <.drawer
      id="rosters-operators-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title={if @editing, do: "Edit #{@name}", else: "Add operator"}
      class="max-w-[640px]"
    >
      <:lede>
        <span id="rosters-operator-form-lede">Operators · shared by every version</span>
      </:lede>

      <%!-- The scoped `FormErrorFocus` hook the save pushes to lives inside this
      drawer, not on the page: the hook only focuses a target it already owns, and
      a form in a drawer is not inside the page region. --%>
      <div
        id="rosters-operator-form-content"
        phx-hook="FormErrorFocus"
        class="flex min-h-0 flex-1 flex-col"
      >
        <.form
          for={@form}
          id="rosters-operator-form"
          novalidate
          phx-change="validate_operator"
          phx-submit="save_operator"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <.form_error_summary
              id="rosters-operator-form-errors"
              title="Fix these to save the operator"
              failures={@failures}
              class=""
            />

            <.input
              field={@form[:employee_id]}
              type="text"
              label="Employee ID"
              help="The ID your payroll or scheduling system uses. The export writes it as employee_id."
              autocomplete="off"
              class="input input-lg w-56 font-mono"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <.input
              field={@form[:display_name]}
              type="text"
              label="Display name"
              autocomplete="off"
              class="input input-lg"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <.input
              field={@form[:seniority_number]}
              type="text"
              label="Seniority number (optional)"
              help="1 is most senior. Used only to order this list and the pick."
              autocomplete="off"
              inputmode="numeric"
              class="input input-lg w-28"
              phx-debounce="blur"
              phx-blur="validate_operator"
            />

            <p class="text-[13px] text-muted">
              Only these three values are stored. No contact details, pay or status.
            </p>

            <p :if={@line_number} id="rosters-operator-holds-line" class="text-sm text-default">
              {@name} holds <strong class="font-semibold text-strong">line {@line_number}</strong>.
              Change the pick in the roster grid.
            </p>
          </.drawer_scroll>

          <.drawer_footer>
            <%!-- The destructive action sits at the opposite edge from the save, as
            the drawer's own rules ask, and it is drawn only while editing: there
            is nothing to delete when adding. --%>
            <.button
              :if={@editing}
              id="rosters-delete-operator"
              type="button"
              variant="danger"
              class="min-h-11 mr-auto"
              phx-click={@on_delete}
              phx-value-id={@operator_id}
            >
              Delete operator
            </.button>
            <.button
              id="rosters-operator-cancel"
              type="button"
              variant="secondary"
              class="min-h-11"
              phx-click={@on_close}
            >
              Cancel
            </.button>
            <.button
              id="rosters-operator-save"
              type="submit"
              class="min-h-11"
              phx-disable-with="Saving…"
            >
              {if @editing, do: "Save operator", else: "Add operator"}
            </.button>
          </.drawer_footer>
        </.form>
      </div>
    </.drawer>
    """
  end

  @doc """
  The delete confirmation: what the operator is, what stops being theirs, and
  that it cannot be undone.

  The held lines are read with `Gtfs.roster_operator_holdings/2`, which answers
  across every version of the organization, because a hard delete empties a pick
  in every version and not only in the one on screen. When any of those lines is
  in another version the sentence names the version each line belongs to —
  "Line 4 in 2027 spring becomes Open" — because this page cannot otherwise
  account for a line the reader is not looking at. When every held line is in
  this version the version is left out: the reader is looking at it.

  An operator nobody holds says only what is removed from them. There is no
  consequence to name, and a sentence about lines that do not exist is worse
  than none.

  The confirmation's destructive button repeats the verb and the object —
  "Delete operator" — so the action is readable from the button alone, and
  "Keep operator" is the way out. The dialog returns focus to the control that
  opened it, which is still in the form the reader came from.
  """
  attr :open, :boolean, default: true
  attr :name, :string, required: true
  attr :holdings, :list, default: []
  attr :version_id, :string, required: true, doc: "the version on screen"

  def delete_operator_confirm(assigns) do
    assigns =
      assign(assigns, :sentence, open_lines_sentence(assigns.holdings, assigns.version_id))

    ~H"""
    <.confirm_dialog
      id="rosters-delete-operator-confirm"
      chrome="planner"
      open={@open}
      title={"Delete #{@name}?"}
      confirm_label="Delete operator"
      cancel_label="Keep operator"
      pending_label="Deleting…"
      on_confirm="confirm_delete_operator"
      on_cancel="cancel_delete_operator"
      return_focus_id="rosters-delete-operator"
    >
      <p id="rosters-delete-operator-body">
        <span :if={@sentence}>{@sentence}</span>
        Their name, employee ID and seniority number are removed from the app.
      </p>
    </.confirm_dialog>
    """
  end

  @doc """
  The import view of the same drawer: a CSV file, then a review of what it says.

  The page owns the upload, the parse and the apply; this component owns the
  copy and the state derived from them. `import_state` is the map `RostersLive`
  holds for the view, and `preview` inside it is exactly what
  `Operations.preview_operator_import/2` returned for the file on screen, so the
  counts, the skipped reasons and the unused columns cannot disagree with the
  module that classified the rows.

  Every outcome that leaves nothing to import — no file chosen yet, a file the
  browser is still sending or refused, a parse that returned a message, or a
  review with nothing to add or update — keeps the drawer open, disables the
  primary and says why in `#rosters-import-reason`. A row with a bad value is
  *not* one of those: it is skipped with its reason, the rest of the file still
  imports, and the primary names how many.
  """
  attr :open, :boolean, default: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :import_state, :map, required: true
  attr :on_close, :string, default: "cancel_operator_import"
  attr :on_apply, :string, default: "apply_operator_import"
  attr :on_cancel_upload, :string, default: "cancel_operator_upload"

  attr :on_validate, :string,
    default: "validate_operator_import",
    doc: "acknowledges the form change LiveView routes the file input's change through"

  def operator_import(assigns) do
    review = import_review(assigns.import_state, assigns.upload)
    {apply_count, disabled_reason} = import_apply_state(review, assigns.upload)

    assigns =
      assigns
      |> assign(review)
      |> assign(:counts, import_counts(review))
      |> assign(:apply_label, import_label(apply_count))
      |> assign(:importable?, is_nil(disabled_reason))
      |> assign(:disabled_reason, disabled_reason)
      |> assign(:error_message, import_error_message(assigns.import_state.stale?, review))

    ~H"""
    <.drawer
      id="rosters-operators-drawer"
      chrome="planner"
      open={@open}
      on_close={@on_close}
      title="Import operators"
      initial_focus={if @preview?, do: :first_field, else: :heading}
      initial_focus_id={if @preview?, do: "rosters-import-review-title", else: nil}
      return_focus_id={@import_state.opener_id}
      class="max-w-[640px]"
    >
      <:lede>
        <span id="rosters-operator-import-lede">Operators · shared by every version</span>
      </:lede>

      <%!-- LiveView starts a file upload from the input's change event, which it
      routes through the surrounding form, so the field needs one even though the
      drawer holds no other form state. --%>
      <form
        id="rosters-import-form"
        phx-change={@on_validate}
        phx-submit={@on_apply}
        class="flex min-h-0 flex-1 flex-col"
      >
        <.drawer_scroll>
          <div id="rosters-operator-import" class="grid gap-5">
            <p id="rosters-import-description" class="text-sm text-default">
              Add or update operators from a CSV file exported by your payroll or scheduling
              system. Nothing changes until you review the file and import it.
            </p>

            <.message
              :if={@error_message}
              id="rosters-import-error"
              kind="error"
              title="The file can't be imported."
              tabindex="-1"
            >
              {@error_message}
            </.message>

            <.upload_field
              id="rosters-import-file"
              upload={@upload}
              label="Operators file"
              help={@file_help}
              cancel_event={@on_cancel_upload}
            />

            <div :if={@preview?} id="rosters-import-review" class="grid gap-5">
              <h3
                id="rosters-import-review-title"
                tabindex="-1"
                class="text-base font-bold text-strong"
              >
                Review {@filename}
              </h3>

              <div class="flex flex-wrap gap-x-9 gap-y-4">
                <div :for={count <- @counts}>
                  <strong
                    id={count.id}
                    class="block font-display text-[28px] font-semibold leading-none tabular-nums text-strong"
                  >
                    {count.value}
                  </strong>
                  <span class="mt-1 block text-[13px] text-muted">{count.label}</span>
                </div>
              </div>

              <.message id="rosters-import-scope" kind="info" title="What gets imported">
                {operator_import_scope()}
              </.message>

              <div :if={@update_count > 0}>
                <h4 class="text-sm font-bold text-strong">Updated ({@update_count})</h4>
                <ul id="rosters-import-updated" class="mt-2 grid text-sm">
                  <li
                    :for={row <- @update_rows}
                    class="border-t border-subtle py-2 [overflow-wrap:anywhere]"
                  >
                    {update_note(row)}
                  </li>
                </ul>
                <p :if={@update_more > 0} class="text-[13px] text-muted">
                  {@update_more} more
                </p>
              </div>

              <div :if={@skipped_count > 0}>
                <h4 class="text-sm font-bold text-strong">Skipped rows ({@skipped_count})</h4>
                <ul id="rosters-import-skipped" class="mt-2 grid text-sm">
                  <li
                    :for={row <- @skipped_rows}
                    class="border-t border-subtle py-2 [overflow-wrap:anywhere]"
                  >
                    {skipped_note(row)}
                  </li>
                </ul>
                <p :if={@skipped_more > 0} class="text-[13px] text-muted">
                  {@skipped_more} more
                </p>
              </div>

              <div :if={@ignored_columns != []}>
                <h4 class="text-[13px] font-[650] text-default">
                  Columns not used:
                  <span id="rosters-import-ignored" class="font-mono font-normal text-muted">
                    {Enum.join(@ignored_columns, ", ")}
                  </span>
                </h4>
                <p class="mt-0.5 text-[13px] text-muted">Those values are never stored.</p>
              </div>
            </div>
          </div>
        </.drawer_scroll>

        <.drawer_footer>
          <p
            :if={@disabled_reason}
            id="rosters-import-reason"
            class="basis-full text-right text-[13px] text-muted"
          >
            {@disabled_reason}
          </p>
          <.button
            id="rosters-import-cancel"
            type="button"
            variant="secondary"
            class="min-h-11"
            phx-click={@on_close}
          >
            Cancel
          </.button>
          <.button
            id="rosters-import-apply"
            type="button"
            class="min-h-11"
            disabled={!@importable?}
            data-unavailable={!@importable?}
            aria-describedby={if @disabled_reason, do: "rosters-import-reason", else: nil}
            phx-click={@on_apply}
            phx-disable-with="Importing…"
          >
            {@apply_label}
          </.button>
        </.drawer_footer>
      </form>
    </.drawer>
    """
  end

  # What the drawer can say about the review it holds. Every count, note and the
  # unused columns come from the reviewed preview, so the screen cannot disagree
  # with `OperatorImport.classify/2` about what the file contained.
  defp import_review(%{preview: preview} = state, upload) do
    current? = is_map(preview) and upload.entries == [] and upload.errors == []
    add = if current?, do: preview.add, else: []
    update = if current?, do: preview.update, else: []
    skipped = if current?, do: preview.skipped, else: []

    %{
      stale?: state.stale?,
      preview?: current?,
      filename: state.filename,
      file_help: operators_file_help(),
      add_count: length(add),
      update_count: length(update),
      update_rows: Enum.take(update, @note_limit),
      update_more: max(length(update) - @note_limit, 0),
      skipped_count: length(skipped),
      skipped_rows: Enum.take(skipped, @note_limit),
      skipped_more: max(length(skipped) - @note_limit, 0),
      ignored_columns: if(current?, do: preview.ignored_columns, else: []),
      parse_error: state.parse_error
    }
  end

  # The primary is available only when applying this review would write
  # something. A skipped row is not a blocker: the file's other rows still
  # import, and the review names what was skipped.
  defp import_apply_state(review, upload) do
    apply_count = review.add_count + review.update_count

    reason =
      cond do
        upload.entries != [] or upload.errors != [] ->
          "Choose a different file to review."

        not review.preview? and is_binary(review.parse_error) ->
          "Choose a different file to review."

        not review.preview? ->
          "Choose a CSV file to review."

        apply_count == 0 ->
          "Nothing to import: every row is skipped."

        true ->
          nil
      end

    {apply_count, reason}
  end

  defp import_counts(%{add_count: add, update_count: update, skipped_count: skipped}) do
    [
      %{id: "rosters-import-count-add", label: "Add", value: add},
      %{id: "rosters-import-count-update", label: "Update", value: update},
      %{id: "rosters-import-count-skipped", label: "Skipped", value: skipped}
    ]
  end

  defp import_label(1), do: "Import 1 operator"
  defp import_label(0), do: "Import operators"
  defp import_label(count), do: "Import #{count} operators"

  defp import_error_message(true, _review), do: @stale_message
  defp import_error_message(false, %{parse_error: message}) when is_binary(message), do: message
  defp import_error_message(_stale?, _review), do: nil

  # The prototype's own sentence, kept as one string so the review and a test
  # quote the same copy.
  @operator_import_scope "Employee ID, display name and seniority number. An operator already here is updated from the file and keeps their line. Operators the file doesn't list stay as they are."

  defp operator_import_scope, do: @operator_import_scope

  defp operators_file_help do
    "One .csv or .txt file, up to 2 MB. Columns: employee_id, display_name and, if you use it, seniority_number."
  end

  # "Row 3 · E4101 · Bo Silva" for a row the file updates, and
  # "Row 4 · E4102 · Display name is blank." for a row it skips. The row number
  # and the ID are physical facts of the file and the last part is whatever the
  # classifier said, so a skipped row and an updated row read the same way
  # wherever they are quoted.
  defp update_note(row), do: "Row #{row.row} · #{row.employee_id} · #{row.display_name}"

  defp skipped_note(%{row: row, id: id, reason: reason}),
    do: "Row #{row}#{if id, do: " · #{id}"} · #{reason}"

  @doc """
  What an operator's held lines are about to be, in one sentence, or `nil` when
  they hold none.

  It is a clause list plus a verb, because the number of held lines decides
  both, and it is a public function rather than markup so that the wording has
  one home: the confirmation draws it, and a test asserts the sentence a reader
  is shown rather than the sentence the template happens to produce.
  """
  def open_lines_sentence([], _version_id), do: nil

  def open_lines_sentence(holdings, version_id) do
    # The version is named only when a line outside this one is involved: with
    # every line here, the reader is already looking at it.
    named? = Enum.any?(holdings, &(&1.gtfs_version_id != version_id))
    one? = length(holdings) == 1

    clauses =
      holdings
      |> Enum.map(&line_clause(&1, named?))
      |> join_clauses()
      # `String.capitalize/1` would downcase a version name mid-sentence;
      # `Wording.capitalize_first/1` upcases only the string's first grapheme.
      |> Wording.capitalize_first()

    "#{clauses} #{if one?, do: "becomes", else: "become"} Open."
  end

  defp line_clause(%{line_number: number, version_name: name}, true),
    do: "line #{number} in #{name}"

  defp line_clause(%{line_number: number}, _named?), do: "line #{number}"

  # "line 4", "line 4 and line 7", "line 4, line 7 and line 11".
  defp join_clauses([only]), do: only

  defp join_clauses([first | rest] = clauses) do
    joiner = if length(clauses) == 2, do: " and ", else: ", "

    Enum.join(Enum.intersperse(rest, joiner)) |> then(&(first <> joiner <> &1))
  end
end
